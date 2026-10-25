import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/app_logger.dart';
import '../../network/music_api.dart';
import '../../network/netease/netease_client.dart';
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

  // ================= 手机验证码登录（v2.4.2，仿倾听） =================
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  bool _phoneBusy = false;
  bool _sending = false;
  int _countdown = 0;
  Timer? _countdownTimer;

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
    _phoneController.dispose();
    _codeController.dispose();
    _countdownTimer?.cancel();
    _qrSub?.cancel();
    super.dispose();
  }

  /// 发送短信验证码（60s 倒计时）。
  Future<void> _sendCaptcha() async {
    final phone = _phoneController.text.trim();
    if (phone.length < 5) {
      showAppSnack('请输入手机号');
      return;
    }
    setState(() => _sending = true);
    try {
      await AppServices.instance.netease.sendCaptcha(phone);
      if (!mounted) return;
      showAppSnack('验证码已发送，请查收短信');
      setState(() => _countdown = 60);
      _countdownTimer?.cancel();
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return t.cancel();
        setState(() => _countdown = _countdown - 1);
        if (_countdown <= 0) t.cancel();
      });
    } catch (e) {
      if (mounted) showAppSnack('$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 手机号 + 验证码登录。
  Future<void> _loginByPhone() async {
    final phone = _phoneController.text.trim();
    final code = _codeController.text.trim();
    if (phone.length < 5 || code.length < 4) {
      showAppSnack('请输入手机号与短信验证码');
      return;
    }
    setState(() => _phoneBusy = true);
    try {
      final r = await AppServices.instance.netease
          .loginByCellphone(phone, code);
      AppServices.instance.netease.cookie = r.cookie;
      if (r.userId != 0) AppServices.instance.netease.userId = r.userId;
      AppLog.i('NeteaseLoginPage',
          '网易云验证码登录成功 uid=${r.userId} nick=${r.nickname}');
      // 补齐浏览器会话 Cookie，与扫码/粘贴路径对齐
      unawaited(AppServices.instance.netease
          .enrichCookie()
          .timeout(const Duration(seconds: 3), onTimeout: () async {}));
      if (!mounted) return;
      showAppSnack('网易云登录成功');
      Navigator.pop(context, true);
    } on NeteaseLoginException catch (e) {
      if (mounted) showAppSnack(e.message);
    } catch (e) {
      if (mounted) showAppSnack('网易云登录失败: $e');
    } finally {
      if (mounted) setState(() => _phoneBusy = false);
    }
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
      // 粘贴的 Cookie 可能只有登录字段（MUSIC_U 等），缺 NMTID 等浏览器
      // 会话字段——写操作（发评论）会被风控。这里异步补齐一次（限时
      // 3 秒，失败不影响登录），与扫码登录路径对齐。
      unawaited(AppServices.instance.netease
          .enrichCookie()
          .timeout(const Duration(seconds: 3), onTimeout: () async {}));
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
            // 补齐浏览器会话 Cookie（NMTID/_ntes_nuid 等）：轮询响应只带
            // 登录态字段，缺这些容易触发网易云风控（发评 code=250）。
            AppServices.instance.netease.enrichCookie();
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
            // 手机验证码登录（v2.4.2，仿倾听）
            GlassCard(
              padding: const EdgeInsets.all(16),
              glowColor: AppColors.violet,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '手机验证码登录',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '输入网易云绑定的手机号，接收短信验证码直接登录',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  MiuixTextField(
                    controller: _phoneController,
                    label: '手机号',
                    useLabelAsPlaceholder: true,
                    singleLine: true,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: MiuixTextField(
                          controller: _codeController,
                          label: '短信验证码',
                          useLabelAsPlaceholder: true,
                          singleLine: true,
                        ),
                      ),
                      const SizedBox(width: 10),
                      NeonButton(
                        label: _countdown > 0 ? '$_countdown s' : '发送验证码',
                        filled: false,
                        onPressed: (_sending || _countdown > 0)
                            ? null
                            : _sendCaptcha,
                        padding: const EdgeInsets.symmetric(
                            vertical: 12, horizontal: 14),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  NeonButton(
                    label: '验证码登录',
                    icon: Icons.sms_outlined,
                    gradient: const [AppColors.violet, AppColors.cyan],
                    onPressed: _phoneBusy ? null : _loginByPhone,
                    padding: const EdgeInsets.symmetric(vertical: 12),
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
