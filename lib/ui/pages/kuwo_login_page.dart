// 酷我音乐登录页：账号密码 + 短信验证码。
//
// 协议层见 network/kuwo/kuwo_auth.dart（沙箱内已实测打通 login_kw /
// send_sms；login_sms / auto_login 与官方形制一致）。
//
// 两种登录方式的取舍：
//   - 账号密码：账号可以是用户名 / 手机号 / 邮箱，口令以 base64 随查询串
//     下发（酷我官方客户端形制）；
//   - 短信验证码：只支持中国大陆手机号，验证码 5 位；酷我**没有二维码登录**。
//
// 登录态由 [KuwoAuth] 持有并持久化，本页只在成功/退出时刷新。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../network/kuwo/kuwo_auth.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';

/// 酷我音乐登录页面。
class KuwoLoginPage extends StatefulWidget {
  const KuwoLoginPage({super.key});

  @override
  State<KuwoLoginPage> createState() => _KuwoLoginPageState();
}

class _KuwoLoginPageState extends State<KuwoLoginPage> {
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  /// 当前页签：0 = 账号密码，1 = 短信验证码。
  int _tab = 0;

  bool _busy = false;

  /// 是否留存口令（用于会话过期后自动重登）。
  bool _remember = true;

  /// 短信验证码凭据（发送成功后非空）。
  KuwoSmsChallenge? _challenge;

  /// 重发倒计时（秒）。
  int _cooldown = 0;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    final saved = KuwoAuth.savedUsername;
    if (saved.isNotEmpty) _userController.text = saved;
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _userController.dispose();
    _passController.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  // ================= 账号密码 =================

