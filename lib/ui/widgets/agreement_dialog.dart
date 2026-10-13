import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/agreement_store.dart';
import '../../core/agreement_text.dart';
import '../../theme/app_theme.dart';
import 'app_widgets.dart';

/// 首次启动的「免责声明 + 使用协议」确认弹窗。
///
/// 行为：
/// - 必须勾选同意后才能点击「同意并继续」；
/// - 勾选状态按 Tab 分别记录，两份都必须确认过；
/// - 点「不同意并退出」会二次确认，确认后退出应用（Android 走系统返回，桌面端直接退出）；
/// - [barrierDismissible] 为 false（首次启动）时，返回键 / 误触关闭都会让弹窗重新弹出，
///   直到用户明确做出选择为止（对应旧版 Material Dialog 的不可关闭语义）。
///
/// 返回 true 表示用户已同意。
///
/// Miuix 的对话框是声明式组件（靠 State 布尔字段驱动显隐），这里用一层
/// Overlay 条目做命令式包装：条目内部自建 `MiuixPopupScope + MiuixOverlayDialog
/// + MiuixPopupHost` 根域，不依赖宿主页面是否已是 Miuix 脚手架。
Future<bool> showAgreementDialog(
  BuildContext context, {
  bool barrierDismissible = false,
}) async {
  final ok = await _showAgreementPopup(
    context,
    readOnly: false,
    dismissible: barrierDismissible,
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
  return _showAgreementPopup(
    context,
    readOnly: true,
    dismissible: true,
    initial: initial,
  );
}

enum AgreementTab { disclaimer, terms }

/// 以 Overlay 条目挂载 [_AgreementPopup]，等弹窗生命周期结束后再交付结果。
Future<bool?> _showAgreementPopup(
  BuildContext context, {
  required bool readOnly,
  required bool dismissible,
  AgreementTab initial = AgreementTab.disclaimer,
}) {
  final overlay =
      Navigator.maybeOf(context, rootNavigator: true)?.overlay ??
      Navigator.maybeOf(context)?.overlay;
  if (overlay == null) return Future.value(null);

  final completer = Completer<bool?>();
  late final OverlayEntry entry;
  var settled = false;
  void finish(bool? result) {
    if (settled) return;
    settled = true;
    entry.remove();
    completer.complete(result);
  }

  entry = OverlayEntry(
    builder: (_) => _AgreementPopup(
      readOnly: readOnly,
      dismissible: dismissible,
      initial: initial,
      onResult: finish,
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

/// 协议弹窗本体：Miuix 声明式对话框 + 退出二次确认。
class _AgreementPopup extends StatefulWidget {
  const _AgreementPopup({
    required this.readOnly,
    required this.dismissible,
    required this.initial,
    required this.onResult,
  });

  final bool readOnly;
  final bool dismissible;
  final AgreementTab initial;
  final ValueChanged<bool?> onResult;

  @override
  State<_AgreementPopup> createState() => _AgreementPopupState();
}

class _AgreementPopupState extends State<_AgreementPopup>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final Set<AgreementTab> _agreed = <AgreementTab>{};

  // 主弹窗显隐；二次确认弹窗显隐。
  bool _showMain = true;
  bool _showConfirm = false;

  /// 用户已做出的最终选择（true = 同意并继续）。null 表示尚未选择。
  bool? _result;

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

  /// 关闭主弹窗（带动画），退出动画结束后由 [_onDismissFinished] 交付结果。
  void _close(bool? result) {
    _result = result;
    setState(() => _showMain = false);
  }

  void _onDismissFinished() {
    // 只读模式或可关闭模式：关闭即交付。
    if (widget.readOnly || widget.dismissible || _result != null) {
      widget.onResult(_result);
      return;
    }
    // 首次启动（不可关闭）：返回键 / 其它路径的关闭一律无效，重新弹出，
    // 直到用户明确勾选同意或走「不同意并退出」为止。
    setState(() => _showMain = true);
  }

  Future<void> _exitApp() async {
    if (Platform.isAndroid) {
      await SystemChannels.platform.invokeMethod('SystemNavigator.pop');
    } else {
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 自给自足的 Miuix 弹窗根域：即便宿主只是普通 MaterialApp（如单测），
    // 对话框也有完整的 Miuix 主题与注册表可用。
    // 明暗跟随当前全局令牌（AppColors.isDark 由根组件维护）。
    return MiuixTheme(
      data: AppTheme.miuix(
        brightness: AppColors.isDark ? Brightness.dark : Brightness.light,
      ),
      child: MiuixPopupScope(
        establishRoot: true,
        child: Stack(
          children: [
            MiuixOverlayDialog(
              show: _showMain,
              backgroundColor: AppColors.bg2,
              maxWidth: 560,
              onDismissFinished: _onDismissFinished,
              content: _buildMainContent(),
            ),
            MiuixOverlayDialog(
              show: _showConfirm,
              title: '退出确认',
              backgroundColor: AppColors.bg2,
              maxWidth: 420,
              onDismissRequest: () => setState(() => _showConfirm = false),
              content: _buildConfirmContent(),
            ),
            const MiuixPopupHost(),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    final screenH = MediaQuery.sizeOf(context).height;
    final paneH = (screenH * 0.42).clamp(200.0, 420.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
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
        MiuixText(
          widget.readOnly
              ? '以下为协议全文，仅供查阅。'
              : '首次使用请阅读并同意以下文件后继续使用。',
          color: AppColors.textTertiary,
          fontSize: 12,
          height: 1.5,
        ),
        const SizedBox(height: 14),
        MiuixTabRow(
          tabs: const ['免责声明', '使用协议'],
          selectedTabIndex: _tab.index,
          onTabSelected: (i) => setState(() => _tab.index = i),
          colors: MiuixTabRowColors(
            backgroundColor: AppColors.bg1,
            contentColor: AppColors.textTertiary,
            selectedBackgroundColor: AppColors.violet,
            selectedContentColor: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: paneH,
          child: TabBarView(
            controller: _tab,
            children: [
              _DocPane(
                text: AgreementText.disclaimer,
                label: '免责声明',
                agreed: _agreed.contains(AgreementTab.disclaimer),
                readOnly: widget.readOnly,
                onChanged: (v) => _toggle(AgreementTab.disclaimer, v),
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
        if (!widget.readOnly) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: NeonButton(
                  label: '不同意并退出',
                  filled: false,
                  onPressed: () => setState(() => _showConfirm = true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: NeonButton(
                  label: '同意并继续',
                  icon: Icons.check_rounded,
                  gradient: AppColors.playGradient,
                  onPressed: _allAgreed ? () => _close(true) : null,
                ),
              ),
            ],
          ),
        ] else ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: NeonButton(
              label: '关闭',
              filled: false,
              onPressed: () => _close(null),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildConfirmContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MiuixText(
          '不同意《免责声明》与《使用协议》将无法继续使用本软件。'
          '确定要退出吗？',
          color: AppColors.textSecondary,
          fontSize: 13,
          height: 1.5,
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            MiuixTextButton(
              '返回',
              onPressed: () => setState(() => _showConfirm = false),
              textStyle: TextStyle(color: AppColors.textTertiary),
            ),
            const SizedBox(width: 8),
            MiuixTextButton(
              '退出',
              onPressed: _exitApp,
              textStyle: TextStyle(
                color: AppColors.danger,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
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
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.75,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
        if (!widget.readOnly)
          MiuixCheckboxPreference(
            title: '我已完整阅读并同意《${widget.label}》',
            value: widget.agreed,
            onChanged: widget.onChanged,
            insideMargin: const EdgeInsets.symmetric(horizontal: 10),
          ),
      ],
    );
  }
}
