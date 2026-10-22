import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';
import 'kv_store.dart';

/// 一项缓存的占用明细。
class CacheEntry {
  const CacheEntry(this.label, this.bytes, {this.detail = ''});

  final String label;
  final int bytes;
  final String detail;

  String get readable => CacheManager.formatBytes(bytes);
}

/// 缓存管理：统一缓存目录 + 占用统计 + 清理。
///
/// ## 现状说明（别被「清理图片缓存」误导）
///
/// App 里封面用的是 `Image.network`，走的是 Flutter 内置的内存 [ImageCache]，
/// **并不落盘**（工程里虽然有 `cached_network_image` 依赖，但没有任何地方在用）。
/// 所以真正能被"清理"的是这三样：
/// - 内存图片缓存（`PaintingBinding.imageCache`，默认上限 100 MB）；
/// - 缓存目录下的临时文件（日志导出、图片落盘缓存等）；
/// - 本地歌曲封面的内存缓存。
///
/// 把内存缓存做成「可清理 + 可自定义上限」比伪造一个磁盘缓存目录更有意义。
class CacheManager {
  CacheManager._();

  static const String _prefs = 'cache';
  static const String _kRoot = 'root_dir';
  static const String _kMemoryLimitMb = 'memory_limit_mb';

  /// 应用在缓存目录下的子目录名。
  static const String imagesDirName = 'images';
  static const String miscDirName = 'misc';

  /// 解密页会把 file_picker 给的临时路径**复制**一份到本地再读——
  /// 移动端那个路径随时会被系统回收，副本必须活到解密结束。
  ///
  /// 这些副本是纯临时数据（几百 MB 很正常），所以放进受管缓存目录，
  /// 用户点「清理缓存」时能真删掉。之前它落在系统临时目录里，
  /// 既绕过了自定义路径，也永远清不掉。
  static const String tempDirName = 'tmp';

  /// 歌曲播放缓存（v2.4.0-fix2）。
  ///
  /// libmpv 自带的 `--cache-on-disk` 在本项目用法下不落盘（见
  /// `player/playback_cache.dart` 顶部说明），所以播放缓存由 App 自己写：
  /// 酷我加密音轨走本地解密中继，中继把解密后的音频按 256 KiB 块落在这里。
  /// 「清理缓存」会连它一起清空。
  static const String playbackDirName = 'playback';

  /// [clear] 会清空内容的子目录。
  ///
  /// **统计与清理必须用同一个列表**（[breakdown] 也用它）：
  /// 之前 breakdown 额外统计了系统临时目录而 clear 不删，
  /// 移动端两者还指向同一个 app cache 目录（父与子），
  /// 于是数字清完几乎不降——用户只会看到「点了没反应」。
  static const List<String> managedDirNames = [
    imagesDirName,
    miscDirName,
    tempDirName,
    playbackDirName,
  ];

