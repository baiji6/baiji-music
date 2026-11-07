// 酷狗音乐登录页：二维码扫码 + 手动 userid/token。
//
// 协议层见 network/kugou/kugou_auth.dart（照 HotDownloader + 倾听 5.6.14，
// 二维码创建/轮询已在沙箱实测打通）。
//
// 两种登录方式：
//   - 二维码：酷狗音乐 App 扫一扫；服务端直接下发二维码 PNG，缺失时用
//     qr_flutter 本地渲染 H5 落地页 URL 兜底；约 2 秒轮询一次状态。
//   - 手动凭据：填写酷狗标准版的 userid 与 token（可附带设备 mid/dfid），
//     与 HotDownloader 的「手动填写凭据」一致。
//
// 登录的意义是解锁高音质（flac / Hi-Res）：未登录取链会被服务端判为
// 版权/会员限制，登录态随取链参数注入后才能拿到高码率文件。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../network/kugou/kugou_auth.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';

/// 酷狗音乐登录页面。
class KugouLoginPage extends StatefulWidget {
  const KugouLoginPage({super.key});

  @override
  State<KugouLoginPage> createState() => _KugouLoginPageState();
}

class _KugouLoginPageState extends State<KugouLoginPage> {
  final _useridController = TextEditingController();
  final _tokenController = TextEditingController();
  final _midController = TextEditingController();
  final _dfidController = TextEditingController();

  /// 页签：0 = 扫码登录，1 = 手动凭据。
  int _tab = 0;

  bool _busy = false;

  // ---------- 扫码态 ----------
  KugouQr? _qr;
  String? _qrStatus;
  String? _qrError;
  Timer? _pollTimer;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    KugouAuth.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    KugouAuth.removeListener(_onAuthChanged);
    _useridController.dispose();
    _tokenController.dispose();
    _midController.dispose();
    _dfidController.dispose();
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  // ================= 扫码登录 =================

