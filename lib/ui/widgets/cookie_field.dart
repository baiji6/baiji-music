library;

/// Cookie 登录输入区（QQ / 网易云登录页共用，v2.3.0-fix1 美化）。
///
/// 相比裸 [AppTextField] 的改进：
/// - 更大的输入区（5 行起步，长 Cookie 可在框内滚动）；
/// - 一键「粘贴」——粘贴长文本是 Cookie 登录的最大痛点；
/// - 一键「清空」+ 实时字符计数（贴没贴上、贴了多少一目了然）；
/// - 粘贴板为空 / 无权限时给出明确提示而不是默默不动。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../theme/app_theme.dart';
import 'app_snackbar.dart';
import 'app_widgets.dart';

class CookieField extends StatefulWidget {
  const CookieField({
    super.key,
    required this.controller,
    required this.hint,
    this.minLines = 5,
    this.maxLines = 8,
  });

  final TextEditingController controller;

  /// 占位提示（平台各自的 Cookie 形态示例）。
  final String hint;
  final int minLines;
  final int maxLines;

  @override
  State<CookieField> createState() => _CookieFieldState();
}

class _CookieFieldState extends State<CookieField> {
  bool _pasteBusy = false;

  Future<void> _paste() async {
    if (_pasteBusy) return;
    setState(() => _pasteBusy = true);
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (!mounted) return;
      if (text.isEmpty) {
        showAppSnack('剪贴板是空的——先去浏览器复制 Cookie');
        return;
      }
      widget.controller.text = text;
      widget.controller.selection = TextSelection.collapsed(
          offset: widget.controller.text.length);
      showAppSnack('已粘贴 ${text.length} 个字符');
    } catch (e) {
      if (!mounted) return;
      showAppSnack('读取剪贴板失败: $e');
    } finally {
      if (mounted) setState(() => _pasteBusy = false);
    }
  }

  void _clear() {
    widget.controller.clear();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 工具行：计数 + 粘贴 / 清空
        Row(
          children: [
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (ctx, v, _) => Text(
                v.text.isEmpty ? '未粘贴' : '${v.text.length} 字符',
                style: TextStyle(
                  fontSize: 11,
                  color: v.text.isEmpty
                      ? AppColors.textTertiary
                      : AppColors.accent,
                ),
              ),
            ),
            const Spacer(),
            _MiniAction(
              icon: Icons.content_paste_rounded,
              label: '粘贴',
              busy: _pasteBusy,
              onTap: _paste,
            ),
            const SizedBox(width: 4),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (ctx, v, _) => _MiniAction(
                icon: Icons.close_rounded,
                label: '清空',
                onTap: v.text.isEmpty ? null : _clear,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        AppTextField(
          controller: widget.controller,
          label: widget.hint,
          useLabelAsPlaceholder: true,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          textStyle: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: AppColors.textPrimary),
          leadingIcon: Icon(
            Icons.cookie_outlined,
            size: 18,
            color: AppColors.textTertiary,
          ),
        ),
      ],
    );
  }
}

/// 工具行的小按钮（粘贴 / 清空）。
class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    return MiuixPressable(
      onPressed: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            busy
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: MiuixCircularProgressIndicator(
                        strokeWidth: 1.6, size: 12),
                  )
                : Icon(icon,
                    size: 14,
                    color: enabled
                        ? AppColors.accent
                        : AppColors.textTertiary),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: enabled ? AppColors.accent : AppColors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
