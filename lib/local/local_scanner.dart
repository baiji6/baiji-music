/// 本地音乐扫描：遍历目录、读取元数据、产出可直接播放的 [Song]。
///
/// **两段式设计**：
/// 1. 枚举阶段——先把所有候选文件列出来（只 stat，不读内容），好让 UI
///    能显示确定的进度分母；
/// 2. 解析阶段——逐个读元数据。这一步放在 `Isolate` 里跑，几千个文件
///    也不会卡住 UI。
///
/// **增量扫描**：用「文件大小 + 修改时间」做指纹。指纹没变的文件直接复用
/// 上次的结果，不重新读盘，第二次扫描几乎是瞬时的。
///
/// **内存控制**：扫描阶段刻意不读封面和内嵌歌词（几千张封面会吃掉几百 MB），
/// 只存索引。封面和歌词在播放时由 `AudioReader` 按需读取。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/metadata/audio_reader.dart';
import 'package:baiji_music/models/models.dart';

/// 支持的音频扩展名（小写）。
const Set<String> kAudioExtensions = <String>{
  'mp3',
  'flac',
  'm4a',
  'mp4',
  'm4b',
  'aac',
  'ogg',
  'opus',
  'oga',
  'wav',
  'wave',
};

/// 单个文件的增量指纹：大小 + 修改时间。
class LocalFingerprint {
  const LocalFingerprint(this.size, this.mtimeMs);

  final int size;
  final int mtimeMs;

  Map<String, dynamic> toJson() => {'s': size, 'm': mtimeMs};