  Future<void> _startQr() async {
    _pollTimer?.cancel();
    setState(() {
      _busy = true;
      _qrError = null;
      _qrStatus = '正在获取二维码…';
      _qr = null;
    });
    try {
      final qr = await KugouAuth.createQr();
      if (!mounted) return;
      setState(() {
        _qr = qr;
        _busy = false;
        _qrStatus = '请用酷狗音乐 App 扫码';
      });
      _schedulePoll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _qrStatus = null;
        _qrError = '获取二维码失败：$e';
      });
      showAppSnack('获取二维码失败：$e');
    }
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    if (_polling || _qr == null || !mounted) return;
    _polling = true;
    try {
      final st = await KugouAuth.checkQr(_qr!.key);
      if (!mounted) return;
      switch (st.event) {
        case KugouQrEvent.waiting:
          if (_qrStatus != '请用酷狗音乐 App 扫码') {
            setState(() => _qrStatus = '请用酷狗音乐 App 扫码');
          }
        case KugouQrEvent.scanned:
          setState(() => _qrStatus = '已扫码，请在手机上确认登录…');
        case KugouQrEvent.confirmed:
          _pollTimer?.cancel();
          setState(() {
            _qr = null;
            _qrStatus = null;
          });
          showAppSnack('酷狗登录成功（userid ${st.userid}）');
        case KugouQrEvent.expired:
          _pollTimer?.cancel();
          setState(() {
            _qrStatus = null;
            _qrError = '二维码已过期，请重新获取';
          });
      }
    } catch (e) {
      // 单次轮询失败不立刻打断（可能是网络抖动），连续失败才提示。
      if (mounted) setState(() => _qrStatus = '轮询中…（$e）');
    } finally {
      _polling = false;
    }
  }

  // ================= 手动登录 =================

  Future<void> _loginManual() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await KugouAuth.saveManual(
        _useridController.text,
        _tokenController.text,
        mid: _midController.text.trim(),
        dfid: _dfidController.text.trim(),
      );
      if (!mounted) return;
      setState(() => _busy = false);
      showAppSnack('酷狗登录已保存');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showAppSnack('$e');
      }
    }
  }

  Future<void> _logout() async {
    await KugouAuth.logout();
    if (mounted) showAppSnack('已退出酷狗登录');
  }

  // ================= 构建 =================

  @override
  Widget build(BuildContext context) {
    final session = KugouAuth.session;
    return PageScaffold(
      title: '酷狗音乐登录',
      snackbarHost: appSnackbarHostState,
      contentPadding: EdgeInsets.zero,
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (session != null && session.isValid) ...[
              _LoggedInCard(session: session, onLogout: _logout),
              const SizedBox(height: 20),
            ],
            GlassCard(
              padding: const EdgeInsets.all(16),
              glowColor: AppColors.cyan,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _TabChip(
                        text: '扫码登录',
                        selected: _tab == 0,
                        onTap: () => setState(() => _tab = 0),
                      ),
                      const SizedBox(width: 10),
                      _TabChip(
                        text: '手动凭据',
                        selected: _tab == 1,
                        onTap: () => setState(() => _tab = 1),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_tab == 0) ..._buildQrForm(),
                  if (_tab == 1) ..._buildManualForm(),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _NoteCard(
              text: '登录后可用酷狗音乐解锁无损 FLAC / Hi-Res 等高音质；'
                  '未登录通常只能播放标准 128K。\n'
                  '凭据仅保存在本机，并随取链请求发送给酷狗服务器。\n'
                  '手动凭据需与取得 token 时同一台设备（mid/dfid），'
                  '否则高音质取链可能鉴权失败。',
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildQrForm() => [
        Text(
          '用酷狗音乐 App 扫一扫登录（App 内「我的」页右上角扫一扫）',
          style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
        ),
        const SizedBox(height: 16),
        Center(
          child: Container(
            width: 208,
            height: 208,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(12),
            child: _qr == null
                ? Icon(Icons.qr_code_2_rounded,
                    size: 96, color: Colors.grey.shade300)
                : _qr!.hasImage
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.memory(
                          _qr!.imageBytes!,
                          width: 184,
                          height: 184,
                          fit: BoxFit.contain,
                        ),
                      )
                    : QrImageView(
                        data: _qr!.url,
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
        if (_qrStatus != null)
          Center(
            child: Text(
              _qrStatus!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
        if (_qrError != null)
          Center(
            child: Text(
              _qrError!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.redAccent),
            ),
          ),
        const SizedBox(height: 12),
        NeonButton(
          label: _busy ? '获取中…' : (_qr == null ? '获取二维码' : '刷新二维码'),
          icon: Icons.qr_code_2_rounded,
          gradient: AppColors.accentGradient,
          onPressed: _busy ? null : _startQr,
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        if (KugouAuth.isLoggedIn) ...[
          const SizedBox(height: 12),
          Center(
            child: Text(
              '当前已登录，重新扫码可切换账号',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
          ),
        ],
      ];

  List<Widget> _buildManualForm() => [
        Text(
          '填写酷狗标准版账号的 userid 与 token',
          style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
        ),
        const SizedBox(height: 12),
        AppTextField(
          controller: _useridController,
          label: 'userid',
          useLabelAsPlaceholder: true,
          leadingIcon: const Icon(Icons.person_outline),
          enabled: !_busy,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        AppTextField(
          controller: _tokenController,
          label: 'token',
          useLabelAsPlaceholder: true,
          leadingIcon: const Icon(Icons.vpn_key_outlined),
          enabled: !_busy,
          obscureText: true,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        AppTextField(
          controller: _midController,
          label: 'MID（选填，需与登录时同设备）',
          useLabelAsPlaceholder: true,
          leadingIcon: const Icon(Icons.devices_outlined),
          enabled: !_busy,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        AppTextField(
          controller: _dfidController,
          label: 'DFID（选填）',
          useLabelAsPlaceholder: true,
          leadingIcon: const Icon(Icons.fingerprint_outlined),
          enabled: !_busy,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _loginManual(),
        ),
        const SizedBox(height: 16),
        NeonButton(
          label: _busy ? '保存中…' : '保存并登录',
          icon: Icons.login_rounded,
          gradient: AppColors.accentGradient,
          onPressed: _busy ? null : _loginManual,
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ];
}

// ================= 小组件 =================

class _TabChip extends StatelessWidget {
  const _TabChip(
      {required this.text, required this.selected, required this.onTap});

  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppColors.accent.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.12),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.accent : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _LoggedInCard extends StatelessWidget {
  const _LoggedInCard({required this.session, required this.onLogout});

  final KugouSession session;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      glowColor: const Color(0xFF1EC17D),
      child: Row(
        children: [
          const Icon(Icons.verified_rounded, color: Color(0xFF1EC17D), size: 32),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('酷狗已登录',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  'userid ${session.userid} · 可解锁无损 / Hi-Res',
                  style:
                      TextStyle(fontSize: 12, color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
          TextButton(onPressed: onLogout, child: const Text('退出')),
        ],
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded,
              size: 18, color: AppColors.textTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                  fontSize: 11.5, color: AppColors.textSecondary, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
