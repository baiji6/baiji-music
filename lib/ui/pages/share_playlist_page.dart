import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../data/playlist_store.dart';
import '../../models/models.dart';
import '../../network/share_playlist_api.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';

/// 分享歌单导入页（v2.4.0）。
///
/// 支持粘贴 QQ / 网易云 / 酷我 三家的歌单分享链接或整段分享文本，
/// 自动识别平台 → 拉取曲目 → 预览并一键保存到本地歌单 / 直接播放。
class SharePlaylistPage extends StatefulWidget {
  const SharePlaylistPage({super.key});

  @override
  State<SharePlaylistPage> createState() => _SharePlaylistPageState();
}

class _SharePlaylistPageState extends State<SharePlaylistPage> {
  final _controller = TextEditingController();

  bool _loading = false;
  String? _error;
  SharedPlaylist? _playlist;

  /// 拉取到的曲目 → 通用 [Song]。
  List<Song> _songs = const [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    final input = _controller.text.trim();
    if (input.isEmpty) {
      setState(() => _error = '请粘贴歌单链接或分享文本');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final pl = await SharePlaylist.parse(input);
      if (!mounted) return;
      setState(() {
        _playlist = pl;
        _songs = _toSongs(pl);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '解析失败：$e';
      });
    }
  }

  /// 平台曲目 → [Song]。
  static List<Song> _toSongs(SharedPlaylist pl) {
    final source = pl.source;
    return pl.tracks.map((t) {
      return Song(
        mid: t.rid,
        songId: source == Source.netease ? (int.tryParse(t.rid) ?? 0) : 0,
        name: t.name,
        singer: t.artist,
        album: t.album,
        albumMid: '',
        duration: t.durationSeconds * 1000,
        cover: '',
        source: source,
      );
    }).toList();
  }

  void _playAll() {
    if (_songs.isEmpty) return;
    PlayerController.instance.playQueue(_songs, startIndex: 0);
    showAppSnack('已开始播放 ${_songs.length} 首');
  }

  /// 保存到本地歌单（同名则合并）。
  void _saveToPlaylist() {
    final pl = _playlist;
    if (pl == null || _songs.isEmpty) return;
    final name = pl.name.isEmpty ? '导入歌单' : pl.name;
    if (!PlaylistStore.playlistNames().contains(name)) {
      PlaylistStore.createPlaylist(name);
    }
    var added = 0;
    for (final s in _songs) {
      if (PlaylistStore.addSong(name, s)) added++;
    }
    showAppSnack('已保存 $added 首到「$name」');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg2,
      appBar: AppBar(
        title: const Text('导入分享歌单'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '粘贴 QQ 音乐 / 网易云音乐 / 酷我音乐 的歌单链接或整段分享文本，'
            '自动识别平台并导入曲目。',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          AppTextField(
            controller: _controller,
            label: '歌单链接 / 分享文本',
            useLabelAsPlaceholder: true,
            minLines: 2,
            maxLines: 5,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: NeonButton(
                  label: _loading ? '解析中…' : '解析歌单',
                  icon: Icons.link_rounded,
                  onPressed: _loading ? null : _parse,
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(fontSize: 13, color: AppColors.danger),
            ),
          ],
          if (_playlist != null) ...[
            const SizedBox(height: 20),
            SectionHeader(title: _playlist!.name.isEmpty ? '导入结果' : _playlist!.name),
            Row(
              children: [
                _Badge(text: '${_songs.length} 首'),
                const SizedBox(width: 8),
                _Badge(text: _sourceLabel(_playlist!.source)),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: NeonButton(
                    label: '全部播放',
                    icon: Icons.play_arrow_rounded,
                    onPressed: _songs.isEmpty ? null : _playAll,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: NeonButton(
                    label: '保存到歌单',
                    icon: Icons.bookmark_add_outlined,
                    onPressed: _songs.isEmpty ? null : _saveToPlaylist,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (final s in _songs)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: GlassCard(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${s.singer} · ${s.album}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12, color: AppColors.textTertiary),
                            ),
                          ],
                        ),
                      ),
                      MiuixIconButton(
                        onPressed: () {
                          PlayerController.instance
                              .playQueue([s], startIndex: 0);
                        },
                        child: Icon(Icons.play_circle_outline_rounded,
                            color: AppColors.accent, size: 22),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  static String _sourceLabel(String source) {
    switch (source) {
      case 'netease':
        return '网易云';
      case 'kuwo':
        return '酷我';
      default:
        return 'QQ 音乐';
    }
  }
}

/// 小徽标（平台 / 曲目数）。
class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.strokeGlass),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
      ),
    );
  }
}
