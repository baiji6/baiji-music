import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/app_logger.dart';
import '../../network/music_api.dart';
import '../../network/netease_qr_login.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';
import '../widgets/cookie_field.dart';

/// 网易云音乐登录页面：Cookie 登录 + 扫码登录。
class NeteaseLoginPage extends StatefulWidget {
  const NeteaseLoginPage({super.key});

  @override
  State<NeteaseLoginPage> createState() => _NeteaseLoginPageState();
}

class _NeteaseLoginPageState extends State<NeteaseLoginPage> {
  final _cookieController = TextEditingController();
  bool _busy = false;

  // ================= 扫码登录（轮询，见 netease_qr_login.dart） =================

  /// 二维码内容（`https://music.163.com/login?codekey=…`）。
  String? _qrContent;
  String? _qrStatus;
  String? _qrError;
  bool _qrBusy = false;
  StreamSubscription<NeteaseQrStatus>? _qrSub;

  @override
  void dispose() {
    _cookieController.dispose();
    _qrSub?.cancel();
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

  // ================= 扫码登录 =================

  /// 扫码主流程：unikey → 本地渲染二维码 → 轮询状态 → 803 落 Cookie。
  Future<void> _loginByQr() async {
    setState(() {
      _qrBusy = true;
      _qrError = null;
      _qrStatus = '正在获取二维码…';
    });

    final NeteaseQr qr;
    try {
      qr = await NeteaseQrLogin.createQr();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _qrBusy = false;
        _qrStatus = null;
        _qrError = '获取二维码失败: $e';
      });
      showAppSnack('获取二维码失败: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _qrContent = qr.content;
      _qrStatus = '等待扫码…';
    });

    _qrSub?.cancel();
    _qrSub = NeteaseQrLogin.poll(qr.unikey).listen(
      (s) {
        if (!mounted) return;
        switch (s.event) {
          case NeteaseQrEvent.waiting:
            setState(() => _qrStatus = '等待扫码…');
          case NeteaseQrEvent.scanned:
            setState(() => _qrStatus = '已扫描，请在手机上确认登录…');
          case NeteaseQrEvent.expired:
            _qrFailed('二维码已过期，请重新获取');
          case NeteaseQrEvent.done:
            AppServices.instance.netease.cookie = s.cookie!;
            AppLog.i('NeteaseLoginPage', '网易云扫码登录成功');
            showAppSnack('网易云扫码登录成功');
            Navigator.pop(context, true);
        }
      },
      onError: (Object e) {
        if (!mounted) return;
        _qrFailed('扫码失败: $e');
      },
    );
  }

  /// 扫码失败收尾：停掉轮询、展示错误。
  void _qrFailed(String msg) {
    _qrSub?.cancel();
    _qrSub = null;
    setState(() {
      _qrBusy = false;
      _qrStatus = null;
      _qrError = msg;
    });
    showAppSnack(msg);
  }

  /// 取消扫码（停止轮询）。
  void _cancelQr() {
    _qrSub?.cancel();
    _qrSub = null;
    setState(() {
      _qrBusy = false;
      _qrStatus = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '网易云音乐登录',
      snackbarHost: appSnackbarHostState,
      // 水平/底部留白由内部 SingleChildScrollView 自管，脚手架只补顶栏高度
      contentPadding: EdgeInsets.zero,
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
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  CookieField(
                    controller: _cookieController,
                    hint: 'MUSIC_U=xxx; ...',
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
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textTertiary,
                        height: 1.6,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // 扫码登录
            GlassCard(
              padding: const EdgeInsets.all(16),
              glowColor: AppColors.cyan,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '扫码登录',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '用网易云音乐 App 扫码（App 内「我的」页面左上角扫一扫）',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_qrContent != null) ...[
                    Center(
                      child: Container(
                        width: 200,
                        height: 200,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: QrImageView(
                          data: _qrContent!,
                          backgroundColor: Colors.white,
                          eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: Colors.black,
                          ),
                          dataModuleStyle: const QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_qrStatus != null) ...[
                    Center(
                      child: Text(
                        _qrStatus!,
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textSecondary),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_qrError != null) ...[
                    Center(
                      child: Text(
                        _qrError!,
                        style:
                            TextStyle(fontSize: 12, color: AppColors.accentAlt),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_qrBusy && _qrContent != null) ...[
                    const Center(
                      child: MiuixCircularProgressIndicator(size: 24),
                    ),
                    const SizedBox(height: 12),
                    NeonButton(
                      label: '取消扫码',
                      filled: false,
                      onPressed: _cancelQr,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ] else
                    NeonButton(
                      label: _qrContent == null ? '获取二维码' : '重新获取',
                      icon: Icons.qr_code_2_rounded,
                      gradient: const [AppColors.cyan, AppColors.violet],
                      onPressed: _qrBusy ? null : _loginByQr,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
