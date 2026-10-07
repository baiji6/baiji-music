import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../player/player_controller.dart';
import '../theme/app_theme.dart';
import 'pages/player_page.dart';

/// 主界面导航外壳。
///
/// - 桌面 / 平板（宽度 >= 860）：左侧霓虹导航栏 + 内容区
/// - 手机：底部玻璃导航栏
/// - 底部常驻迷你播放条（玻璃拟态胶囊）
/// - 顶部可选的渐变标题栏
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.pages, required this.titles});

  final List<Widget> pages;
  final List<String> titles;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _icons = [
    Icons.explore_outlined,
    Icons.search_rounded,
    Icons.library_music_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 860;

    return Scaffold(
      extendBody: true,
      body: NebulaBackground(
        child: isWide ? _buildWide(context) : _buildNarrow(context),
      ),
    );
  }

  Widget _buildWide(BuildContext context) {
    return Row(
      children: [
        _Rail(index: _index, onChanged: (i) => setState(() => _index = i)),
        Expanded(
          child: Column(
            children: [
              Expanded(child: pageHost(index: _index)),
              const MiniPlayerBar(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNarrow(BuildContext context) {
    return Column(
      children: [
        Expanded(child: pageHost(index: _index)),
        MiniPlayerBar(
          margin: const EdgeInsets.fromLTRB(14, 0, 14, 4),
        ),
        _buildNavigationBar(),
      ],
    );
  }

  Widget _buildNavigationBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.bg2.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: AppColors.strokeGlass),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          backgroundColor: Colors.transparent,
          destinations: [
            for (var i = 0; i < widget.titles.length; i++)
              NavigationDestination(
                icon: Icon(_icons[i]),
                selectedIcon: ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    colors: AppColors.neonGradient,
                  ).createShader(bounds),
                  child: Icon(_icons[i], color: Colors.white),
                ),
                label: widget.titles[i],
              ),
          ],
        ),
      ),
    );
  }

  Widget pageHost({required int index}) {
    // 切换时使用渐变淡入
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) {
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.02, 0),
              end: Offset.zero,
            ).animate(anim),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(
        key: ValueKey(index),
        child: widget.pages[index],
      ),
    );
  }
}

/// 桌面端侧边导航栏（霓虹渐变指示条）。
class _Rail extends StatelessWidget {
  const _Rail({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    const icons = [
      Icons.explore_outlined,
      Icons.search_rounded,
      Icons.library_music_outlined,
    ];
    const labels = ['发现', '搜索', '我的'];

    return Container(
      width: 92,
      margin: const EdgeInsets.all(18),
      padding: const EdgeInsets.symmetric(vertical: 26),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: AppColors.strokeGlass),
      ),
      child: Column(
        children: [
          const NeonText('BAIJI', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 2)),
          const SizedBox(height: 6),
          const Text(
            '白姬音乐',
            style: TextStyle(color: AppColors.textTertiary, fontSize: 10, letterSpacing: 1),
          ),
          const SizedBox(height: 30),
          for (var i = 0; i < icons.length; i++) ...[
            _RailItem(
              icon: icons[i],
              label: labels[i],
              selected: i == index,
              onTap: () => onChanged(i),
            ),
            const SizedBox(height: 10),
          ],
          const Spacer(),
          const Icon(Icons.settings_outlined, size: 22, color: AppColors.textTertiary),
          const SizedBox(height: 8),
          const Text('设置', style: TextStyle(color: AppColors.textTertiary, fontSize: 10)),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: 64,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.violet.withValues(alpha: 0.24) : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? AppColors.violet.withValues(alpha: 0.6) : Colors.transparent,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppColors.violet.withValues(alpha: 0.35),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 23,
              color: selected ? AppColors.cyan : AppColors.textTertiary,
            ),
            const SizedBox(height: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? AppColors.textPrimary : AppColors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 迷你播放条（玻璃胶囊悬浮于底部，接入全局播放器）。
class MiniPlayerBar extends StatefulWidget {
  const MiniPlayerBar({super.key, this.margin = const EdgeInsets.all(14)});

  final EdgeInsetsGeometry margin;

  @override
  State<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends State<MiniPlayerBar> {
  Song? _song;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    final pc = PlayerController.instance;
    _song = pc.currentSong;
    _playing = pc.isPlaying;
    _subs = [
      pc.onSongChanged.listen((s) {
        if (mounted) setState(() => _song = s);
      }),
      pc.onPlayStateChanged.listen((p) {
        if (mounted) setState(() => _playing = p);
      }),
      pc.onPositionChanged.listen((pos) {
        if (!mounted) return;
        setState(() => _position = pos);
      }),
    ];
    // 拉取当前曲目总时长（media_kit: Player.stream.duration）
    pc.onDurationChanged.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    });
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final song = _song;
    final hasSong = song != null;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: widget.margin,
        height: 66,
        padding: const EdgeInsets.only(left: 10, right: 14),
        decoration: BoxDecoration(
          color: AppColors.bg2.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppColors.strokeGlass),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 26,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Row(
          children: [
            GestureDetector(
              // 点击封面/歌名区域进入完整播放页
              onTap: hasSong
                  ? () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const PlayerPage()))
                  : null,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: SizedBox(
                      width: 46,
                      height: 46,
                      child: hasSong && song.coverUrl.isNotEmpty
                          ? Image.network(
                              song.coverUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const _MiniCover(),
                            )
                          : const _MiniCover(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: MediaQuery.of(context).size.width * 0.42,
                    child: _MiniTitle(
                      hasSong: hasSong,
                      song: song,
                      position: _position,
                      duration: _duration,
                      fmt: _fmt,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              onPressed: hasSong
                  ? () {
                      PlayerController.instance.toggle();
                      setState(() =>
                          _playing = PlayerController.instance.isPlaying);
                    }
                  : null,
              icon: Icon(
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: hasSong ? AppColors.cyan : AppColors.textTertiary,
                size: 28,
              ),
            ),
            IconButton(
              onPressed: hasSong ? () => PlayerController.instance.next() : null,
              icon: const Icon(Icons.skip_next_rounded,
                  color: AppColors.textSecondary, size: 22),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniCover extends StatelessWidget {
  const _MiniCover();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: AppColors.accentGradient),
      ),
      child: const Icon(Icons.music_note, color: Colors.white, size: 22),
    );
  }
}
/// 迷你播放条的标题区（歌名 + 细进度条 + 时间）。
///
/// 独立成一个 widget，便于整体包进 GestureDetector 打开完整播放页。
class _MiniTitle extends StatelessWidget {
  const _MiniTitle({
    required this.hasSong,
    required this.song,
    required this.position,
    required this.duration,
    required this.fmt,
  });

  final bool hasSong;
  final Song? song;
  final Duration position;
  final Duration duration;
  final String Function(Duration) fmt;

  @override
  Widget build(BuildContext context) {
    final total = duration.inMilliseconds;
    final progress =
        total > 0 ? (position.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          hasSong ? song!.name : '未在播放',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  minHeight: 3,
                  value: progress,
                  backgroundColor: AppColors.surfaceGlassStrong,
                  valueColor: const AlwaysStoppedAnimation<Color>(AppColors.cyan),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              hasSong ? '${fmt(position)} / ${fmt(duration)}' : '00:00',
              style: const TextStyle(color: AppColors.textTertiary, fontSize: 10),
            ),
          ],
        ),
      ],
    );
  }
}
