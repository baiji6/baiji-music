import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/agreement_store.dart';
import '../../core/agreement_text.dart';
import '../../theme/app_theme.dart';
import 'app_widgets.dart';

/// 首次启动的「免责声明 + 使用协议」确认弹窗。
///
/// 行为：
/// - 必须勾选同意后才能点击「同意并继续」；
/// - 勾选状态按 Tab 分别记录，两份都必须确认过；
/// - 点「不同意并退出」会二次确认，确认后退出应用（Android 走系统返回，桌面端直接退出）。
///
/// 返回 true 表示用户已同意。
Future<bool> showAgreementDialog(
  BuildContext context, {
  bool barrierDismissible = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => _AgreementDialog(dismissible: barrierDismissible),
  );
  if (ok == true) {
    await AgreementStore.accept();
    return true;
  }
  return false;
}

/// 只展示、不要求确认地打开协议全文（设置页入口用）。
Future<void> showAgreementReader(
  BuildContext context, {
  AgreementTab initial = AgreementTab.disclaimer,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _AgreementDialog(
      dismissible: true,
      readOnly: true,
      initial: initial,
    ),
  );
}

enum AgreementTab { disclaimer, terms }

class _AgreementDialog extends StatefulWidget {
  const _AgreementDialog({
    required this.dismissible,
    this.readOnly = false,
    this.initial = AgreementTab.disclaimer,
  });

  final bool dismissible;
  final bool readOnly;
  final AgreementTab initial;

  @override
  State<_AgreementDialog> createState() => _AgreementDialogState();
}

class _AgreementDialogState extends State<_AgreementDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  final Set<AgreementTab> _agreed = <AgreementTab>{};

  @override
  void initState() {
    super.initState();
    _tab = TabController(
      length: AgreementTab.values.length,
      vsync: this,
      initialIndex: widget.initial.index,
    );
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  bool get _allAgreed => _agreed.length == AgreementTab.values.length;

  void _toggle(AgreementTab t, bool v) {
    setState(() {
      if (v) {
        _agreed.add(t);
      } else {
        _agreed.remove(t);
      }
    });
  }

  Future<void> _decline() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: const Text('退出确认', style: TextStyle(fontSize: 16)),
        content: const Text(
          '不同意《免责声明》与《使用协议》将无法继续使用本软件。'
          '确定要退出吗？',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('返回',
                style: TextStyle(color: AppColors.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    if (Platform.isAndroid) {
      await SystemChannels.platform.invokeMethod('SystemNavigator.pop');
    } else {
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // 桌面宽屏给它一个舒服的阅读宽度，移动端则接近满屏。
    final maxW = size.width > 720 ? 640.0 : size.width - 32;
    final maxH = size.height * 0.86;

    return Dialog(
      backgroundColor: AppColors.bg2,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const NeonText(
                    '白姬音乐',
                    style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.readOnly
                        ? '以下为协议全文，仅供查阅。'
                        : '首次使用请阅读并同意以下文件后继续使用。',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TabBar(
              controller: _tab,
              labelColor: AppColors.cyan,
              unselectedLabelColor: AppColors.textTertiary,
              indicatorColor: AppColors.cyan,
              labelStyle: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700),
              tabs: const [
                Tab(text: '免责声明'),
                Tab(text: '使用协议'),
              ],
            ),
            const Divider(height: 1, color: AppColors.strokeGlass),
            Expanded(
              child: TabBarView(
                controller: _tab,
                children: [
                  _DocPane(
                    text: AgreementText.disclaimer,
                    label: '免责声明',
                    agreed: _agreed.contains(AgreementTab.disclaimer),
                    readOnly: widget.readOnly,
                    onChanged: (v) =>
                        _toggle(AgreementTab.disclaimer, v),
                  ),
                  _DocPane(
                    text: AgreementText.terms,
                    label: '使用协议',
                    agreed: _agreed.contains(AgreementTab.terms),
                    readOnly: widget.readOnly,
                    onChanged: (v) => _toggle(AgreementTab.terms, v),
                  ),
                ],
              ),
            ),
            if (!widget.readOnly)
              const Divider(height: 1, color: AppColors.strokeGlass),
            if (!widget.readOnly)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: NeonButton(
                        label: '不同意并退出',
                        filled: false,
                        onPressed: _decline,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: NeonButton(
                        label: '同意并继续',
                        icon: Icons.check_rounded,
                        gradient: AppColors.playGradient,
                        onPressed: _allAgreed
                            ? () => Navigator.pop(context, true)
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            if (widget.readOnly)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: NeonButton(
                    label: '关闭',
                    filled: false,
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 单份协议的正文面板：可滚动阅读 + 阅读完成勾选。
class _DocPane extends StatefulWidget {
  const _DocPane({
    required this.text,
    required this.label,
    required this.agreed,
    required this.readOnly,
    required this.onChanged,
  });

  final String text;
  final String label;
  final bool agreed;
  final bool readOnly;
  final ValueChanged<bool> onChanged;

  @override
  State<_DocPane> createState() => _DocPaneState();
}

class _DocPaneState extends State<_DocPane> {
  /// 每页一个独立控制器。
  ///
  /// 若不给，竖屏下两个 Tab 的 ScrollView 会同时挂到 [PrimaryScrollController]，
  /// 而 `thumbVisibility: true` 要求滚动条只对应**唯一**一个 ScrollPosition，
  /// 否则运行时会抛 "is attached to more than one ScrollPosition"。
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _scroll,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 8),
              child: Text(
                widget.text.trim(),
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.75,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
        if (!widget.readOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 12, 6),
            child: CheckboxListTile(
              value: widget.agreed,
              onChanged: (v) => widget.onChanged(v ?? false),
              activeColor: AppColors.cyan,
              checkColor: AppColors.bg0,
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                '我已完整阅读并同意《${widget.label}》',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
