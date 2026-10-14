import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/download/download_extras.dart';
import 'package:baiji_music/models/models.dart';

import 'download_manager.dart';

/// 单个下载任务的状态。
enum DownloadTaskState {
  /// 已入队，等待取直链
  queued('等待中'),

  /// 正在取直链 / 已拿到直链还没开始收字节
  preparing('准备中'),

  /// 正在接收数据
  downloading('下载中'),

  /// 音频落盘，正在补歌词/封面
  finalizing('补齐附属文件'),

  /// 成功
  done('已完成'),

  /// 失败（可重试）
  failed('失败'),

  /// 用户取消
  canceled('已取消');

  const DownloadTaskState(this.label);

  final String label;

  bool get isTerminal =>
      this == DownloadTaskState.done ||
      this == DownloadTaskState.failed ||
      this == DownloadTaskState.canceled;

  bool get isActive => !isTerminal;
}

/// 一个下载任务的完整状态快照。
///
/// 之所以做成**不可变快照**而不是可变对象：任务列表要在多处被同时观察
/// （下载页、播放页迷你条、搜索页提示），可变对象在这些地方容易读到
/// 撕裂的中间态。每次变更产生新实例并广播，UI 只需重建。
class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.song,
    required this.state,
    required this.createdAt,
    this.received = 0,
    this.total = -1,
    this.filePath = '',
    this.error = '',
    this.extras = '',
    this.qualityLabel = '',
    this.bytesPerSecond = 0,
    this.finishedAt,
  });

  /// 任务唯一 id（时间戳 + 歌曲标识，够用且无需额外依赖）。
  final String id;

  /// 原始网络歌曲（保留歌名/歌手/封面/音质档，落盘后可直接当本地曲播放）。
  final Song song;

  final DownloadTaskState state;

  /// 入队时间（毫秒时间戳）。
  final int createdAt;

  /// 已下载字节。
  final int received;

  /// 总字节；服务端未给出长度时为 -1，表示不确定。
  final int total;

  /// 完成后的文件绝对路径。
  final String filePath;

  /// 失败原因。
  final String error;

  /// 已补齐的附属文件说明（如"歌词 + 封面"）。
  final String extras;

  /// 实际生效音质。
  final String qualityLabel;

  /// 平均速度（字节/秒），用于展示。
  final int bytesPerSecond;

  /// 完成时间（毫秒时间戳）。
  final int? finishedAt;

  /// 进度 0~1；总长未知时返回 null（不确定进度）。
  double? get ratio {
    if (state == DownloadTaskState.done) return 1;
    if (total <= 0) return null;
    return (received / total).clamp(0.0, 1.0);
  }

  bool get isIndeterminate => total <= 0;

  String get displayName => song.name;

  DownloadTask copyWith({
    DownloadTaskState? state,
    int? received,
    int? total,
    String? filePath,
    String? error,
    String? extras,
    String? qualityLabel,
    int? bytesPerSecond,
    int? finishedAt,
  }) =>
      DownloadTask(
        id: id,
        song: song,
        state: state ?? this.state,
        createdAt: createdAt,
        received: received ?? this.received,
        total: total ?? this.total,
        filePath: filePath ?? this.filePath,
        error: error ?? this.error,
        extras: extras ?? this.extras,
        qualityLabel: qualityLabel ?? this.qualityLabel,
        bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
        finishedAt: finishedAt ?? this.finishedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'song': song.toJson(),
        'received': received,
        'total': total,
        'filePath': filePath,
        'extras': extras,
        'qualityLabel': qualityLabel,
        'finishedAt': finishedAt ?? 0,
      };

  /// 从持久化数据恢复。**只恢复已完成任务**——进行中的任务在进程被杀后
  /// 必然已中断，恢复成"下载中"是撒谎。
  static DownloadTask? fromJson(Map<String, dynamic> m) {
    final path = m['filePath'] as String? ?? '';
    if (path.isEmpty) return null;
    final songRaw = m['song'];
    if (songRaw is! Map) return null;
    final at = (m['finishedAt'] as num?)?.toInt() ?? 0;
    return DownloadTask(
      id: m['id'] as String? ?? path,
      song: Song.fromJson(Map<String, dynamic>.from(songRaw)),
      state: DownloadTaskState.done,
      createdAt: at,
      received: (m['received'] as num?)?.toInt() ?? 0,
      total: (m['total'] as num?)?.toInt() ?? -1,
      filePath: path,
      extras: m['extras'] as String? ?? '',
      qualityLabel: m['qualityLabel'] as String? ?? '',
      bytesPerSecond: 0,
      finishedAt: at == 0 ? null : at,
    );
  }
}

