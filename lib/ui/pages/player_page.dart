import 'dart:async';

import 'package:baiji_music/data/history_store.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/lyric_api.dart';
import 'package:baiji_music/player/player_controller.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:baiji_music/ui/widgets/app_widgets.dart';
import 'package:flutter/material.dart';

/// 播放页：封面 + 进度条 + 播放控制 + 音质切换 + 歌词（逐字/译文/点击跳转）。
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final _player = PlayerController.instance;

  Song? _song;
  PlayMode _mode = PlayMode.sequential;
  Quality? _actualQuality;
  bool _playing = false;
  bool _fav = false;

  /// 当前歌曲的歌词Future（切歌时重建）。
  Future<Lyrics>? _lyricsFuture;
  String _lyricsKey = '';

  StreamSubscription<Song?>? _songSub;
  StreamSubscription<Quality?>? _qualitySub;
  StreamSubscription<bool>? _playSub;

  @override
  void initState() {
    super.initState();
    _song = _player.currentSong;
    _mode = _player.playMode;
    _actualQuality = _player.actualQqQuality;
    _playing = _player.isPlaying;
    _syncFavorite();
    _loadLyrics();

    _songSub = _player.onSongChanged.listen((song) {
      if (!mounted) return;
      setState(() {
        _song = song;
        _playing = _player.isPlaying;
      });
      _syncFavorite();
      _loadLyrics();
    });

    // 自动降级时同步"实际音质"角标
    _qualitySub = _player.onQualityChanged.listen((q) {
      if (!mounted) return;
      setState(() => _actualQuality = q);
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

  Future<void> _toggleFavorite() async {
    final s = _song;
    if (s == null) return;
    setState(() {
      HistoryStore.toggleFavorite(s);
      _fav = HistoryStore.isFavorite(s.mid);
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_fav ? '已收藏' : '已取消收藏'),
        duration: const Duration(seconds: 1),
      ),
    );
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_mode.label),
        duration: const Duration(seconds: 1),
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
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
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
                    _QualityButton(
                      actual: _actualQuality,
                      onPicked: _pickQuality,
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

  Future<void> _pickQuality(Quality q) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('正在切换到 ${q.label}…'),
        duration: const Duration(seconds: 1),
      ),
    );
    await _player.switchQuality(q);
    if (!mounted) return;
    setState(() {
      _actualQuality = _player.actualQqQuality;
      _playing = _player.isPlaying;
    });
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

// ==================== 音质按钮 ====================

class _QualityButton extends StatelessWidget {
  const _QualityButton({required this.actual, required this.onPicked});

  final Quality? actual;
  final Future<void> Function(Quality) onPicked;

  @override
  Widget build(BuildContext context) {
    final player = PlayerController.instance;
    final requested = player.currentQuality;
    final effective = actual ?? requested;
    final downgraded = actual != null && actual!.code != requested.code;

    return PopupMenuButton<Quality>(
      tooltip: '切换音质',
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      color: AppColors.bg2,
      onSelected: (q) => onPicked(q),
      itemBuilder: (ctx) => [
        for (final q in Quality.playbackOptions)
          PopupMenuItem<Quality>(
            value: q,
            child: Row(
              children: [
                Icon(
                  q.code == effective.code
                      ? Icons.check_rounded
                      : Icons.audiotrack_rounded,
                  size: 16,
                  color: q.code == effective.code
                      ? AppColors.cyan
                      : AppColors.textTertiary,
                ),
                const SizedBox(width: 10),
                Text(q.label, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
      ],
      child: Container(
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
                color: downgraded ? AppColors.warning : AppColors.cyan),
            const SizedBox(width: 5),
            Text(
              effective.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: downgraded ? AppColors.warning : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 歌词视图 ====================

/// 歌词区：自动滚动到当前行、逐字染色、点击跳转到对应时间。
class _LyricView extends StatefulWidget {
  const _LyricView({super.key, required this.lyrics, required this.onSeek});

  final Lyrics lyrics;
  final Future<void> Function(Duration) onSeek;

  @override
  State<_LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<_LyricView> {
  final ScrollController _scroll = ScrollController();
  final List<GlobalKey> _keys = [];
  StreamSubscription<Duration>? _sub;

  int _active = -1;
  int _lastTickBucket = -1;
  bool _userDragging = false;
  Timer? _resumeTimer;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.lyrics.length; i++) {
      _keys.add(GlobalKey());
    }
    final player = PlayerController.instance;
    _active = widget.lyrics.indexAt(player.position);
    _sub = player.onPositionChanged.listen(_onPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive(animate: false));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _resumeTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onPosition(Duration pos) {
    // 逐字染色需要较细粒度，这里按 100ms 节流重建
    final bucket = pos.inMilliseconds ~/ 100;
    if (bucket == _lastTickBucket) return;
    _lastTickBucket = bucket;

    final idx = widget.lyrics.indexAt(pos);
    final changed = idx != _active;
    if (!mounted) return;
    setState(() => _active = idx);
    if (changed) _scrollToActive();
  }

  void _scrollToActive({bool animate = true}) {
    if (_userDragging) return;
    if (_active < 0 || _active >= _keys.length) return;
    final ctx = _keys[_active].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.42,
      duration: animate ? const Duration(milliseconds: 320) : Duration.zero,
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

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.lyrics;
    final posMs = PlayerController.instance.position.inMilliseconds;

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
                  if (line.isWordLevel)
                    RichText(
                      textAlign: TextAlign.start,
                      text: TextSpan(
                        children: line.words.map((w) {
                          final p = w.progressAt(posMs).clamp(0.0, 1.0);
                          return TextSpan(
                            text: w.text,
                            style: TextStyle(
                              fontSize: 15,
                              height: 1.45,
                              fontWeight:
                                  isActive ? FontWeight.w700 : FontWeight.w500,
                              color: Color.lerp(
                                isActive
                                    ? AppColors.textSecondary
                                    : AppColors.textTertiary,
                                isActive ? AppColors.cyan : AppColors.textTertiary,
                                p,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    )
                  else
                    Text(
                      line.displayText,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.45,
                        fontWeight:
                            isActive ? FontWeight.w700 : FontWeight.w500,
                        color: isActive
                            ? AppColors.cyan
                            : AppColors.textTertiary,
                      ),
                    ),
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