  /// libmpv 在各平台的默认缓存目录（best-effort，只为「顺手清掉」）。
  ///
  /// media_kit 把 `cache-on-disk` 打开了，而 `PlayerConfiguration` 不暴露
  /// `cache-dir`、`NativePlayer._create()` 的 options 又是硬编码的，
  /// 外部没法在 `mpv_initialize()` 之前改缓存目录。万一某个版本/某个平台
  /// 真的往这里写了东西，「清理缓存」至少能把历史残留扫掉。
  ///
  /// 只在**没有在播放**时才由 [clearPlaybackExtras] 处理——播放中删活动
  /// 句柄在 Windows 上会直接失败，在 POSIX 上也可能让 libmpv 读错数据。
  static List<Directory> libmpvDefaultCacheDirs() {
    final out = <Directory>[];
    try {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null || home.isEmpty) return out;
      if (Platform.isLinux || Platform.isAndroid) {
        final xdg = Platform.environment['XDG_CACHE_HOME'];
        final base = (xdg != null && xdg.isNotEmpty)
            ? xdg
            : '$home${Platform.pathSeparator}.cache';
        out.add(Directory('$base${Platform.pathSeparator}mpv'));
      } else if (Platform.isMacOS) {
        out.add(Directory(
            '$home${Platform.pathSeparator}Library${Platform.pathSeparator}Caches${Platform.pathSeparator}mpv'));
      } else if (Platform.isWindows) {
        final local = Platform.environment['LOCALAPPDATA'];
        if (local != null && local.isNotEmpty) {
          out.add(Directory('$local${Platform.pathSeparator}mpv${Platform.pathSeparator}cache'));
        }
      }
    } catch (_) {}
    return out;
  }

  /// 受管目录的绝对路径。
  static Future<List<Directory>> managedDirs() async {
    final root = await cacheRoot();
    return [
      for (final name in managedDirNames)
        Directory('${root.path}${Platform.pathSeparator}$name'),
    ];
  }

  static String? _runtimeRoot;

  /// 用户自定义的缓存目录；为空表示用系统默认。
  static String get customRoot =>
      KvStore.instance.getString('$_prefs:$_kRoot') ?? '';

  /// 自定义目录的标记文件。目录里没有它就说明不是我们建的缓存目录，
  /// 拒绝使用——否则用户误选了「文档」这类目录，一次「清理缓存」就把
  /// 整个目录连根拔起了。
  static const String _kMarker = '.baiji_cache';

  static Future<void> setCustomRoot(String? path) async {
    if (path == null || path.trim().isEmpty) {
      await KvStore.instance.remove('$_prefs:$_kRoot');
      _runtimeRoot = null;
    } else {
      final dir = Directory(path.trim());
      await dir.create(recursive: true);
      final marker = File(
          '${dir.path}${Platform.pathSeparator}$_kMarker');
      if (!await marker.exists()) {
        // 只在空目录里写标记；目录里已有其它文件说明用户选错了地方
        var entries = 0;
        try {
          await for (final _ in dir.list(followLinks: false)) {
            if (++entries >= 1) break;
          }
        } catch (_) {}
        if (entries > 0) {
          throw StateError(
              '所选目录里已有其它文件，为避免误删请改选一个空目录或新建目录');
        }
        await marker.writeAsString('baiji music cache');
      }
      await KvStore.instance.setString('$_prefs:$_kRoot', dir.path);
      _runtimeRoot = dir.path;
    }
    AppLog.i('CacheManager', '缓存目录已设为 ${await cacheRoot()}');
  }

  /// 当前生效的缓存根目录。自定义目录不存在时自动退回默认目录，
  /// 免得用户把目录删了之后整个 App 的缓存读写全崩。
  static Future<Directory> cacheRoot() async {
    final custom = _runtimeRoot ?? customRoot;
    if (custom.isNotEmpty) {
      final dir = Directory(custom);
      if (await dir.exists()) return dir;
      AppLog.w('CacheManager', '自定义缓存目录不存在，改用默认目录: $custom');
    }
    final dir = await getApplicationCacheDirectory();
    return Directory('${dir.path}${Platform.pathSeparator}$_prefs');
  }

  /// 在缓存目录下取一个子目录，不存在则创建。
  static Future<Directory> subDir(String name) async {
    final root = await cacheRoot();
    final dir = Directory(
        '${root.path}${Platform.pathSeparator}$name');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 缓存目录下的一个文件路径（不保证存在）。
  static Future<File> cacheFile(String name) async =>
      File('${(await subDir(miscDirName)).path}${Platform.pathSeparator}$name');

  /// 内存图片缓存上限（MB）。
  static int get memoryLimitMb {
    final v = KvStore.instance.getInt('$_prefs:$_kMemoryLimitMb', def: 100);
    return v.clamp(16, 1024);
  }

  static Future<void> setMemoryLimitMb(int mb) =>
      KvStore.instance.setInt('$_prefs:$_kMemoryLimitMb', mb.clamp(16, 1024));

  /// 把内存图片缓存上限应用到当前进程（重启后失效，所以每次启动都要设一次）。
  static void applyMemoryLimit() {
    PaintingBinding.instance.imageCache.maximumSize = memoryLimitMb * 1024 * 1024;
  }

  /// 递归统计目录占用；目录不存在返回 0。
  static Future<int> dirSize(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {
            // 文件正被占用 / 已删除，跳过
          }
        }
      }
    } catch (_) {
      // 权限不足等
    }
    return total;
  }

  /// 各类缓存占用明细。
  ///
  /// **统计口径必须与 [clear] 完全一致**——只统计不清理的条目会让
  /// 「占用」和「清完之后的占用」对不上，用户只会觉得清理没生效。
  static Future<List<CacheEntry>> breakdown() async {
    final out = <CacheEntry>[];

    final cache = PaintingBinding.instance.imageCache;
    final live = cache.liveImageCount;
    out.add(CacheEntry(
      '内存图片缓存',
      cache.currentSizeBytes,
      detail: '$live 张在用 / 上限 $memoryLimitMb MB',
    ));

    final dirs = await managedDirs();
    var cacheBytes = 0;
    for (final dir in dirs) {
      cacheBytes += await dirSize(dir);
    }
    final root = await cacheRoot();
    out.add(CacheEntry(
      '缓存目录',
      cacheBytes,
      detail: '${root.path}\n（${managedDirNames.join(' / ')}，清理时会全部清空）',
    ));

    // 歌曲播放缓存（v2.4.0-fix2）：受管的 playback 目录 + libmpv 默认缓存目录残留
    var playbackBytes = 0;
    final playbackDir = Directory(
        '${root.path}${Platform.pathSeparator}$playbackDirName');
    playbackBytes += await dirSize(playbackDir);
    final libmpvDirs = libmpvDefaultCacheDirs();
    for (final d in libmpvDirs) {
      // 自定义缓存根目录可能就在 libmpv 目录里，别重复统计
      if (d.path == root.path || root.path.startsWith('$d.path${Platform.pathSeparator}')) {
        continue;
      }
      playbackBytes += await dirSize(d);
    }
    out.add(CacheEntry(
      '歌曲播放缓存',
      playbackBytes,
      detail: playbackBytes > 0
          ? '${playbackDir.path}\n${libmpvDirs.isEmpty ? '' : '（含 libmpv 缓存目录 ${libmpvDirs.map((d) => d.path).join(' / ')}）'}'
          : '酷我加密音轨的边下边播缓存，按 256 KiB 块落盘',
    ));

    return out;
  }

  static Future<int> totalBytes() async {
    var sum = 0;
    for (final e in await breakdown()) {
      sum += e.bytes;
    }
    return sum;
  }

  /// 清理缓存。
  ///
  /// **不碰**下载目录、历史记录、歌单与本地音乐库——那些是用户数据不是缓存。
  /// 内存图片缓存会被整个清空，当前正在显示的封面会重新加载一次。
  ///
  /// 注意本地歌曲封面另有一份独立的字节缓存（`LocalCoverCache`，在 ui 层，
  /// 200 条上限），由设置页在调用本方法后一并清掉——core 不反向依赖 ui。
  ///
  /// [onIssue] 用来回传删不掉的条目：静默吞掉异常会让「权限不足」
  /// 表现为「点了没反应」，比报错更让人困惑。
  static Future<int> clear({void Function(String path, String reason)? onIssue}) async {
    var freed = 0;

    // 整个内存缓存清空：正在显示的封面会闪一下并重新请求一次
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();

    // 清空 [managedDirNames] 里的全部子目录，范围与 breakdown() 严格一致。
    // 只删 App 自己建的目录，不碰根目录下用户可能自己放的东西。
    for (final dir in await managedDirs()) {
      freed += await emptyDir(dir, onIssue);
    }

    // libmpv 的默认缓存目录（v2.4.0-fix2）：见 [libmpvDefaultCacheDirs]。
    // 由调用方通过 [clearPlaybackExtras] 在确认没有在播放时单独触发，
    // 这里不重复处理。

    AppLog.i('CacheManager', '缓存已清理，释放约 ${formatBytes(freed)}');
    return freed;
  }

  /// 清理「歌曲播放缓存」里**不属于** [managedDirNames] 的部分——
  /// 即 libmpv 在各平台的默认缓存目录残留。
  ///
  /// **必须在确认没有在播放时调用**：播放中删 libmpv 的活动缓存文件，
  /// Windows 上会直接失败，POSIX 上也可能让它读到截断的数据。
  /// 返回释放的字节数。
  static Future<int> clearPlaybackExtras(
      {void Function(String path, String reason)? onIssue}) async {
    var freed = 0;
    final root = await cacheRoot();
    for (final dir in libmpvDefaultCacheDirs()) {
      if (dir.path == root.path ||
          root.path.startsWith('$dir.path${Platform.pathSeparator}')) {
        continue;
      }
      if (!await dir.exists()) continue;
      freed += await emptyDir(dir, onIssue);
    }
    if (freed > 0) {
      AppLog.i('CacheManager', 'libmpv 缓存目录已清理，释放约 ${formatBytes(freed)}');
    }
    return freed;
  }

  /// 清空目录内容但保留目录本身。返回释放的字节数。
  static Future<int> emptyDir(Directory dir,
      [void Function(String path, String reason)? onIssue]) async {
    if (!await dir.exists()) return 0;
    var freed = 0;
    try {
      await for (final e in dir.list(followLinks: false)) {
        try {
          if (e is File) {
            freed += await e.length();
            await e.delete();
          } else if (e is Directory) {
            freed += await dirSize(e);
            await e.delete(recursive: true);
          }
        } catch (err) {
          // 单个文件删不掉（占用中 / 权限不足）不影响其它，但要如实上报。
          onIssue?.call(e.path, '$err');
          AppLog.w('CacheManager', '删除失败 ${e.path}: $err');
        }
      }
    } catch (err) {
      onIssue?.call(dir.path, '$err');
      AppLog.w('CacheManager', '遍历目录失败 ${dir.path}: $err');
    }
    return freed;
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    final s = v >= 100 || i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '$s ${units[i]}';
  }
}