import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/app_logger.dart';
import '../../data/local_music_store.dart';
import '../../local/local_scanner.dart';
import '../../models/models.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/cover_image.dart';

/// 本地音乐页：扫描本机磁盘上的音频文件，读元数据并直接播放。
///
/// **首次进入自动扫一次**，之后增量（指纹未变的文件不再读盘）。
/// 用户可以追加自定义目录，也可以手动「重新扫描」或「全量重扫」。
class LocalMusicPage extends StatefulWidget {
  const LocalMusicPage({super.key});

  @override
  State<LocalMusicPage> createState() => _LocalMusicPageState();
}

class _LocalMusicPageState extends State<LocalMusicPage> {
  List<Song> _songs = const <Song>[];
  List<String> _customDirs = const <String>[];

  bool _scanning = false;
  LocalScanProgress? _progress;
  String _hint = '';
  Timer? _hintTimer;

  bool _showDirs = false;

  @override
  void initState() {
    super.initState();
    _load();
    // 首次自动扫：只在从没扫过的时候触发，避免每次进页面都扫一遍
    if (!LocalMusicStore.hasScanned()) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
    }
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  void _load() {
    setState(() {
      _songs = LocalMusicStore.songs();
      _customDirs = LocalMusicStore.customDirs();
    });
  }