  static LocalFingerprint? fromJson(dynamic v) {
    if (v is! Map) return null;
    return LocalFingerprint(
      (v['s'] as num?)?.toInt() ?? 0,
      (v['m'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LocalFingerprint &&
      other.size == size &&
      other.mtimeMs == mtimeMs;

  @override
  int get hashCode => Object.hash(size, mtimeMs);
}

/// 扫描进度。
class LocalScanProgress {
  const LocalScanProgress(this.done, this.total, this.currentFile);

  final int done;
  final int total;

  /// 当前正在处理的文件名（仅用于展示，可能是路径末段）。
  final String currentFile;

  double get ratio => total <= 0 ? 0 : done / total;
}

/// 扫描结果。
class LocalScanResult {
  const LocalScanResult({
    required this.songs,
    required this.missing,
    required this.reusedCount,
    required this.parsedCount,
    required this.failedCount,
  });

  /// 当前所有有效歌曲：含本次新解析的 + 指纹未变直接复用的。
  final List<Song> songs;

  /// 上次有记录、这次却找不到的路径（文件被删了或目录不可访问）。
  final List<String> missing;

  /// 指纹未变、直接复用旧结果的文件数。
  final int reusedCount;

  /// 本次真正读了元数据的文件数。
  final int parsedCount;

  /// 读取失败被跳过的文件数。
  final int failedCount;

  @override
  String toString() =>
      'LocalScanResult(${songs.length} 首 / 复用 $reusedCount / 新解析 $parsedCount / 失败 $failedCount)';
}

// ==================== 对外入口 ====================

class LocalScanner {
  LocalScanner._();

  /// 扫描 [dirs] 下的音频文件。
  ///
  /// [known] 是上次的「路径 → 指纹 + 歌曲」缓存；指纹一致的文件不再读盘。
  /// [force] 为 true 时忽略指纹，全部重扫。
  /// [onProgress] 由主线程回调（通过 Isolate 消息转发），可安全更新 UI。
  static Future<LocalScanResult> scan({
    required List<String> dirs,
    Map<String, Song> known = const {},
    Map<String, LocalFingerprint> knownFingerprints = const {},
    bool force = false,
    void Function(LocalScanProgress progress)? onProgress,
  }) async {
    final port = ReceivePort();
    final completer = Completer<LocalScanResult>();
    StreamSubscription<dynamic>? sub;

    sub = port.listen((msg) {
      if (msg is _ProgressMsg) {
        onProgress?.call(LocalScanProgress(msg.done, msg.total, msg.file));
      } else if (msg is _DoneMsg) {
        completer.complete(msg.result);
      } else if (msg is _ErrorMsg) {
        completer.completeError(msg.error, msg.stack);
      }
    });

    Isolate? worker;
    try {
      worker = await Isolate.spawn(
        _scanEntry,
        _ScanRequest(
          dirs: dirs,
          known: known,
          knownFingerprints: knownFingerprints,
          force: force,
          sendPort: port.sendPort,
        ),
      );

      // 兜底：worker 若被 OOM 或平台限制直接杀掉，一条消息都不会发回来，
      // 那时 `completer.future` 会永久挂起，UI 一直卡在「扫描中」。
      // 给个上限，超时后连 isolate 一起回收。
      try {
        return await completer.future
            .timeout(const Duration(minutes: 10));
      } on TimeoutException {
        worker.kill(priority: Isolate.immediate);
        rethrow;
      }
    } finally {
      await sub.cancel();
      port.close();
    }
  }

  /// 同步扫描（无 Isolate）。仅供测试与「就想阻塞一下」的场景使用。
  static LocalScanResult scanSync({
    required List<String> dirs,
    Map<String, Song> known = const {},
    Map<String, LocalFingerprint> knownFingerprints = const {},
    bool force = false,
    void Function(LocalScanProgress progress)? onProgress,
  }) =>
      _scanSync(
        dirs: dirs,
        known: known,
        knownFingerprints: knownFingerprints,
        force: force,
        onProgress: onProgress,
      );

  /// 各平台的常见音乐目录（已过滤掉不存在的）。
  static Future<List<String>> defaultDirs() async {
    final out = <String>[];

    void add(String? p) {
      if (p == null || p.isEmpty) return;
      if (!out.contains(p)) out.add(p);
    }

    final sep = Platform.pathSeparator;

    // 应用自己的下载目录（桌面端在 Downloads，移动端在外部存储）
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final ext = await getExternalStorageDirectory();
        add(ext?.path);
      } else {
        final dl = await getDownloadsDirectory();
        add(dl?.path);
      }
    } catch (e) {
      AppLog.w('LocalScanner', '获取下载目录失败: $e');
    }

    if (Platform.isAndroid) {
      // 国内常见音乐 App 的落盘位置
      for (final p in <String>[
        '/sdcard/Music',
        '/sdcard/Download',
        '/sdcard/Movies',
        '/sdcard/netease/cloudmusic/Music',
        '/sdcard/qqmusic/song',
        '/sdcard/KuwoMusic/music',
        '/sdcard/kgmusic/download',
      ]) {
        add(p);
      }
    } else if (!Platform.isIOS) {
      // 桌面端：HOME 下的音乐 / 下载
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '';
      if (home.isNotEmpty) {
        add('$home${sep}Music');
        add('$home${sep}Downloads');
      }
    }
    // iOS 沙盒内没有公共音乐目录，交给文件选择器

    return out.where((p) => Directory(p).existsSync()).toList();
  }

  /// 申请扫描所需的权限。桌面端与 iOS 恒为 true。
  ///
  /// 只有 **Android** 需要真正请求：
  /// - Android 13+ 用 `READ_MEDIA_AUDIO`（manifest 里已声明），
  ///   更早版本用 `storage`；若还想扫到媒体库未收录的文件，
  ///   还需要「所有文件访问权限」，拿不到也不致命——公共音乐目录仍可读。
  /// - iOS 沙盒里根本访问不到公共音乐目录，任何权限都没有意义；
  ///   那里只能靠 `file_picker` 让用户自己选目录，不需要预先授权。
  ///   而且 iOS 上的 `storage`/`audio` 缺少对应 Info.plist key 时，
  ///   `request()` 会直接失败，还不如不请求。
  /// - macOS / Windows / Linux 没有运行时存储权限这一说。
  static Future<bool> ensurePermission() async {
    if (!Platform.isAndroid) return true;

    try {
      var st = await Permission.audio.status;
      if (!st.isGranted) st = await Permission.audio.request();
      if (st.isGranted) return true;

      // 被永久拒绝时引导到设置页，比反复弹窗体验好
      if (st.isPermanentlyDenied) {
        await openAppSettings();
        return false;
      }

      // Android 13 以下没有 media audio 权限，退回 storage
      final s = await Permission.storage.status;
      if (s.isGranted) return true;
      final r = await Permission.storage.request();
      return r.isGranted;
    } catch (e) {
      AppLog.w('LocalScanner', '权限申请异常: $e');
      return false;
    }
  }

  /// 读取某首本地歌的歌词：优先同目录同名 .lrc，其次文件内嵌。
  Future<String> readLyric(Song song) => LocalScanner.readLyricFor(song);

  /// 播放用的 URI（media_kit 认 `file://`）。文件已不存在时返回空串。
  ///
  /// `Uri.file` 负责处理 Windows 盘符、路径里的空格与中文，
  /// 不要手工拼 `'file://' + path`。
  static String playUri(Song song) {
    final p = song.localPath;
    if (p.isEmpty) return '';
    try {
      if (!File(p).existsSync()) return '';
    } catch (_) {
      return '';
    }
    return Uri.file(p).toString();
  }

  /// 静态版本，便于在 Isolate 或任意位置调用。
  static Future<String> readLyricFor(Song song) async {
    final path = song.localPath;
    if (path.isEmpty) return '';

    // 1) 外部 .lrc（用户自己放的，优先级最高）
    final external = _readExternalLyric(path);
    if (external != null && external.trim().isNotEmpty) return external;

    // 2) 文件内嵌
    try {
      final m = await AudioReader.read(path, withCover: false);
      return m.lyric;
    } catch (e) {
      AppLog.w('LocalScanner', '读取内嵌歌词失败: $e');
      return '';
    }
  }

  /// 读取某首本地歌的封面字节（播放页展示用，按需读取）。
  static Future<Uint8List?> readCover(Song song) async {
    final path = song.localPath;
    if (path.isEmpty) return null;
    try {
      final m = await AudioReader.read(path, withLyric: false);
      return m.coverBytes;
    } catch (e) {
      AppLog.w('LocalScanner', '读取内嵌封面失败: $e');
      return null;
    }
  }
}

// ==================== Isolate 消息 ====================

class _ScanRequest {
  const _ScanRequest({
    required this.dirs,
    required this.known,
    required this.knownFingerprints,
    required this.force,
    required this.sendPort,
  });

  final List<String> dirs;
  final Map<String, Song> known;
  final Map<String, LocalFingerprint> knownFingerprints;
  final bool force;
  final SendPort sendPort;
}

class _ProgressMsg {
  const _ProgressMsg(this.done, this.total, this.file);

  final int done;
  final int total;
  final String file;
}

class _DoneMsg {
  const _DoneMsg(this.result);

  final LocalScanResult result;
}

class _ErrorMsg {
  const _ErrorMsg(this.error, this.stack);

  final Object error;
  final StackTrace stack;
}

/// Isolate 入口（必须是顶层函数或静态方法）。
void _scanEntry(_ScanRequest req) {
  try {
    final r = _scanSync(
      dirs: req.dirs,
      known: req.known,
      knownFingerprints: req.knownFingerprints,
      force: req.force,
      onProgress: (p) => req.sendPort.send(_ProgressMsg(p.done, p.total, p.currentFile)),
    );
    req.sendPort.send(_DoneMsg(r));
  } catch (e, st) {
    req.sendPort.send(_ErrorMsg(e, st));
  }
}

// ==================== 扫描实现 ====================

LocalScanResult _scanSync({
  required List<String> dirs,
  required Map<String, Song> known,
  required Map<String, LocalFingerprint> knownFingerprints,
  required bool force,
  void Function(LocalScanProgress progress)? onProgress,
}) {
  // ---- 阶段一：枚举 ----
  final files = <String>[];
  for (final d in dirs) {
    _collectFiles(Directory(d), files);
  }

  final total = files.length;
  final songs = <Song>[];
  final seen = <String>{};
  var reused = 0;
  var parsed = 0;
  var failed = 0;

  for (var i = 0; i < files.length; i++) {
    final path = files[i];
    seen.add(path);

    // 每 16 个文件报一次进度，避免消息刷屏
    if (onProgress != null && (i % 16 == 0 || i == files.length - 1)) {
      onProgress(LocalScanProgress(i, total, path));
    }

    final stat = _safeStat(path);
    if (stat == null) {
      failed++;
      continue;
    }
    final fp = LocalFingerprint(stat.size, stat.mtimeMs);

    // ---- 增量：指纹没变就复用 ----
    if (!force) {
      final old = knownFingerprints[path];
      final cached = known[path];
      if (old != null && old == fp && cached != null) {
        songs.add(cached);
        reused++;
        continue;
      }
    }

    // ---- 解析元数据 ----
    final meta = AudioReader.readSync(path, withCover: false, withLyric: false);
    if (meta.format.isEmpty) {
      failed++;
      continue;
    }
    // 各容器在「打不开」时仍会返回带 format 的空对象，单看 format 无法
    // 区分「无标签的正常音频」和「根本不是音频的残片」。用「既无标签又
    // 无时长」来判定后者——真实音频哪怕没标签也读得出时长。
    if (!meta.hasTags && meta.durationMs <= 0) {
      failed++;
      continue;
    }

    songs.add(_toSong(path, meta, fp));
    parsed++;
  }

  // ---- 上次有、这次没扫到的，视为已删除 ----
  final missing = known.keys.where((p) => !seen.contains(p)).toList();

  // 按「艺术家 → 专辑 → 标题」排序，列表看起来更整齐
  songs.sort(_compareSongs);

  if (onProgress != null) {
    onProgress(LocalScanProgress(total, total, ''));
  }

  return LocalScanResult(
    songs: songs,
    missing: missing,
    reusedCount: reused,
    parsedCount: parsed,
    failedCount: failed,
  );
}

/// 递归收集目录下的音频文件。
///
/// 跳过以 `.` 开头的隐藏目录（`.git`、`.cache` 等），
/// 并对单目录文件数设上限，防止误扫到系统目录时卡死。
void _collectFiles(Directory dir, List<String> out, {int depth = 0}) {
  if (depth > 8) return;
  try {
    if (!dir.existsSync()) return;
    for (final e in dir.listSync(followLinks: false)) {
      if (e is Directory) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) continue;
        _collectFiles(e, out, depth: depth + 1);
      } else if (e is File) {
        if (_isAudio(e.path)) out.add(e.path);
      }
    }
  } catch (e) {
    // 无权限 / 已删除 / 符号链接环，统统跳过
    AppLog.w('LocalScanner', '遍历 ${dir.path} 失败: $e');
  }
}

