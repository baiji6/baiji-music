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

  /// 扫码进度提示（等待扫码 / 已扫描待确认…）。
  String? _qrStatus;

  /// 真正的错误（只有无法继续时才写）。
  String? _qrError;

  /// 用户离开页面后置位，用于让轮询循环尽快退出。
  bool _canceled = false;

  /// 单次轮询的间隔。
  static const Duration _pollInterval = Duration(seconds: 2);

  /// 一张二维码最多轮询多久（腾讯侧约 30 秒失效，这里留足余量）。
  static const int _maxPollsPerQr = 20;

  /// 连续异常 / 空响应超过这个次数才放弃（网络抖动不该中断整个流程）。
  static const int _maxConsecutiveFailures = 3;

  /// 自动换新码的上限，防止服务端异常时无限刷新。
  static const int _maxQrRefresh = 3;

  @override
  void dispose() {
    _canceled = true;
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

  /// 扫码登录主流程：取码 → 轮询 → 失效自动换码。
  ///
  /// 腾讯的二维码有效期只有约 30 秒，所以这里在收到「已失效」时
  /// **自动重新取码继续轮询**，而不是让用户手动点刷新。
  Future<void> _loginByQr() async {
    setState(() {
      _busy = true;
      _qrError = null;
      _qrStatus = '正在获取二维码…';
      _canceled = false;
    });

    final login = AppServices.instance.qq.login;
    var refreshed = 0;
    var consecutiveFailures = 0;

    while (!_canceled && mounted) {
      // ---- 取一张新码 ----
      Qrcode qrcode;
      try {
        qrcode = await login.getQrcode();
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _qrStatus = null;
          _qrError = '获取二维码失败: $e';
        });
        _showSnack('获取二维码失败: $e');
        return;
      }
      if (!mounted) return;
      setState(() {
        _qrImage = qrcode.image;
        _qrStatus = '等待扫码…';
      });

      // ---- 轮询这张码 ----
      var polls = 0;
      var needNewQr = false;

      while (!_canceled && mounted && polls < _maxPollsPerQr) {
        polls++;
        await Future<void>.delayed(_pollInterval);
        if (_canceled || !mounted) return;

        QrCheck check;
        try {
          check = await login.checkQrcode(qrcode.qrsig);
          consecutiveFailures = 0; // 成功拿到响应就清零
        } catch (e) {
          // 网络抖动不该中断整个流程，容忍几次再放弃
          consecutiveFailures++;
          AppLog.w('QQLoginPage',
              '第 $consecutiveFailures 次轮询异常: $e');
          if (consecutiveFailures >= _maxConsecutiveFailures) {
            setState(() {
              _busy = false;
              _qrStatus = null;
              _qrError = '网络异常，二维码登录中断：$e';
            });
            _showSnack('网络异常，二维码登录中断');
            return;
          }
          continue;
        }

        switch (check.event) {
          case QrEvent.done:
            await _finishQrLogin(login, check);
            return;

          case QrEvent.waiting:
            // 66 = 二维码未失效，还没人扫。这里以前被错当成"已扫描"。
            setState(() =>
                _qrStatus = '等待扫码…（已等待 ${polls * 2}s）');
            break;

          case QrEvent.confirmed:
            setState(() => _qrStatus = '已扫描，请在手机上确认登录…');
            break;

          case QrEvent.expired:
          case QrEvent.refused:
            // 失效：自动换一张新码，用户无感
            AppLog.i('QQLoginPage', '二维码${check.event.name}，自动换新码');
            needNewQr = true;
            break;

          case QrEvent.other:
            // 空响应 / 无法解析：连续出现说明这张码已经不被服务端认可
            consecutiveFailures++;
            if (consecutiveFailures >= _maxConsecutiveFailures) {
              needNewQr = true;
            }
            break;
        }

        if (needNewQr) break;
      }

      if (_canceled || !mounted) return;

      // 走到这里说明这张码用完了（失效或超时），换一张
      refreshed++;
      if (refreshed > _maxQrRefresh) {
        setState(() {
          _busy = false;
          _qrStatus = null;
          _qrError = '二维码多次失效，请重试';
        });
        return;
      }
      setState(() => _qrStatus = '正在刷新二维码…');
    }

    if (mounted) {
      setState(() {
        _busy = false;
        _qrStatus = null;
      });
    }
  }

  /// 扫码确认后换取凭证并收尾。
  Future<void> _finishQrLogin(LoginApi login, QrCheck check) async {
    try {
      final cred = await login.authorizeQr(check.uin, check.sigx);
      AppLog.i('QQLoginPage', '扫码登录成功 uid=${cred.strMusicid}');
      if (!mounted) return;
      _showSnack('QQ 扫码登录成功', isError: false);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _qrStatus = null;
        _qrError = '登录失败: $e';
      });
      _showSnack('登录失败: $e');
    }
  }

  /// 中断轮询（循环会在下一个检查点退出）。
  void _cancelQr() {
    _canceled = true;
    setState(() {
      _busy = false;
      _qrStatus = null;
    });
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
                      '粘贴浏览器中 y.qq.com 的完整 Cookie，QQ 与微信登录都支持',
                      style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _cookieController,
                      maxLines: 3,
                      minLines: 2,
                      style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        // 微信登录的 cookie 里没有 uin，账号 id 落在 wxuin 上，
                        // 两个都要提示到，否则用户会以为贴错了。
                        hintText: 'uin=xxx（微信为 wxuin=xxx）; qm_keyst=xxx; …',
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
                    // 进度提示（中性色）与错误（警示色）分开显示：
                    // 以前两者共用一个字段，等待扫码也会被渲染成红色报错。
                    if (_qrStatus != null) ...[
                      Center(
                        child: Text(
                          _qrStatus!,
                          style: const TextStyle(
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
                          style: const TextStyle(fontSize: 12, color: AppColors.magenta),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_busy && _qrImage != null) ...[
                      const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.cyan),
                        ),
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
                        label: _qrImage == null ? '获取二维码' : '重新获取',
                        icon: Icons.qr_code_2_rounded,
                        gradient: const [AppColors.magenta, AppColors.violet],
                        onPressed: _busy ? null : _loginByQr,
                        padding: const EdgeInsets.symmetric(vertical: 12),
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
