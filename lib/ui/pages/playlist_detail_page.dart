// 三平台歌单详情（#143 推荐歌单 / #145 我的歌单 共用）。
//
// 仿倾听：顶部大封面 + 歌单名 / 创建者 / 曲目数 + 「播放全部」，
// 下面是可点播的曲目列表。数据走 [PlaylistApi]。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../models/models.dart';
import '../../network/playlist_api.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';
import '../widgets/cover_image.dart';
import '../widgets/platform_picker.dart';

class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({
    super.key,
    required this.source,
    required this.id,
    this.name = '',
    this.cover = '',
  });

  /// 平台标识（[Source.qq] / [Source.netease] / [Source.kuwo]）。
  final String source;

  final String id;

  /// 列表页已拿到的名字（酷我详情接口不回歌单名，用它兜底）。
  final String name;

  /// 列表页已拿到的封面。
  final String cover;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  bool _loading = true;
  String? _error;
  PlaylistDetail? _detail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final d = await PlaylistApi.of(widget.source, widget.id,
        fallbackName: widget.name, fallbackCover: widget.cover);
    if (!mounted) return;
    setState(() {
      _detail = d;
      _loading = false;
      _error = d == null ? '歌单加载失败' : null;
    });
  }

  void _playAll() {
    final songs = _detail?.songs ?? const <Song>[];
    if (songs.isEmpty) return;
    PlayerController.instance.playQueue(songs, startIndex: 0);
  }

  void _playAt(int index) {
    final songs = _detail?.songs ?? const <Song>[];
    if (index < 0 || index >= songs.length) return;
    PlayerController.instance.playQueue(songs, startIndex: index);
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    final label = PlatformPicker.infoOf(widget.source).label;
    return Scaffold(
      backgroundColor: AppColors.bg2,
      appBar: AppBar(
        title: Text('$label歌单'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: MiuixCircularProgressIndicator(size: 28))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!,
                            style: TextStyle(color: AppColors.textSecondary)),
                        const SizedBox(height: 12),
                        NeonButton(
                          label: '重试',
                          icon: Icons.refresh_rounded,
                          onPressed: _load,
                        ),
                      ],
                    ),
                  ),
                )
              : _buildBody(d!),
    );
  }

  Widget _buildBody(PlaylistDetail d) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildHeader(d)),
        if (d.songs.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 40),
              child: EmptyView(
                  icon: Icons.queue_music_rounded,
                  title: '这个歌单还没有可播放的曲目'),
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _SongRow(
                song: d.songs[i],
                index: i,
                onTap: () => _playAt(i),
              ),
              childCount: d.songs.length,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 30)),
      ],
    );
  }

  Widget _buildHeader(PlaylistDetail d) {
    final name = d.name.isNotEmpty ? d.name : widget.name;
    final cover = d.cover.isNotEmpty ? d.cover : widget.cover;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FrostedImage(url: cover, size: 96, radius: 18),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? '歌单' : name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (d.creator.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'by ${d.creator}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textTertiary),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '${d.songs.length} 首',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (d.desc.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              d.desc,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: NeonButton(
              label: '播放全部',
              icon: Icons.play_arrow_rounded,
              onPressed: d.songs.isEmpty
                  ? null
                  : () {
                      _playAll();
                      showAppSnack('已开始播放歌单');
                    },
            ),
          ),
        ],
      ),
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.song,
    required this.index,
    required this.onTap,
  });

  final Song song;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MiuixPressable(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
              ),
            ),
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
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
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
                color: AppColors.accent, size: 22),
          ],
        ),
      ),
    );
  }
}
