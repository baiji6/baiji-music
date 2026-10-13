import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/app_version.dart';
import '../../core/dev_mode.dart';
import '../../theme/app_theme.dart';
import '../widgets/agreement_dialog.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';

/// 关于页。
///
/// 隐藏入口：连续点击版本号 10 次 → 输入密码开启**开发者模式**
/// （抓包调试等高级功能的开关，见设置页「开发者模式」分区）。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  /// 版本号连点计数。
  int _versionTaps = 0;

  /// 上一次点击时刻（用于间隔超时重置计数）。
  DateTime? _lastTapAt;

  /// 密码输入弹层显隐（Miuix 声明式）。
  bool _showPasswordDialog = false;

  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  void _onVersionTap() {
    final now = DateTime.now();
    // 间隔太久重新计数，防止日常误触慢慢累积出来
    if (_lastTapAt == null ||
        now.difference(_lastTapAt!) > DevMode.tapWindow) {
      _versionTaps = 1;
    } else {
      _versionTaps++;
    }
    _lastTapAt = now;

    if (_versionTaps < DevMode.tapThreshold) return;
    _versionTaps = 0;
    _lastTapAt = null;

    if (DevMode.instance.enabled) {
      showAppSnack('开发者模式已开启（设置页 → 开发者模式）');
      return;
    }
    _passwordController.clear();
    setState(() => _showPasswordDialog = true);
  }

  void _submitPassword() {
    final input = _passwordController.text;
    if (!DevMode.checkPassword(input)) {
      showAppSnack('密码不正确');
      return;
    }
    setState(() => _showPasswordDialog = false);
    DevMode.instance.setEnabled(true).then((_) {
      if (!mounted) return;
      showAppSnack('开发者模式已开启：设置页新增「开发者模式」分区');
    });
  }

  @override
  Widget build(BuildContext context) {
    return MiuixScaffold(
      containerColor: Colors.transparent,
      snackbarHost: MiuixSnackbarHost(state: appSnackbarHostState),
      topBar: MiuixTopAppBar(
        title: '关于',
        titleColor: AppColors.skyBlue,
        color: Colors.transparent,
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary, size: 20),
        ),
      ),
      content: (padding) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: AppColors.neonGradient),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.accentAlt.withValues(alpha: 0.4),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 40),
            ),
            SizedBox(height: 20),
            const NeonText(
              '白姬音乐',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            // 连点 10 次开启开发者模式的隐藏入口
            GestureDetector(
              onTap: _onVersionTap,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      AppVersion.display,
                      style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                    ),
                    if (DevMode.instance.enabled) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.developer_mode_rounded,
                          size: 13, color: AppColors.accent),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            GlassCard(
              child: Column(
                children: [
                  _infoTile('平台支持', 'iOS / macOS / Windows / Linux / Android'),
                  MiuixHorizontalDivider(
                      thickness: 1, color: AppColors.strokeGlass),
                  _infoTile('音源', 'QQ 音乐 + 网易云音乐'),
                  MiuixHorizontalDivider(
                      thickness: 1, color: AppColors.strokeGlass),
                  _infoTile('技术栈', 'Flutter 3.47 · Dart · 纯 Dart 加密'),
                  MiuixHorizontalDivider(
                      thickness: 1, color: AppColors.strokeGlass),
                  _infoTile('构建加固', 'R8 / UPX / Dart Obfuscate / Strip'),
                  MiuixHorizontalDivider(
                      thickness: 1, color: AppColors.strokeGlass),
                  _infoTile('作者', '白姬9527'),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // 法律信息（从设置页移来：与「关于」语义一致，设置页不再重复）
            const SectionHeader(title: '法律信息'),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  MiuixArrowPreference(
                    title: '免责声明',
                    summary: '点击查看全文',
                    startAction: Icon(Icons.gavel_rounded,
                        color: AppColors.warning, size: 22),
                    onClick: () => showAgreementReader(
                      context,
                      initial: AgreementTab.disclaimer,
                    ),
                  ),
                  MiuixHorizontalDivider(
                      thickness: 1, color: AppColors.strokeGlass),
                  MiuixArrowPreference(
                    title: '使用协议',
                    summary: '点击查看全文',
                    startAction: Icon(Icons.article_rounded,
                        color: AppColors.accentAlt, size: 22),
                    onClick: () => showAgreementReader(
                      context,
                      initial: AgreementTab.terms,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '© 2024-2026 白姬音乐. All rights reserved.',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
      // 开发者模式密码弹层（声明式，挂 bottomBar 槽位由 root popup host 渲染）
      bottomBar: MiuixOverlayDialog(
        show: _showPasswordDialog,
        title: '开启开发者模式',
        summary: '请输入开发者密码',
        backgroundColor: AppColors.bg2,
        onDismissRequest: () => setState(() => _showPasswordDialog = false),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MiuixTextField(
              controller: _passwordController,
              autofocus: true,
              obscureText: true,
              label: '密码',
              singleLine: true,
              onSubmitted: (_) => _submitPassword(),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                MiuixTextButton('取消', onPressed: () {
                  setState(() => _showPasswordDialog = false);
                }),
                const SizedBox(width: 8),
                MiuixTextButton('确定', onPressed: _submitPassword),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
