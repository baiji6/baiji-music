import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/app_logger.dart';
import '../../core/kv_store.dart';
import '../../data/local_music_store.dart';
import '../../local/local_scanner.dart';
import '../../local/local_song_query.dart';
import '../../models/models.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
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
  bool _hintWarn = false;
  Timer? _hintTimer;

  bool _showDirs = false;

  // ---- 搜索 / 排序（偏好持久化到 KvStore） ----
  static const String _kSortKey = 'localMusic.sortKey';
  static const String _kSortDesc = 'localMusic.sortDesc';

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  LocalSortKey _sortKey = LocalSortKey.title;
  bool _sortDesc = false;
  bool _searchOpen = false;

  // ---- 弹层显隐（Miuix 弹窗是声明式的）----
  bool _showSortSheet = false;
  bool _showClearAllDialog = false;

  @override
  void initState() {
    super.initState();
    _restoreSortPref();
    _load();
    // 首次自动扫：只在从没扫过的时候触发，避免每次进页面都扫一遍
    if (!LocalMusicStore.hasScanned()) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
    }
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _restoreSortPref() {
    try {
      final kv = KvStore.instance;
      _sortKey = LocalSortKey.fromId(kv.getString(_kSortKey));
      _sortDesc = kv.getBool(_kSortDesc);
    } catch (_) {
      // KvStore 未初始化时用默认值，不影响浏览
    }
  }

  Future<void> _setSort(LocalSortKey key, {bool? desc}) async {
    setState(() {
      _sortKey = key;
      if (desc != null) _sortDesc = desc;
    });
    try {
      final kv = KvStore.instance;
      await kv.setString(_kSortKey, key.id);
      await kv.setBool(_kSortDesc, _sortDesc);
    } catch (_) {/* 持久化失败不阻塞交互 */}
  }

  /// 当前真正要渲染的列表：原始库 → 过滤 → 排序。
  ///
  /// 播放队列也用它，保证 `startIndex` 与屏幕上的行号一致。
  List<Song> get _view => LocalSongQuery.apply(
        _songs,
        query: _query,
        key: _sortKey,
        desc: _sortDesc,
      );

  String get _sortLabel => '${_sortKey.label}${_sortDesc ? ' ↓' : ' ↑'}';

  /// 无临时提示时的常驻计数行（同时暴露当前排序方式）。
  String _countLine() {
    final total = _songs.length;
    final shown = _view.length;
    if (_query.trim().isEmpty) return '共 $total 首 · 按$_sortLabel排列';
    return '匹配 $shown / $total 首 · 按$_sortLabel排列';
  }

  void _load() {
    setState(() {
      _songs = LocalMusicStore.songs();
      _customDirs = LocalMusicStore.customDirs();
    });
  }

  void _flash(String text, {bool warn = false}) {
    _hintTimer?.cancel();
    setState(() {
      _hint = text;
      _hintWarn = warn;
    });
    if (warn) return; // 错误信息保留，直到下次操作
    _hintTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() {
        _hint = '';
        _hintWarn = false;
      });
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

  void _openClearAll() {
    setState(() => _showClearAllDialog = true);
  }

  Future<void> _confirmClearAll() async {
    setState(() => _showClearAllDialog = false);
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
    PlayerController.instance.playQueue(_view, startIndex: index);
    setState(() {});
  }

  /// 排序 / 目录管理 / 重扫 / 清空（旧 PopupMenuButton 的 Miuix 底部弹层版）。
  void _onSortAction(String v) {
    setState(() => _showSortSheet = false);
    if (v.startsWith('k:')) {
      final key = LocalSortKey.fromId(v.substring(2));
      // 同一项再点一次就翻转升降序
      _setSort(key, desc: key == _sortKey ? !_sortDesc : false);
    } else if (v == 'dirs') {
      setState(() => _showDirs = !_showDirs);
    } else if (v == 'force') {
      _scan(force: true);
    } else if (v == 'clear') {
      _openClearAll();
    }
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
      child: MiuixScaffold(
        containerColor: Colors.transparent,
        snackbarHost: MiuixSnackbarHost(state: appSnackbarHostState),
        topBar: MiuixTopAppBar(
          title: '本地音乐',
          navigationIcon: MiuixIconButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Icon(Icons.arrow_back_rounded,
                color: AppColors.textPrimary),
          ),
          actions: [
            MiuixIconButton(
              onPressed: () {
                if (_searchOpen) {
                  _searchCtrl.clear();
                  setState(() {
                    _searchOpen = false;
                    _query = '';
                  });
                } else {
                  setState(() => _searchOpen = true);
                }
              },
              child: Icon(
                _searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
                color: _searchOpen ? AppColors.cyan : AppColors.textPrimary,
              ),
            ),
            MiuixIconButton(
              onPressed: () => setState(() => _showSortSheet = true),
              child: const Icon(Icons.swap_vert_rounded,
                  color: AppColors.textPrimary),
            ),
            MiuixIconButton(
              onPressed: _scanning ? null : () => _scan(),
              child: const Icon(Icons.refresh_rounded, color: AppColors.cyan),
            ),
          ],
        ),
        content: (padding) => Column(
          children: [
            // 扫描进度条
            if (_scanning)
              MiuixLinearProgressIndicator(
                progress: _progress?.total == 0 ? null : _progress?.ratio,
                height: 2,
              ),

            // 搜索框
            if (_searchOpen) _buildSearchBar(),

            // 目录管理
            if (_showDirs) _buildDirPanel(),

            // 提示行 / 计数行
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(
                children: [
                  Icon(
                    _hint.isNotEmpty && _hint.contains('失败')
                        ? Icons.error_outline_rounded
                        : _scanning
                            ? Icons.info_outline_rounded
                            : Icons.library_music_outlined,
                    size: 14,
                    color: _hintWarn
                        ? AppColors.magenta
                        : AppColors.textTertiary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _scanning
                          ? '正在扫描 ${_progress?.done ?? 0}/${_progress?.total ?? 0}…'
                          : _hint.isNotEmpty
                              ? _hint
                              : _countLine(),
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
        bottomBar: _buildSheets(),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: MiuixTextField(
        controller: _searchCtrl,
        autofocus: true,
        label: '搜索歌名 / 歌手 / 专辑',
        useLabelAsPlaceholder: true,
        singleLine: true,
        textInputAction: TextInputAction.search,
        cursorColor: AppColors.cyan,
        textStyle: const TextStyle(fontSize: 13),
        trailingIcon: _query.isNotEmpty
            ? MiuixIconButton(
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _query = '');
                },
                child: const Icon(Icons.close_rounded,
                    size: 16, color: AppColors.textTertiary),
              )
            : null,
        onChanged: (v) => setState(() => _query = v),
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
                MiuixTextButton(
                  '添加目录',
                  onPressed: _pickDir,
                  textStyle: const TextStyle(
                      fontSize: 12, color: AppColors.cyan),
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
                      MiuixIconButton(
                        onPressed: () => _removeDir(d),
                        child: const Icon(Icons.close_rounded,
                            size: 16, color: AppColors.textTertiary),
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
            MiuixCircularProgressIndicator(),
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
                MiuixTextButton(
                  '扫描系统音乐目录',
                  onPressed: () => _scan(force: true),
                  textStyle: const TextStyle(
                      fontSize: 12, color: AppColors.cyan),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final view = _view;
    if (view.isEmpty) {
      // 有库但搜索/排序后为空 —— 是筛选结果为空，不是没有音乐
      if (_query.trim().isNotEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.search_off_rounded,
                    size: 48, color: AppColors.textTertiary),
                const SizedBox(height: 14),
                Text(
                  '没有匹配「${_query.trim()}」的歌曲',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 12),
                MiuixTextButton(
                  '清空搜索',
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                  },
                  textStyle: const TextStyle(
                      fontSize: 12, color: AppColors.cyan),
                ),
              ],
            ),
          ),
        );
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: view.length,
      itemBuilder: (ctx, i) {
        final s = view[i];
        final playing = current?.mid == s.mid;
        return GlassCard(
          margin: const EdgeInsets.only(bottom: 8),
          child: MiuixPressable(
            onPressed: () => _play(s, i),
            borderRadius: BorderRadius.circular(22),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  CoverImage(song: s, size: 44, radius: 10),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color:
                                playing ? AppColors.cyan : AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          s.singer.isEmpty ? '未知艺术家' : s.singer,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textTertiary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  TagBadge(
                    s.format.isEmpty ? '本地' : s.format.toUpperCase(),
                    color: AppColors.violet,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _fmtDuration(s.duration),
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textTertiary),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.play_arrow_rounded,
                      color: AppColors.cyan, size: 24),
                ],
              ),
            ),
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

  /// 集中挂载本页的 Miuix 声明式弹层。
  Widget _buildSheets() {
    return Stack(
      children: [
        // ---- 清空确认 ----
        MiuixOverlayDialog(
          show: _showClearAllDialog,
          title: '清空本地音乐',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () => setState(() => _showClearAllDialog = false),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MiuixText(
                '将删除已保存的本地歌曲清单。文件本身不会被删除，重新扫描即可恢复。',
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.6,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MiuixTextButton(
                    '取消',
                    onPressed: () =>
                        setState(() => _showClearAllDialog = false),
                    textStyle: const TextStyle(color: AppColors.textTertiary),
                  ),
                  const SizedBox(width: 8),
                  MiuixTextButton(
                    '清空',
                    onPressed: _confirmClearAll,
                    textStyle: const TextStyle(
                        color: AppColors.magenta, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ],
          ),
        ),
        // ---- 排序 / 目录 / 重扫 / 清空 ----
        MiuixOverlayBottomSheet(
          show: _showSortSheet,
          title: '排序：$_sortLabel',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () => setState(() => _showSortSheet = false),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final k in LocalSortKey.values)
                  MiuixPressable(
                    onPressed: () => _onSortAction('k:${k.id}'),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: k == _sortKey
                            ? AppColors.cyan.withValues(alpha: 0.12)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            k == _sortKey
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 17,
                            color: k == _sortKey
                                ? AppColors.cyan
                                : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            k.label,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: k == _sortKey
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: k == _sortKey
                                  ? AppColors.cyan
                                  : AppColors.textPrimary,
                            ),
                          ),
                          if (k == _sortKey) ...[
                            const Spacer(),
                            Icon(
                              _sortDesc
                                  ? Icons.arrow_downward_rounded
                                  : Icons.arrow_upward_rounded,
                              size: 15,
                              color: AppColors.cyan,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                const MiuixHorizontalDivider(),
                _SheetAction(
                  icon: Icons.folder_open_rounded,
                  label: _showDirs ? '隐藏目录管理' : '显示目录管理',
                  onTap: () => _onSortAction('dirs'),
                ),
                _SheetAction(
                  icon: Icons.restart_alt_rounded,
                  label: '全量重扫',
                  onTap: () => _onSortAction('force'),
                ),
                _SheetAction(
                  icon: Icons.delete_outline_rounded,
                  label: '清空列表',
                  danger: true,
                  onTap: () => _onSortAction('clear'),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 排序底部弹层里的普通操作行。
class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.magenta : AppColors.textPrimary;
    return MiuixPressable(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(fontSize: 13, color: color)),
          ],
        ),
      ),
    );
  }
}
