import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../download/download_manager.dart';
import '../../metadata/audio_reader.dart';
import '../../models/models.dart';
import '../../download/download_task.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';
import '../widgets/cover_image.dart';

/// 下载管理页：显示下载任务队列（进行中 + 历史），点完成项可直接播放。
///
/// 进度与状态来自 [DownloadTaskRegistry]，是**全局**的：即使中途离开本页，
/// 任务仍在后台跑，回来能接上；换句话说进度不随页面生命周期丢失。
class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  List<DownloadTask> _tasks = const [];
  StreamSubscription<List<DownloadTask>>? _sub;

  /// 「清空下载（删文件）」确认弹窗显隐。
  bool _showClearAllDialog = false;

  @override
  void initState() {
    super.initState();
    _sub = DownloadTaskRegistry.instance.changes.listen((list) {
      if (!mounted) return;
      setState(() => _tasks = list);
    });
    // 首次进入：拉回持久化的历史任务，并补上磁盘上存在但没记录的文件
    _bootstrap();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await DownloadTaskRegistry.instance.restore();
    await _mergeDiskFiles();
    if (!mounted) return;
    setState(() => _tasks = DownloadTaskRegistry.instance.tasks);
  }

  /// 把下载目录里存在、但任务表里没有的音频文件补成"已完成"条目。
  ///
  /// 之前的实现直接 `listSync()` 展示裸 [File]，只有文件名和大小，
  /// 没法播放（构造不出带 localPath 的 Song）、也认不出是哪首歌。
  /// 这里用 AudioReader 读元数据补齐，读不出来的退化成"文件名 - 无名"。
  Future<void> _mergeDiskFiles() async {
    final reg = DownloadTaskRegistry.instance;
    final known = reg.tasks.map((t) => t.filePath).toSet();

    final dir = await DownloadManager.instance.getDownloadDir();
    if (!dir.existsSync()) return;
    final files = dir
        .listSync()
        .whereType<File>()
        .where(_isAudio)
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

    for (final f in files) {
      if (known.contains(f.path)) continue;
      final song = await _songOfFile(f);
      reg.update(reg.enqueue(song).id, (t) => t.copyWith(
            state: DownloadTaskState.done,
            filePath: f.path,
            received: f.lengthSync(),
            total: f.lengthSync(),
            qualityLabel: '本地已有',
            finishedAt: f.statSync().modified.millisecondsSinceEpoch,
          ));
    }
  }

  bool _isAudio(File f) {
    final n = f.path.toLowerCase();
    return n.endsWith('.mp3') ||
        n.endsWith('.flac') ||
        n.endsWith('.m4a') ||
        n.endsWith('.ogg') ||
        n.endsWith('.wav') ||
        n.endsWith('.aac') ||
        n.endsWith('.ape') ||
        n.endsWith('.nac');
  }

  Future<Song> _songOfFile(File f) async {
    final fileName = _fileName(f);
    try {
      final meta = await AudioReader.read(f.path);
      if (meta.title.isNotEmpty) {
        return Song(
          mid: 'dl:${f.path}',
          songId: 0,
          name: meta.title,
          singer: meta.artist.isEmpty ? '未知艺术家' : meta.artist,
          album: meta.album.isEmpty ? '未知专辑' : meta.album,
          albumMid: '',
          duration: meta.durationMs,
          cover: '',
          source: Source.local,
          localPath: f.path,
          localSize: f.lengthSync(),
          localMtime: f.statSync().modified.millisecondsSinceEpoch,
          format: meta.format,
        );
      }
    } catch (_) {/* 元数据读不出来就退回文件名解析 */}

    // 文件名约定为「歌手 - 歌名」
    final base = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;
    final idx = base.indexOf(' - ');
    final singer = idx > 0 ? base.substring(0, idx) : '未知艺术家';
    final name = idx > 0 && idx + 3 < base.length ? base.substring(idx + 3) : base;
    return Song(
      mid: 'dl:${f.path}',
      songId: 0,
      name: name,
      singer: singer,
      album: '未知专辑',
      albumMid: '',
      duration: 0,
      cover: '',
      source: Source.local,
      localPath: f.path,
      localSize: f.lengthSync(),
      localMtime: f.statSync().modified.millisecondsSinceEpoch,
      format: '',
    );
  }

  Future<void> _play(DownloadTask task) async {
    if (!File(task.filePath).existsSync()) {
      showAppSnack('文件已被删除或移动');
      return;
    }
    final song = downloadedSongOf(task);
    await PlayerController.instance.playQueue([song], startIndex: 0);
    if (!mounted) return;
    showAppSnack('正在播放: ${song.name}');
  }

  Future<void> _deleteFile(DownloadTask task) async {
    try {
      final f = File(task.filePath);
      if (await f.exists()) await f.delete();
    } catch (e) {
      showAppSnack('删除失败: $e');
    }
    // 暂停任务的 .part 残片一并删掉，不然下载目录会留下隐形垃圾
    if (task.partPath.isNotEmpty) {
      try {
        final p = File(task.partPath);
        if (await p.exists()) await p.delete();
      } catch (_) {/* 残片删不掉无所谓 */}
    }
    // 顺带删掉同名的歌词/封面外挂文件
    final stem = task.filePath.contains('.')
        ? task.filePath.substring(0, task.filePath.lastIndexOf('.'))
        : task.filePath;
    for (final suffix in const ['.lrc', '.qrc', '.txt', '.jpg', '.png', '.jpeg']) {
      try {
        final side = File('$stem$suffix');
        if (await side.exists()) await side.delete();
      } catch (_) {/* 外挂文件删不掉无所谓 */}
    }
    DownloadTaskRegistry.instance.remove(task.id);
    if (!mounted) return;
    setState(() => _tasks = DownloadTaskRegistry.instance.tasks);
  }

  /// 继续下载：从暂停任务的 `.part` 断点续传（HTTP Range）。
  Future<void> _resume(DownloadTask task) async {
    if (!task.canResume) {
      showAppSnack('续传残片已丢失，请重新下载');
      return;
    }
    showAppSnack('继续下载: ${task.song.name}');
    unawaited(runManagedDownload(
      task.song,
      qqQuality: DownloadManager.instance.qqQuality,
      neQuality: DownloadManager.instance.neQuality,
      resumeTaskId: task.id,
    ));
  }

  Future<void> _retry(DownloadTask task) async {
    showAppSnack('重新下载: ${task.song.name}');
    // 有残片就续传，没有才从头下
    final canResume = task.partPath.isNotEmpty &&
        DownloadTaskRegistry.fileExists(task.partPath);
    unawaited(runManagedDownload(
      task.song,
      qqQuality: DownloadManager.instance.qqQuality,
      neQuality: DownloadManager.instance.neQuality,
      resumeTaskId: canResume ? task.id : null,
    ));
  }

  void _openClearAll() {
    setState(() => _showClearAllDialog = true);
  }

  Future<void> _confirmClearAll() async {
    setState(() => _showClearAllDialog = false);

    for (final t in DownloadTaskRegistry.instance.tasks) {
      if (t.state.isActive) continue;
      try {
        if (t.filePath.isNotEmpty) {
          final f = File(t.filePath);
          if (await f.exists()) await f.delete();
        }
        if (t.partPath.isNotEmpty) {
          final p = File(t.partPath);
          if (await p.exists()) await p.delete();
        }
      } catch (_) {}
    }
    // 暂停态任务（残片已删）也一并无痕移除
    for (final t in DownloadTaskRegistry.instance.tasks.toList()) {
      if (t.state.isPaused) DownloadTaskRegistry.instance.remove(t.id);
    }
    DownloadTaskRegistry.instance.clearFinished();
    await _mergeDiskFiles();
    if (!mounted) return;
    setState(() => _tasks = DownloadTaskRegistry.instance.tasks);
  }

  String _fileName(File f) => f.path.split(Platform.pathSeparator).last;

  /// 任务所属分组：0 = 进行中，1 = 已暂停，2 = 已完成。
  int _groupOf(DownloadTask t) {
    if (t.state.isActive) return 0;
    if (t.state.isPaused) return 1;
    return 2;
  }

  String _groupHeader(
      DownloadTask t, int activeN, int pausedN, int finishedN) {
    return switch (_groupOf(t)) {
      0 => '进行中（$activeN）',
      1 => '已暂停（$pausedN）',
      _ => '已完成（$finishedN）',
    };
  }

  String _fmtBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _fmtSpeed(int bps) {
    if (bps <= 0) return '';
    return '${_fmtBytes(bps)}/s';
  }

  @override
  Widget build(BuildContext context) {
    final active = _tasks.where((t) => t.state.isActive).toList();
    final paused = _tasks.where((t) => t.state.isPaused).toList();
    final finished = _tasks.where((t) => t.state.isTerminal).toList();

    final body = _tasks.isEmpty
        ? Center(
            child: Text(
              '暂无下载\n搜索歌曲后长按可下载',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _tasks.length,
            itemBuilder: (ctx, i) {
              final t = _tasks[i];
              // 分组标题：进行中 / 已暂停 / 已完成
              final prev = i == 0 ? null : _tasks[i - 1];
              final groupChanged = prev == null || _groupOf(prev) != _groupOf(t);
              final header = groupChanged ? _groupHeader(t, active.length, paused.length, finished.length) : null;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (header != null)
                    Padding(
                      padding: EdgeInsets.only(
                          top: i == 0 ? 0 : 14, bottom: 8, left: 4),
                      child: Text(
                        header,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textTertiary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  _taskTile(t),
                ],
              );
            },
          );

    return PageScaffold(
      title: '下载管理',
      snackbarHost: appSnackbarHostState,
      contentPadding: EdgeInsets.zero,
      actions: [
        if (finished.isNotEmpty)
          MiuixIconButton(
            onPressed: () {
              final n = DownloadTaskRegistry.instance.clearFinished();
              setState(() => _tasks = DownloadTaskRegistry.instance.tasks);
              showAppSnack('已清除 $n 条记录（文件保留）');
            },
            child: Icon(Icons.playlist_remove_rounded,
                color: AppColors.textSecondary),
          ),
        if (finished.isNotEmpty)
          MiuixIconButton(
            onPressed: _openClearAll,
            child: Icon(Icons.delete_sweep_rounded, color: AppColors.danger),
          ),
      ],
      bottomBar: _buildDialogs(),
      child: body,
    );
  }

  Widget _taskTile(DownloadTask t) {
    final failed = t.state == DownloadTaskState.failed;
    final done = t.state == DownloadTaskState.done;
    final paused = t.state == DownloadTaskState.paused;
    final ratio = t.ratio;

    return GlassCard(
      margin: const EdgeInsets.only(bottom: 8),
      child: MiuixPressable(
        onPressed: done ? () => _play(t) : null,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 歌曲封面：已完成用文件内嵌封面，进行中/暂停用网络封面
              _taskCover(t, done: done, failed: failed),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      t.song.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: failed ? AppColors.danger : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      t.song.singer.isEmpty ? '未知艺术家' : t.song.singer,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textTertiary),
                    ),
                    const SizedBox(height: 4),
                    // 进度条：进行中与已暂停任务都需要（暂停显示断点进度）
                    if (t.state.isActive || paused)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: MiuixLinearProgressIndicator(
                                  progress: paused ? (ratio ?? 0) : ratio,
                                  height: 4,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                ratio == null
                                    ? t.state.label
                                    : '${(ratio * 100).toStringAsFixed(0)}%',
                                style: TextStyle(
                                    fontSize: 10, color: AppColors.textTertiary),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            [
                              if (t.received > 0)
                                '${_fmtBytes(t.received)}${t.total > 0 ? ' / ${_fmtBytes(t.total)}' : ''}',
                              if (paused) '点右侧继续续传',
                              if (!paused && _fmtSpeed(t.bytesPerSecond).isNotEmpty)
                                _fmtSpeed(t.bytesPerSecond),
                            ].join(' · '),
                            style: TextStyle(
                                fontSize: 10, color: AppColors.textTertiary),
                          ),
                        ],
                      )
                    else
                      Text(
                        [
                          t.state.label,
                          if (t.qualityLabel.isNotEmpty) t.qualityLabel,
                          if (t.total > 0) _fmtBytes(t.total),
                          if (t.extras.isNotEmpty) t.extras,
                          if (failed && t.error.isNotEmpty) t.error,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color:
                              failed ? AppColors.danger : AppColors.textTertiary,
                        ),
                      ),
                  ],
                ),
              ),
              _trailing(t),
            ],
          ),
        ),
      ),
    );
  }

  /// 任务封面：已完成 → 读文件内嵌封面（不依赖网络）；其余 → 网络封面。
  Widget _taskCover(DownloadTask t, {required bool done, required bool failed}) {
    final song = done && DownloadTaskRegistry.fileExists(t.filePath)
        ? downloadedSongOf(t)
        : t.song;
    return SizedBox(
      width: 44,
      height: 44,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: CoverImage(
          song: song,
          size: 44,
          radius: 12,
          memCacheWidth: 132,
        ),
      ),
    );
  }

  Widget _trailing(DownloadTask t) {
    if (t.state.isActive) {
      // 暂停：取消当前传输，保留 .part 残片供续传
      return Padding(
        padding: const EdgeInsets.only(right: 4, top: 6),
        child: MiuixIconButton(
          onPressed: () {
            DownloadTaskRegistry.instance.requestPause(t.id);
            showAppSnack('已暂停: ${t.song.name}');
          },
          child: Icon(Icons.pause_rounded,
              color: AppColors.accent, size: 22),
        ),
      );
    }
    if (t.state == DownloadTaskState.paused) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 继续：从 .part 断点续传（HTTP Range）
          MiuixIconButton(
            onPressed: () => _resume(t),
            child: Icon(Icons.play_circle_fill_rounded,
                color: AppColors.accent, size: 26),
          ),
          MiuixIconButton(
            onPressed: () => _deleteFile(t),
            child: Icon(Icons.close_rounded,
                color: AppColors.textTertiary, size: 18),
          ),
        ],
      );
    }
    if (t.state == DownloadTaskState.failed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiuixIconButton(
            onPressed: () => _retry(t),
            child: Icon(Icons.refresh_rounded,
                color: AppColors.accent, size: 20),
          ),
          MiuixIconButton(
            onPressed: () {
              DownloadTaskRegistry.instance.remove(t.id);
              setState(() => _tasks = DownloadTaskRegistry.instance.tasks);
            },
            child: Icon(Icons.close_rounded,
                color: AppColors.textTertiary, size: 18),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MiuixIconButton(
          onPressed: () => _play(t),
          child: Icon(Icons.play_circle_fill_rounded,
              color: AppColors.accent, size: 26),
        ),
        MiuixIconButton(
          onPressed: () => _deleteFile(t),
          child: Icon(Icons.delete_outline,
              color: AppColors.danger, size: 20),
        ),
      ],
    );
  }

  /// 「清空下载（删文件）」确认弹窗。
  Widget _buildDialogs() {
    return Stack(
      children: [
        MiuixOverlayDialog(
          show: _showClearAllDialog,
          title: '清空下载',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () => setState(() => _showClearAllDialog = false),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MiuixText(
                '确定删除所有已下载的歌曲文件？',
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MiuixTextButton(
                    '取消',
                    onPressed: () =>
                        setState(() => _showClearAllDialog = false),
                    textStyle: TextStyle(color: AppColors.textTertiary),
                  ),
                  const SizedBox(width: 8),
                  MiuixTextButton(
                    '清空',
                    onPressed: _confirmClearAll,
                    textStyle: TextStyle(
                        color: AppColors.danger, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
