// 酷狗每日推荐（v2.5.4）。
//
// 数据源：`https://gateway.kugou.com/everyday_song_recommend`
// （签名盐 = gateway 盐，x-router: everydayrec.service.kugou.com）。
// 服务端每天给一批 30 首左右的歌，字段见 [KugouPlaylistSong.fromDaily]。
//
// 与「歌单详情」的区别：这里不是歌单，而是当天的一份推荐列表，
// 所以单独一个页面，标题写日期 + 首数，支持「播放全部」与点播。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../models/models.dart';
import '../../network/kugou/kugou_playlist_api.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/cover_image.dart';

class KugouDailyPage extends StatefulWidget {
  const KugouDailyPage({super.key});

  @override
  State<KugouDailyPage> createState() => _KugouDailyPageState();
}

class _KugouDailyPageState extends State<KugouDailyPage> {
  bool _loading = true;
  String? _error;
  List<Song> _songs = const [];
  String _date = '';

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
    try {
      final raw = await KugouPlaylistApi.dailyRecommend();
      if (!mounted) return;
      setState(() {
        _songs = [for (final s in raw) KugouPlaylistApi.toSong(s)];
        _date = _todayLabel();
        _loading = false;
        _error = raw.isEmpty ? '今天还没有每日推荐' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '每日推荐加载失败';
      });
    }
  }

  static String _todayLabel() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  void _playAll() {
    if (_songs.isEmpty) return;
    PlayerController.instance.playQueue(_songs, startIndex: 0);
  }

  void _playAt(int index) {
    if (index < 0 || index >= _songs.length) return;
    PlayerController.instance.playQueue(_songs, startIndex: index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg2,
      appBar: AppBar(
        title: const Text('酷狗每日推荐'),
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
              : _buildBody(),
    );
  }

  Widget _buildBody() {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildHeader()),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => _DailyRow(
              song: _songs[i],
              index: i,
              onTap: () => _playAt(i),
            ),
            childCount: _songs.length,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 30)),
      ],
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$_date 的推荐',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            '${_songs.length} 首 · 每天更新',
            style:
                TextStyle(fontSize: 12, color: AppColors.textTertiary),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: NeonButton(
              label: '播放全部',
              icon: Icons.play_arrow_rounded,
              onPressed: _songs.isEmpty ? null : _playAll,
            ),
          ),
        ],
      ),
    );
  }
}

class _DailyRow extends StatelessWidget {
  const _DailyRow({
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
                style: TextStyle(
                    fontSize: 12, color: AppColors.textTertiary),
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
            Icon(Icons.play_arrow_rounded,
                color: AppColors.accent, size: 22),
          ],
        ),
      ),
    );
  }
}
