import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../data/playlist_store.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';
import '../widgets/cover_image.dart';

/// 本地歌单列表页。
class PlaylistPage extends StatefulWidget {
  const PlaylistPage({super.key});

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  /// 「新建歌单」输入弹窗显隐。
  bool _showCreateDialog = false;
  final _nameCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  void _openCreateDialog() {
    _nameCtrl.clear();
    setState(() => _showCreateDialog = true);
  }

  void _submitCreate() {
    final ok = PlaylistStore.createPlaylist(_nameCtrl.text);
    setState(() => _showCreateDialog = false);
    if (ok) {
      _refresh();
    } else {
      showAppSnack('歌单已存在或名称为空');
    }
  }

  void _openPlaylist(String name) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _PlaylistDetailPage(name: name),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final names = PlaylistStore.playlistNames();
    return MiuixScaffold(
      containerColor: Colors.transparent,
      snackbarHost: MiuixSnackbarHost(state: appSnackbarHostState),
      topBar: MiuixTopAppBar(
        title: '本地歌单',
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.pop(context),
          child: const Icon(Icons.arrow_back_rounded,
              color: AppColors.textPrimary),
        ),
        actions: [
          MiuixIconButton(
            onPressed: _openCreateDialog,
            child: const Icon(Icons.add_rounded, color: AppColors.cyan),
          ),
        ],
      ),
      content: (padding) => names.isEmpty
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
                child: MiuixPressable(
                  onPressed: () => _openPlaylist(names[i]),
                  borderRadius: BorderRadius.circular(22),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                                colors: AppColors.accentGradient),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.queue_music_rounded,
                              color: Colors.white, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                names[i],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${PlaylistStore.songsOf(names[i]).length} 首',
                                style: const TextStyle(
                                    fontSize: 12, color: AppColors.textTertiary),
                              ),
                            ],
                          ),
                        ),
                        MiuixIconButton(
                          onPressed: () {
                            PlaylistStore.deletePlaylist(names[i]);
                            _refresh();
                          },
                          child: const Icon(Icons.delete_outline,
                              color: AppColors.danger, size: 20),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
      bottomBar: _buildDialogs(),
    );
  }

  Widget _buildDialogs() {
    return Stack(
      children: [
        MiuixOverlayDialog(
          show: _showCreateDialog,
          title: '新建歌单',
          backgroundColor: AppColors.bg2,
          onDismissRequest: () => setState(() => _showCreateDialog = false),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MiuixTextField(
                controller: _nameCtrl,
                autofocus: true,
                label: '歌单名称',
                singleLine: true,
                textStyle: const TextStyle(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MiuixTextButton(
                    '取消',
                    onPressed: () =>
                        setState(() => _showCreateDialog = false),
                    textStyle: const TextStyle(color: AppColors.textTertiary),
                  ),
                  const SizedBox(width: 8),
                  MiuixTextButton('创建', onPressed: _submitCreate),
                ],
              ),
            ],
          ),
        ),
      ],
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
    return MiuixScaffold(
      containerColor: Colors.transparent,
      snackbarHost: MiuixSnackbarHost(state: appSnackbarHostState),
      topBar: MiuixTopAppBar(
        title: widget.name,
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.pop(context),
          child: const Icon(Icons.arrow_back_rounded,
              color: AppColors.textPrimary),
        ),
      ),
      content: (padding) => songs.isEmpty
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
                child: MiuixPressable(
                  onPressed: () {
                    PlayerController.instance.playQueue(songs, startIndex: i);
                  },
                  borderRadius: BorderRadius.circular(22),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        CoverImage(song: songs[i], size: 44, radius: 10),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                songs[i].name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                songs[i].singer,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12, color: AppColors.textTertiary),
                              ),
                            ],
                          ),
                        ),
                        MiuixIconButton(
                          onPressed: () {
                            PlaylistStore.removeSong(
                                widget.name, songs[i].mid);
                            _refresh();
                          },
                          child: const Icon(Icons.delete_outline,
                              color: AppColors.danger, size: 20),
                        ),
                        const Icon(Icons.play_arrow_rounded,
                            color: AppColors.cyan, size: 24),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
