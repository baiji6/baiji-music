// 通用「信息弹窗」（v2.4.0-fix1）
//
// 用于「设备 GUID」这类需要**完整展示 + 一键复制**的场景。
// 之前只用 snackbar 弹一行，GUID 太长在手机上根本看不全、也复制不了。
//
// Miuix 的对话框是声明式组件（靠 State 布尔字段驱动显隐），这里沿用
// agreement_dialog.dart 的做法：用一层 Overlay 条目做命令式包装，
// 条目内部自建 `MiuixPopupScope + MiuixOverlayDialog + MiuixPopupHost`
// 根域，不依赖宿主页面是否已是 Miuix 脚手架。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../theme/app_theme.dart';
import 'app_snackbar.dart';

/// 弹出一个只读信息弹窗。
///
/// - [title] 标题
/// - [lines] 正文行（每行一段，会自动等宽字体展示）
/// - [copyText] 复制按钮复制的文本；为空则不显示复制按钮
Future<void> showAppInfoDialog(
  BuildContext context, {
  required String title,
  required List<String> lines,
  String? copyText,
  String? summary,
}) {
  final overlay =
      Navigator.maybeOf(context, rootNavigator: true)?.overlay ??
          Navigator.maybeOf(context)?.overlay;
  if (overlay == null) {
    showAppSnack(lines.isEmpty ? '' : lines.join('\n'));
    return Future.value();
  }

  final completer = Completer<void>();
  late final OverlayEntry entry;
  var settled = false;
  void finish() {
    if (settled) return;
    settled = true;
    entry.remove();
    completer.complete();
  }

  entry = OverlayEntry(
    builder: (_) => _InfoPopup(
      title: title,
      summary: summary,
      lines: lines,
      copyText: copyText,
      onClosed: finish,
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

/// 信息弹窗本体。
class _InfoPopup extends StatefulWidget {
  const _InfoPopup({
    required this.title,
    required this.summary,
    required this.lines,
    required this.copyText,
    required this.onClosed,
  });

  final String title;
  final String? summary;
  final List<String> lines;
  final String? copyText;
  final VoidCallback onClosed;

  @override
  State<_InfoPopup> createState() => _InfoPopupState();
}

class _InfoPopupState extends State<_InfoPopup> {
  bool _show = true;

  void _close() => setState(() => _show = false);

  Future<void> _copy() async {
    final text = widget.copyText;
    if (text == null || text.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      showAppSnack('已复制到剪贴板');
    } catch (e) {
      showAppSnack('复制失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MiuixTheme(
      data: AppTheme.miuix(
        brightness: AppColors.isDark ? Brightness.dark : Brightness.light,
      ),
      child: MiuixPopupScope(
        establishRoot: true,
        child: Stack(
          children: [
            MiuixOverlayDialog(
              show: _show,
              title: widget.title,
              backgroundColor: AppColors.bg2,
              maxWidth: 460,
              onDismissRequest: _close,
              onDismissFinished: widget.onClosed,
              content: _buildContent(),
            ),
            const MiuixPopupHost(),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.summary != null) ...[
          MiuixText(
            widget.summary!,
            color: AppColors.textTertiary,
            fontSize: 12,
            height: 1.5,
          ),
          const SizedBox(height: 12),
        ],
        // GUID 很长，用可横向滚动的容器 + 等宽字体，避免被截断。
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: SelectableText(
              widget.lines.join('\n'),
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: AppColors.textSecondary,
                fontFamily: 'monospace',
                fontFamilyFallback: const [
                  'Menlo',
                  'Consolas',
                  'Courier New',
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (widget.copyText != null && widget.copyText!.isNotEmpty) ...[
              MiuixTextButton(
                '复制',
                onPressed: _copy,
                textStyle: TextStyle(
                  color: AppColors.violet,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
            ],
            MiuixTextButton(
              '关闭',
              onPressed: _close,
              textStyle: TextStyle(color: AppColors.textTertiary),
            ),
          ],
        ),
      ],
    );
  }
}
