import 'package:flutter/material.dart';

import '../../core/app_logger.dart';
import '../../network/music_api.dart';
import '../../theme/app_theme.dart';
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
      _showSnack('请粘贴网易云 Cookie');
      return;
    }
    if (!cookie.contains('MUSIC_U')) {
      _showSnack('Cookie 需包含 MUSIC_U 字段才能正常使用');
      return;
    }
    setState(() => _busy = true);
    try {
      AppServices.instance.netease.cookie = cookie;
      // 验证 cookie 有效性
      final test = AppServices.instance.netease.isLoggedIn();
      AppLog.i('NeteaseLoginPage', '网易云 Cookie 已保存 loggedIn=$test');
      if (mounted) {
        _showSnack('网易云 Cookie 登录成功', isError: false);
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _showSnack('网易云登录失败: $e');
      }
    }
  }

  void _showSnack(String msg, {bool isError = true}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        backgroundColor: isError ? AppColors.danger : AppColors.magenta,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('网易云音乐登录'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
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
                    const Text(
                      '粘贴浏览器中 music.163.com 的 Cookie（需包含 MUSIC_U）',
                      style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _cookieController,
                      maxLines: 4,
                      minLines: 2,
                      style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        hintText: 'MUSIC_U=xxx; ...',
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
                      child: const Text(
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