  void _flash(String text, {bool warn = false}) {
    _hintTimer?.cancel();
    setState(() => _hint = text);
    if (warn) return; // 错误信息保留，直到下次操作
    _hintTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _hint = '');
    });
  }

  Future<List<String>> _dirs() async {
    final system = await LocalScanner.defaultDirs();
    // 系统目录 + 用户目录，去重后交给扫描器
    final all = <String>[..._customDirs, ...system];
    final seen = <String>{};
    return all.where((p) => seen.add(p)).toList();
  }

  Future<void> _scan({bool force = false}) async {
    if (_scanning) return;

    // 移动端需要存储权限才能读到公共目录
    if (!await LocalScanner.ensurePermission()) {
      _flash('没有存储权限，无法扫描本地音乐', warn: true);
      return;
    }

    setState(() {
      _scanning = true;
      _progress = null;
      _hint = '';
    });

    try {
      final dirs = await _dirs();
      if (dirs.isEmpty) {
        _flash('没有可扫描的目录，请手动添加一个', warn: true);
        setState(() => _scanning = false);
        return;
      }

      final result = await LocalScanner.scan(
        dirs: dirs,
        known: LocalMusicStore.songsByPath(),
        knownFingerprints: LocalMusicStore.fingerprints(),
        force: force,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p);
        },
      );

      await LocalMusicStore.save(result);
      if (!mounted) return;

      final reused = result.reusedCount;
      final parsed = result.parsedCount;
      final failed = result.failedCount;
      AppLog.i('LocalMusicPage', '扫描完成: $result');

      _load();
      setState(() {
        _scanning = false;
        _progress = null;
      });

      if (result.songs.isEmpty) {
        _flash('没找到音频文件，试试手动选择目录', warn: true);
      } else {
        _flash('共 ${result.songs.length} 首 · 新解析 $parsed · 复用 $reused'
            '${failed > 0 ? ' · 跳过 $failed' : ''}');
      }
    } catch (e) {
      AppLog.e('LocalMusicPage', '扫描失败: $e');
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _progress = null;
      });
      _flash('扫描失败：$e', warn: true);
    }
  }

  Future<void> _pickDir() async {
    try {
      final picked = await FilePicker.platform.getDirectoryPath();
      if (picked == null || picked.isEmpty || !mounted) return;

      await LocalMusicStore.addCustomDir(picked);
      await LocalScanner.ensurePermission();
      _load();
      _flash('已添加目录，正在扫描…');
      await _scan();
    } catch (e) {
      AppLog.e('LocalMusicPage', '选择目录失败: $e');
      if (mounted) _flash('选择目录失败：$e', warn: true);
    }
  }

  Future<void> _removeDir(String path) async {
    await LocalMusicStore.removeCustomDir(path);
    _load();
    await _scan(force: true);
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: const Text('清空本地音乐', style: TextStyle(fontSize: 16)),
        content: const Text(
          '将删除已保存的本地歌曲清单。文件本身不会被删除，重新扫描即可恢复。',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: AppColors.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: AppColors.magenta)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    LocalCoverCache.clear();
    await LocalMusicStore.clear();
    _load();
    _flash('已清空');
  }

  void _play(Song song, int index) {
    final uri = LocalScanner.playUri(song);
    if (uri.isEmpty) {
      _flash('文件已不存在，请重新扫描', warn: true);
      return;
    }
    PlayerController.instance.playQueue(_songs, startIndex: index);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final current = PlayerController.instance.currentSong;

    // 返回时带 true，让「我的」页刷新歌曲数量（覆盖 AppBar 返回键、
    // 侧滑手势与系统返回键三条路径）
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop(true);
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('本地音乐'),
        actions: [
          IconButton(
            tooltip: '重新扫描（增量）',
            icon: const Icon(Icons.refresh_rounded, color: AppColors.cyan),
            onPressed: _scanning ? null : () => _scan(),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            color: AppColors.bg2,
            onSelected: (v) {
              switch (v) {
                case 'dirs':
                  setState(() => _showDirs = !_showDirs);
                case 'force':
                  _scan(force: true);
                case 'clear':
                  _clearAll();
              }
            },
            itemBuilder: (_) => [
              PopUpItem(
                _showDirs ? '隐藏目录管理' : '显示目录管理',
                'dirs',
                Icons.folder_open_rounded,
              ).item,
              PopUpItem('全量重扫', 'force', Icons.restart_alt_rounded).item,
              PopUpItem('清空列表', 'clear', Icons.delete_outline_rounded).item,
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 扫描进度条
          if (_scanning)
            LinearProgressIndicator(
              value: _progress?.total == 0 ? null : _progress?.ratio,
              minHeight: 2,
              backgroundColor: AppColors.surfaceGlass,
              valueColor: const AlwaysStoppedAnimation<Color>(AppColors.cyan),
            ),

          // 目录管理
          if (_showDirs) _buildDirPanel(),

          // 提示行
          if (_hint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 14,
                    color: AppColors.textTertiary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _scanning
                          ? '正在扫描 ${_progress?.done ?? 0}/${_progress?.total ?? 0}…'
                          : _hint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          Expanded(child: _buildBody(current)),
        ],
      ),
      ),
    );
  }

  Widget _buildDirPanel() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '扫描目录',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _pickDir,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                  label: const Text('添加目录'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.cyan,
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            if (_customDirs.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 4),
                child: Text(
                  '只扫描系统音乐目录。添加自定义目录后会自动重新扫描。',
                  style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
                ),
              )
            else
              for (final d in _customDirs)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.folder_rounded,
                          size: 15, color: AppColors.cyan),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          d,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 16),
                        color: AppColors.textTertiary,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => _removeDir(d),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(Song? current) {
    if (_scanning && _songs.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppColors.cyan),
            SizedBox(height: 16),
            Text(
              '正在扫描本地音乐…',
              style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
            ),
          ],
        ),
      );
    }

    if (_songs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.library_music_outlined,
                  size: 52, color: AppColors.textTertiary),
              const SizedBox(height: 16),
              const Text(
                '还没有本地音乐',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '扫描本机上的 MP3 / FLAC / M4A / OGG / WAV 文件，\n自动识别标题、艺术家、专辑与时长',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
              ),
              const SizedBox(height: 20),
              NeonButton(
                label: '选择文件夹',
                icon: Icons.folder_open_rounded,
                onPressed: _pickDir,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                radius: 14,
              ),
              if (!Platform.isAndroid && !Platform.isIOS) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => _scan(force: true),
                  child: const Text(
                    '扫描系统音乐目录',
                    style: TextStyle(fontSize: 12, color: AppColors.cyan),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _songs.length,
      itemBuilder: (ctx, i) {
        final s = _songs[i];
        final playing = current?.mid == s.mid;
        return GlassCard(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: CoverImage(song: s, size: 44, radius: 10),
            title: Text(
              s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: playing ? AppColors.cyan : null,
              ),
            ),
            subtitle: Text(
              s.singer.isEmpty ? '未知艺术家' : s.singer,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TagBadge(
                  s.format.isEmpty ? '本地' : s.format.toUpperCase(),
                  color: AppColors.violet,
                ),
                const SizedBox(width: 6),
                Text(
                  _fmtDuration(s.duration),
                  style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.play_arrow_rounded,
                    color: AppColors.cyan, size: 24),
              ],
            ),
            onTap: () => _play(s, i),
          ),
        );
      },
    );
  }

  String _fmtDuration(int ms) {
    if (ms <= 0) return '--:--';
    final total = ms ~/ 1000;
    final m = total ~/ 60;
    final sec = total % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}

/// PopupMenu 条目（只是为了让 itemBuilder 里少些重复代码）。
class PopUpItem {
  const PopUpItem(this.label, this.value, this.icon);

  final String label;
  final String value;
  final IconData icon;

  PopupMenuItem<String> get item => PopupMenuItem<String>(
        value: value,
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppColors.textSecondary),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      );
}
