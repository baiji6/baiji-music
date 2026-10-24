import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/app_version.dart';
import '../../data/history_store.dart';
import '../../data/local_music_store.dart';
import '../../data/playlist_store.dart';
import '../../models/models.dart';
import '../../network/hot_search_api.dart';
import '../../network/music_api.dart';
import '../../network/playlist_api.dart';
import '../widgets/platform_chips.dart';
import '../widgets/platform_picker.dart';
import 'playlist_detail_page.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'about_page.dart';
import 'play_stats_page.dart';
import 'download_page.dart';
import 'favorite_page.dart';
import 'history_page.dart';
import 'kuwo_direct_page.dart';
import 'local_music_page.dart';
import 'log_page.dart';
import 'netease_login_page.dart';
import 'playlist_page.dart';
import 'qq_login_page.dart';
import 'settings_page.dart';
import 'share_playlist_page.dart';
import 'toolbox_page.dart';

/// 我的页：账号卡片（QQ 登录 + 网易云 Cookie 登录）+ 本地歌单 / 下载 / 历史 / 收藏 / 设置 / 日志 / 关于。
class LibraryHome extends StatefulWidget {
  const LibraryHome({super.key});

  @override
  State<LibraryHome> createState() => _LibraryHomeState();
}

class _LibraryHomeState extends State<LibraryHome> {
  String _loginHint = '';

  /// 下拉刷新的转圈状态（提升给 MiuixPullToRefresh）。
  bool _refreshing = false;

  /// 登录方式选择弹层显隐。
  bool _showLoginSheet = false;

  /// 退出登录确认对话框显隐。
  bool _showLogoutDialog = false;

  // ===== 我的歌单（#145，仿倾听：登录后按账号拉取，三平台切换）=====
  String _mySource = Source.qq;
  List<HotPlaylist> _myPlaylists = const [];
  bool _myLoading = false;

  /// 拉当前平台的「我的歌单」。未登录返回空 → UI 显示登录引导。
  Future<void> _loadMyPlaylists() async {
    setState(() => _myLoading = true);
    final list = await PlaylistApi.myPlaylists(_mySource);
    if (!mounted) return;
    setState(() {
      _myPlaylists = list;
      _myLoading = false;
    });
  }

  void _switchMySource(String source) {
    if (source == _mySource) return;
    setState(() => _mySource = source);
    _loadMyPlaylists();
  }