/// 下载任务注册表：把"下载"从一次性 Future 变成**可观察的队列**。
///
/// 之前 `DownloadManager.download()` 只是个阻塞 Future，调用方拿一个
/// `_downloadProgress` 局部变量渲染进度条：切页就没了、搜索页完全没反馈、
/// 下载完也点不到。这里持有全局任务列表并广播变更，任意页面都能订阅。
class DownloadTaskRegistry {
  DownloadTaskRegistry._();

  static final DownloadTaskRegistry instance = DownloadTaskRegistry._();

  static const String _prefs = 'download_prefs';
  static const String _keyHistory = 'download_history';

  final List<DownloadTask> _tasks = [];

  /// 保留的最大已完成任务数（历史太长发文件、渲染也慢）。
  static const int maxDone = 100;

  final StreamController<List<DownloadTask>> _changes =
      StreamController<List<DownloadTask>>.broadcast();

  /// 只读快照，顺序为「进行中在前、最新在后」。
  List<DownloadTask> get tasks {
    final active = _tasks.where((t) => t.state.isActive).toList();
    final done = _tasks.where((t) => !t.state.isActive).toList();
    return [...active, ...done];
  }

  List<DownloadTask> get activeTasks =>
      _tasks.where((t) => t.state.isActive).toList();

  int get activeCount => activeTasks.length;

  Stream<List<DownloadTask>> get changes => _changes.stream;

  // ===== 对外操作 =====

  /// 登记一个新任务（状态 [DownloadTaskState.queued]）。
  DownloadTask enqueue(Song song) {
    final task = DownloadTask(
      id: '${DateTime.now().microsecondsSinceEpoch}#${song.mid}',
      song: song,
      state: DownloadTaskState.queued,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    _tasks.insert(0, task);
    _emit();
    return task;
  }

  /// 就地更新某个任务并广播。
  void update(String id, DownloadTask Function(DownloadTask) patch) {
    final i = _tasks.indexWhere((t) => t.id == id);
    if (i < 0) return;
    _tasks[i] = patch(_tasks[i]);
    if (_tasks[i].state.isTerminal) {
      _trimDone();
      _persist();
    }
    _emit();
  }

  /// 移除一个任务（只在终态下允许移除）。
  bool remove(String id) {
    final i = _tasks.indexWhere((t) => t.id == id);
    if (i < 0) return false;
    if (_tasks[i].state.isActive) return false; // 进行中要先取消
    _tasks.removeAt(i);
    _persist();
    _emit();
    return true;
  }

  /// 清除全部终态任务，返回清除条数。
  int clearFinished() {
    final before = _tasks.length;
    _tasks.removeWhere((t) => t.state.isTerminal);
    final n = before - _tasks.length;
    if (n > 0) {
      _persist();
      _emit();
    }
    return n;
  }

  /// 进程重启后恢复历史（已完成）任务，并剔除文件已不存在的条目。
  Future<void> restore() async {
    if (_tasks.isNotEmpty) return;
    final raw = KvStore.instance.getString('$_prefs:$_keyHistory');
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final list = decoded;
      var changed = false;
      for (final m in list) {
        final t = DownloadTask.fromJson(m);
        if (t == null) continue;
        if (!fileExists(t.filePath)) {
          changed = true;
          continue;
        }
        _tasks.add(t);
      }
      if (changed) _persist();
      _emit();
    } catch (e) {
      AppLog.w('DownloadTaskRegistry', '恢复下载历史失败: $e');
    }
  }

  // ===== 内部 =====

  void _emit() {
    if (_changes.isClosed) return;
    _changes.add(tasks);
  }

  /// 只把已完成任务落盘（进行中的进度无需持久化）。
  void _persist() {
    try {
      final done = _tasks.where((t) => t.state.isTerminal).toList();
      final keep = done.length <= maxDone ? done : done.sublist(0, maxDone);
      KvStore.instance.setString(
        '$_prefs:$_keyHistory',
        jsonEncode(keep.map((t) => t.toJson()).toList()),
      );
    } catch (e) {
      AppLog.w('DownloadTaskRegistry', '保存下载历史失败: $e');
    }
  }

