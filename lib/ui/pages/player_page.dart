import 'dart:async';
import 'dart:io';

import 'package:baiji_music/data/history_store.dart';
import 'package:baiji_music/download/download_manager.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/lyric_api.dart';
import 'package:baiji_music/player/player_controller.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/ui/widgets/app_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 播放页：封面 + 进度条 + 播放控制 + 平台化音质切换 + 下载 + 歌词（逐字/译文/点击跳转）。
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final _player = PlayerController.instance;

  Song? _song;
  PlayMode _mode = PlayMode.sequential;
  Quality? _actualQq;
  NeteaseQuality? _actualNe;
  bool _playing = false;
  bool _fav = false;

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
    setState(() => _downloadProgress = null);
    if (error != null) {
      _showSnack('下载失败: $error', isError: true);
    } else if (path != null) {
      _showSnack('下载完成: ${path.split(Platform.pathSeparator).last}');
    } else {
      _showSnack('下载失败（无可用直链）', isError: true);
    }
  }

  /// 弹出音质选择底部弹层，返回用户选择的音质（取消返回 null）。
  Future<T?> _pickQuality<T>({
    required String title,
    required List<T> options,
    required T current,
    required String Function(T) label,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _QualitySheet<T>(
        title: title,
        options: options,
        current: current,
        label: label,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final song = _song;
    final size = MediaQuery.of(context).size;
    final wide = size.width > 760;

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
              // 顶栏
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down_rounded,
                          color: AppColors.textSecondary, size: 28),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            song?.name ?? '未在播放',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            song?.singer ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textTertiary),
                          ),
                        ],
                      ),
                    ),
                    _DownloadButton(
                      enabled: song != null,
                      progress: _downloadProgress,
                      onTap: _download,
                    ),
                    const SizedBox(width: 6),
                    _QualityButton(
                      song: song,
                      actualQq: _actualQq,
                      actualNe: _actualNe,
                      onQq: _pickQqQuality,
                      onNetease: _pickNeteaseQuality,
                    ),
                  ],
                ),
              ),

              if (song == null)
                const Expanded(
                  child: Center(
                    child: Text('未在播放\n去搜索一首歌吧',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: AppColors.textTertiary, fontSize: 13)),
                  ),
                )
              else if (wide)
                Expanded(
                    child: _buildWide(song))
              else
                Expanded(child: _buildNarrow(song)),

              // 进度条 + 控制区
              _ProgressSection(onSeek: _seekTo),
              _ControlsRow(
                playing: _playing,
                mode: _mode,
                favorite: _fav,
                hasSong: song != null,
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
          ),
        ),
      ),
    );
  }

  /// 窄屏：封面在上，歌词在下。
  Widget _buildNarrow(Song song) => Column(
        children: [
          const SizedBox(height: 10),
          _CoverArt(song: song, size: 200),
          const SizedBox(height: 14),
          Expanded(child: _buildLyrics()),
        ],
      );

  /// 宽屏：左侧封面，右侧歌词。
  Widget _buildWide(Song song) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Center(child: _CoverArt(song: song, size: 260)),
          ),
          Expanded(child: _buildLyrics()),
        ],
      );

  Widget _buildLyrics() {
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
        );
      },
    );
  }
}

// ==================== 封面 ====================

class _CoverArt extends StatelessWidget {
  const _CoverArt({required this.song, required this.size});

  final Song song;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = song.coverUrl;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: AppColors.violet.withValues(alpha: 0.35),
            blurRadius: 34,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: url.isEmpty
            ? GradientCover(
                size: size,
                gradient: song.isNetease
                    ? const [AppColors.magenta, AppColors.violet]
                    : AppColors.accentGradient,
              )
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => GradientCover(size: size),
              ),
      ),
    );
  }
}

// ==================== 进度条 ====================

class _ProgressSection extends StatelessWidget {
  const _ProgressSection({required this.onSeek});

  final Future<void> Function(Duration) onSeek;

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final player = PlayerController.instance;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
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
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 14),
                      activeTrackColor: AppColors.cyan,
                      inactiveTrackColor: AppColors.surfaceGlassStrong,
                      thumbColor: AppColors.cyan,
                    ),
                    child: Slider(
                      value: value.toDouble().clamp(0.0, maxMs),
                      max: maxMs,
                      onChanged: (v) => onSeek(Duration(milliseconds: v.round())),
                    ),
                  ),
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
              );
            },
          );
        },
      ),
    );
  }
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

  @override
  Widget build(BuildContext context) {
    final dim = hasSong ? AppColors.textPrimary : AppColors.textTertiary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: Icon(mode.icon, size: 22),
            color: AppColors.textSecondary,
            tooltip: mode.label,
            onPressed: hasSong ? () => onMode() : null,
          ),
          IconButton(
            icon: const Icon(Icons.skip_previous_rounded, size: 34),
            color: dim,
            onPressed: hasSong ? () => onPrev() : null,
          ),
          Container(
            width: 62,
            height: 62,
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
                size: 34,
              ),
              onPressed: hasSong ? () => onToggle() : null,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.skip_next_rounded, size: 34),
            color: dim,
            onPressed: hasSong ? () => onNext() : null,
          ),
          IconButton(
            icon: Icon(
              favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              size: 23,
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

/// 播放音质切换。
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
    if (s == null) return _chip(label: '音质', downgraded: false, netease: false);
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
      child: _chip(
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
      child: _chip(
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

  static Widget _chip({
    required String label,
    required bool downgraded,
    required bool netease,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surfaceGlass,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.strokeGlass),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.high_quality_rounded,
                size: 15,
                color: downgraded
                    ? AppColors.warning
                    : (netease ? AppColors.magenta : AppColors.cyan)),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: downgraded ? AppColors.warning : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      );
}

// ==================== 下载按钮 ====================

/// 下载入口：下载中变为进度环，完成后恢复图标。
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
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppColors.strokeGlass),
      ),
      child: p != null
          ? Padding(
              padding: const EdgeInsets.all(8),
              child: CircularProgressIndicator(
                // 服务端未返回总长度时（进度仍为 0）退化为不确定态
                value: p > 0 ? p : null,
                strokeWidth: 2,
                color: AppColors.cyan,
              ),
            )
          : IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: const Icon(Icons.download_rounded, size: 19),
              color: enabled ? AppColors.cyan : AppColors.textTertiary,
              tooltip: '下载当前歌曲',
              onPressed: enabled ? onTap : null,
            ),
    );
  }
}

