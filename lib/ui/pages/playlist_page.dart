import 'package:flutter/material.dart';

import '../../data/playlist_store.dart';
import '../../models/models.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// 本地歌单列表页。
class PlaylistPage extends StatefulWidget {
  const PlaylistPage({super.key});

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  void _refresh() => setState(() {});

  void _showCreateDialog() {
    final ctrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: const Text('新建歌单', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: '歌单名称',
            hintStyle: const TextStyle(color: AppColors.textTertiary),
            filled: true,
            fillColor: AppColors.surfaceGlass,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.strokeGlass),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: AppColors.textTertiary)),
          ),
          TextButton(
            onPressed: () {
              final ok = PlaylistStore.createPlaylist(ctrl.text);
              Navigator.pop(ctx);
              if (ok) {
                _refresh();
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('歌单已存在或名称为空')),
                );
              }
            },
            child: const Text('创建', style: TextStyle(color: AppColors.cyan)),
          ),
        ],
      ),
    );
  }

  void _openPlaylist(String name) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _PlaylistDetailPage(name: name),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final names = PlaylistStore.playlistNames();
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('本地歌单'),
        actions: [
          IconButton(
            onPressed: _showCreateDialog,
            icon: const Icon(Icons.add_rounded, color: AppColors.cyan),
          ),
        ],
      ),
      body: names.isEmpty
          ? const Center(
              child: Text(
                '暂无歌单\n点击右上角 + 创建',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: names.length,
              itemBuilder: (ctx, i) => GlassCard(
                margin: const EdgeInsets.only(bottom: 10),
                onTap: () => _openPlaylist(names[i]),
                child: ListTile(
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: AppColors.accentGradient),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.queue_music_rounded, color: Colors.white, size: 22),
                  ),
                  title: Text(names[i], style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    '${PlaylistStore.songsOf(names[i]).length} 首',
                    style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
                  ),
                  trailing: IconButton(
                    onPressed: () {
                      PlaylistStore.deletePlaylist(names[i]);
                      _refresh();
                    },
                    icon: const Icon(Icons.delete_outline, color: AppColors.danger, size: 20),
                  ),
                ),
              ),
            ),
    );
  }
}

class _PlaylistDetailPage extends StatefulWidget {
  final String name;
  const _PlaylistDetailPage({required this.name});

  @override
  State<_PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<_PlaylistDetailPage> {
  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final songs = PlaylistStore.songsOf(widget.name);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(widget.name),
      ),
      body: songs.isEmpty
          ? const Center(
              child: Text(
                '歌单为空\n去搜索页添加歌曲',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: songs.length,
              itemBuilder: (ctx, i) => GlassCard(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: songs[i].coverUrl.isEmpty
                          ? GradientCover(size: 44)
                          : Image.network(songs[i].coverUrl, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const GradientCover(size: 44)),
                    ),
                  ),
                  title: Text(songs[i].name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  subtitle: Text(songs[i].singer, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: () {
                          PlaylistStore.removeSong(widget.name, songs[i].mid);
                          _refresh();
                        },
                        icon: const Icon(Icons.delete_outline, color: AppColors.danger, size: 20),
                      ),
                      const Icon(Icons.play_arrow_rounded, color: AppColors.cyan, size: 24),
                    ],
                  ),
                  onTap: () {
                    PlayerController.instance.playQueue(songs, startIndex: i);
                  },
                ),
              ),
            ),
    );
  }
}