  Future<void> _loginByPassword() async {
    if (_busy) return;
    final user = _userController.text.trim();
    final pass = _passController.text;
    if (user.isEmpty) {
      showAppSnack('请输入账号');
      return;
    }
    if (pass.isEmpty) {
      showAppSnack('请输入密码');
      return;
    }
    setState(() => _busy = true);
    try {
      final s = await KuwoAuth.loginWithPassword(user, pass,
          remember: _remember);
      if (!mounted) return;
      showAppSnack('酷我登录成功${s.nickname.isNotEmpty ? "：${s.nickname}" : ""}');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showAppSnack('$e');
      }
    }
  }

  // ================= 短信验证码 =================

  Future<void> _sendCode() async {
    if (_busy || _cooldown > 0) return;
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) {
      showAppSnack('请输入手机号');
      return;
    }
    if (!KuwoAuth.isValidPhone(phone)) {
      showAppSnack('请输入 11 位中国大陆手机号');
      return;
    }
    setState(() => _busy = true);
    try {
      final c = await KuwoAuth.sendSms(phone);
      if (!mounted) return;
      setState(() {
        _challenge = c;
        _busy = false;
        _cooldown = 60;
      });
      _cooldownTimer?.cancel();
      _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {
          _cooldown--;
          if (_cooldown <= 0) _cooldownTimer?.cancel();
        });
      });
      showAppSnack('验证码已发送至 $phone');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showAppSnack('$e');
      }
    }
  }

  Future<void> _loginBySms() async {
    if (_busy) return;
    final challenge = _challenge;
    if (challenge == null) {
      showAppSnack('请先获取验证码');
      return;
    }
    final code = _codeController.text.trim();
    if (code.length != KuwoAuthConst.smsCodeLength) {
      showAppSnack('请输入 ${KuwoAuthConst.smsCodeLength} 位验证码');
      return;
    }
    setState(() => _busy = true);
    try {
      final s = await KuwoAuth.loginWithSms(challenge, code);
      if (!mounted) return;
      showAppSnack('酷我登录成功${s.nickname.isNotEmpty ? "：${s.nickname}" : ""}');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showAppSnack('$e');
      }
    }
  }

  // ================= 退出登录 =================

  Future<void> _logout() async {
    await KuwoAuth.logout();
    if (!mounted) return;
    showAppSnack('已退出酷我登录');
    setState(() {});
  }

  // ================= 构建 =================

  @override
  Widget build(BuildContext context) {
    final session = KuwoAuth.session;
    return PageScaffold(
      title: '酷我音乐登录',
      snackbarHost: appSnackbarHostState,
      contentPadding: EdgeInsets.zero,
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (session != null && session.isValid) ...[
              _LoggedInCard(
                session: session,
                onLogout: _logout,
              ),
              const SizedBox(height: 20),
            ],
            GlassCard(
              padding: const EdgeInsets.all(16),
              glowColor: AppColors.cyan,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 页签
                  Row(
                    children: [
                      _TabChip(
                        text: '账号密码',
                        selected: _tab == 0,
                        onTap: _busy ? null : () => setState(() => _tab = 0),
                      ),
                      const SizedBox(width: 10),
                      _TabChip(
                        text: '短信验证码',
                        selected: _tab == 1,
                        onTap: _busy ? null : () => setState(() => _tab = 1),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_tab == 0) ..._buildPasswordForm(),
                  if (_tab == 1) ..._buildSmsForm(),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _NoteCard(
              text: _tab == 0
                  ? '账号可以是酷我用户名、手机号或邮箱。\n'
                      '口令会随请求加密下发（酷我官方客户端同款形制），'
                      '仅用于向酷我服务器登录。\n'
                      '勾选「记住密码」后，会话过期可自动重登；'
                      '口令以国密 SM4 加密后存在本机。'
                  : '验证码将发送到该手机号（仅支持中国大陆号码）。\n'
                      '未注册的手机号登录成功后会自动创建酷我账号。\n'
                      '验证码 5 位数字，有效期约 5 分钟。',
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildPasswordForm() => [
        AppTextField(
          controller: _userController,
          label: '账号',
          useLabelAsPlaceholder: true,
          leadingIcon: const Icon(Icons.person_outline),
          enabled: !_busy,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        AppTextField(
          controller: _passController,
          label: '密码',
          useLabelAsPlaceholder: true,
          leadingIcon: const Icon(Icons.lock_outline),
          enabled: !_busy,
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _loginByPassword(),
        ),
        const SizedBox(height: 12),
        _RememberRow(
          value: _remember,
          onChanged: _busy ? null : (v) => setState(() => _remember = v),
        ),
        const SizedBox(height: 16),
        NeonButton(
          label: _busy ? '登录中…' : '登录',
          icon: Icons.login_rounded,
          gradient: AppColors.accentGradient,
          onPressed: _busy ? null : _loginByPassword,
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ];

  List<Widget> _buildSmsForm() => [
        AppTextField(
          controller: _phoneController,
          label: '手机号',
          useLabelAsPlaceholder: true,
          leadingIcon: const Icon(Icons.phone_android_outlined),
          enabled: !_busy,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AppTextField(
                controller: _codeController,
                label: '验证码',
                useLabelAsPlaceholder: true,
                leadingIcon: const Icon(Icons.sms_outlined),
                enabled: !_busy,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _loginBySms(),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 48,
              child: NeonButton(
                label: _cooldown > 0 ? '$_cooldown 秒' : '获取验证码',
                icon: Icons.markunread_mailbox_outlined,
                gradient: AppColors.accentGradient,
                onPressed: (_busy || _cooldown > 0) ? null : _sendCode,
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        NeonButton(
          label: _busy ? '登录中…' : '登录',
          icon: Icons.login_rounded,
          gradient: AppColors.accentGradient,
          onPressed: _busy ? null : _loginBySms,
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ];
}

/// 已登录状态卡片。
class _LoggedInCard extends StatelessWidget {
  const _LoggedInCard({required this.session, required this.onLogout});

  final KuwoSession session;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    final name = session.nickname.isNotEmpty ? session.nickname : '酷我用户';
    return GlassCard(
      padding: const EdgeInsets.all(16),
      glowColor: AppColors.aqua,
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceGlassStrong,
            ),
            clipBehavior: Clip.antiAlias,
            child: session.avatar.isNotEmpty
                ? Image.network(
                    session.avatar,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.account_circle,
                      color: AppColors.accent,
                    ),
                  )
                : Icon(Icons.account_circle, color: AppColors.accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  'UID ${session.uid}${session.username.isNotEmpty ? " · ${session.username}" : ""}',
                  style: TextStyle(
          fontSize: 11,
          color: AppColors.textTertiary,
        ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onLogout,
            child: Text(
              '退出登录',
              style: TextStyle(fontSize: 12, color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}

/// 页签小片。
class _TabChip extends StatelessWidget {
  const _TabChip({required this.text, required this.selected, this.onTap});

  final String text;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.surfaceGlassStrong : AppColors.surfaceGlass,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.strokeGlass,
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AppColors.accent : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// 「记住密码」行。
class _RememberRow extends StatelessWidget {
  const _RememberRow({required this.value, this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        MiuixSwitch(
          value: value,
          onChanged: onChanged,
        ),
        const SizedBox(width: 8),
        Text(
          '记住密码（会话过期自动重登）',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

/// 说明卡片。
class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.strokeGlass),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: AppColors.textTertiary,
          height: 1.6,
        ),
      ),
    );
  }
}
