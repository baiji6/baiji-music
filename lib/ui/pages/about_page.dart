import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_version.dart';
import '../../core/dev_mode.dart';
import '../../theme/app_theme.dart';
import '../widgets/agreement_dialog.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';

/// 项目主页（GitHub）。
const String kGitHubUrl = 'https://github.com/baiji6/baiji-music';

/// QQ 群跳转链接（点击唤起 QQ 加群）。
const String kQqGroupUrl =
    'https://qun.qq.com/universal-share/share?ac=1&authKey=GZcIArq0%2FC2kFnBz%2BXIW64EAkp6ntNaaFHCcOCx2zoRPfkpC8MvkhHvq1vcyRcNN&busi_data=eyJncm91cENvZGUiOiIxMDcwNTcxNjM2IiwidG9rZW4iOiJTNlRyVkEybVk4a2RRa3FDVHhKbjRCL0VZVWlLeDlreFFEeEJVQUdoRzdRWFU4aENkblJVTXl0c1JPWGcyTzV6IiwidWluIjoiMjQ0OTA2NzgzNCJ9&data=Z1IltiwQtQxFk_RSwY8M-iPQhNL88DSNZvzroAQ9tEqKPea5C7pnQXzzUgaz5MSXFag-PPHOE2gzfvCd0vK23w&svctype=4&tempid=h5_group_info';

/// QQ 群号（展示用）。
const String kQqGroupId = '1070571636';

Future<void> _launchExternal(String url) async {
  final uri = Uri.parse(url);
  // externalApplication：GitHub 走浏览器，QQ 群链接走系统分发（能唤起 QQ）
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    showAppSnack('无法打开链接：$url');
  }
}

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

  /// 密码是否错误（仅用于输入框红框提示，不拦截提交）。
  bool _passwordError = false;

  /// 密码可见性（小眼睛切换）。
  bool _obscurePassword = true;

  /// 捐赠码弹层显隐（声明式，挂 bottomBar 槽位）。
  bool _showDonateDialog = false;

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
    setState(() {
      _passwordError = false;
      _showPasswordDialog = true;
    });
  }

  void _submitPassword() {
    final input = _passwordController.text;
    if (!DevMode.checkPassword(input)) {
      setState(() => _passwordError = true);
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
    final body = SingleChildScrollView(
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
            const SectionHeader(title: '应用信息', icon: Icons.info_outline_rounded),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
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
                  _infoTile('构建加固', 'R8 · UPX · Dart 混淆'),
                  MiuixHorizontalDivider(
                      thickness: 1, color: AppColors.strokeGlass),
                  _infoTile('作者', '白姬9527'),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // 社区与支持（v2.3.1）：GitHub 项目主页 / QQ 群 / 捐赠
            const SectionHeader(
                title: '社区与支持', icon: Icons.volunteer_activism_rounded),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  MiuixArrowPreference(
                    title: 'GitHub 项目主页',
                    summary: kGitHubUrl,
                    startAction: Icon(Icons.code_rounded,
                        color: AppColors.accent, size: 22),
                    onClick: () => _launchExternal(kGitHubUrl),
                  ),
                  MiuixHorizontalDivider(
                      thickness: 1, color: AppColors.strokeGlass),
                  MiuixArrowPreference(
                    title: 'QQ 交流群',
                    summary: '群号 $kQqGroupId · 点击唤起 QQ 加群',
                    startAction: Icon(Icons.groups_rounded,
                        color: AppColors.accentAlt, size: 22),
                    onClick: () => _launchExternal(kQqGroupUrl),
                  ),
                  MiuixHorizontalDivider(
                      thickness: 1, color: AppColors.strokeGlass),
                  MiuixArrowPreference(
                    title: '请作者喝一杯',
                    summary: '扫描收款码捐赠 · 全部自愿',
                    startAction: Icon(Icons.redeem_rounded,
                        color: AppColors.warning, size: 22),
                    onClick: () => setState(() => _showDonateDialog = true),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // 法律信息（从设置页移来：与「关于」语义一致，设置页不再重复）
            const SectionHeader(
                title: '法律信息', icon: Icons.gavel_rounded),
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
      );
  // 开发者模式密码弹层（声明式，挂 bottomBar 槽位由 root popup host 渲染）
  return PageScaffold(
    title: '关于',
    snackbarHost: appSnackbarHostState,
    contentPadding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
    bottomBar: Stack(children: [
      _buildPasswordDialog(),
      _buildDonateDialog(),
    ]),
    child: body,
  );
  }

  /// 捐赠码弹层：支付宝收款码 + 微信赞赏码并排，长按无动作（截图保存）。
  Widget _buildDonateDialog() {
    return MiuixOverlayDialog(
      show: _showDonateDialog,
      title: '请作者喝一杯',
      summary: '开发与维护不易，扫码支持一下（完全自愿）',
      backgroundColor: AppColors.bg2,
      onDismissRequest: () => setState(() => _showDonateDialog = false),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset('assets/donate/alipay.jpg',
                          width: 150, fit: BoxFit.cover),
                    ),
                    const SizedBox(height: 6),
                    Text('支付宝',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset('assets/donate/reward.png',
                          width: 150, fit: BoxFit.cover),
                    ),
                    const SizedBox(height: 6),
                    Text('微信赞赏',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          MiuixTextButton('关闭', onPressed: () {
            setState(() => _showDonateDialog = false);
          }),
        ],
      ),
    );
  }

  // 开发者模式密码弹层（声明式，挂 bottomBar 槽位由 root popup host 渲染）。
  Widget _buildPasswordDialog() {
    return MiuixOverlayDialog(
        show: _showPasswordDialog,
        title: '开启开发者模式',
        summary: '请输入开发者密码',
        backgroundColor: AppColors.bg2,
        onDismissRequest: () => setState(() => _showPasswordDialog = false),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 密码输入：统一用 AppTextField（玻璃底 + 浮动标签 + 强调色光标）。
            // 它内部已处理弹窗挂在 popup host 上缺少 MaterialLocalizations
            // 的问题（v2.2.9 前这里是手绘 TextField + Localizations.override
            // + 定高 52 的兜底，根因是缺本地化被 RenderErrorBox 撑爆）。
            AppTextField(
              controller: _passwordController,
              autofocus: true,
              label: '密码',
              useLabelAsPlaceholder: true,
              obscureText: _obscurePassword,
              error: _passwordError,
              textStyle: TextStyle(
                  fontSize: 15, letterSpacing: 2, color: AppColors.textPrimary),
              leadingIcon: Icon(Icons.lock_outline_rounded,
                  size: 18, color: AppColors.textTertiary),
              trailingIcon: MiuixIconButton(
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                child: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                  color: AppColors.textTertiary,
                ),
              ),
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
    );
  }

  /// 应用信息行。value 列必须可收缩：长值（平台列表 / 构建链）会把
  /// Row 撑爆——v2.2.6 真机日志里的 RenderFlex overflow 就是这里。
  Widget _infoTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
