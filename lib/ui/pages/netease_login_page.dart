import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/app_logger.dart';
import '../../network/music_api.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';

/// 网易云音乐登录页面：Cookie 登录。
class NeteaseLoginPage extends StatefulWidget {
  const NeteaseLoginPage({super.key});

  @override
  State<NeteaseLoginPage> createState() => _NeteaseLoginPageState();
}

class _NeteaseLoginPageState extends State<NeteaseLoginPage> {
  final _cookieController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _cookieController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final cookie = _cookieController.text.trim();
    if (cookie.isEmpty) {
      showAppSnack('请粘贴网易云 Cookie');
      return;
    }
    if (!cookie.contains('MUSIC_U')) {
      showAppSnack('Cookie 需包含 MUSIC_U 字段才能正常使用');
      return;
    }
    setState(() => _busy = true);
    try {
      AppServices.instance.netease.cookie = cookie;
      // 验证 cookie 有效性
      final test = AppServices.instance.netease.isLoggedIn();
      AppLog.i('NeteaseLoginPage', '网易云 Cookie 已保存 loggedIn=$test');
      if (mounted) {
        showAppSnack('网易云 Cookie 登录成功');
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showAppSnack('网易云登录失败: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MiuixScaffold(
      containerColor: Colors.transparent,
      snackbarHost: MiuixSnackbarHost(state: appSnackbarHostState),
      topBar: MiuixTopAppBar(
        title: '网易云音乐登录',
        titleColor: AppColors.skyBlue,
        color: Colors.transparent,
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.pop(context),
          child: Icon(Icons.arrow_back_rounded,
              color: AppColors.textPrimary),
        ),
      ),
      content: (padding) => SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlassCard(
                padding: const EdgeInsets.all(16),
                glowColor: AppColors.magenta,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Cookie 登录',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '粘贴浏览器中 music.163.com 的 Cookie（需包含 MUSIC_U）',
                      style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
                    ),
                    const SizedBox(height: 12),
                    MiuixTextField(
                      controller: _cookieController,
                      label: 'MUSIC_U=xxx; ...',
                      useLabelAsPlaceholder: true,
                      minLines: 2,
                      maxLines: 4,
                      cursorColor: AppColors.accentAlt,
                      textStyle: TextStyle(
                          fontSize: 12, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 12),
                    NeonButton(
                      label: '网易云登录',
                      icon: Icons.login_rounded,
                      gradient: const [AppColors.magenta, AppColors.violet],
                      onPressed: _busy ? null : _login,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceGlass,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '获取方法：\n'
                        '1. 在浏览器中登录 music.163.com\n'
                        '2. 按 F12 打开开发者工具 → Application/Storage → Cookies\n'
                        '3. 复制包含 MUSIC_U 的整段 Cookie\n'
                        '4. 粘贴到上方输入框',
                        style: TextStyle(fontSize: 11, color: AppColors.textTertiary, height: 1.6),
                      ),
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
}
