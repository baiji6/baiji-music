import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../data/history_store.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';
import '../widgets/cover_image.dart';

/// 播放历史页。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final recent = HistoryStore.playHistory();
    return PageScaffold(
      title: '播放历史',
      snackbarHost: appSnackbarHostState,
      contentPadding: EdgeInsets.zero,
      actions: [
        if (recent.isNotEmpty)
          MiuixTextButton(
            '清空',
            onPressed: () {
              HistoryStore.clearPlay();
              _refresh();
            },
            textStyle: TextStyle(color: AppColors.danger, fontSize: 13),
          ),
      ],
      child: recent.isEmpty
          ? Center(
              child: Text(
                '暂无播放记录\n去搜索页听一首歌吧',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: recent.length,
              itemBuilder: (ctx, i) {
                final song = recent[i];
                final isCurrent =
                    PlayerController.instance.currentSong?.mid == song.mid;
                return GlassCard(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: MiuixPressable(
                    onPressed: () {
                      PlayerController.instance.playQueue(recent, startIndex: i);
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
                                        ? AppColors.accent
                                        : AppColors.textPrimary,
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
                          TagBadge(
                            song.isNetease ? '网易云' : 'QQ',
                            color: song.isNetease
                                ? AppColors.accentAlt
                                : AppColors.accent,
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.play_arrow_rounded,
                              color: AppColors.accent, size: 24),
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
