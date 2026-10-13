import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/app_logger.dart';
import '../../data/history_store.dart';
import '../../download/download_task.dart';
import '../../models/models.dart';
import '../../network/music_api.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';
import '../widgets/cover_image.dart';

/// 搜索页：霓虹搜索框 + 音源切换 + 搜索结果列表 + 搜索历史。
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
  String _source = Source.qq; // 当前搜索音源

  /// 当前显示到第几页（1 起）。
  int _page = 1;

  /// 是否正在加载某一页（按钮显示转圈，列表本身保持可滚动）。
  bool _loadingMore = false;

  /// 页码 → 该页结果。来回翻页直接命中缓存，不重复请求。
  final Map<int, List<Song>> _pageCache = {};

  /// 已经请求过的最大页码。
  int _maxPage = 1;

  /// [maxPage] 那一页是否装满了——不满即判定到底。
  bool _lastPageFull = false;

  /// 请求代次：每次发起全新搜索就 +1，用来作废还在飞的旧分页请求。
  int _requestGen = 0;

  /// 歌曲操作弹层（收藏 / 下载 / 播放）显隐与目标歌曲。
  bool _showActionSheet = false;
  Song? _actionSong;

  /// 能否继续往后翻：前面还有已缓存的页，或当前页之后仍可能有内容。
  bool get _hasMore => _page < _maxPage || _lastPageFull;

  /// 能否往回翻。历史上只能一路向后翻，想看前面的结果只能重新搜一遍。
  bool get _hasPrev => _page > 1;

  /// 每页条数。QQ 走 `page_num`+`num_per_page`，网易云走 `offset`+`limit`，
  /// `MusicApi.search` 已把两者统一为 [page]/[num]，两个音源行为一致。
  static const int pageSize = 20;

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

  /// 全新搜索（换关键词、换音源、重试都走这里）：丢弃页缓存，只取第 1 页。
  Future<void> _search(String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return;

    FocusScope.of(context).unfocus();
    // 代次 +1：让还在飞的旧请求立刻失效。没有这个的话，
    // 「第 1 页点下一页 → 请求未返回时换关键词」会把旧关键词的分页结果
    // 混进新关键词的列表里。
    final gen = ++_requestGen;
    setState(() {
      _keyword = k;
      _error = null;
      _loading = true;
      _loadingMore = false;
      _pageCache.clear();
      _maxPage = 1;
      _page = 1;
    });

    HistoryStore.addSearch(k);
    if (mounted) setState(() => _history = HistoryStore.searchHistory());

    try {
      final results = await MusicApi.search(_source, k, page: 1, num: pageSize);
      if (!mounted || gen != _requestGen) return;
      setState(() {
        _pageCache[1] = results;
        _lastPageFull = results.length >= pageSize;
        _rebuildList();
        _loading = false;
      });
      AppLog.i('SearchHome',
          '搜索「$k」(${_source == Source.qq ? 'QQ' : '网易云'}) 第 1 页命中 ${results.length} 首');
    } catch (e) {
      if (!mounted || gen != _requestGen) return;
      setState(() {
        _loading = false;
        _error = '搜索失败: $e';
      });
    }
  }

  /// 翻到第 [page] 页。已缓存则直接重建列表，不发请求。
  Future<void> _goToPage(int page) async {
    if (page < 1 || _loading || _loadingMore) return;

    final cached = _pageCache[page];
    if (cached != null) {
      setState(() {
        _page = page;
        _rebuildList();
      });
      AppLog.d('SearchHome', '翻页命中缓存 page=$page 累计 ${_results.length} 首');
      return;
    }

    FocusScope.of(context).unfocus();
    final gen = _requestGen;
    final k = _keyword;
    final src = _source;
    setState(() {
      _loadingMore = true;
      _error = null;
    });
    try {
      final results =
          await MusicApi.search(src, k, page: page, num: pageSize);
      // 期间可能已经换了关键词 / 音源发起新搜索，这次结果直接丢弃
      if (!mounted || gen != _requestGen || k != _keyword) return;
      setState(() {
        _pageCache[page] = results;
        // 「到底」只看最远那页：往回翻时不能被更早那页的结果覆盖掉这个结论，
        // 否则在第 1 页会把「第 3 页不满」误当成还有更多。
        if (page > _maxPage) {
          _maxPage = page;
          _lastPageFull = results.length >= pageSize;
        }
        _page = page;
        _rebuildList();
        _loadingMore = false;
      });
      AppLog.i('SearchHome',
          '搜索「$_keyword」第 $page 页命中 ${results.length} 首，累计 ${_results.length} 首');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      if (gen != _requestGen || k != _keyword) return;
      _showSnack('加载第 $page 页失败: $e', isError: true);
    }
  }

  /// 按页缓存重建 1..[_page] 的累计列表。
  ///
  /// 保持「累计」而不是「只显示当前页」：一路往下翻时列表越来越长，
  /// 「全部播放」也能一次播完已加载的全部曲目；往回翻则把超出该页的部分收掉。
  void _rebuildList() {
    final seen = <String>{};
    final merged = <Song>[];
    for (var p = 1; p <= _page; p++) {
      for (final s in (_pageCache[p] ?? const <Song>[])) {
        // 去重：翻页时服务端可能重复返回同一首（尤其热词结果）
        if (seen.add('${s.source}:${s.mid}')) merged.add(s);
      }
    }
    _results = merged;
  }

  /// 「下一页」按钮。
  Future<void> _loadNextPage() => _goToPage(_page + 1);

  /// 「上一页」按钮。
  Future<void> _loadPrevPage() => _goToPage(_page - 1);

  void _clear() {
    _controller.clear();
    setState(() {
      _keyword = '';
      _results = [];
      _error = null;
      _page = 1;
      _pageCache.clear();
      _maxPage = 1;
      _lastPageFull = false;
    });
  }

  void _playSong(Song song) {
    HistoryStore.addPlay(song);
    PlayerController.instance.playQueue([song], startIndex: 0).then((_) {
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

  void _switchSource(String source) {
    if (_source == source) return;
    setState(() => _source = source);
    // 如果有搜索关键词，自动重新搜索
    if (_keyword.isNotEmpty) {
      _search(_keyword);
    }
  }

  void _showSongActions(Song song) {
    setState(() {
      _actionSong = song;
      _showActionSheet = true;
    });
  }

  /// 执行歌曲操作弹层里的某一项。
  void _runSongAction(String action) {
    final song = _actionSong;
    setState(() => _showActionSheet = false);
    if (song == null) return;
    switch (action) {
      case 'fav':
        final isFav = HistoryStore.isFavorite(song.mid);
        HistoryStore.toggleFavorite(song);
        showAppSnack(isFav ? '已取消收藏' : '已收藏');
      case 'download':
        _downloadSong(song);
      case 'play':
        _playSong(song);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    showAppSnack(msg);
  }

  /// 下载单曲。进度与结果统一交给全局任务队列，本页只弹提示；
  /// 想看进度条请去「下载管理」页。
  Future<void> _downloadSong(Song song) async {
    _showSnack('已加入下载队列');
    final path = await runManagedDownload(
      song,
      qqQuality: PlayerController.instance.currentQuality,
      neQuality: PlayerController.instance.currentNeteaseQuality,
    );
    if (!mounted) return;
    if (path == null) {
      _showSnack('下载失败，可在下载管理查看原因', isError: true);
      return;
    }
    final name = path.split(Platform.pathSeparator).last;
    _showSnack('下载完成: $name');
  }

  @override
  Widget build(BuildContext context) {
    final sourceColor =
        _source == Source.qq ? AppColors.accent : AppColors.accentAlt;
    return Stack(
      children: [
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(20, 26, 20, 6),
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
                    // 音源切换按钮
                    _SourceSwitch(
                      current: _source,
                      onSwitch: _switchSource,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: MiuixTextField(
                  controller: _controller,
                  label: _source == Source.qq
                      ? '搜索 QQ 音乐曲库…'
                      : '搜索网易云音乐曲库…',
                  useLabelAsPlaceholder: true,
                  singleLine: true,
                  autofocus: false,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _search,
                  onChanged: (v) {
                    if (v.trim().isEmpty && _keyword.isNotEmpty) {
                      _clear();
                    }
                    setState(() {});
                  },
                  cursorColor: sourceColor,
                  textStyle: TextStyle(
                      color: AppColors.textPrimary, fontSize: 15),
                  leadingIcon: Icon(Icons.search_rounded,
                      color: sourceColor, size: 22),
                  trailingIcon: _controller.text.isEmpty
                      ? null
                      : MiuixIconButton(
                          onPressed: _clear,
                          child: Icon(Icons.close_rounded,
                              color: AppColors.textTertiary, size: 18),
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
        ),
        _buildActionSheet(),
      ],
    );
  }

  /// 歌曲操作弹层（收藏 / 下载 / 播放）。
  Widget _buildActionSheet() {
    final song = _actionSong;
    final isFav =
        song == null ? false : HistoryStore.isFavorite(song.mid);
    return MiuixOverlayBottomSheet(
      show: _showActionSheet && song != null,
      title: song?.name ?? '',
      backgroundColor: AppColors.bg2,
      onDismissRequest: () => setState(() => _showActionSheet = false),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (song != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '${song.singer} · ${song.album}',
                style: TextStyle(
                    fontSize: 12, color: AppColors.textTertiary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          _SheetActionRow(
            icon: isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            label: isFav ? '取消收藏' : '收藏',
            color: isFav ? AppColors.accentAlt : AppColors.accent,
            onTap: () => _runSongAction('fav'),
          ),
          _SheetActionRow(
            icon: Icons.download_rounded,
            label: '下载',
            color: AppColors.accent,
            onTap: () => _runSongAction('download'),
          ),
          _SheetActionRow(
            icon: Icons.play_circle_outline_rounded,
            label: '播放',
            color: AppColors.accent,
            onTap: () => _runSongAction('play'),
          ),
          const SizedBox(height: 12),
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
          SectionHeader(
            title: '热门搜索',
            trailing: Icon(Icons.local_fire_department_rounded,
                size: 20, color: AppColors.accentAlt),
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < _hotTags.length; i++)
                MiuixPressable(
                  onPressed: () {
                    _controller.text = _hotTags[i];
                    _search(_hotTags[i]);
                  },
                  borderRadius: BorderRadius.circular(14),
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
                          style: TextStyle(
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
                : MiuixPressable(
                    onPressed: () {
                      HistoryStore.clearSearch();
                      setState(() => _history = []);
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Text(
                        '清空',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textTertiary),
                      ),
                    ),
                  ),
          ),
          if (_history.isEmpty)
            Text(
              '暂无历史记录',
              style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final h in _history)
                  MiuixPressable(
                    onPressed: () {
                      _controller.text = h;
                      _search(h);
                    },
                    borderRadius: BorderRadius.circular(12),
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
                          Icon(Icons.history_rounded,
                              size: 14, color: AppColors.textTertiary),
                          const SizedBox(width: 6),
                          Text(
                            h,
                            style: TextStyle(
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
              Expanded(
                child: Text(
                  '「$_keyword」· ${_results.length} 首 · ${_source == Source.qq ? 'QQ 音乐' : '网易云音乐'} 第 $_page 页',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              MiuixPressable(
                onPressed: () => _playAll(_results),
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  children: [
                    Icon(Icons.play_circle_fill_rounded,
                        color: AppColors.accent, size: 17),
                    SizedBox(width: 4),
                    Text(
                      '全部播放',
                      style: TextStyle(fontSize: 12, color: AppColors.accent),
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
            itemCount: _results.length + 1,
            itemBuilder: (context, i) {
              if (i == _results.length) return _buildFooter();
              return _SongTile(
                song: _results[i],
                onTap: () => _playSong(_results[i]),
                onLongPress: () => _showSongActions(_results[i]),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 结果列表底部的翻页条：上一页 / 页码 / 下一页。
  ///
  /// 三个状态互斥：加载中转圈；一页都没翻过且已到底 → 提示；否则显示翻页按钮。
  Widget _buildFooter() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: MiuixCircularProgressIndicator(size: 22),
        ),
      );
    }

    final atFirstPage = !_hasPrev;
    final atLastPage = !_hasMore;
    if (atFirstPage && atLastPage) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text(
            '已显示全部 ${_results.length} 首结果',
            style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _PageButton(
            label: '上一页',
            icon: Icons.keyboard_arrow_up_rounded,
            enabled: _hasPrev,
            onPressed: _loadPrevPage,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              '第 $_page 页',
              style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
            ),
          ),
          _PageButton(
            label: atLastPage ? '已到底' : '下一页',
            icon: Icons.keyboard_arrow_down_rounded,
            enabled: _hasMore,
            onPressed: _loadNextPage,
          ),
        ],
      ),
    );
  }
}

/// 翻页按钮。不可用时置灰而不是隐藏——否则「已到底」和「上一页」会互相挤掉，
/// 整条底栏在不同页之间反复改变高度。
class _PageButton extends StatelessWidget {
  const _PageButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: NeonButton(
        label: label,
        icon: icon,
        onPressed: enabled ? onPressed : null,
      ),
    );
  }
}

/// 音源切换按钮组。
class _SourceSwitch extends StatelessWidget {
  const _SourceSwitch({required this.current, required this.onSwitch});

  final String current;
  final ValueChanged<String> onSwitch;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.strokeGlass),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SourceChip(
            label: 'QQ',
            color: AppColors.accent,
            active: current == Source.qq,
            onTap: () => onSwitch(Source.qq),
          ),
          _SourceChip(
            label: '网易',
            color: AppColors.accentAlt,
            active: current == Source.netease,
            onTap: () => onSwitch(Source.netease),
          ),
        ],
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({
    required this.label,
    required this.color,
    required this.active,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MiuixPressable(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          gradient: active
              ? LinearGradient(colors: [color, color.withValues(alpha: 0.7)])
              : null,
          borderRadius: BorderRadius.circular(18),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.4),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? Colors.white : AppColors.textTertiary,
          ),
        ),
      ),
    );
  }
}

/// 搜索结果歌曲行。
class _SongTile extends StatelessWidget {
  const _SongTile({required this.song, required this.onTap, this.onLongPress});

  final Song song;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final current = PlayerController.instance.currentSong;
    final isCurrent = current?.mid == song.mid;
    return MiuixPressable(
      onPressed: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: GlassCard(
          padding: const EdgeInsets.all(12),
          radius: 18,
          glowColor: isCurrent ? AppColors.cyan : null,
          child: Row(
            children: [
              CoverImage(song: song, size: 46, radius: 12),
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
                        color: isCurrent ? AppColors.accent : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${song.singer} · ${song.album}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
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
                color: song.isNetease ? AppColors.accentAlt : AppColors.accent,
              ),
              const SizedBox(width: 6),
              Icon(
                isCurrent
                    ? (PlayerController.instance.isPlaying
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_filled_rounded)
                    : Icons.play_circle_outline_rounded,
                color: isCurrent ? AppColors.accent : AppColors.textTertiary,
                size: 26,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 歌曲操作弹层里的一行（收藏 / 下载 / 播放）。
class _SheetActionRow extends StatelessWidget {
  const _SheetActionRow({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MiuixPressable(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