  void _openMyPlaylist(HotPlaylist p) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlaylistDetailPage(
        source: _mySource,
        id: p.id,
        name: p.name,
        cover: p.cover,
      ),
    ));
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    // 让刷新指示器至少走完一轮动画，避免"拉一下就闪没"
    await Future.delayed(const Duration(milliseconds: 450));
    await _loadMyPlaylists();
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _loginHint = '';
    });
  }

  bool get _qqLoggedIn => AppServices.instance.qq.isLoggedIn();

  String _statusText() =>
      _qqLoggedIn ? '已登录：${AppServices.instance.qq.credential.strMusicid}' : '未登录';

  /// 账号卡片按钮：未登录 → 弹登录方式选择；已登录 → 弹退出确认。
  void _openLogin() {
    if (_qqLoggedIn) {
      setState(() => _showLogoutDialog = true);
      return;
    }
    setState(() => _showLoginSheet = true);
  }

  /// 选定登录方式，关弹层并跳转对应登录页。
  void _chooseLogin(String choice) {
    setState(() => _showLoginSheet = false);
    _goLogin(choice);
  }

  Future<void> _goLogin(String choice) async {
    // 底部弹层关闭后 context 可能已失效，先取好 Navigator 并在 await 后复查 mounted
    final navigator = Navigator.of(context);
    if (choice == 'qq') {
      final result = await navigator.push<bool>(
        MaterialPageRoute(builder: (_) => const QQLoginPage()),
      );
      if (!mounted || result != true) return;
      _refresh();
    } else if (choice == 'netease') {
      final result = await navigator.push<bool>(
        MaterialPageRoute(builder: (_) => const NeteaseLoginPage()),
      );
      if (!mounted || result != true) return;
      _refresh();
    }
  }

  void _confirmLogout() {
    setState(() => _showLogoutDialog = false);
    AppServices.instance.qq.logout();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final recent = HistoryStore.playHistory();
    final playlists = PlaylistStore.playlistNames();
    final localCount = LocalMusicStore.songs().length;
    final entries = <(String, String, IconData, Color, VoidCallback)>[
      ('本地音乐', localCount > 0 ? '$localCount 首' : '去扫描',
          Icons.library_music_rounded, AppColors.aqua,
          () => _openLocalMusic(context)),
      ('本地歌单', '${playlists.length} 个', Icons.queue_music_rounded, AppColors.accent,
          () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlaylistPage()))),
      ('下载管理', '0 首', Icons.download_rounded, AppColors.violet,
          () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DownloadPage()))),
      ('播放历史', '${recent.length} 首', Icons.history_rounded, AppColors.accentAlt,
          () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HistoryPage()))),
      ('我的收藏', '${HistoryStore.favorites().length} 首', Icons.favorite_border_rounded, AppColors.aqua,
          () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FavoritePage()))),
    ];

    return Stack(
      children: [
        SafeArea(
          child: MiuixPullToRefresh(
            isRefreshing: _refreshing,
            onRefresh: _refresh,
            color: AppColors.accent,
            refreshTexts: const ['下拉刷新', '松手立即刷新', '正在刷新…', '刷新完成'],
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics()),
              padding: EdgeInsets.fromLTRB(20, 26, 20, 30),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const NeonText(
                    '我的',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 1),
                  ),
                  const SizedBox(height: 20),

                  // 账号卡片
                  GlassCard(
                    padding: const EdgeInsets.all(20),
                    glowColor: AppColors.violet,
                    child: Row(
                      children: [
                        Container(
                          width: 58,
                          height: 58,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(colors: AppColors.neonGradient),
                            borderRadius: BorderRadius.circular(18),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.accentAlt.withValues(alpha: 0.4),
                                blurRadius: 18,
                              ),
                            ],
                          ),
                          child: Icon(
                            _qqLoggedIn ? Icons.verified_rounded : Icons.person_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _statusText(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 17, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _qqLoggedIn
                                    ? '绿钻音质已同步 · QQ 音乐'
                                    : '登录 QQ 音乐账号，同步绿钻与无损音质',
                                style: TextStyle(
                                    fontSize: 12, color: AppColors.textTertiary),
                              ),
                              if (_loginHint.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  _loginHint,
                                  style: TextStyle(
                                      fontSize: 11, color: AppColors.accentAlt),
                                ),
                              ],
                            ],
                          ),
                        ),
                        NeonButton(
                          label: _qqLoggedIn ? '退出' : '登录',
                          icon: _qqLoggedIn
                              ? Icons.logout_rounded
                              : Icons.login_rounded,
                          onPressed: _openLogin,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          radius: 12,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 我的歌单（#145：登录后按账号拉取，三平台切换，仿倾听）
                  SectionHeader(
                    title: '我的歌单',
                    subtitle: PlatformPicker.infoOf(_mySource).label,
                    trailing: PlatformChips(
                      current: _mySource,
                      onChanged: _switchMySource,
                      compact: true,
                    ),
                  ),
                  Builder(builder: (context) {
                    final loggedIn = MusicApi.isLoggedIn(_mySource);
                    if (_myLoading) {
                      return const GlassCard(
                        padding: EdgeInsets.symmetric(vertical: 28),
                        child: Center(
                          child: MiuixCircularProgressIndicator(size: 22),
                        ),
                      );
                    }
                    if (!loggedIn) {
                      return GlassCard(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            '登录${PlatformPicker.infoOf(_mySource).label}'
                            '后可同步你的歌单',
                            style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textTertiary),
                          ),
                        ),
                      );
                    }
                    if (_myPlaylists.isEmpty) {
                      return GlassCard(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            '这个账号暂无歌单，下拉刷新试试',
                            style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textTertiary),
                          ),
                        ),
                      );
                    }
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: EdgeInsets.zero,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.72,
                      ),
                      itemCount: _myPlaylists.length,
                      itemBuilder: (context, i) {
                        final p = _myPlaylists[i];
                        return _MyPlaylistCard(
                          playlist: p,
                          onTap: () => _openMyPlaylist(p),
                        );
                      },
                    );
                  }),
                  const SizedBox(height: 24),

                  // 本地数据入口
                  const SectionHeader(title: '本地内容'),
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    childAspectRatio: 1.65,
                    children: [
                      for (final e in entries)
                        GlassCard(
                          padding: const EdgeInsets.all(16),
                          radius: 20,
                          onTap: e.$5,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: e.$4.withValues(alpha: 0.16),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: e.$4.withValues(alpha: 0.4)),
                                ),
                                child: Icon(e.$3, color: e.$4, size: 21),
                              ),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    e.$1,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    e.$2,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.textTertiary,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // 设置 / 关于
                  const SectionHeader(title: '更多'),
                  GlassCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        // 本地播放统计（v2.3.1）：时长/次数/单曲循环，纯本地
                        _SettingTile(
                          icon: Icons.bar_chart_rounded,
                          title: '播放统计',
                          subtitle: '今日与近 7 日听歌时长 · 次数排行 · 最爱',
                          color: AppColors.accent,
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const PlayStatsPage())),
                        ),
                        // 分享歌单导入（v2.4.0）
                        _SettingTile(
                          icon: Icons.playlist_add_rounded,
                          title: '导入分享歌单',
                          subtitle: 'QQ / 网易云 / 酷我 歌单链接一键导入',
                          color: AppColors.accentAlt,
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const SharePlaylistPage())),
                        ),
                        // 酷我 ID 直达播放（v2.4.0-fix1）
                        _SettingTile(
                          icon: Icons.bolt_rounded,
                          title: '酷我 ID 直达播放',
                          subtitle: '输入酷我歌曲 ID / 单曲链接直接播放',
                          color: AppColors.violet,
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const KuwoDirectPage())),
                        ),
                        _SettingTile(
                          icon: Icons.settings_outlined,
                          title: '设置',
                          subtitle: '音质偏好 · 下载目录 · 缓存管理',
                          color: AppColors.accent,
                          onTap: () => _openSettings(context),
                        ),
                        _SettingTile(
                          icon: Icons.build_outlined,
                          title: '工具箱',
                          subtitle: '本地音乐解密 · 更多实用工具',
                          color: AppColors.warning,
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const ToolboxPage())),
                        ),
                        _SettingTile(
                          icon: Icons.bug_report_outlined,
                          title: '日志与调试',
                          subtitle: '查看/导出运行日志',
                          color: AppColors.violet,
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LogPage())),
                        ),
                        _SettingTile(
                          icon: Icons.info_outline_rounded,
                          title: '关于',
                          subtitle: AppVersion.display,
                          color: AppColors.accentAlt,
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutPage())),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        _buildLoginSheet(),
        _buildLogoutDialog(),
      ],
    );
  }

  /// 登录方式选择弹层（声明式 MiuixOverlayBottomSheet）。
  Widget _buildLoginSheet() {
    return MiuixOverlayBottomSheet(
      show: _showLoginSheet,
      title: '选择登录方式',
      backgroundColor: AppColors.bg2,
      onDismissRequest: () => setState(() => _showLoginSheet = false),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _LoginOptionRow(
            gradient: const [AppColors.cyan, AppColors.aqua],
            title: 'QQ 音乐登录',
            subtitle: 'Cookie / 二维码扫码',
            onTap: () => _chooseLogin('qq'),
          ),
          const SizedBox(height: 8),
          _LoginOptionRow(
            gradient: const [AppColors.magenta, AppColors.violet],
            title: '网易云音乐登录',
            subtitle: 'Cookie 登录',
            onTap: () => _chooseLogin('netease'),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// 退出登录确认对话框（声明式 MiuixOverlayDialog，按钮放在 content 里）。
  Widget _buildLogoutDialog() {
    return MiuixOverlayDialog(
      show: _showLogoutDialog,
      title: '退出登录',
      maxWidth: 420,
      backgroundColor: AppColors.bg2,
      onDismissRequest: () => setState(() => _showLogoutDialog = false),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '确定退出当前 QQ 音乐账号吗？',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              MiuixTextButton(
                '取消',
                onPressed: () => setState(() => _showLogoutDialog = false),
                textStyle: TextStyle(color: AppColors.textTertiary),
              ),
              const SizedBox(width: 8),
              MiuixTextButton(
                '退出',
                onPressed: _confirmLogout,
                textStyle: TextStyle(color: AppColors.accentAlt),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 打开本地音乐页；返回时刷新卡片上的数量。
  Future<void> _openLocalMusic(BuildContext context) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LocalMusicPage()),
    );
    if (!mounted || result != true) return;
    _refresh();
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
  }
}

/// 登录方式弹层里的一行。
class _LoginOptionRow extends StatelessWidget {
  const _LoginOptionRow({
    required this.gradient,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final List<Color> gradient;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MiuixPressable(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: gradient),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.login_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MiuixPressable(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// 「我的歌单」卡片：封面 + 名字 + 曲目数（仿倾听三列网格）。
class _MyPlaylistCard extends StatelessWidget {
  const _MyPlaylistCard({required this.playlist, required this.onTap});

  final HotPlaylist playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(8),
      radius: 14,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SizedBox(
              width: double.infinity,
              child: FrostedImage(url: playlist.cover, size: 0, radius: 10),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            playlist.trackCount != null ? '${playlist.trackCount} 首' : '歌单',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }
}
