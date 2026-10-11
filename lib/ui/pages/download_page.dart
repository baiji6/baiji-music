import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../download/download_manager.dart';
import '../../metadata/audio_reader.dart';
import '../../models/models.dart';
import '../../download/download_task.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

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
      _snack('文件已被删除或移动', isError: true);
      return;
    }
    final song = downloadedSongOf(task);
    await PlayerController.instance.playQueue([song], startIndex: 0);
    if (!mounted) return;
    _snack('正在播放: ${song.name}');
  }

  void _snack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 13)),
      backgroundColor: isError ? AppColors.danger : AppColors.cyan,
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _deleteFile(DownloadTask task) async {
    try {
      final f = File(task.filePath);
      if (await f.exists()) await f.delete();
    } catch (e) {
      _snack('删除失败: $e', isError: true);
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

  Future<void> _retry(DownloadTask task) async {
    _snack('重新下载: ${task.song.name}');
    unawaited(runManagedDownload(
      task.song,
      qqQuality: DownloadManager.instance.qqQuality,
      neQuality: DownloadManager.instance.neQuality,
    ));
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: const Text('清空下载', style: TextStyle(fontSize: 16)),
        content: const Text('确定删除所有已下载的歌曲文件？', style: TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: AppColors.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    for (final t in DownloadTaskRegistry.instance.tasks) {
      if (t.state.isActive) continue;
      try {
        final f = File(t.filePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    DownloadTaskRegistry.instance.clearFinished();
    await _mergeDiskFiles();
    if (!mounted) return;
    setState(() => _tasks = DownloadTaskRegistry.instance.tasks);
  }

  String _fileName(File f) => f.path.split(Platform.pathSeparator).last;

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
    final finished = _tasks.where((t) => t.state.isTerminal).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('下载管理'),
        actions: [
          if (finished.isNotEmpty)
            IconButton(
              tooltip: '清除已完成记录（保留文件）',
              onPressed: () {
                final n = DownloadTaskRegistry.instance.clearFinished();
                setState(() => _tasks = DownloadTaskRegistry.instance.tasks);
                _snack('已清除 $n 条记录（文件保留）');
              },
              icon: const Icon(Icons.playlist_remove_rounded, color: AppColors.textSecondary),
            ),
          if (finished.isNotEmpty)
            IconButton(
              tooltip: '清空下载（删文件）',
              onPressed: _clearAll,
              icon: const Icon(Icons.delete_sweep_rounded, color: AppColors.danger),
            ),
        ],
      ),
      body: _tasks.isEmpty
          ? const Center(
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
                // 分组标题：进行中 / 已完成
                final showHeader = i == 0 || _tasks[i - 1].state.isActive != t.state.isActive;
                final header = showHeader
                    ? (t.state.isActive ? '进行中（${active.length}）' : '已完成（${finished.length}）')
                    : null;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (header != null)
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : 14, bottom: 8, left: 4),
                        child: Text(
                          header,
                          style: const TextStyle(
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
            ),
    );
  }

  Widget _taskTile(DownloadTask t) {
    final failed = t.state == DownloadTaskState.failed;
    final done = t.state == DownloadTaskState.done;
    final ratio = t.ratio;

    return GlassCard(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            gradient: failed
                ? const LinearGradient(colors: [AppColors.danger, Colors.transparent])
                : const LinearGradient(colors: AppColors.neonGradient),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            done
                ? Icons.check_rounded
                : failed
                    ? Icons.error_outline_rounded
                    : Icons.music_note_rounded,
            color: Colors.white,
            size: 22,
          ),
        ),
        title: Text(
          t.song.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: failed ? AppColors.danger : null,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.song.singer.isEmpty ? '未知艺术家' : t.song.singer,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
            ),
            const SizedBox(height: 4),
            // 进度条：只有进行中任务需要
            if (t.state.isActive)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: ratio,
                            minHeight: 4,
                            backgroundColor: AppColors.surfaceGlass,
                            valueColor:
                                const AlwaysStoppedAnimation<Color>(AppColors.cyan),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        ratio == null
                            ? t.state.label
                            : '${(ratio * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                            fontSize: 10, color: AppColors.textTertiary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (t.received > 0)
                        '${_fmtBytes(t.received)}${t.total > 0 ? ' / ${_fmtBytes(t.total)}' : ''}',
                      if (_fmtSpeed(t.bytesPerSecond).isNotEmpty)
                        _fmtSpeed(t.bytesPerSecond),
                    ].join(' · '),
                    style: const TextStyle(
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
                  color: failed ? AppColors.danger : AppColors.textTertiary,
                ),
              ),
          ],
        ),
        isThreeLine: t.state.isActive,
        trailing: _trailing(t),
        onTap: done ? () => _play(t) : null,
      ),
    );
  }

  Widget _trailing(DownloadTask t) {
    if (t.state.isActive) {
      return const Padding(
        padding: EdgeInsets.only(right: 8),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.cyan),
        ),
      );
    }
    if (t.state == DownloadTaskState.failed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '重试',
            onPressed: () => _retry(t),
            icon: const Icon(Icons.refresh_rounded, color: AppColors.cyan, size: 20),
          ),
          IconButton(
            tooltip: '删除记录',
            onPressed: () {
              DownloadTaskRegistry.instance.remove(t.id);
              setState(() => _tasks = DownloadTaskRegistry.instance.tasks);
            },
            icon: const Icon(Icons.close_rounded, color: AppColors.textTertiary, size: 18),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '播放',
          onPressed: () => _play(t),
          icon: const Icon(Icons.play_circle_fill_rounded, color: AppColors.cyan, size: 26),
        ),
        IconButton(
          tooltip: '删除文件',
          onPressed: () => _deleteFile(t),
          icon: const Icon(Icons.delete_outline, color: AppColors.danger, size: 20),
        ),
      ],
    );
  }
}