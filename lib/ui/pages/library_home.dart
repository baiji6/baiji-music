import 'package:flutter/material.dart';

import '../../data/history_store.dart';
import '../../data/playlist_store.dart';
import '../../network/music_api.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'about_page.dart';
import 'download_page.dart';
import 'history_page.dart';
import 'log_page.dart';
import 'netease_login_page.dart';
import 'playlist_page.dart';
import 'qq_login_page.dart';
import 'settings_page.dart';

/// 我的页：账号卡片（QQ 登录 + 网易云 Cookie 登录）+ 本地歌单 / 下载 / 历史 / 收藏 / 设置 / 日志 / 关于。
class LibraryHome extends StatefulWidget {
  const LibraryHome({super.key});

  @override
  State<LibraryHome> createState() => _LibraryHomeState();
}

class _LibraryHomeState extends State<LibraryHome> {
  String _loginHint = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _loginHint = '';
    });
  }

  bool get _qqLoggedIn => AppServices.instance.qq.isLoggedIn();

  String _statusText() =>
      _qqLoggedIn ? '已登录：${AppServices.instance.qq.credential.strMusicid}' : '未登录';

  Future<void> _openLogin() async {
    if (_qqLoggedIn) {
      final ok = await _confirmLogout(context);
      if (ok == true) {
        AppServices.instance.qq.logout();
        _refresh();
      }
      return;
    }
    // 弹出登录方式选择
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
        decoration: const BoxDecoration(
          color: AppColors.bg2,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '选择登录方式',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [AppColors.cyan, AppColors.aqua]),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.login_rounded, color: Colors.white, size: 20),
              ),
              title: const Text('QQ 音乐登录', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              subtitle: const Text('Cookie / 二维码扫码', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
              onTap: () => Navigator.pop(ctx, 'qq'),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [AppColors.magenta, AppColors.violet]),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.login_rounded, color: Colors.white, size: 20),
              ),
              title: const Text('网易云音乐登录', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              subtitle: const Text('Cookie 登录', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
              onTap: () => Navigator.pop(ctx, 'netease'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    if (choice == 'qq') {
      final result = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const QQLoginPage()),
      );
      if (result == true) _refresh();
    } else if (choice == 'netease') {
      final result = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const NeteaseLoginPage()),
      );
      if (result == true) _refresh();
    }
  }

  Future<bool?> _confirmLogout(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: const Text('退出登录', style: TextStyle(fontSize: 16)),
        content: const Text('确定退出当前 QQ 音乐账号吗？',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: AppColors.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出', style: TextStyle(color: AppColors.magenta)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recent = HistoryStore.playHistory();
    final playlists = PlaylistStore.playlistNames();
    final entries = <(String, String, IconData, Color, VoidCallback)>[
      ('本地歌单', '${playlists.length} 个', Icons.queue_music_rounded, AppColors.cyan,
          () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlaylistPage()))),
      ('下载管理', '0 首', Icons.download_rounded, AppColors.violet,
          () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DownloadPage()))),
      ('播放历史', '${recent.length} 首', Icons.history_rounded, AppColors.magenta,
          () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HistoryPage()))),
      ('我的收藏', '${HistoryStore.playHistory().length} 首', Icons.favorite_border_rounded, AppColors.aqua,
          () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HistoryPage()))),
    ];

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () async => _refresh(),
        color: AppColors.cyan,
        backgroundColor: AppColors.surfaceGlass,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(20, 26, 20, 30),
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
                            color: AppColors.magenta.withValues(alpha: 0.4),
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
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textTertiary),
                          ),
                          if (_loginHint.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              _loginHint,
                              style: const TextStyle(
                                  fontSize: 11, color: AppColors.magenta),
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
                                style: const TextStyle(
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
                    _SettingTile(
                      icon: Icons.settings_outlined,
                      title: '设置',
                      subtitle: '音质偏好 · 下载目录 · 缓存管理',
                      color: AppColors.cyan,
                      onTap: () => _openSettings(context),
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
                      subtitle: '白姬音乐 v2.0.0 · 跨平台重构版',
                      color: AppColors.magenta,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutPage())),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
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
    return ListTile(
      leading: Icon(icon, color: color, size: 22),
      title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11, color: AppColors.textTertiary)),
      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
      onTap: onTap,
    );
  }
}