bool _isAudio(String path) {
  final name = path.split(Platform.pathSeparator).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return false;
  return kAudioExtensions.contains(name.substring(dot + 1).toLowerCase());
}

class _Stat {
  const _Stat(this.size, this.mtimeMs);

  final int size;
  final int mtimeMs;
}

_Stat? _safeStat(String path) {
  try {
    final s = File(path).statSync();
    if (s.type == FileSystemEntityType.notFound) return null;
    return _Stat(s.size, s.modified.millisecondsSinceEpoch);
  } catch (_) {
    return null;
  }
}

/// 元数据 + 文件路径 → Song。
///
/// 标签优先，文件名兜底：没有任何内嵌标签时，把
/// 「歌手 - 歌名.mp3」这类文件名拆开用。
Song _toSong(String path, AudioMetadata meta, LocalFingerprint fp) {
  final name = path.split(Platform.pathSeparator).last;
  final base = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;

  var title = meta.title;
  var artist = meta.artist;

  if (!meta.hasTags) {
    final guessed = AudioReader.parseFileName(path);
    title = guessed.$1;
    artist = guessed.$2;
  } else {
    if (title.isEmpty) title = base;
  }

  return Song(
    // 路径即唯一标识：重命名后会被当成新歌，但比内容哈希便宜得多
    mid: path,
    songId: path.hashCode & 0x7FFFFFFF,
    name: title,
    singer: artist,
    album: meta.album,
    albumMid: '',
    duration: meta.durationMs,
    cover: '',
    source: Source.local,
    localPath: path,
    localSize: fp.size,
    localMtime: fp.mtimeMs,
    format: meta.format,
  );
}

/// 列出排序：艺术家 → 专辑 → 标题，全空的名字排最后。
int _compareSongs(Song a, Song b) {
  final an = a.singer.isEmpty ? '\uFFFF' : a.singer;
  final bn = b.singer.isEmpty ? '\uFFFF' : b.singer;
  var c = an.compareTo(bn);
  if (c != 0) return c;

  final aa = a.album.isEmpty ? '\uFFFF' : a.album;
  final ba = b.album.isEmpty ? '\uFFFF' : b.album;
  c = aa.compareTo(ba);
  if (c != 0) return c;

  return a.name.compareTo(b.name);
}

/// 外部歌词：与音频同目录、同名，扩展名为 .lrc。
String? _readExternalLyric(String audioPath) {
  final dot = audioPath.lastIndexOf('.');
  if (dot <= 0) return null;
  final base = audioPath.substring(0, dot);
  for (final ext in <String>['.lrc', '.LRC']) {
    final f = File('$base$ext');
    try {
      if (f.existsSync()) return f.readAsStringSync();
    } catch (_) {
      // 读不了就试下一个
    }
  }
  return null;
}
