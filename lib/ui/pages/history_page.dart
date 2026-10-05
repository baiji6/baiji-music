import 'package:flutter/material.dart';

import '../../data/history_store.dart';
import '../../models/models.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

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
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('播放历史'),
        actions: [
          if (recent.isNotEmpty)
            TextButton(
              onPressed: () {
                HistoryStore.clearPlay();
                _refresh();
              },
              child: const Text('清空', style: TextStyle(color: AppColors.danger, fontSize: 13)),
            ),
        ],
      ),
      body: recent.isEmpty
          ? const Center(
              child: Text(
                '暂无播放记录\n去搜索页听一首歌吧',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: recent.length,
              itemBuilder: (ctx, i) => GlassCard(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: recent[i].cover.isEmpty
                          ? GradientCover(
                              size: 44,
                              gradient: recent[i].isNetease
                                  ? const [AppColors.magenta, AppColors.violet]
                                  : AppColors.accentGradient,
                            )
                          : Image.network(
                              recent[i].cover,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const GradientCover(size: 44),
                            ),
                    ),
                  ),
                  title: Text(
                    recent[i].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: PlayerController.instance.currentSong?.mid == recent[i].mid
                          ? AppColors.cyan
                          : null,
                    ),
                  ),
                  subtitle: Text(
                    recent[i].singer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TagBadge(
                        recent[i].isNetease ? '网易云' : 'QQ',
                        color: recent[i].isNetease ? AppColors.magenta : AppColors.cyan,
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.play_arrow_rounded, color: AppColors.cyan, size: 24),
                    ],
                  ),
                  onTap: () {
                    PlayerController.instance.playQueue(recent, startIndex: i);
                    _refresh();
                  },
                ),
              ),
            ),
    );
  }
}
