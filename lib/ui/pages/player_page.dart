import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/data/history_store.dart';
import 'package:baiji_music/download/download_extras.dart';
import 'package:baiji_music/download/download_manager.dart';
import 'package:baiji_music/download/download_task.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/metadata/audio_spec.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/lyric_api.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:baiji_music/player/player_controller.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/core/album_saver.dart';
import 'package:baiji_music/ui/pages/netease_login_page.dart';
import 'package:baiji_music/ui/pages/song_comment_page.dart';
import 'package:baiji_music/ui/widgets/app_snackbar.dart';
import 'package:baiji_music/ui/widgets/amll_lyrics_view.dart';
import 'package:baiji_music/ui/widgets/app_widgets.dart';
import 'package:baiji_music/ui/widgets/cover_image.dart';
import 'package:baiji_music/ui/widgets/download_options_sheet.dart';
import 'package:baiji_music/ui/widgets/lyric_style_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// 播放页：封面 + 进度条 + 播放控制 + 平台化音质切换 + 下载 + 歌词（逐字/译文/点击跳转）。
///
/// 布局按**屏幕方向**分流（而不是单纯按宽度）：
/// - 竖屏：整屏封面页 + 歌词页，两页横向 [PageView]，封面左滑即进入歌词页；
/// - 横屏：左侧封面/歌名/操作，右侧歌词，底部为紧凑的进度条+控制条，
///   封面尺寸由「可用高度」反推，不会再出现被裁切的问题。
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final _player = PlayerController.instance;

  /// 竖屏「封面页 / 歌词页」横向翻页控制器。
  final PageController _pages = PageController();

  Song? _song;
  PlayMode _mode = PlayMode.sequential;
  Quality? _actualQq;
  NeteaseQuality? _actualNe;
  bool _playing = false;
  bool _fav = false;

  /// 当前页序号：0 = 封面页，1 = 歌词页。
  int _pageIndex = 0;

  /// 下载进度 0~1；null 表示当前没有下载任务（0 表示刚开始、还拿不到总长度）。
  ///
  /// 数据来自全局 [DownloadTaskRegistry] 中**当前歌曲**的那个任务，
  /// 所以离开页面再回来进度还在，也不会因为重建而丢。
  double? _downloadProgress;
  StreamSubscription<List<DownloadTask>>? _taskSub;

  /// 当前歌曲的歌词Future（切歌时重建）。
  Future<Lyrics>? _lyricsFuture;
  String _lyricsKey = '';

  /// 「网易云未登录只有逐行歌词」提示条是否已被用户手动关闭（切歌不复位，
  /// 同一首歌反复关掉再打开不该又弹出来；换歌自然由 key 重建整个视图）。
  bool _neLoginHintDismissed = false;

  // ===== Miuix 声明式弹层的显隐 =====
  bool _showLyricStyleSheet = false;
  bool _showAudioSpecSheet = false;
  bool _showDownloadQualitySheet = false;
  bool _showPlayQualitySheet = false;

  /// 下载音质弹层正在为哪首歌选音质。
  Song? _pendingDownloadSong;

  StreamSubscription<Song?>? _songSub;
  StreamSubscription<Quality?>? _qualitySub;
  StreamSubscription<NeteaseQuality?>? _neQualitySub;
  StreamSubscription<bool>? _playSub;
  StreamSubscription<double>? _rateSub;

  /// 当前倍速（0.01~50 无级，按钮常显、弹层可调）。
  double _rate = 1.0;

  /// 倍速调节弹层显隐。
  bool _showRateSheet = false;

  @override
  void initState() {
    super.initState();
    _song = _player.currentSong;
    _mode = _player.playMode;
    _actualQq = _player.actualQqQuality;
    _actualNe = _player.actualNeteaseQuality;
    _playing = _player.isPlaying;
    _rate = _player.rate;
    _syncFavorite();
    _loadLyrics();
    _syncDownloadProgress();
    _taskSub = DownloadTaskRegistry.instance.changes.listen((tasks) {
      if (!mounted) return;
      setState(() => _syncDownloadProgress(tasks));
    });

    _songSub = _player.onSongChanged.listen((song) {
      if (!mounted) return;
      setState(() {
        _song = song;
        _playing = _player.isPlaying;
        // 切歌后旧曲目的"实际音质"不再适用，等取流结果回来再刷新
        _actualQq = null;
        _actualNe = null;
      });
      _syncFavorite();
      _loadLyrics();
    });

    // 自动降级时同步"实际音质"角标（QQ）
    _qualitySub = _player.onQualityChanged.listen((q) {
      if (!mounted) return;
      setState(() => _actualQq = q);
    });

    // 自动降级时同步"实际音质"角标（网易云）
    _neQualitySub = _player.onNeteaseQualityChanged.listen((q) {
      if (!mounted) return;
      setState(() => _actualNe = q);
    });

    _playSub = _player.onPlayStateChanged.listen((playing) {
      if (!mounted) return;
      setState(() => _playing = playing);
    });

    _rateSub = _player.onRateChanged.listen((r) {
      if (!mounted) return;
      setState(() => _rate = r);
    });
  }

  @override
  void dispose() {
    _songSub?.cancel();
    _qualitySub?.cancel();
    _neQualitySub?.cancel();
    _playSub?.cancel();
    _rateSub?.cancel();
    _taskSub?.cancel();
    _pages.dispose();
    super.dispose();
  }

  /// 把全局任务队列里**当前歌曲**的进度同步到 [_downloadProgress]。
  ///
  /// 只关心当前歌曲：下载别的歌不该让当前播放页的按钮转圈。
  /// 返回值直接给 setState 用，省一次 setState。
  double? _syncDownloadProgress([List<DownloadTask>? tasks]) {
    final s = _song;
    if (s == null) return _downloadProgress = null;
    final list = tasks ?? DownloadTaskRegistry.instance.tasks;
    DownloadTask? mine;
    for (final t in list) {
      if (t.song.mid == s.mid) {
        mine = t;
        break;
      }
    }
    if (mine == null || !mine.state.isActive) return _downloadProgress = null;
    return _downloadProgress = mine.ratio ?? 0;
  }

  void _syncFavorite() {
    final s = _song;
    _fav = s != null && s.mid.isNotEmpty && HistoryStore.isFavorite(s.mid);
  }

  void _loadLyrics() {
    final s = _song;
    if (s == null) {
      setState(() {
        _lyricsFuture = null;
        _lyricsKey = '';
      });
      return;
    }
    final key = '${s.source}:${s.mid}';
    if (key == _lyricsKey && _lyricsFuture != null) return;
    _lyricsKey = key;
    setState(() {
      _lyricsFuture = LyricApi.of(s);
    });
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    showAppSnack(msg);
  }

  Future<void> _toggleFavorite() async {
    final s = _song;
    if (s == null) return;
    setState(() {
      HistoryStore.toggleFavorite(s);
      _fav = HistoryStore.isFavorite(s.mid);
    });
    _showSnack(_fav ? '已收藏' : '已取消收藏');
  }

  Future<void> _togglePlay() async {
    setState(() => _playing = !_playing);
    _player.toggle();
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted) return;
    setState(() => _playing = _player.isPlaying);
  }

  Future<void> _seekTo(Duration pos) async {
    await _player.seek(pos);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _switchPlayMode() async {
    await _player.cyclePlayMode();
    if (!mounted) return;
    setState(() => _mode = _player.playMode);
    _showSnack(_mode.label);
  }

  // ===== 音质切换（按平台） =====

  Future<void> _pickQqQuality(Quality q) async {
    _showSnack('正在切换到 ${q.label}…');
    await _player.switchQuality(q);
    _refreshQuality();
  }

  Future<void> _pickNeteaseQuality(NeteaseQuality q) async {
    _showSnack('正在切换到 ${q.label}…');
    await _player.switchNeteaseQuality(q);
    _refreshQuality();
  }

  void _refreshQuality() {
    if (!mounted) return;
    setState(() {
      _actualQq = _player.actualQqQuality;
      _actualNe = _player.actualNeteaseQuality;
      _playing = _player.isPlaying;
    });
  }

  // ===== 下载（按平台选音质） =====

  /// 第一步：弹音质选择（Miuix 声明式弹层），选完再走 [_onDownloadQualityPicked]。
  Future<void> _download() async {
    final s = _song;
    if (s == null || _downloadProgress != null) return;
    setState(() {
      _pendingDownloadSong = s;
      _showDownloadQualitySheet = true;
    });
  }

  /// 第二步：音质与歌词粒度都已选好，落库并加入下载队列。
  ///
  /// [lyric] 是本次下载临时选择的歌词粒度（null = 跟随全局设置）。
  Future<void> _onDownloadQualityPicked(
      Object picked, LyricDownloadMode lyric) async {
    final s = _pendingDownloadSong;
    setState(() {
      _showDownloadQualitySheet = false;
      _pendingDownloadSong = null;
    });
    if (s == null) return;
    final dm = DownloadManager.instance;
    if (s.isNetease) {
      final q = picked as NeteaseQuality;
      await dm.saveNeQuality(q);
      await _runDownload(s, qq: dm.qqQuality, ne: q, lyric: lyric);
    } else {
      final q = picked as Quality;
      await dm.saveQqQuality(q);
      await _runDownload(s, qq: q, ne: dm.neQuality, lyric: lyric);
    }
  }

  /// 下载单曲。实际下载交给全局任务队列（进度可在下载管理页看），
  /// 本页只在下载完成后提示结果——播放器上只留一个轻量提示更干净。
  Future<void> _runDownload(
    Song song, {
    required Quality qq,
    required NeteaseQuality ne,
    LyricDownloadMode? lyric,
  }) async {
    if (!mounted) return;
    _showSnack('已加入下载队列');
    final path = await runManagedDownload(
      song,
      qqQuality: qq,
      neQuality: ne,
      lyricMode: lyric,
    );
    if (!mounted) return;
    if (path == null) {
      _showSnack('下载失败，可在下载管理查看原因', isError: true);
      return;
    }
    final name = path.split(Platform.pathSeparator).last;
    _showSnack('下载完成: $name');
  }

  /// 下载弹层里点歌词行：只下载歌词文件，不下载音乐。
  Future<void> _onLyricOnlyPicked(LyricDownloadMode mode) async {
    final s = _pendingDownloadSong ?? _song;
    setState(() {
      _showDownloadQualitySheet = false;
      _pendingDownloadSong = null;
    });
    if (s == null) return;
    _showSnack('正在下载歌词…');
    final r = await DownloadExtras.downloadLyricOnly(s, lyricMode: mode);
    if (!mounted) return;
    if (r == null) {
      _showSnack('歌词下载失败（无歌词资源或写入失败）', isError: true);
      return;
    }
    final name = r.path.split(Platform.pathSeparator).last;
    _showSnack('歌词已下载: $name（${r.mode.label}）');
  }

  /// 弹出音质选择底部弹层，返回用户选择的音质（取消返回 null）。
  ///
  /// 用 [isScrollControlled] + 固定 72% 高度 + [ListView.builder]，
  /// 保证 QQ 音乐 17 档（末档 AAC 48）一定能滚到、看得见。
  @override
  Widget build(BuildContext context) {
    final song = _song;
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    // 全出血页面：自绘顶栏 + 自带 SafeArea 与渐变底，不套 PageScaffold 的
    // 顶栏和内容 Padding（否则窗口 inset 会双重叠加）。
    return PageScaffold(
      showTopBar: false,
      snackbarHost: appSnackbarHostState,
      // Miuix 弹层统一挂在脚手架的 popup 作用域内（Stack 本身不占布局）
      bottomBar: _buildSheets(),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bg1, AppColors.bg0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // 顶栏：只保留返回键与音源标识（歌名/操作已下移到封面下方）
              _buildTopBar(song, landscape),

              if (song == null)
                Expanded(
                  child: Center(
                    child: Text('未在播放\n去搜索一首歌吧',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: AppColors.textTertiary, fontSize: 13)),
                  ),
                )
              else if (landscape)
                Expanded(child: _buildLandscape(song))
              else
                Expanded(child: _buildPortrait(song)),

              // 进度条 + 控制区
              _buildBottom(landscape),
            ],
          ),
        ),
      ),
    );
  }

  /// 播放页的全部声明式弹层（歌词样式 / 音频规格 / 下载音质 / 播放音质）。
  Widget _buildSheets() {
    final song = _song;
    return Stack(
      children: [
        // 歌词样式（字号 / 对齐 / 放大 / 字重 / 圆角 / 三色）
        showLyricStyleSheet(
          show: _showLyricStyleSheet,
          onDismiss: () => setState(() => _showLyricStyleSheet = false),
        ),
        // 音频规格
        MiuixOverlayBottomSheet(
          show: _showAudioSpecSheet,
          title: '音频规格',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () => setState(() => _showAudioSpecSheet = false),
          content: _AudioSpecSheet(
            onDismiss: () => setState(() => _showAudioSpecSheet = false),
          ),
        ),
        // 下载选项：歌词粒度（默认逐字，无逐字回退逐行）+ 音质（按平台）
        MiuixOverlayBottomSheet(
          show: _showDownloadQualitySheet,
          title: song != null && song.isNetease
              ? '下载 · 网易云音乐'
              : '下载 · QQ 音乐',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () => setState(() {
            _showDownloadQualitySheet = false;
            _pendingDownloadSong = null;
          }),
          content: song != null && song.isNetease
              ? DownloadOptionsSheet<NeteaseQuality>(
                  options: NeteaseQuality.downloadOptions,
                  current: DownloadManager.instance.neQuality,
                  label: (q) => q.label,
                  subtitle: (q) => q.ext.replaceFirst('.', '').toUpperCase(),
                  lyricMode: DownloadExtras.lyricMode,
                  onConfirm: (q, lyric) => _onDownloadQualityPicked(q, lyric),
                  onLyricOnly: _onLyricOnlyPicked,
                )
              : DownloadOptionsSheet<Quality>(
                  options: Quality.downloadOptions,
                  current: DownloadManager.instance.qqQuality,
                  label: (q) => q.label,
                  subtitle: (q) => q.bitrate > 0
                      ? '${q.bitrate} kbps · ${q.ext.replaceFirst('.', '').toUpperCase()}'
                      : q.ext.replaceFirst('.', '').toUpperCase(),
                  lyricMode: DownloadExtras.lyricMode,
                  onConfirm: (q, lyric) => _onDownloadQualityPicked(q, lyric),
                  onLyricOnly: _onLyricOnlyPicked,
                ),
        ),
        // 倍速调节（0.01~50 无级滑杆 + 常用预设）
        MiuixOverlayBottomSheet(
          show: _showRateSheet,
          title: '倍速播放',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () => setState(() => _showRateSheet = false),
          content: _RateSheet(
            rate: _rate,
            onDismiss: () => setState(() => _showRateSheet = false),
          ),
        ),
        // 播放音质切换（按平台）
        MiuixOverlayBottomSheet(
          show: _showPlayQualitySheet,
          title: song != null && song.isNetease
              ? '网易云音乐 · 播放音质'
              : 'QQ 音乐 · 播放音质',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () => setState(() => _showPlayQualitySheet = false),
          content: song != null && song.isNetease
              ? _QualitySheet<NeteaseQuality>(
                  options: NeteaseQuality.playbackOptions,
                  current: _player.currentNeteaseQuality,
                  label: (q) => q.label,
                  onSelect: (q) {
                    setState(() => _showPlayQualitySheet = false);
                    _pickNeteaseQuality(q);
                  },
                )
              : _QualitySheet<Quality>(
                  options: Quality.playbackOptions,
                  current: _player.currentQuality,
                  label: (q) => q.label,
                  onSelect: (q) {
                    setState(() => _showPlayQualitySheet = false);
                    _pickQqQuality(q);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildTopBar(Song? song, bool landscape) => Padding(
        padding: EdgeInsets.fromLTRB(6, landscape ? 2 : 8, 14, 0),
        child: Row(
          children: [
            MiuixIconButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Icon(Icons.keyboard_arrow_down_rounded,
                  color: AppColors.textSecondary, size: 28),
            ),
            const SizedBox(width: 2),
            Text('正在播放',
                style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
            const Spacer(),
            if (song != null) _SourceChip(song: song),
            const SizedBox(width: 4),
            // 评论（QQ / 网易云）：未登录可看，登录后可发；本地歌曲无评论
            MiuixIconButton(
              onPressed: () {
                final s = song;
                if (s == null || s.isLocal) return;
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SongCommentPage(song: s),
                ));
              },
              child: Icon(Icons.mode_comment_outlined,
                  size: 20, color: AppColors.textSecondary),
            ),
            // 歌词字号 / 对齐的快捷入口，不必绕到设置页
            MiuixIconButton(
              onPressed: () =>
                  setState(() => _showLyricStyleSheet = true),
              child: Icon(Icons.format_size_rounded,
                  color: AppColors.textSecondary, size: 20),
            ),
          ],
        ),
      );

  /// 竖屏：整屏封面页 → 左滑 → 歌词页。
  Widget _buildPortrait(Song song) => Column(
        children: [
          Expanded(
            child: PageView(
              controller: _pages,
              onPageChanged: (i) {
                if (mounted) setState(() => _pageIndex = i);
              },
              children: [
                _CoverPage(
                  song: song,
                  actions: _buildActions(),
                  compact: false,
                ),
                _buildLyrics(),
              ],
            ),
          ),
          _PageIndicator(
            index: _pageIndex,
            count: 2,
            onTap: (i) => _pages.animateToPage(
              i,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
            ),
          ),
        ],
      );

  /// 横屏：左侧封面 + 歌名 + 操作，右侧歌词。
  ///
  /// 关键点：左侧列宽固定为可用宽度的 40%，封面尺寸再按**可用高度**反推，
  /// 因此横屏下封面永远完整可见（旧实现写死 260px，横屏高度不足会被裁切）。
  Widget _buildLandscape(Song song) => LayoutBuilder(
        builder: (ctx, c) {
          final leftW = (c.maxWidth * 0.40).clamp(180.0, 420.0).toDouble();
          return Row(
            children: [
              SizedBox(
                width: leftW,
                child: _CoverPage(
                  song: song,
                  actions: _buildActions(),
                  compact: true,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(child: _buildLyrics()),
            ],
          );
        },
      );

  /// 封面下方的操作行：下载 + 音质切换 + 音频规格。
  Widget _buildActions() => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          _DownloadButton(
            enabled: _song != null,
            progress: _downloadProgress,
            onTap: _download,
          ),
          const SizedBox(width: 12),
          _QualityButton(
            song: _song,
            actualQq: _actualQq,
            actualNe: _actualNe,
            onOpenSheet: () =>
                setState(() => _showPlayQualitySheet = true),
          ),
          const SizedBox(width: 12),
          // 倍速（0.01~50 无级）：图标按钮与「音频规格」同款；
          // 非 1.0x 时高亮，当前值在弹层顶部大字显示
          MiuixIconButton(
            onPressed: _song == null
                ? null
                : () => setState(() => _showRateSheet = true),
            child: Icon(Icons.speed_rounded,
                size: 21,
                color: _rate != 1.0 ? AppColors.accent : AppColors.textSecondary),
          ),
          const SizedBox(width: 12),
          // 音频规格（采样率 / 比特率 / 声道 / 编码）
          MiuixIconButton(
            onPressed: _song == null
                ? null
                : () => setState(() => _showAudioSpecSheet = true),
            child: Icon(Icons.graphic_eq_rounded,
                size: 20, color: AppColors.accent),
          ),
        ],
      );

  /// 打开「音频规格」面板。
  ///
  /// 本地歌曲要读文件头、在线流要问解码器，都是异步的——先转圈再填，
  /// 不用弹窗先空着再突然跳出内容。

  Widget _buildBottom(bool landscape) {
    if (!landscape) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlayerProgressSection(onSeek: _seekTo),
          _ControlsRow(
            playing: _playing,
            mode: _mode,
            favorite: _fav,
            hasSong: _song != null,
            onToggle: _togglePlay,
            onPrev: () async {
              await _player.previous();
              if (!mounted) return;
              setState(() => _playing = _player.isPlaying);
            },
            onNext: () async {
              await _player.next();
              if (!mounted) return;
              setState(() => _playing = _player.isPlaying);
            },
            onMode: _switchPlayMode,
            onFavorite: _toggleFavorite,
          ),
          const SizedBox(height: 12),
        ],
      );
    }

    // 横屏竖向空间紧张：进度条与控制条并排，省下一整行的高度给封面/歌词
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Row(
        children: [
          Expanded(
              child: PlayerProgressSection(onSeek: _seekTo, inlineTime: true)),
          const SizedBox(width: 4),
          _ControlsRow(
            playing: _playing,
            mode: _mode,
            favorite: _fav,
            hasSong: _song != null,
            compact: true,
            onToggle: _togglePlay,
            onPrev: () async {
              await _player.previous();
              if (!mounted) return;
              setState(() => _playing = _player.isPlaying);
            },
            onNext: () async {
              await _player.next();
              if (!mounted) return;
              setState(() => _playing = _player.isPlaying);
            },
            onMode: _switchPlayMode,
            onFavorite: _toggleFavorite,
          ),
        ],
      ),
    );
  }

  Widget _buildLyrics() {
    final future = _lyricsFuture;
    if (future == null) {
      return Center(
          child: Text('暂无歌词',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 13)));
    }
    // 歌词卡片：半透明玻璃底 + 可调圆角（LyricSettings.corner）。
    // 圆角为 0 时退化成直角卡片，视觉上与旧版一致。
    final settings = LyricSettings.instance;
    final corner = settings.corner;
    return FutureBuilder<Lyrics>(
      future: future,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: SizedBox(
                width: 22,
                height: 22,
                child: MiuixCircularProgressIndicator(
                    strokeWidth: 2, size: 22)),
          );
        }
        final lyrics = snap.data;
        if (lyrics == null || lyrics.isEmpty) {
          return Center(
            child: Text('暂无歌词\n本曲可能没有提供歌词资源',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textTertiary, fontSize: 13)),
          );
        }
        // 网易云未登录时服务端只给逐行歌词（yrc 需要登录），
        // 这里给一条可关闭的提示，引导去登录拿逐字歌词。
        final song = _song;
        final showNeHint = song != null &&
            song.isNetease &&
            !MusicApi.isLoggedIn(song.source) &&
            !lyrics.hasWordTiming &&
            !_neLoginHintDismissed;
        return ClipRRect(
          borderRadius: BorderRadius.circular(corner),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.surfaceGlass,
              borderRadius: BorderRadius.circular(corner),
              border: Border.all(color: AppColors.strokeGlass),
            ),
            child: Column(
              children: [
                if (showNeHint) _buildNeteaseLoginHint(),
                Expanded(
                  child: AmllLyricsView(
                    key: ValueKey(_lyricsKey),
                    lyrics: lyrics,
                    onSeek: _seekTo,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 网易云未登录提示条：说明为什么只有逐行歌词，并提供去登录入口。
  Widget _buildNeteaseLoginHint() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
      child: Row(
        children: [
          Icon(Icons.lyrics_outlined,
              size: 15, color: AppColors.textTertiary),
          const SizedBox(width: 6),
          Expanded(
            child: Text('网易云未登录：仅逐行歌词，登录后显示逐字染色',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 12)),
          ),
          GestureDetector(
            onTap: () {
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const NeteaseLoginPage()));
            },
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text('去登录',
                  style: TextStyle(
                      color: AppColors.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
          ),
          GestureDetector(
            onTap: () =>
                setState(() => _neLoginHintDismissed = true),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Icon(Icons.close,
                  size: 15, color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 封面页 ====================

/// 整屏封面页：封面占满可用空间 → 居中歌名 → 操作行。
///
/// 封面边长 = min(可用宽, 可用高 - 预留) 并夹在 [110, 460]，
/// 竖屏下几乎顶满宽度，横屏下按高度收缩，两种方向都不会被裁切。
class _CoverPage extends StatelessWidget {
  const _CoverPage({
    required this.song,
    required this.actions,
    required this.compact,
  });

  final Song song;
  final Widget actions;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        // 预留：歌名（1~2 行）+ 操作行 + 间距
        final reserve = compact ? 112.0 : 152.0;
        final side = math.min(c.maxWidth - 28, c.maxHeight - reserve);
        final size = side.clamp(110.0, 460.0).toDouble();
        return SingleChildScrollView(
          // 极小尺寸下允许滚动，避免溢出报错
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _CoverArt(song: song, size: size),
                  SizedBox(height: compact ? 12 : 18),
                  _SongTitle(song: song, compact: compact),
                  SizedBox(height: compact ? 10 : 14),
                  actions,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 居中歌名 + 歌手/专辑。
class _SongTitle extends StatelessWidget {
  const _SongTitle({required this.song, required this.compact});

  final Song song;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final sub = <String>[
      if (song.singer.isNotEmpty) song.singer,
      if (song.album.isNotEmpty) song.album,
    ].join(' · ');

    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            song.name,
            textAlign: TextAlign.center,
            maxLines: compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 16 : 20,
              height: 1.28,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          if (sub.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              sub,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

/// 分页指示点（点击可跳页）。
class _PageIndicator extends StatelessWidget {
  const _PageIndicator({
    required this.index,
    required this.count,
    required this.onTap,
  });

  final int index;
  final int count;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 2, 0, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            MiuixPressable(
              onPressed: () => onTap(i),
              borderRadius: BorderRadius.circular(3),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: i == index ? 20 : 7,
                  height: 5,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: i == index ? AppColors.accent : AppColors.strokeGlass,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 音源标识。
class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final ne = song.isNetease;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppColors.strokeGlass),
      ),
      child: Text(
        ne ? '网易云音乐' : 'QQ 音乐',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: ne ? AppColors.accentAlt : AppColors.accent,
        ),
      ),
    );
  }
}

// ==================== 封面 ====================

class _CoverArt extends StatelessWidget {
  const _CoverArt({required this.song, required this.size});

  final Song song;
  final double size;

  /// 长按封面保存到相册。桌面端与 gal 不支持的平台会给出明确提示。
  Future<void> _saveCover(BuildContext context) async {
    void say(String text, {bool error = false}) {
      showAppSnack(text);
    }

    say('正在保存封面…');
    final r = await AlbumSaver.saveCover(song);
    switch (r.state) {
      case CoverSaveState.ok:
        say('封面已保存到相册 · ${AlbumSaver.albumName}');
      case CoverSaveState.noCover:
        say(r.message.isEmpty ? '这首歌没有封面' : r.message);
      case CoverSaveState.denied:
      case CoverSaveState.failed:
        say(r.message.isEmpty ? '保存封面失败' : r.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.11;
    return MiuixPressable(
      // 封面只响应长按（保存到相册）；给个空的 onPressed 让组件保持启用。
      onPressed: () {},
      onLongPress: () => _saveCover(context),
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
              color: AppColors.violet.withValues(alpha: 0.35),
              blurRadius: 34,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: CoverImage(song: song, size: size, radius: radius),
      ),
    );
  }
}

// ==================== 进度条 ====================

/// 进度条 + 时间标签（竖屏两行、横屏与控件同一行）。
///
/// 公开是为了让「进度条塌缩」回归能直接测生产组件（见
/// `test/player_progress_bar_test.dart`）。
class PlayerProgressSection extends StatelessWidget {
  const PlayerProgressSection({
    super.key,
    required this.onSeek,
    this.inlineTime = false,
  });

  final Future<void> Function(Duration) onSeek;

  /// true：时间标签与滑块同一行（横屏省高度）。
  final bool inlineTime;

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final player = PlayerController.instance;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inlineTime ? 0 : 22),
      child: StreamBuilder<Duration>(
        stream: player.onPositionChanged,
        initialData: player.position,
        builder: (ctx, posSnap) {
          final pos = posSnap.data ?? Duration.zero;
          return StreamBuilder<Duration>(
            stream: player.onDurationChanged,
            initialData: player.duration,
            builder: (ctx, durSnap) {
              final total = durSnap.data ?? Duration.zero;
              final maxMs = total.inMilliseconds > 0
                  ? total.inMilliseconds.toDouble()
                  : 1.0;
              final value = pos.inMilliseconds.clamp(0, maxMs.round());
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (inlineTime)
                    Row(
                      children: [
                        Text(_fmt(pos),
                            style: TextStyle(
                                fontSize: 11, color: AppColors.textTertiary)),
                        Expanded(child: _slider(maxMs, value)),
                        Text(_fmt(total),
                            style: TextStyle(
                                fontSize: 11, color: AppColors.textTertiary)),
                      ],
                    )
                  else ...[
                    _slider(maxMs, value),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_fmt(pos),
                              style: TextStyle(
                                  fontSize: 11, color: AppColors.textTertiary)),
                          Text(_fmt(total),
                              style: TextStyle(
                                  fontSize: 11, color: AppColors.textTertiary)),
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// 滑杆必须显式撑满宽度。
  ///
  /// [MiuixSlider] 内部是 `LayoutBuilder + SizedBox(height) + CustomPaint`，
  /// CustomPaint 无子节点时按内容尺寸（0 宽）测量——在 [Column] 的宽松横向
  /// 约束下会塌缩成轨道高度的一小截，视觉上就是「进度条不见了」
  /// （v2.3.0-fix3 用户反馈；倍速滑杆与歌词样式弹窗早已用同一手法规避）。
  /// 横屏时它位于 Row 的 [Expanded] 内（紧约束），撑满同样成立。
  Widget _slider(double maxMs, int value) => SizedBox(
        width: double.infinity,
        child: MiuixSlider(
          value: value.toDouble().clamp(0.0, maxMs),
          max: maxMs,
          onValueChanged: (v) => onSeek(Duration(milliseconds: v.round())),
        ),
      );
}

// ==================== 控制区 ====================

class _ControlsRow extends StatelessWidget {
  const _ControlsRow({
    required this.playing,
    required this.mode,
    required this.favorite,
    required this.hasSong,
    required this.onToggle,
    required this.onPrev,
    required this.onNext,
    required this.onMode,
    required this.onFavorite,
    this.compact = false,
  });

  final bool playing;
  final PlayMode mode;
  final bool favorite;
  final bool hasSong;
  final Future<void> Function() onToggle;
  final Future<void> Function() onPrev;
  final Future<void> Function() onNext;
  final Future<void> Function() onMode;
  final Future<void> Function() onFavorite;

  /// 横屏紧凑模式：按钮整体缩小。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final dim = hasSong ? AppColors.textPrimary : AppColors.textTertiary;
    final main = compact ? 46.0 : 62.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 0 : 16, 6, compact ? 0 : 16, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          MiuixIconButton(
            onPressed: hasSong ? () => onMode() : null,
            child: Icon(mode.icon,
                size: compact ? 19 : 22, color: AppColors.textSecondary),
          ),
          SizedBox(width: compact ? 8 : 0),
          MiuixIconButton(
            onPressed: hasSong ? () => onPrev() : null,
            child: Icon(Icons.skip_previous_rounded,
                size: compact ? 26 : 34, color: dim),
          ),
          SizedBox(width: compact ? 10 : 0),
          Container(
            width: main,
            height: main,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: hasSong
                    ? AppColors.neonGradient
                    : [AppColors.surfaceGlassStrong, AppColors.surfaceGlass],
              ),
              boxShadow: hasSong
                  ? [
                      BoxShadow(
                        color: AppColors.accent.withValues(alpha: 0.45),
                        blurRadius: 22,
                      )
                    ]
                  : null,
            ),
            child: MiuixIconButton(
              onPressed: hasSong ? () => onToggle() : null,
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: hasSong ? Colors.white : AppColors.textTertiary,
                size: main * 0.55,
              ),
            ),
          ),
          SizedBox(width: compact ? 10 : 0),
          MiuixIconButton(
            onPressed: hasSong ? () => onNext() : null,
            child: Icon(Icons.skip_next_rounded,
                size: compact ? 26 : 34, color: dim),
          ),
          SizedBox(width: compact ? 8 : 0),
          MiuixIconButton(
            onPressed: hasSong ? () => onFavorite() : null,
            child: Icon(
              favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              size: compact ? 20 : 23,
              color: favorite ? AppColors.aqua : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 音质按钮（按平台） ====================

/// 播放音质切换（封面下方的胶囊按钮）。
///
/// 选项、实际音质判定、切换调用**全部按歌曲所属平台分发**：
/// QQ 歌曲走 [Quality] / `switchQuality`，网易云歌曲走 [NeteaseQuality] /
/// `switchNeteaseQuality`。两者参数体系不同，混用会取不到流。
class _QualityButton extends StatelessWidget {
  const _QualityButton({
    required this.song,
    required this.actualQq,
    required this.actualNe,
    required this.onOpenSheet,
  });

  final Song? song;
  final Quality? actualQq;
  final NeteaseQuality? actualNe;

  /// 点击胶囊：打开「播放音质」Miuix 弹层（由页面状态驱动显隐）。
  final VoidCallback onOpenSheet;

  @override
  Widget build(BuildContext context) {
    final s = song;
    if (s == null) return _pill(label: '音质', downgraded: false, netease: false);
    return s.isNetease ? _neteaseMenu() : _qqMenu();
  }

  Widget _qqMenu() {
    final player = PlayerController.instance;
    final requested = player.currentQuality;
    final effective = actualQq ?? requested;
    final downgraded = actualQq != null && actualQq!.code != requested.code;

    return MiuixPressable(
      onPressed: onOpenSheet,
      borderRadius: BorderRadius.circular(19),
      child: _pill(
        label: effective.label,
        downgraded: downgraded,
        netease: false,
      ),
    );
  }

  Widget _neteaseMenu() {
    final player = PlayerController.instance;
    final requested = player.currentNeteaseQuality;
    final effective = actualNe ?? requested;
    final downgraded = actualNe != null && actualNe!.level != requested.level;

    return MiuixPressable(
      onPressed: onOpenSheet,
      borderRadius: BorderRadius.circular(19),
      child: _pill(
        label: effective.label,
        downgraded: downgraded,
        netease: true,
      ),
    );
  }

  static Widget _pill({
    required String label,
    required bool downgraded,
    required bool netease,
  }) =>
      Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceGlass,
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: AppColors.strokeGlass),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.high_quality_rounded,
                size: 16,
                color: downgraded
                    ? AppColors.warning
                    : (netease ? AppColors.accentAlt : AppColors.accent)),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: downgraded ? AppColors.warning : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      );
}

// ==================== 倍速调节面板 ====================

/// 倍速调节：0.01~50 无级滑杆（对数刻度）+ 常用预设。
///
/// 线性刻度下 1.0x 会挤在最左端约 2% 的行程里没法用，所以滑杆位置
/// 与倍率之间走**对数映射**：pos = ln(rate/min) / ln(max/min)，
/// 1.0x 落在约 46% 行程处，低倍速区间与高倍速区间都有足够的可调行程。
/// 拖动过程中实时生效（libmpv 改 speed 是无损操作，连续调节无爆音）。
class _RateSheet extends StatefulWidget {
  const _RateSheet({required this.rate, required this.onDismiss});

  final double rate;
  final VoidCallback onDismiss;

  @override
  State<_RateSheet> createState() => _RateSheetState();
}

class _RateSheetState extends State<_RateSheet> {
  late double _rate = widget.rate;

  static const _presets = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 5.0];

  double _posOf(double rate) => PlayerController.rateToPos(rate);

  double _rateOf(double pos) => PlayerController.posToRate(pos);

  static String _formatRate(double r) =>
      r == r.roundToDouble() ? r.toStringAsFixed(0) : r.toStringAsFixed(2);

  Future<void> _apply(double r) async {
    final clamped =
        r.clamp(PlayerController.minRate, PlayerController.maxRate);
    setState(() => _rate = clamped);
    await PlayerController.instance.setRate(clamped);
  }

  @override
  Widget build(BuildContext context) {
    final active = _rate != 1.0;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.speed_rounded,
                    size: 18,
                    color: active ? AppColors.accent : AppColors.textSecondary),
                const SizedBox(width: 8),
                Text(
                  '${_formatRate(_rate)}x',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color:
                        active ? AppColors.accent : AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                // 一键回正常速度
                if (active)
                  MiuixTextButton(
                    '恢复 1.0x',
                    onPressed: () async {
                      await _apply(1.0);
                      widget.onDismiss();
                    },
                    textStyle: TextStyle(color: AppColors.accent),
                  ),
              ],
            ),
            // CustomPaint 无子节点时在松约束（Column）下会缩成 0 宽——
            // 必须 SizedBox 强制撑满，否则滑杆整个不可见（v2.2.9-fix2）。
            SizedBox(
              width: double.infinity,
              child: MiuixSlider(
                value: _posOf(_rate).clamp(0.0, 1.0),
                min: 0.0,
                max: 1.0,
                steps: 0,
                onValueChanged: (v) => _apply(_rateOf(v)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${PlayerController.minRate.toStringAsFixed(2)}x ~ ${PlayerController.maxRate.toStringAsFixed(0)}x 无级调节；'
                '拖动即时生效，倍速会被记住（含下次启动）。',
                style:
                    TextStyle(fontSize: 11, color: AppColors.textTertiary),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in _presets)
                  MiuixPressable(
                    onPressed: () => _apply(p),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 13, vertical: 7),
                      decoration: BoxDecoration(
                        color: _rate == p
                            ? AppColors.accent.withValues(alpha: 0.15)
                            : AppColors.surfaceGlass,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: _rate == p
                                ? AppColors.accent
                                : AppColors.strokeGlass),
                      ),
                      child: Text(
                        '${_formatRate(p)}x',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _rate == p
                              ? AppColors.accent
                              : AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 下载按钮 ====================

/// 下载入口（封面下方的胶囊按钮）：下载中变为进度环 + 百分比。
class _DownloadButton extends StatelessWidget {
  const _DownloadButton({
    required this.enabled,
    required this.progress,
    required this.onTap,
  });

  final bool enabled;
  final double? progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final downloading = p != null;
    return MiuixPressable(
      onPressed: enabled && !downloading ? onTap : null,
      borderRadius: BorderRadius.circular(19),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceGlass,
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: AppColors.strokeGlass),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (downloading)
              SizedBox(
                width: 15,
                height: 15,
                child: MiuixCircularProgressIndicator(
                  // 服务端未返回总长度时（进度仍为 0）退化为不确定态
                  progress: p > 0 ? p : null,
                  strokeWidth: 2,
                  size: 15,
                ),
              )
            else
              Icon(Icons.download_rounded,
                  size: 16,
                  color: enabled ? AppColors.accent : AppColors.textTertiary),
            const SizedBox(width: 6),
            Text(
              downloading
                  ? (p > 0 ? '${(p * 100).round()}%' : '下载中')
                  : '下载',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color:
                    enabled ? AppColors.textSecondary : AppColors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 音质选择弹层 ====================

/// 通用音质选择底部弹层（泛型支持 QQ 的 [Quality] 与网易云的 [NeteaseQuality]）。
///
/// 旧实现用 `ConstrainedBox(maxHeight: 屏高 * 0.5)` + `SingleChildScrollView`，
/// QQ 音乐 17 档（末档 AAC 48）会被裁在可视区之外且没有滚动条提示。
/// 现在改为：固定 72% 屏高 + [ListView.builder] + 常驻滚动条，末档一定可滚到。
///
/// 由 [MiuixOverlayBottomSheet] 承载（标题 / 拖拽把手 / 圆角都是 Miuix 的），
/// 选中后回调 [onSelect]，显隐由页面状态驱动。
class _QualitySheet<T> extends StatelessWidget {
  const _QualitySheet({
    required this.options,
    required this.current,
    required this.label,
    required this.onSelect,
    this.subtitle,
  });

  final List<T> options;
  final T current;
  final String Function(T) label;
  final String Function(T)? subtitle;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.6;
    return SizedBox(
      height: height,
      child: Scrollbar(
        thumbVisibility: true,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
          itemCount: options.length,
          itemBuilder: (ctx, i) {
            final q = options[i];
            final selected = q == current;
            final sub = subtitle?.call(q) ?? '';
            return MiuixPressable(
              onPressed: () => onSelect(q),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.accent.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.audiotrack_rounded,
                      size: 18,
                      color: selected
                          ? AppColors.accent
                          : AppColors.textTertiary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label(q),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: selected
                                  ? AppColors.accent
                                  : AppColors.textPrimary,
                            ),
                          ),
                          if (sub.isNotEmpty)
                            Text(
                              sub,
                              style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textTertiary),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ==================== 歌词视图 ====================

/// 歌词区由 [AmllLyricsView]（flutter_lyric / AMLL 风格引擎）承担：
/// 逐字高亮、切句动效、滚动跟随、前奏倒计时、点击跳转都由引擎实现。
///
/// 旧的自绘实现（`_LyricView` + `KaraokeLine` 的 dstIn 遮罩）在
/// v2.3.0-fix3 及以前使用，用户连续反馈「逐字歌词没有」，已整体替换。

/// 音频规格面板：采样率 / 比特率 / 声道 / 容器与编码。
///
/// 数据来源分两种（见 [AudioSpecService]）：
/// 本地歌曲直接读文件头，在线流问 libmpv。拿不到的值显示「未知」而不是猜。
class _AudioSpecSheet extends StatefulWidget {
  const _AudioSpecSheet({required this.onDismiss});

  /// 关闭弹层（由页面状态驱动显隐）。
  final VoidCallback onDismiss;

  @override
  State<_AudioSpecSheet> createState() => _AudioSpecSheetState();
}

class _AudioSpecSheetState extends State<_AudioSpecSheet> {
  late Future<AudioSpec> _future;

  @override
  void initState() {
    super.initState();
    _future = AudioSpecService.ofCurrent();
  }

  @override
  Widget build(BuildContext context) {
    // 外层 Container / 拖拽把手 / SafeArea 由 MiuixOverlayBottomSheet 提供
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.graphic_eq_rounded,
                    size: 18, color: AppColors.accent),
                SizedBox(width: 8),
                Text(
                  '音频规格',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 14),
            FutureBuilder<AudioSpec>(
              future: _future,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 26),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: MiuixCircularProgressIndicator(
                            strokeWidth: 2, size: 22),
                      ),
                    ),
                  );
                }
                final spec = snap.data ?? const AudioSpec();
                if (spec.isEmpty) {
                  return Padding(
                    padding: EdgeInsets.symmetric(vertical: 22),
                    child: Text(
                      '没能读到这首歌的音频规格。'
                      '在线流要等解码器给出信息，如果刚切歌可以稍等几秒再打开。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  );
                }
                final items = spec.items;
                return Column(
                  children: [
                    for (final it in items)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 92,
                              child: Text(
                                it.label,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: AppColors.textTertiary,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                it.value,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 10),
                    Text(
                      '采样率越高还原细节越多；比特率是无损以外的音质档，'
                      '无损格式（FLAC / ALAC）通常不标注固定码率。',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.5,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            Center(
              child: MiuixTextButton('关闭', onPressed: widget.onDismiss),
            ),
          ],
        ),
      ),
    );
  }
}
