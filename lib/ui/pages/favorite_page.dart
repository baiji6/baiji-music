import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../data/history_store.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
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
    return MiuixScaffold(
      containerColor: Colors.transparent,
      snackbarHost: MiuixSnackbarHost(state: appSnackbarHostState),
      topBar: MiuixTopAppBar(
        title: '我的收藏',
        color: Colors.transparent,
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary, size: 20),
        ),
        actions: [
          if (favs.isNotEmpty)
            MiuixTextButton(
              '清空',
              onPressed: () {
                HistoryStore.clearFavorites();
                _refresh();
              },
              textStyle: const TextStyle(color: AppColors.danger, fontSize: 13),
            ),
        ],
      ),
      content: (padding) => favs.isEmpty
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
              itemBuilder: (ctx, i) {
                final song = favs[i];
                final isCurrent =
                    PlayerController.instance.currentSong?.mid == song.mid;
                return GlassCard(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: MiuixPressable(
                    onPressed: () {
                      PlayerController.instance.playQueue(favs, startIndex: i);
                      _refresh();
                    },
                    borderRadius: BorderRadius.circular(18),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          CoverImage(song: song, size: 44, radius: 10),
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
                                    color: isCurrent
                                        ? AppColors.cyan
                                        : AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  song.singer,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12, color: AppColors.textTertiary),
                                ),
                              ],
                            ),
                          ),
                          TagBadge(
                            song.isNetease ? '网易云' : 'QQ',
                            color: song.isNetease
                                ? AppColors.magenta
                                : AppColors.cyan,
                          ),
                          const SizedBox(width: 4),
                          MiuixIconButton(
                            onPressed: () {
                              HistoryStore.toggleFavorite(song);
                              _refresh();
                              showAppSnack('已取消收藏');
                            },
                            child: const Icon(Icons.favorite_rounded,
                                color: AppColors.aqua, size: 22),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