// ==================== 音质选择弹层 ====================

/// 通用音质选择底部弹层（泛型支持 QQ 的 [Quality] 与网易云的 [NeteaseQuality]）。
class _QualitySheet<T> extends StatelessWidget {
  const _QualitySheet({
    required this.title,
    required this.options,
    required this.current,
    required this.label,
  });

  final String title;
  final List<T> options;
  final T current;
  final String Function(T) label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 26),
      decoration: const BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          const Text(
            '若所选音质不可用，会自动降级到最近的一档可用音质',
            style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
          ),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.5,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final q in options)
                    ListTile(
                      dense: true,
                      title: Text(
                        label(q),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: q == current ? FontWeight.w700 : FontWeight.w500,
                          color: q == current ? AppColors.cyan : AppColors.textPrimary,
                        ),
                      ),
                      trailing: q == current
                          ? const Icon(Icons.check_rounded,
                              color: AppColors.cyan, size: 20)
                          : null,
                      onTap: () => Navigator.pop(context, q),
                    ),
                ],
              ),
            ),
          ),
        ],
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
  const _LyricView({super.key, required this.lyrics, required this.onSeek});

  final Lyrics lyrics;
  final Future<void> Function(Duration) onSeek;

  @override
  State<_LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<_LyricView>
    with SingleTickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();
  final List<GlobalKey> _keys = [];

  /// 逐帧推进的播放头（毫秒）。仅当前行监听，避免整列表重建。
  final ValueNotifier<int> _head = ValueNotifier<int>(0);

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
  void dispose() {
    _posSub?.cancel();
    _playSub?.cancel();
    _resumeTimer?.cancel();
    _ticker?.dispose();
    _scroll.dispose();
    _head.dispose();
    super.dispose();
  }

  void _setAnchor(Duration d) {
    _anchorMs = d.inMilliseconds;
    _anchorAt = DateTime.now();
    _pushHead();
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

  void _pushHead() {
    final v = _smoothMs();
    if (v != _head.value) _head.value = v;
  }

  void _syncActive() {
    final idx = widget.lyrics.indexAt(Duration(milliseconds: _smoothMs()));
    if (idx == _active) return;
    if (!mounted) return;
    setState(() => _active = idx);
    _scrollToActive();
  }

  void _onTick(Duration elapsed) {
    _pushHead();
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
      _pushHead();
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
    final baseColor = isActive
        ? AppColors.cyan
        : (sung ? AppColors.textSecondary : AppColors.textTertiary);

    if (!line.isWordLevel) {
      return Text(
        line.displayText,
        style: TextStyle(
          fontSize: 15,
          height: 1.45,
          fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
          color: baseColor,
        ),
      );
    }

    // 非当前行：无需逐帧重绘，整行按"已唱过/未唱"静态着色
    if (!isActive) {
      return RichText(
        textAlign: TextAlign.start,
        text: TextSpan(
          children: [
            for (final w in line.words)
              TextSpan(
                text: w.text,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                  color: baseColor,
                ),
              ),
          ],
        ),
      );
    }

    // 当前行：逐帧平滑染色
    return _KaraokeLine(line: line, head: _head);
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.lyrics;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is UserScrollNotification) _onUserScroll();
        return false;
      },
      child: ListView.builder(
        controller: _scroll,
        padding: EdgeInsets.symmetric(
            vertical: MediaQuery.of(context).size.height * 0.3),
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
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildLine(line, isActive: isActive, sung: i < _active),
                  if (line.translation != null && line.translation!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        line.translation!,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: isActive
                              ? AppColors.textSecondary
                              : AppColors.textTertiary.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  if (line.romanization != null && line.romanization!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        line.romanization!,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.3,
                          color: isActive
                              ? AppColors.textSecondary
                              : AppColors.textTertiary.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 当前行的逐字染色：唯一订阅播放头的组件，用 [RepaintBoundary] 隔离重绘。
class _KaraokeLine extends StatelessWidget {
  const _KaraokeLine({required this.line, required this.head});

  final LyricLine line;
  final ValueListenable<int> head;

  /// smoothstep：把线性进度映射为 S 曲线，起止更柔和，不再有"跳一格"的生硬感。
  static double _ease(double p) {
    if (p <= 0) return 0;
    if (p >= 1) return 1;
    return p * p * (3 - 2 * p);
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: head,
        builder: (ctx, posMs, _) => RichText(
          textAlign: TextAlign.start,
          text: TextSpan(
            children: [
              for (final w in line.words)
                TextSpan(
                  text: w.text,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.45,
                    fontWeight: FontWeight.w700,
                    color: Color.lerp(
                      AppColors.textTertiary,
                      AppColors.cyan,
                      _ease(w.progressAt(posMs)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
