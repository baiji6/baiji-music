import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/app_logger.dart';
import '../../network/login_api.dart';
import '../../network/music_api.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// QQ 音乐登录页面：Cookie 登录 + 二维码登录。
class QQLoginPage extends StatefulWidget {
  const QQLoginPage({super.key});

  @override
  State<QQLoginPage> createState() => _QQLoginPageState();
}

class _QQLoginPageState extends State<QQLoginPage> {
  final _cookieController = TextEditingController();
  Uint8List? _qrImage;
  bool _busy = false;
  String? _qrError;

  @override
  void dispose() {
    _cookieController.dispose();
    super.dispose();
  }

  Future<void> _loginByCookie() async {
    final cookie = _cookieController.text.trim();
    if (cookie.isEmpty) {
      _showSnack('请粘贴 QQ 音乐 Cookie');
      return;
    }
    setState(() => _busy = true);
    try {
      final cred = await AppServices.instance.qq.login.loginByCookie(cookie);
      AppServices.instance.qq.credential = cred;
      AppLog.i('QQLoginPage', 'QQ Cookie 登录成功 uid=${cred.strMusicid}');
      if (mounted) {
        _showSnack('QQ Cookie 登录成功', isError: false);
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _qrError = 'QQ 登录失败: $e';
        });
        _showSnack('QQ 登录失败: $e');
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
            AppLog.i('QQLoginPage', '扫码登录成功 uid=${cred.strMusicid}');
            if (mounted) {
              _showSnack('QQ 扫码登录成功', isError: false);
              Navigator.pop(context, true);
            }
            return;
          case QrEvent.scan:
          case QrEvent.conf:
            if (mounted) {
              setState(() => _qrError = '已扫描，请在手机上确认登录…');
            }
            break;
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
            break;
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
        _showSnack('二维码登录失败: $e');
      }
    }
  }

  void _showSnack(String msg, {bool isError = true}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        backgroundColor: isError ? AppColors.danger : AppColors.cyan,
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
        title: const Text('QQ 音乐登录'),
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
              // Cookie 登录
              GlassCard(
                padding: const EdgeInsets.all(16),
                glowColor: AppColors.cyan,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Cookie 登录',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '粘贴浏览器中 music.qq.com 的完整 Cookie',
                      style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _cookieController,
                      maxLines: 3,
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
                    const SizedBox(height: 12),
                    NeonButton(
                      label: 'Cookie 登录',
                      icon: Icons.login_rounded,
                      onPressed: _busy ? null : _loginByCookie,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // 二维码登录
              GlassCard(
                padding: const EdgeInsets.all(16),
                glowColor: AppColors.magenta,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '扫码登录',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '使用 QQ 音乐 App 扫描二维码',
                      style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
                    ),
                    const SizedBox(height: 16),
                    if (_qrImage != null) ...[
                      Center(
                        child: Container(
                          width: 200,
                          height: 200,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Image.memory(_qrImage!, fit: BoxFit.contain),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_qrError != null) ...[
                      Center(
                        child: Text(
                          _qrError!,
                          style: const TextStyle(fontSize: 12, color: AppColors.magenta),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (!_busy || _qrImage == null)
                      NeonButton(
                        label: _qrImage == null ? '获取二维码' : '刷新二维码',
                        icon: Icons.qr_code_2_rounded,
                        gradient: const [AppColors.magenta, AppColors.violet],
                        onPressed: _busy ? null : _loginByQr,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    if (_busy && _qrImage != null) ...[
                      const SizedBox(height: 12),
                      const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.cyan),
                        ),
                      ),
                    ],
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
