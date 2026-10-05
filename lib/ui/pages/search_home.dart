import 'package:flutter/material.dart';

import '../../core/app_logger.dart';
import '../../data/history_store.dart';
import '../../models/models.dart';
import '../../network/music_api.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// 搜索页：霓虹搜索框 + 双音源并发搜索 + 搜索结果列表 + 搜索历史。
class SearchHome extends StatefulWidget {
  const SearchHome({super.key});

  @override
  State<SearchHome> createState() => _SearchHomeState();
}

class _SearchHomeState extends State<SearchHome> {
  final _controller = TextEditingController();
  String _keyword = '';
  bool _loading = false;
  String? _error;
  List<Song> _results = [];
  List<String> _history = [];

  static const _hotTags = [
    '周杰伦', '林俊杰', '陈奕迅', '邓紫棋', '薛之谦',
    '纯音乐', '夜曲', '晴天', '大海', '稻香',
  ];

  @override
  void initState() {
    super.initState();
    _history = HistoryStore.searchHistory();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _keyword = k;
      _loading = true;
      _error = null;
    });
    HistoryStore.addSearch(k);
    setState(() => _history = HistoryStore.searchHistory());
    try {
      // 双音源并发搜索
      final results = await Future.wait([
        MusicApi.search(Source.qq, k).catchError((_) => <Song>[]),
        MusicApi.search(Source.netease, k).catchError((_) => <Song>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _results = [...results[0], ...results[1]];
        _loading = false;
      });
      AppLog.i('SearchHome', '搜索「$k」命中 ${_results.length} 首');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '搜索失败: $e';
      });
    }
  }

  void _clear() {
    _controller.clear();
    setState(() {
      _keyword = '';
      _results = [];
      _error = null;
    });
  }

  void _playSong(Song song) {
    HistoryStore.addPlay(song);
    PlayerController.instance.playQueue([song], startIndex: 0).then((_) {
      // 历史已写入；更新当前曲目
      if (mounted) setState(() {});
    });
    setState(() {});
  }

  void _playAll(List<Song> songs) {
    if (songs.isEmpty) return;
    for (final s in songs) {
      HistoryStore.addPlay(s);
    }
    PlayerController.instance
        .playQueue(songs, startIndex: 0)
        .then((_) {
      if (mounted) setState(() {});
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 26, 20, 6),
            child: Row(
              children: [
                const NeonText(
                  '搜索',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                const TagBadge('QQ 音乐', color: AppColors.cyan),
                const SizedBox(width: 8),
                const TagBadge('网易云', color: AppColors.magenta),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              radius: 18,
              glowColor: AppColors.cyan,
              child: TextField(
                controller: _controller,
                textInputAction: TextInputAction.search,
                onSubmitted: _search,
                onChanged: (v) {
                  if (v.trim().isEmpty && _keyword.isNotEmpty) {
                    _clear();
                  }
                  setState(() {});
                },
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
                cursorColor: AppColors.cyan,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: '搜索歌曲、歌手、专辑…',
                  hintStyle: const TextStyle(color: AppColors.textTertiary),
                  icon: const Icon(Icons.search_rounded, color: AppColors.cyan, size: 22),
                  suffixIcon: _controller.text.isEmpty
                      ? null
                      : IconButton(
                          onPressed: _clear,
                          icon: const Icon(Icons.close_rounded,
                              color: AppColors.textTertiary, size: 18),
                        ),
                ),
              ),
            ),
          ),
          Expanded(
            child: _keyword.isEmpty
                ? _buildDefault()
                : (_loading ? _buildLoading() : _buildResult()),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
      itemCount: 8,
      itemBuilder: (_, _) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: GlassCard(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: const [
              GlassSkeleton(width: 46, height: 46, radius: 12),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GlassSkeleton(width: 160, height: 15),
                    SizedBox(height: 9),
                    GlassSkeleton(width: 90, height: 11),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDefault() {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '热门搜索',
            trailing: Icon(Icons.local_fire_department_rounded,
                size: 20, color: AppColors.magenta),
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < _hotTags.length; i++)
                GestureDetector(
                  onTap: () {
                    _controller.text = _hotTags[i];
                    _search(_hotTags[i]);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceGlass,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: i < 3
                            ? Colors.orangeAccent.withValues(alpha: 0.5)
                            : AppColors.strokeGlass,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${i + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: i < 3 ? Colors.orangeAccent : AppColors.textTertiary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _hotTags[i],
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 30),
          SectionHeader(
            title: '搜索历史',
            trailing: _history.isEmpty
                ? null
                : GestureDetector(
                    onTap: () {
                      HistoryStore.clearSearch();
                      setState(() => _history = []);
                    },
                    child: const Text(
                      '清空',
                      style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
                    ),
                  ),
          ),
          if (_history.isEmpty)
            const Text(
              '暂无历史记录',
              style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final h in _history)
                  GestureDetector(
                    onTap: () {
                      _controller.text = h;
                      _search(h);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceGlass,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.strokeGlass),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.history_rounded,
                              size: 14, color: AppColors.textTertiary),
                          const SizedBox(width: 6),
                          Text(
                            h,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildResult() {
    if (_error != null) {
      return EmptyView(
        icon: Icons.wifi_off_rounded,
        title: '搜索失败',
        subtitle: _error,
        action: NeonButton(
          label: '重试',
          icon: Icons.refresh_rounded,
          onPressed: () => _search(_keyword),
        ),
      );
    }
    if (_results.isEmpty) {
      return EmptyView(
        icon: Icons.search_off_rounded,
        title: '未找到「$_keyword」',
        subtitle: '换个关键词试试，或切换音源',
        action: NeonButton(
          label: '再搜一次',
          icon: Icons.bolt_rounded,
          onPressed: () => _search(_keyword),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: Row(
            children: [
              Text(
                '「$_keyword」· ${_results.length} 首',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textTertiary,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => _playAll(_results),
                child: const Row(
                  children: [
                    Icon(Icons.play_circle_fill_rounded,
                        color: AppColors.cyan, size: 17),
                    SizedBox(width: 4),
                    Text(
                      '全部播放',
                      style: TextStyle(fontSize: 12, color: AppColors.cyan),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 30),
            itemCount: _results.length,
            itemBuilder: (context, i) => _SongTile(
              song: _results[i],
              onTap: () => _playSong(_results[i]),
            ),
          ),
        ),
      ],
    );
  }
}

/// 搜索结果歌曲行。
class _SongTile extends StatelessWidget {
  const _SongTile({required this.song, required this.onTap});

  final Song song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final current = PlayerController.instance.currentSong;
    final isCurrent = current?.mid == song.mid;
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: GlassCard(
          padding: const EdgeInsets.all(12),
          radius: 18,
          glowColor: isCurrent ? AppColors.cyan : null,
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 46,
                  height: 46,
                  child: song.cover.isEmpty
                      ? GradientCover(size: 46, gradient: song.isNetease
                          ? const [AppColors.magenta, AppColors.violet]
                          : AppColors.accentGradient)
                      : Image.network(
                          song.cover,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => GradientCover(
                              size: 46, gradient: AppColors.accentGradient),
                        ),
                ),
              ),
              const SizedBox(width: 14),
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
                        color: isCurrent ? AppColors.cyan : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${song.singer} · ${song.album}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TagBadge(
                song.isNetease ? '网易云' : 'QQ',
                color: song.isNetease ? AppColors.magenta : AppColors.cyan,
              ),
              const SizedBox(width: 6),
              Icon(
                isCurrent
                    ? (PlayerController.instance.isPlaying
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_filled_rounded)
                    : Icons.play_circle_outline_rounded,
                color: isCurrent ? AppColors.cyan : AppColors.textTertiary,
                size: 26,
              ),
            ],
          ),
        ),
      ),
    );
  }
}