  /// 完成后任务上限裁剪（保留最新的 maxDone 条）。
  void _trimDone() {
    var doneCount = _tasks.where((t) => t.state == DownloadTaskState.done).length;
    if (doneCount <= maxDone) return;
    for (var i = _tasks.length - 1; i >= 0 && doneCount > maxDone; i--) {
      if (_tasks[i].state == DownloadTaskState.done) {
        _tasks.removeAt(i);
        doneCount--;
      }
    }
  }

  static bool fileExists(String path) {
    if (path.isEmpty) return false;
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }
}

/// 执行一次受管下载：登记任务 → 跑进度 → 补歌词封面 → 广播终态。
///
/// 返回落盘路径；失败返回 null。**不要**再自己写 UI 进度，
/// 进度已经进了 [DownloadTaskRegistry]。
///
/// [lyricMode] 为本次下载临时选择的歌词粒度（下载弹层里勾的）；
/// 传 null 用全局设置。选了逐字但没有逐字数据时自动回退逐行，
/// 见 [DownloadExtras.resolveLyricMode]。
Future<String?> runManagedDownload(
  Song song, {
  required Quality qqQuality,
  required NeteaseQuality neQuality,
  LyricDownloadMode? lyricMode,
}) async {
  final reg = DownloadTaskRegistry.instance;
  final task = reg.enqueue(song);

  final startedAt = DateTime.now().millisecondsSinceEpoch;
  void markProgress(int received, int total) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - startedAt;
    final bps = elapsed > 0 ? (received * 1000 ~/ elapsed) : 0;
    reg.update(task.id, (t) => t.copyWith(
          state: DownloadTaskState.downloading,
          received: received,
          total: total,
          bytesPerSecond: bps,
        ));
  }

  String? path;
  try {
    reg.update(task.id,
        (t) => t.copyWith(state: DownloadTaskState.preparing));

    path = await DownloadManager.instance.download(
      song,
      qqQuality: qqQuality,
      neQuality: neQuality,
      onProgress: markProgress,
    );

    if (path == null) {
      reg.update(task.id, (t) => t.copyWith(
            state: DownloadTaskState.failed,
            error: '无可用直链（所选音质服务端未提供）',
            finishedAt: DateTime.now().millisecondsSinceEpoch,
          ));
      return null;
    }

    reg.update(task.id, (t) => t.copyWith(
          state: DownloadTaskState.finalizing,
          filePath: path!,
          total: t.total > 0 ? t.total : 0,
        ));

    // 歌词 / 封面属于附加信息，失败不回滚音频
    String extras = '';
    try {
      extras = await DownloadExtras.attach(
        filePath: path,
        song: song,
        lyricMode: lyricMode,
      );
    } catch (e) {
      AppLog.w('DownloadTaskRegistry', '写入歌词/封面失败: $e');
    }

    reg.update(task.id, (t) => t.copyWith(
          state: DownloadTaskState.done,
          filePath: path!,
          extras: extras,
          qualityLabel: _qualityLabelOf(song, qqQuality, neQuality),
          received: t.total > 0 ? t.total : t.received,
          finishedAt: DateTime.now().millisecondsSinceEpoch,
        ));
    return path;
  } catch (e, st) {
    AppLog.e('DownloadTaskRegistry', '下载异常: $e\n$st');
    reg.update(task.id, (t) => t.copyWith(
          state: DownloadTaskState.failed,
          error: '$e',
          finishedAt: DateTime.now().millisecondsSinceEpoch,
        ));
    return null;
  }
}

String _qualityLabelOf(Song song, Quality qq, NeteaseQuality ne) =>
    song.isNetease ? ne.label : qq.label;

/// 把已完成的下载任务转成可直接播放的本地 [Song]。
///
/// 关键点：[DownloadManager] 只落盘音频文件，不写元数据，所以必须
/// 手动构造 `source: local` + `localPath`，`isLocal` 才为真。
Song downloadedSongOf(DownloadTask task) {
  final s = task.song;
  return Song(
    mid: s.mid,
    songId: s.songId,
    name: s.name,
    singer: s.singer,
    album: s.album,
    albumMid: s.albumMid,
    duration: s.duration,
    cover: s.cover,
    source: Source.local,
    localPath: task.filePath,
    localSize: _sizeOf(task.filePath),
    localMtime: task.finishedAt ?? 0,
    format: _extOf(task.filePath),
  );
}

int _sizeOf(String path) {
  try {
    return File(path).lengthSync();
  } catch (_) {
    return 0;
  }
}

String _extOf(String path) {
  final i = path.lastIndexOf('.');
  return i < 0 ? '' : path.substring(i + 1).toLowerCase();
}