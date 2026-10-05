import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/app_logger.dart';
import '../../data/history_store.dart';
import '../../data/playlist_store.dart';
import '../../network/login_api.dart';
import '../../network/music_api.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'about_page.dart';
import 'download_page.dart';
import 'history_page.dart';
import 'log_page.dart';
import 'playlist_page.dart';

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
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LoginSheet(
        onDone: () {
          Navigator.pop(context);
          _refresh();
        },
      ),
    );
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('设置面板在完整版中提供：音质偏好已由播放器自动应用'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}

// ==================== 登录弹层 ====================

/// 登录弹层：QQ 二维码登录 + Cookie 登录。
class _LoginSheet extends StatefulWidget {
  const _LoginSheet({required this.onDone});

  final VoidCallback onDone;

  @override
  State<_LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<_LoginSheet> {
  final _cookieController = TextEditingController();
  final _wyCookieController = TextEditingController();
  Uint8List? _qrImage;
  bool _busy = false;
  String? _qrError;

  @override
  void dispose() {
    _cookieController.dispose();
    _wyCookieController.dispose();
    super.dispose();
  }

  Future<void> _loginByCookie() async {
    final cookie = _cookieController.text.trim();
    if (cookie.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请粘贴 QQ 音乐 Cookie')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final cred = await AppServices.instance.qq.login.loginByCookie(cookie);
      AppServices.instance.qq.credential = cred;
      AppLog.i('LibraryHome', 'QQ Cookie 登录成功 uid=${cred.strMusicid}');
      if (mounted) widget.onDone();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _qrError = 'QQ 登录失败: $e';
        });
      }
    }
  }

  Future<void> _loginWyByCookie() async {
    final cookie = _wyCookieController.text.trim();
    if (cookie.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请粘贴网易云 Cookie（需包含 MUSIC_U）')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      AppServices.instance.netease.cookie = cookie;
      AppLog.i('LibraryHome', '网易云 Cookie 已保存');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('网易云 Cookie 登录成功')),
        );
        widget.onDone();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _qrError = '网易云登录失败: $e';
        });
      }
    }
  }

  Future<void> _loginByQr() async {
    setState(() {
      _busy = true;
      _qrError = null;
    });
    try {
      final login = AppServices.instance.qq.login;
      final qrcode = await login.getQrcode();

      if (!mounted) return;
      setState(() => _qrImage = qrcode.image);
      // 轮询扫码状态
      const pollInterval = Duration(seconds: 2);
      var attempt = 0;
      while (mounted && attempt < 90) {
        attempt++;
        await Future<void>.delayed(pollInterval);
        final check = await login.checkQrcode(qrcode.qrsig);
        switch (check.event) {
          case QrEvent.done:
            final cred = await login.authorizeQr(check.uin, check.sigx);
            AppLog.i('LibraryHome', '扫码登录成功 uid=${cred.strMusicid}');
            if (mounted) widget.onDone();
            return;
          case QrEvent.scan:
          case QrEvent.conf:
            if (mounted) {
              setState(() => _qrError = '已扫描，请在手机上确认登录…');
            }
            continue;
          case QrEvent.refuse:
            if (mounted) {
              setState(() {
                _busy = false;
                _qrError = '用户拒绝了登录';
              });
            }
            return;
          case QrEvent.timeout:
          case QrEvent.other:
            // 等待扫码
            if (mounted) {
              setState(() => _qrError = '等待扫码…（${attempt * 2}s）');
            }
            continue;
        }
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _qrError = '二维码已过期，请重试';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _qrError = '二维码登录失败: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 30),
        decoration: const BoxDecoration(
          color: AppColors.bg2,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const NeonText('登录',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded,
                      color: AppColors.textTertiary),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'QQ 音乐（Cookie / 二维码）  网易云（Cookie）',
              style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
            ),
            const SizedBox(height: 20),

            // QQ Cookie 登录
            GlassCard(
              padding: const EdgeInsets.all(14),
              glowColor: AppColors.cyan,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'QQ 音乐 Cookie 登录',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '粘贴浏览器中 music.qq.com 的完整 Cookie',
                    style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _cookieController,
                    maxLines: 2,
                    minLines: 2,
                    style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'uin=xxx; qm_keyst=xxx; …',
                      hintStyle: const TextStyle(
                          fontSize: 12, color: AppColors.textTertiary),
                      filled: true,
                      fillColor: AppColors.surfaceGlass,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.strokeGlass),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  NeonButton(
                    label: 'QQ 登录',
                    icon: Icons.login_rounded,
                    onPressed: _busy ? null : _loginByCookie,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 网易云 Cookie 登录
            GlassCard(
              padding: const EdgeInsets.all(14),
              glowColor: AppColors.magenta,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '网易云 Cookie 登录',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '粘贴浏览器中 music.163.com 的 Cookie（需含 MUSIC_U）',
                    style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _wyCookieController,
                    maxLines: 2,
                    minLines: 2,
                    style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'MUSIC_U=xxx; …',
                      hintStyle: const TextStyle(
                          fontSize: 12, color: AppColors.textTertiary),
                      filled: true,
                      fillColor: AppColors.surfaceGlass,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.strokeGlass),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  NeonButton(
                    label: '网易云登录',
                    icon: Icons.login_rounded,
                    gradient: const [AppColors.magenta, AppColors.violet],
                    onPressed: _busy ? null : _loginWyByCookie,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_qrImage != null) ...[
              Center(
                child: Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(_qrImage!, fit: BoxFit.contain),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_qrError != null) ...[
              Text(
                _qrError!,
                style: const TextStyle(fontSize: 12, color: AppColors.magenta),
              ),
              const SizedBox(height: 12),
            ],
            NeonButton(
              label: 'QQ 扫码登录（二维码 + 轮询）',
              icon: Icons.qr_code_2_rounded,
              gradient: const [AppColors.magenta, AppColors.violet],
              onPressed: _busy ? null : _loginByQr,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            if (_busy) ...[
              const SizedBox(height: 14),
              const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.cyan),
                ),
              ),
            ],
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
    return ListTile(
      leading: Icon(icon, color: color, size: 22),
      title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11, color: AppColors.textTertiary)),
      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
      onTap: onTap,
    );
  }
}