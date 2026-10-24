import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../data/history_store.dart';
import '../../models/models.dart';
import '../../network/hot_search_api.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/cover_image.dart';
import '../widgets/platform_chips.dart';
import '../widgets/platform_picker.dart';
import 'playlist_detail_page.dart';

/// 发现页：欢迎 Header + 快捷入口 + 最近播放（接本地历史）。
class DiscoverHome extends StatefulWidget {
  const DiscoverHome({super.key});

  @override
  State<DiscoverHome> createState() => _DiscoverHomeState();
}

class _DiscoverHomeState extends State<DiscoverHome> {
  static const _quickActions = <(String, IconData, Color)>[];

  /// 下拉刷新的转圈状态（提升给 MiuixPullToRefresh）。
  bool _refreshing = false;

  // ===== 推荐歌单（#143，仿倾听：真实数据 + 三平台切换）=====
  //
  // 之前这两块是写死的空列表，页面上什么都出不来；现在按当前平台拉
  // 「热门歌单」，点卡片进歌单详情（可整单播放）。
  String _plSource = Source.qq;
  List<HotPlaylist> _hotPlaylists = const [];
  bool _plLoading = false;
  String? _plError;

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    setState(() {
      _plLoading = true;
      _plError = null;
    });
    try {
      final list = await hotPlaylistsOf(_plSource, limit: 12);
      if (!mounted) return;
      setState(() {
        _hotPlaylists = list;
        _plLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _plLoading = false;
        _plError = '推荐歌单加载失败';
      });
    }
  }

  void _switchPlSource(String source) {
    if (source == _plSource) return;
    setState(() => _plSource = source);
    _loadPlaylists();
  }

  void _openPlaylist(HotPlaylist p) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlaylistDetailPage(
        source: _plSource,
        id: p.id,
        name: p.name,
        cover: p.cover,
      ),
    ));
  }

  List<Song> get _recent => HistoryStore.playHistory();

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await Future.delayed(const Duration(milliseconds: 450));
    await _loadPlaylists();
    if (!mounted) return;
    setState(() => _refreshing = false);
  }

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
      child: MiuixPullToRefresh(
        isRefreshing: _refreshing,
        onRefresh: _refresh,
        color: AppColors.accent,
        refreshTexts: const ['下拉刷新', '松手立即刷新', '正在刷新…', '刷新完成'],
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(20, 26, 20, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
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
                          color: AppColors.accent.withValues(alpha: 0.35),
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

              // 推荐歌单（#143：真实数据 + 三平台切换）
              SectionHeader(
                title: '推荐歌单',
                subtitle: '${PlatformPicker.infoOf(_plSource).label}精选',
                trailing: PlatformChips(
                  current: _plSource,
                  onChanged: _switchPlSource,
                  compact: true,
                ),
              ),
              SizedBox(
                height: 210,
                child: _plLoading && _hotPlaylists.isEmpty
                    ? ListView.separated(
                        scrollDirection: Axis.horizontal,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: 3,
                        separatorBuilder: (_, _) => const SizedBox(width: 14),
                        itemBuilder: (_, _) =>
                            const GlassSkeleton(width: 150, height: 190),
                      )
                    : _hotPlaylists.isEmpty
                        ? GlassCard(
                            width: 260,
                            padding: const EdgeInsets.all(18),
                            child: Center(
                              child: Text(
                                _plError ?? '暂无推荐歌单',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textTertiary),
                              ),
                            ),
                          )
                        : ListView.separated(
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            itemCount: _hotPlaylists.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 14),
                            itemBuilder: (context, i) {
                              final p = _hotPlaylists[i];
                              return _HotPlaylistCard(
                                playlist: p,
                                onTap: () => _openPlaylist(p),
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
                    : MiuixPressable(
                        onPressed: _playAllRecent,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          child: Row(
                            children: [
                              Icon(Icons.play_circle_fill_rounded,
                                  color: AppColors.accent, size: 16),
                              SizedBox(width: 4),
                              Text(
                                '全部播放',
                                style: TextStyle(
                                    fontSize: 12, color: AppColors.accent),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
              if (recent.isEmpty)
                GlassCard(
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
    return MiuixPressable(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            CoverImage(song: song, size: 44, radius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color:
                          isCurrent ? AppColors.accent : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    song.singer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textTertiary),
                  ),
                ],
              ),
            ),
            SourceBadge(song),
            const SizedBox(width: 8),
            Icon(Icons.play_arrow_rounded,
                color: AppColors.accent, size: 26),
          ],
        ),
      ),
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
            style: TextStyle(
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
/// 一张推荐歌单卡片：封面 + 名称 + 创建者 / 播放量。
class _HotPlaylistCard extends StatelessWidget {
  const _HotPlaylistCard({required this.playlist, required this.onTap});

  final HotPlaylist playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sub = <String>[
      if (playlist.creator.isNotEmpty) playlist.creator,
      if (playlist.playCount != null) '${playlist.playCount} 次播放',
    ].join(' · ');
    return GlassCard(
      width: 150,
      padding: const EdgeInsets.all(12),
      glowColor: AppColors.violet,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FrostedImage(url: playlist.cover, size: 126, radius: 14),
          const SizedBox(height: 10),
          Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 3),
          Text(
            sub.isEmpty ? '歌单' : sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }
}
