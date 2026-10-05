import 'package:flutter/material.dart';

import '../../data/history_store.dart';
import '../../models/models.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// 发现页：欢迎 Header + 快捷入口 + 最近播放（接本地历史）。
class DiscoverHome extends StatefulWidget {
  const DiscoverHome({super.key});

  @override
  State<DiscoverHome> createState() => _DiscoverHomeState();
}

class _DiscoverHomeState extends State<DiscoverHome> {
  static const _playlists = [
    ('经典华语', '周杰伦 / 林俊杰 / 陈奕迅', Icons.album_outlined),
    ('纯音乐 · 白噪音', '专注学习工作', Icons.spa_outlined),
    ('欧美流行', 'Billboard 热门', Icons.bolt_outlined),
    ('日语动漫', 'ACG 精选', Icons.auto_awesome_outlined),
  ];

  static const _quickActions = [
    ('每日推荐', Icons.today_outlined, AppColors.cyan),
    ('排行榜', Icons.leaderboard_outlined, AppColors.violet),
    ('私人 FM', Icons.radio_outlined, AppColors.magenta),
    ('收藏歌单', Icons.favorite_outline, AppColors.aqua),
  ];

  List<Song> get _recent => HistoryStore.playHistory();

  void _playAllRecent() {
    final recent = _recent;
    if (recent.isEmpty) return;
    for (final s in recent) {
      HistoryStore.addPlay(s);
    }
    PlayerController.instance.playQueue(recent, startIndex: 0);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final recent = _recent;
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () async {
          if (mounted) setState(() {});
        },
        color: AppColors.cyan,
        backgroundColor: AppColors.surfaceGlass,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(20, 26, 20, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            NeonText(
                              '白姬音乐',
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 6),
                        Text(
                          '聆听未来 · 双音源无损曲库',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: AppColors.accentGradient),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.cyan.withValues(alpha: 0.35),
                          blurRadius: 16,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.workspace_premium_rounded,
                        color: Colors.white, size: 22),
                  ),
                ],
              ),
              const SizedBox(height: 26),

              // 快捷入口
              Row(
                children: [
                  for (var i = 0; i < _quickActions.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(
                      child: _QuickAction(
                        label: _quickActions[i].$1,
                        icon: _quickActions[i].$2,
                        color: _quickActions[i].$3,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 28),

              // 推荐歌单（占位入口）
              const SectionHeader(
                title: '推荐歌单',
                subtitle: '为您精选',
                trailing: Icon(Icons.arrow_forward_ios_rounded,
                    size: 16, color: AppColors.textTertiary),
              ),
              SizedBox(
                height: 210,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  itemCount: _playlists.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 14),
                  itemBuilder: (context, i) {
                    final p = _playlists[i];
                    return GlassCard(
                      width: 150,
                      padding: const EdgeInsets.all(12),
                      glowColor: AppColors.violet,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GradientCover(
                            size: 126,
                            icon: p.$3,
                            gradient: [
                              AppColors.accentGradient[i % 2],
                              AppColors.playGradient[i % 2 == 0 ? 0 : 1],
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            p.$1,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            p.$2,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 28),

              // 最近播放（真实历史）
              SectionHeader(
                title: '最近播放',
                subtitle: '继续收听',
                trailing: recent.isEmpty
                    ? null
                    : GestureDetector(
                        onTap: _playAllRecent,
                        child: const Row(
                          children: [
                            Icon(Icons.play_circle_fill_rounded,
                                color: AppColors.cyan, size: 16),
                            SizedBox(width: 4),
                            Text(
                              '全部播放',
                              style: TextStyle(
                                  fontSize: 12, color: AppColors.cyan),
                            ),
                          ],
                        ),
                      ),
              ),
              if (recent.isEmpty)
                const GlassCard(
                  padding: EdgeInsets.symmetric(vertical: 26),
                  child: Center(
                    child: Text(
                      '暂无播放记录\n去搜索页听一首歌吧',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.7,
                          color: AppColors.textTertiary),
                    ),
                  ),
                )
              else
                GlassCard(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    children: [
                      for (var i = 0; i < recent.length && i < 6; i++)
                        _RecentTile(
                          song: recent[i],
                          onTap: () {
                            HistoryStore.addPlay(recent[i]);
                            PlayerController.instance
                                .playQueue(recent, startIndex: i);
                            if (mounted) setState(() {});
                          },
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({required this.song, required this.onTap});

  final Song song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isCurrent = PlayerController.instance.currentSong?.mid == song.mid;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 44,
          height: 44,
          child: song.cover.isEmpty
              ? GradientCover(
                  size: 44,
                  gradient: song.isNetease
                      ? const [AppColors.magenta, AppColors.violet]
                      : AppColors.accentGradient,
                )
              : Image.network(
                  song.cover,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const GradientCover(size: 44),
                ),
        ),
      ),
      title: Text(
        song.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: isCurrent ? AppColors.cyan : null,
        ),
      ),
      subtitle: Text(
        song.singer,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TagBadge(
            song.isNetease ? '网易云' : 'QQ',
            color: song.isNetease ? AppColors.magenta : AppColors.cyan,
          ),
          const SizedBox(width: 8),
          const Icon(Icons.play_arrow_rounded, color: AppColors.cyan, size: 26),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(vertical: 14),
      radius: 18,
      child: Column(
        children: [
          Icon(icon, size: 26, color: color),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}