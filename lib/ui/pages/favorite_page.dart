import 'package:flutter/material.dart';

import '../../data/history_store.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/cover_image.dart';

/// 我的收藏页。展示 [HistoryStore.favorites] 中用户收藏的歌曲，
/// 点击播放，点击右侧红心可取消收藏。
class FavoritePage extends StatefulWidget {
  const FavoritePage({super.key});

  @override
  State<FavoritePage> createState() => _FavoritePageState();
}

class _FavoritePageState extends State<FavoritePage> {
  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final favs = HistoryStore.favorites();
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('我的收藏'),
        actions: [
          if (favs.isNotEmpty)
            TextButton(
              onPressed: () {
                HistoryStore.clearFavorites();
                _refresh();
              },
              child: const Text('清空', style: TextStyle(color: AppColors.danger, fontSize: 13)),
            ),
        ],
      ),
      body: favs.isEmpty
          ? const Center(
              child: Text(
                '还没有收藏的歌曲\n在搜索结果长按或点击收藏按钮试试',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: favs.length,
              itemBuilder: (ctx, i) => GlassCard(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CoverImage(song: favs[i], size: 44, radius: 10),
                  title: Text(
                    favs[i].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: PlayerController.instance.currentSong?.mid == favs[i].mid
                          ? AppColors.cyan
                          : null,
                    ),
                  ),
                  subtitle: Text(
                    favs[i].singer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TagBadge(
                        favs[i].isNetease ? '网易云' : 'QQ',
                        color: favs[i].isNetease ? AppColors.magenta : AppColors.cyan,
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.favorite_rounded,
                            color: AppColors.aqua, size: 22),
                        tooltip: '取消收藏',
                        onPressed: () {
                          HistoryStore.toggleFavorite(favs[i]);
                          _refresh();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('已取消收藏'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  onTap: () {
                    PlayerController.instance.playQueue(favs, startIndex: i);
                    _refresh();
                  },
                ),
              ),
            ),
    );
  }
}
