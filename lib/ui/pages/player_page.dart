import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/data/history_store.dart';
import 'package:baiji_music/download/download_manager.dart';
import 'package:baiji_music/download/download_task.dart';
import 'package:baiji_music/lyrics/karaoke_fill.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/metadata/audio_spec.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/lyric_api.dart';
import 'package:baiji_music/player/player_controller.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/core/album_saver.dart';
import 'package:baiji_music/ui/widgets/app_snackbar.dart';
import 'package:baiji_music/ui/widgets/app_widgets.dart';
import 'package:baiji_music/ui/widgets/cover_image.dart';
import 'package:baiji_music/ui/widgets/lyric_style_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/scheduler.dart';
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

  @override
  void initState() {
    super.initState();
    _song = _player.currentSong;
    _mode = _player.playMode;
    _actualQq = _player.actualQqQuality;
    _actualNe = _player.actualNeteaseQuality;
    _playing = _player.isPlaying;
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
  }

  @override
  void dispose() {
    _songSub?.cancel();
    _qualitySub?.cancel();
    _neQualitySub?.cancel();
    _playSub?.cancel();
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

  /// 第二步：音质已选好，落库并加入下载队列。
  Future<void> _onDownloadQualityPicked(Object picked) async {
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
      await _runDownload(s, qq: dm.qqQuality, ne: q);
    } else {
      final q = picked as Quality;
      await dm.saveQqQuality(q);
      await _runDownload(s, qq: q, ne: dm.neQuality);
    }
  }

  /// 下载单曲。实际下载交给全局任务队列（进度可在下载管理页看），
  /// 本页只在下载完成后提示结果——播放器上只留一个轻量提示更干净。
  Future<void> _runDownload(
    Song song, {
    required Quality qq,
    required NeteaseQuality ne,
  }) async {
    if (!mounted) return;
    _showSnack('已加入下载队列');
    final path = await runManagedDownload(song, qqQuality: qq, neQuality: ne);
    if (!mounted) return;
    if (path == null) {
      _showSnack('下载失败，可在下载管理查看原因', isError: true);
      return;
    }
    final name = path.split(Platform.pathSeparator).last;
    _showSnack('下载完成: $name');
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
        // 下载音质（按平台）
        MiuixOverlayBottomSheet(
          show: _showDownloadQualitySheet,
          title: song != null && song.isNetease
              ? '下载音质 · 网易云音乐'
              : '下载音质 · QQ 音乐',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () => setState(() {
            _showDownloadQualitySheet = false;
            _pendingDownloadSong = null;
          }),
          content: song != null && song.isNetease
              ? _QualitySheet<NeteaseQuality>(
                  options: NeteaseQuality.downloadOptions,
                  current: DownloadManager.instance.neQuality,
                  label: (q) => q.label,
                  subtitle: (q) => q.ext.replaceFirst('.', '').toUpperCase(),
                  onSelect: (q) => _onDownloadQualityPicked(q),
                )
              : _QualitySheet<Quality>(
                  options: Quality.downloadOptions,
                  current: DownloadManager.instance.qqQuality,
                  label: (q) => q.label,
                  subtitle: (q) => q.bitrate > 0
                      ? '${q.bitrate} kbps · ${q.ext.replaceFirst('.', '').toUpperCase()}'
                      : q.ext.replaceFirst('.', '').toUpperCase(),
                  onSelect: (q) => _onDownloadQualityPicked(q),
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
                _buildLyrics(padFactor: 0.3),
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
              Expanded(child: _buildLyrics(padFactor: 0.18)),
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
          _ProgressSection(onSeek: _seekTo),
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
          Expanded(child: _ProgressSection(onSeek: _seekTo, inlineTime: true)),
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

  Widget _buildLyrics({required double padFactor}) {
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
        return ClipRRect(
          borderRadius: BorderRadius.circular(corner),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.surfaceGlass,
              borderRadius: BorderRadius.circular(corner),
              border: Border.all(color: AppColors.strokeGlass),
            ),
            child: _LyricView(
              key: ValueKey(_lyricsKey),
              lyrics: lyrics,
              onSeek: _seekTo,
              padFactor: padFactor,
            ),
          ),
        );
      },
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

class _ProgressSection extends StatelessWidget {
  const _ProgressSection({required this.onSeek, this.inlineTime = false});

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

  Widget _slider(double maxMs, int value) => MiuixSlider(
        value: value.toDouble().clamp(0.0, maxMs),
        max: maxMs,
        onValueChanged: (v) => onSeek(Duration(milliseconds: v.round())),
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

/// 歌词区：逐帧平滑的卡拉 OK 染色 + 自动滚动 + 点击跳转。
///
/// 平滑要点（旧实现按 100ms 节流整列表重建，肉眼可见卡顿与跳变）：
/// 1. 播放头由 [Ticker] 逐帧推进，并在播放器上报的真实进度之间做墙钟插值，
///    因此不再受 100ms 上报间隔限制，进度是连续的；
/// 2. 只有"当前行"订阅播放头，其余行静态渲染，逐帧重建被限制在一行之内；
/// 3. 单字进度经 smoothstep 缓动，消除线性染色的生硬边界。
class _LyricView extends StatefulWidget {
  const _LyricView({
    super.key,
    required this.lyrics,
    required this.onSeek,
    required this.padFactor,
  });

  final Lyrics lyrics;
  final Future<void> Function(Duration) onSeek;

  /// 上下留白占屏高比例（竖屏整页歌词留白大，横屏收紧）。
  final double padFactor;

  @override
  State<_LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<_LyricView>
    with SingleTickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();
  final List<GlobalKey> _keys = [];

  Ticker? _ticker;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playSub;

  int _active = -1;
  bool _userDragging = false;
  Timer? _resumeTimer;

  /// 逐帧的播放位置（毫秒），专供逐字卡拉 OK 染色使用。
  ///
  /// 不能直接依赖 setState：逐字染色需要**每帧**都重绘当前行，
  /// 而行号变化一整首歌也就几十次。所以单独用 notifier 驱动，
  /// 只有当前行内部的 [ValueListenableBuilder] 会重建。
  final ValueNotifier<int> _head = ValueNotifier<int>(0);

  /// 播放器最近一次上报的真实进度 + 对应墙钟时刻，用于插值出平滑进度。
  int _anchorMs = 0;
  DateTime _anchorAt = DateTime.now();
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.lyrics.length; i++) {
      _keys.add(GlobalKey());
    }
    final player = PlayerController.instance;
    _playing = player.isPlaying;
    // 先定好当前行，再设基准——否则 _setAnchor 会在 initState 期间触发 setState
    _active = widget.lyrics.indexAt(player.position);
    _setAnchor(player.position);
    _head.value = player.position.inMilliseconds;

    _posSub = player.onPositionChanged.listen(_setAnchor);
    _playSub = player.onPlayStateChanged.listen((p) {
      _playing = p;
      // 暂停/恢复都必须重置基准，否则暂停期间会继续插值、恢复时瞬间跳变
      _setAnchor(player.position);
      _syncTicker();
    });
    _syncTicker();

    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scrollToActive(animate: false));
  }

  @override
  void didUpdateWidget(covariant _LyricView old) {
    super.didUpdateWidget(old);
    if (old.lyrics.length != widget.lyrics.length) {
      _keys.clear();
      for (var i = 0; i < widget.lyrics.length; i++) {
        _keys.add(GlobalKey());
      }
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _playSub?.cancel();
    _resumeTimer?.cancel();
    _ticker?.dispose();
    _head.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _setAnchor(Duration d) {
    _anchorMs = d.inMilliseconds;
    _anchorAt = DateTime.now();
    // 暂停时 Ticker 不跑，逐字染色的播放头不会自己前进。seek（点击歌词）
    // 后必须在这里补齐，否则高亮行对了、行内填充边界还停在旧位置。
    if (_head.value != _anchorMs) _head.value = _anchorMs;
    _syncActive();
  }

  /// 在真实进度上叠加墙钟走时，得到逐帧连续的播放位置（毫秒）。
  int _smoothMs() {
    if (!_playing) return _anchorMs;
    final est = _anchorMs + DateTime.now().difference(_anchorAt).inMilliseconds;
    final total = PlayerController.instance.duration.inMilliseconds;
    if (total > 0 && est > total) return total;
    return est < 0 ? 0 : est;
  }

  void _syncActive() {
    final idx = widget.lyrics.indexAt(Duration(milliseconds: _smoothMs()));
    if (idx == _active) return;
    if (!mounted) return;
    setState(() => _active = idx);
    _scrollToActive();
  }

  /// 逐帧做两件事：更新逐字染色的播放头、判断当前唱到哪一行。
  void _onTick(Duration elapsed) {
    final ms = _smoothMs();
    // 逐字染色靠这个 notifier 每帧推进；只在值真的变了时才通知，
    // 避免无谓重建。
    if (_head.value != ms) _head.value = ms;
    _syncActive();
  }

  /// 只在播放时跑 Ticker，暂停时停掉（省电，也避免无意义的重建）。
  void _syncTicker() {
    if (_playing) {
      _ticker ??= createTicker(_onTick);
      if (!_ticker!.isActive) _ticker!.start();
    } else {
      final t = _ticker;
      if (t != null && t.isActive) t.stop();
      // 暂停时行号不该变，但补一次同步能纠正拖动进度条后的偏差；
      // 逐字染色的播放头同样要跟上，否则拖完进度条颜色还停在原地。
      final ms = _smoothMs();
      if (_head.value != ms) _head.value = ms;
      _syncActive();
    }
  }

  void _scrollToActive({bool animate = true}) {
    if (_userDragging) return;
    if (_active < 0 || _active >= _keys.length) return;
    final ctx = _keys[_active].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.42,
      duration: animate ? const Duration(milliseconds: 380) : Duration.zero,
      curve: Curves.easeOutCubic,
    );
  }

  void _onUserScroll() {
    _userDragging = true;
    _resumeTimer?.cancel();
    // 用户停止滑动 5 秒后，歌词自动滚回当前播放位置（需求：5s 自动定位）。
    _resumeTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      _userDragging = false;
      _scrollToActive();
    });
  }

  Widget _buildLine(LyricLine line, {required bool isActive}) {
    final settings = LyricSettings.instance;

    // 当前行轻微放大加粗，是整屏的视觉重心；非当前行压一档形成层次。
    final size =
        isActive ? settings.fontSize * settings.activeScale : settings.fontSize;
    final weight = isActive ? settings.activeWeight : settings.inactiveWeight;
    final height = isActive ? 1.32 : 1.45;

    if (!line.isWordLevel) {
      final color =
          isActive ? settings.unsungColor : settings.inactiveColor;
      return Text(
        line.displayText,
        textAlign: settings.textAlign,
        style: TextStyle(
          fontSize: size,
          height: height,
          fontWeight: weight,
          color: color,
        ),
      );
    }

    // 非当前行统一暗灰：**不区分已唱 / 未唱**。
    //
    // 参考视频里层次完全由"当前行白字被逐字填成绿色、其余暗灰"建立，
    // 已唱过的行并没有更亮的残留色——那样整屏会散出一堆半亮不亮的中灰，
    // 行与行之间读不清。颜色统一后逐字 span 可以合并成整行 Text。
    if (!isActive) {
      return Text(
        line.displayText,
        textAlign: settings.textAlign,
        style: TextStyle(
          fontSize: size,
          height: height,
          fontWeight: weight,
          color: settings.inactiveColor,
        ),
      );
    }

    // 当前行：逐字填充 + 轻微放大。放大只影响字号，
    // 逐字填满是另一条独立的渲染链路，两者不能互相取代。
    return _KaraokeLine(
      line: line,
      head: _head,
      fontSize: size,
      height: height,
      align: settings.textAlign,
      weight: settings.activeWeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.lyrics;
    final settings = LyricSettings.instance;
    // 监听字号 / 对齐设置变化，改动后歌词立即重排
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is UserScrollNotification) _onUserScroll();
          return false;
        },
        child: ListView.builder(
          controller: _scroll,
          padding: EdgeInsets.symmetric(
              vertical: MediaQuery.of(context).size.height * widget.padFactor),
          itemCount: lyrics.length,
          itemBuilder: (ctx, i) {
            final line = lyrics[i];
            final isActive = i == _active;
            return MiuixPressable(
              onPressed: () => widget.onSeek(Duration(milliseconds: line.startMs)),
              child: Container(
                key: _keys[i],
                width: double.infinity,
                // 当前行字号略大，行距相应放宽一点即可（不需要原来 16那么大的留白）
                padding: EdgeInsets.symmetric(
                    horizontal: 26, vertical: isActive ? 11 : 9),
                child: Column(
                  crossAxisAlignment: settings.alignLeft
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.center,
                  children: [
                    _buildLine(line, isActive: isActive),
                    if (line.translation != null &&
                        line.translation!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: SizedBox(
                          width: double.infinity,
                          child: Text(
                            line.translation!,
                            textAlign: settings.textAlign,
                            style: TextStyle(
                              fontSize: isActive
                                  ? settings.fontSize * 0.8 * settings.activeScale
                                  : settings.fontSize * 0.8,
                              height: 1.35,
                              color: isActive
                                  ? AppColors.textSecondary
                                  : AppColors.textTertiary
                                      .withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ),
                    if (line.romanization != null &&
                        line.romanization!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: SizedBox(
                          width: double.infinity,
                          child: Text(
                            line.romanization!,
                            textAlign: settings.textAlign,
                            style: TextStyle(
                              fontSize: isActive
                                  ? settings.fontSize * 0.72 * settings.activeScale
                                  : settings.fontSize * 0.72,
                              height: 1.3,
                              color: isActive
                                  ? AppColors.textSecondary
                                  : AppColors.textTertiary
                                      .withValues(alpha: 0.6),
                            ),
                          ),
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

/// 当前行的逐字卡拉 OK 填充。
///
/// 严格对照视频效果：每个字在自己的起止时间内**从左往右逐渐填满**——
/// 字的左半是已唱色、右半是未唱色，填充边界是一条竖线，随播放推进扫过
/// 整个字，直到该字结束才完全变绿。**不是**整字一起渐变跳色。
///
/// 实现方式：[ShaderMask] + 分段 [LinearGradient]。
/// - 用 [TextPainter] 量出每个字在行内的水平区间 `[left, right]`（文本
///   不变时缓存，播放期间只重算填充进度，不重新排版）；
/// - 每个字按 `progressAt` 算出填充前沿 `left + 宽度×进度`，在渐变上放
///   「前沿之前 = 已唱色、之后 = 未唱色」的硬 stop，即得到竖直边界；
/// - `BlendMode.srcIn` 用渐变整体替换文字颜色，文字本身的 alpha（字形）
///   原样保留。
///
/// 与"整行放大"是两条独立的渲染链路：放大决定字号，逐字填充决定颜色，
/// 两者必须同时存在——只放大不填充，逐字歌词就等于没了。
class _KaraokeLine extends StatefulWidget {
  const _KaraokeLine({
    required this.line,
    required this.head,
    required this.fontSize,
    required this.height,
    required this.align,
    required this.weight,
  });

  final LyricLine line;
  final ValueListenable<int> head;
  final double fontSize;
  final double height;
  final TextAlign align;

  /// 当前行字重。字重变化会改变每个字的字形宽度，缓存必须失效重量排。
  final FontWeight weight;

  @override
  State<_KaraokeLine> createState() => _KaraokeLineState();
}

class _KaraokeLineState extends State<_KaraokeLine> {
  /// 每个字在行内的水平区间（像素）。空列表 = 该字无文本（QRC 罗马音占位）。
  List<List<double>>? _wordSpans;

  /// 量取 [_wordSpans] 时使用的排版宽度，用于判断缓存是否失效。
  double _laidWidth = -1;

  /// 排版后的内容宽度（归一化 stop 用；多行换行时等于排版宽度）。
  double _contentWidth = 0;

  TextSpan _span(Color color) => TextSpan(
        children: [
          for (final w in widget.line.words)
            TextSpan(
              text: w.text,
              style: TextStyle(
                fontSize: widget.fontSize,
                height: widget.height,
                fontWeight: widget.weight,
                color: color,
              ),
            ),
        ],
      );

  /// 用 TextPainter 量每个字的水平区间。文本/字号/宽度不变时直接复用，
  /// 避免每帧重排版——播放期间这里只在进度 tick 里被调用。
  void _measure(double maxWidth) {
    if (_wordSpans != null && _laidWidth == maxWidth) return;
    final painter = TextPainter(
      text: _span(LyricSettings.instance.unsungColor),
      textAlign: widget.align,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);

    final spans = <List<double>>[];
    var offset = 0;
    for (final w in widget.line.words) {
      final len = w.text.length;
      if (len > 0) {
        final boxes = painter.getBoxesForSelection(
          TextSelection(baseOffset: offset, extentOffset: offset + len),
        );
        if (boxes.isNotEmpty) {
          var left = double.infinity;
          var right = double.negativeInfinity;
          for (final b in boxes) {
            if (b.left < left) left = b.left;
            if (b.right > right) right = b.right;
          }
          spans.add([left, right]);
        } else {
          spans.add(const <double>[]);
        }
      } else {
        spans.add(const <double>[]);
      }
      offset += len;
    }
    _wordSpans = spans;
    _contentWidth = painter.width;
    _laidWidth = maxWidth;
    painter.dispose();
  }

  @override
  void didUpdateWidget(covariant _KaraokeLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.line != widget.line ||
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.height != widget.height ||
        oldWidget.align != widget.align ||
        oldWidget.weight != widget.weight) {
      _wordSpans = null;
    }
  }

  @override
  void dispose() {
    _wordSpans = null;
    super.dispose();
  }

  Gradient? _buildGradient(int posMs) {
    final spans = _wordSpans;
    if (spans == null || _contentWidth <= 0) return null;

    // 已唱 / 未唱色来自 LyricSettings（默认荧光黄绿 + 亮白，可在设置里
    // 自定义）。分段逻辑在 KaraokeFill 里，那里是纯函数，有独立单测。
    final settings = LyricSettings.instance;
    final built = KaraokeFill.build(
      wordSpans: spans,
      ratios: [
        for (final w in widget.line.words) w.progressAt(posMs),
      ],
      width: _contentWidth,
      sung: settings.sungColor,
      unsung: settings.unsungColor,
    );
    if (built == null) return null;
    return LinearGradient(
      colors: built.$2,
      stops: built.$1,
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: widget.head,
        builder: (ctx, posMs, _) => LayoutBuilder(
          builder: (ctx, constraints) {
            final maxWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : double.infinity;
            _measure(maxWidth);
            final gradient = _buildGradient(posMs);
            final child = RichText(
              textAlign: widget.align,
              text: _span(LyricSettings.instance.unsungColor),
            );
            if (gradient == null) return child;
            return ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) => gradient.createShader(bounds),
              child: child,
            );
          },
        ),
      ),
    );
  }
}
