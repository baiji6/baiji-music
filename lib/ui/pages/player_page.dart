import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/data/history_store.dart';
import 'package:baiji_music/download/download_extras.dart';
import 'package:baiji_music/download/download_manager.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/lyric_api.dart';
import 'package:baiji_music/player/player_controller.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/core/album_saver.dart';
import 'package:baiji_music/ui/widgets/cover_image.dart';
import 'package:baiji_music/ui/widgets/lyric_style_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

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
  double? _downloadProgress;

  /// 当前歌曲的歌词Future（切歌时重建）。
  Future<Lyrics>? _lyricsFuture;
  String _lyricsKey = '';

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
    _pages.dispose();
    super.dispose();
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        backgroundColor: isError ? AppColors.danger : AppColors.cyan,
        duration: const Duration(seconds: 2),
      ),
    );
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

  Future<void> _download() async {
    final s = _song;
    if (s == null || _downloadProgress != null) return;

    final dm = DownloadManager.instance;
    if (s.isNetease) {
      final picked = await _pickQuality<NeteaseQuality>(
        title: '下载音质 · 网易云音乐',
        options: NeteaseQuality.downloadOptions,
        current: dm.neQuality,
        label: (q) => q.label,
        subtitle: (q) => q.ext.replaceFirst('.', '').toUpperCase(),
      );
      if (picked == null || !mounted) return;
      await dm.saveNeQuality(picked);
      await _runDownload(s, qq: dm.qqQuality, ne: picked);
    } else {
      final picked = await _pickQuality<Quality>(
        title: '下载音质 · QQ 音乐',
        options: Quality.downloadOptions,
        current: dm.qqQuality,
        label: (q) => q.label,
        subtitle: (q) => q.bitrate > 0
            ? '${q.bitrate} kbps · ${q.ext.replaceFirst('.', '').toUpperCase()}'
            : q.ext.replaceFirst('.', '').toUpperCase(),
      );
      if (picked == null || !mounted) return;
      await dm.saveQqQuality(picked);
      await _runDownload(s, qq: picked, ne: dm.neQuality);
    }
  }

  Future<void> _runDownload(
    Song song, {
    required Quality qq,
    required NeteaseQuality ne,
  }) async {
    if (!mounted) return;
    setState(() => _downloadProgress = 0);
    String? path;
    String? error;
    try {
      path = await DownloadManager.instance.download(
        song,
        qqQuality: qq,
        neQuality: ne,
        onProgress: (done, total) {
          if (!mounted) return;
          // 服务端未给出总长度时 total <= 0，退化为不确定进度
          setState(() => _downloadProgress =
              total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0);
        },
      );
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    if (error != null) {
      setState(() => _downloadProgress = null);
      _showSnack('下载失败: $error', isError: true);
      return;
    }
    if (path == null) {
      setState(() => _downloadProgress = null);
      _showSnack('下载失败（无可用直链）', isError: true);
      return;
    }

    // 音频已落盘，再按设置补齐歌词 / 封面并写入元数据：
    // 这一步失败只影响附加信息，不回滚音频，也不再显示进度条。
    String extra = '';
    try {
      extra = await DownloadExtras.attach(filePath: path, song: song);
    } catch (e) {
      AppLog.w('PlayerPage', '写入歌词/封面失败: $e');
    }
    if (!mounted) return;
    setState(() => _downloadProgress = null);
    final name = path.split(Platform.pathSeparator).last;
    _showSnack(extra.isEmpty ? '下载完成: $name' : '$name · $extra');
  }

  /// 弹出音质选择底部弹层，返回用户选择的音质（取消返回 null）。
  ///
  /// 用 [isScrollControlled] + 固定 72% 高度 + [ListView.builder]，
  /// 保证 QQ 音乐 17 档（末档 AAC 48）一定能滚到、看得见。
  Future<T?> _pickQuality<T>({
    required String title,
    required List<T> options,
    required T current,
    required String Function(T) label,
    String Function(T)? subtitle,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _QualitySheet<T>(
        title: title,
        options: options,
        current: current,
        label: label,
        subtitle: subtitle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final song = _song;
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
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
                const Expanded(
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

  Widget _buildTopBar(Song? song, bool landscape) => Padding(
        padding: EdgeInsets.fromLTRB(6, landscape ? 2 : 8, 14, 0),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded,
                  color: AppColors.textSecondary, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 2),
            const Text('正在播放',
                style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
            const Spacer(),
            if (song != null) _SourceChip(song: song),
            const SizedBox(width: 4),
            // 歌词字号 / 对齐的快捷入口，不必绕到设置页
            IconButton(
              tooltip: '歌词样式',
              icon: const Icon(Icons.format_size_rounded,
                  color: AppColors.textSecondary, size: 20),
              onPressed: () => showLyricStyleSheet(context),
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

  /// 封面下方的操作行：下载 + 音质切换。
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
            onQq: _pickQqQuality,
            onNetease: _pickNeteaseQuality,
          ),
        ],
      );

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
              setState(() => _playing = _player.isPlaying);
            },
            onNext: () async {
              await _player.next();
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
              setState(() => _playing = _player.isPlaying);
            },
            onNext: () async {
              await _player.next();
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
      return const Center(
          child: Text('暂无歌词',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 13)));
    }
    return FutureBuilder<Lyrics>(
      future: future,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.cyan)),
          );
        }
        final lyrics = snap.data;
        if (lyrics == null || lyrics.isEmpty) {
          return const Center(
            child: Text('暂无歌词\n本曲可能没有提供歌词资源',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textTertiary, fontSize: 13)),
          );
        }
        return _LyricView(
          key: ValueKey(_lyricsKey),
          lyrics: lyrics,
          onSeek: _seekTo,
          padFactor: padFactor,
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
              style: const TextStyle(
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
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: i == index ? 20 : 7,
                  height: 5,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: i == index ? AppColors.cyan : AppColors.strokeGlass,
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
          color: ne ? AppColors.magenta : AppColors.cyan,
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
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = messenger?.showSnackBar;
    void say(String text, {bool error = false}) {
      ok?.call(SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        backgroundColor: error ? AppColors.bg2 : null,
      ));
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
    return GestureDetector(
      onLongPress: () => _saveCover(context),
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
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.textTertiary)),
                        Expanded(child: _slider(maxMs, value)),
                        Text(_fmt(total),
                            style: const TextStyle(
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
                              style: const TextStyle(
                                  fontSize: 11, color: AppColors.textTertiary)),
                          Text(_fmt(total),
                              style: const TextStyle(
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

  Widget _slider(double maxMs, int value) => SliderTheme(
        data: SliderThemeData(
          trackHeight: 4,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          activeTrackColor: AppColors.cyan,
          inactiveTrackColor: AppColors.surfaceGlassStrong,
          thumbColor: AppColors.cyan,
        ),
        child: Slider(
          value: value.toDouble().clamp(0.0, maxMs),
          max: maxMs,
          onChanged: (v) => onSeek(Duration(milliseconds: v.round())),
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
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(mode.icon, size: compact ? 19 : 22),
            color: AppColors.textSecondary,
            tooltip: mode.label,
            onPressed: hasSong ? () => onMode() : null,
          ),
          SizedBox(width: compact ? 8 : 0),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(Icons.skip_previous_rounded, size: compact ? 26 : 34),
            color: dim,
            onPressed: hasSong ? () => onPrev() : null,
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
                        color: AppColors.cyan.withValues(alpha: 0.45),
                        blurRadius: 22,
                      )
                    ]
                  : null,
            ),
            child: IconButton(
              icon: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: hasSong ? Colors.white : AppColors.textTertiary,
                size: main * 0.55,
              ),
              onPressed: hasSong ? () => onToggle() : null,
            ),
          ),
          SizedBox(width: compact ? 10 : 0),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(Icons.skip_next_rounded, size: compact ? 26 : 34),
            color: dim,
            onPressed: hasSong ? () => onNext() : null,
          ),
          SizedBox(width: compact ? 8 : 0),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(
              favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              size: compact ? 20 : 23,
            ),
            color: favorite ? AppColors.aqua : AppColors.textSecondary,
            tooltip: favorite ? '取消收藏' : '收藏',
            onPressed: hasSong ? () => onFavorite() : null,
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
    required this.onQq,
    required this.onNetease,
  });

  final Song? song;
  final Quality? actualQq;
  final NeteaseQuality? actualNe;
  final ValueChanged<Quality> onQq;
  final ValueChanged<NeteaseQuality> onNetease;

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

    return PopupMenuButton<String>(
      tooltip: downgraded
          ? 'QQ 音乐音质：请求 ${requested.label}，实际 $effective（已降级）'
          : 'QQ 音乐音质',
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      color: AppColors.bg2,
      onSelected: (code) {
        final q = Quality.fromCode(code);
        if (q != null) onQq(q);
      },
      itemBuilder: (ctx) => [
        const PopupMenuItem<String>(
          enabled: false,
          child: Text('QQ 音乐 · 播放音质',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
        ),
        for (final q in Quality.playbackOptions)
          PopupMenuItem<String>(
            value: q.code,
            child: _menuRow(
              label: q.label,
              checked: q.code == effective.code,
            ),
          ),
      ],
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

    return PopupMenuButton<String>(
      tooltip: downgraded
          ? '网易云音质：请求 ${requested.label}，实际 $effective（已降级）'
          : '网易云音质',
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      color: AppColors.bg2,
      onSelected: (level) {
        final q = NeteaseQuality.fromLevel(level);
        if (q != null) onNetease(q);
      },
      itemBuilder: (ctx) => [
        const PopupMenuItem<String>(
          enabled: false,
          child: Text('网易云音乐 · 播放音质',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
        ),
        for (final q in NeteaseQuality.playbackOptions)
          PopupMenuItem<String>(
            value: q.level,
            child: _menuRow(
              label: q.label,
              checked: q.level == effective.level,
            ),
          ),
      ],
      child: _pill(
        label: effective.label,
        downgraded: downgraded,
        netease: true,
      ),
    );
  }

  static Widget _menuRow({required String label, required bool checked}) =>
      Row(
        children: [
          Icon(
            checked ? Icons.check_rounded : Icons.audiotrack_rounded,
            size: 16,
            color: checked ? AppColors.cyan : AppColors.textTertiary,
          ),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      );

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
                    : (netease ? AppColors.magenta : AppColors.cyan)),
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
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(19),
        onTap: enabled && !downloading ? onTap : null,
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
                  child: CircularProgressIndicator(
                    // 服务端未返回总长度时（进度仍为 0）退化为不确定态
                    value: p > 0 ? p : null,
                    strokeWidth: 2,
                    color: AppColors.cyan,
                  ),
                )
              else
                Icon(Icons.download_rounded,
                    size: 16,
                    color: enabled ? AppColors.cyan : AppColors.textTertiary),
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
class _QualitySheet<T> extends StatelessWidget {
  const _QualitySheet({
    required this.title,
    required this.options,
    required this.current,
    required this.label,
    this.subtitle,
  });

  final String title;
  final List<T> options;
  final T current;
  final String Function(T) label;
  final String Function(T)? subtitle;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.72;
    return Container(
      height: height,
      decoration: const BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 拖拽把手
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.strokeGlass,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w900),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    color: AppColors.textTertiary,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded,
                      size: 12, color: AppColors.textTertiary),
                  const SizedBox(width: 5),
                  const Expanded(
                    child: Text(
                      '若所选音质不可用，会自动降级到最近的一档可用音质',
                      style:
                          TextStyle(fontSize: 11, color: AppColors.textTertiary),
                    ),
                  ),
                  Text('共 ${options.length} 档',
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textTertiary)),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.strokeGlass),
            Expanded(
              child: Scrollbar(
                thumbVisibility: true,
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
                  itemCount: options.length,
                  itemBuilder: (ctx, i) {
                    final q = options[i];
                    final selected = q == current;
                    final sub = subtitle?.call(q) ?? '';
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => Navigator.of(context).pop(q),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: selected
                                ? AppColors.cyan.withValues(alpha: 0.12)
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
                                    ? AppColors.cyan
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
                                            ? AppColors.cyan
                                            : AppColors.textPrimary,
                                      ),
                                    ),
                                    if (sub.isNotEmpty)
                                      Text(
                                        sub,
                                        style: const TextStyle(
                                            fontSize: 10,
                                            color: AppColors.textTertiary),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
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
    _scroll.dispose();
    super.dispose();
  }

  void _setAnchor(Duration d) {
    _anchorMs = d.inMilliseconds;
    _anchorAt = DateTime.now();
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

  /// 逐帧只做一件事：判断当前唱到哪一行了。
  void _onTick(Duration elapsed) {
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
      // 暂停时行号不该变，但补一次同步能纠正拖动进度条后的小偏差
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
    _resumeTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      _userDragging = false;
      _scrollToActive();
    });
  }

  Widget _buildLine(LyricLine line,
      {required bool isActive, required bool sung}) {
    final settings = LyricSettings.instance;
    final baseColor = isActive
        ? AppColors.textPrimary
        : (sung ? AppColors.textSecondary : AppColors.textTertiary);

    // 当前行放大并加粗，是整屏的视觉重心；非当前行压小一档形成层次。
    final size =
        isActive ? settings.fontSize * settings.activeScale : settings.fontSize;
    final weight = isActive ? FontWeight.w800 : FontWeight.w500;
    final height = isActive ? 1.32 : 1.45;

    if (!line.isWordLevel) {
      return Text(
        line.displayText,
        textAlign: settings.textAlign,
        style: TextStyle(
          fontSize: size,
          height: height,
          fontWeight: weight,
          color: baseColor,
        ),
      );
    }

    // 逐字信息仍被完整渲染（歌词里可能有逐字标注），但不再按播放进度染色——
    // 整行统一高亮放大，观感更接近主流播放器。
    return RichText(
      textAlign: settings.textAlign,
      text: TextSpan(
        children: [
          for (final w in line.words)
            TextSpan(
              text: w.text,
              style: TextStyle(
                fontSize: size,
                height: height,
                fontWeight: weight,
                color: baseColor,
              ),
            ),
        ],
      ),
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
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onSeek(Duration(milliseconds: line.startMs)),
              child: Container(
                key: _keys[i],
                width: double.infinity,
                // 当前行字号变大了，行距也相应放宽，避免上下行贴上来
                padding: EdgeInsets.symmetric(
                    horizontal: 26, vertical: isActive ? 16 : 9),
                child: Column(
                  crossAxisAlignment: settings.alignLeft
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.center,
                  children: [
                    _buildLine(line, isActive: isActive, sung: i < _active),
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
