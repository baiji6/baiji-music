import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/ui_settings.dart';
import '../../theme/app_theme.dart';

/// 更新日志的 Markdown 排版：字号压到 12~13，整体偏灰，和 App 暗色玻璃
/// 主题一致。设置页更新日志与 main.dart 全局更新弹窗共用这一份，
/// 保证两处视觉统一。
MarkdownStyleSheet get changelogSheet => MarkdownStyleSheet(
      p: TextStyle(
          fontSize: 12.5, height: 1.5, color: AppColors.textSecondary),
      listBullet: TextStyle(color: AppColors.textTertiary),
      h1: TextStyle(
          fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
      h2: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary),
      h3: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary),
      h4: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary),
      h5: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary),
      h6: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary),
      code: TextStyle(
          fontSize: 12,
          color: AppColors.accent,
          backgroundColor: AppColors.surfaceGlass),
      codeblockDecoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.strokeGlass),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: AppColors.accent.withValues(alpha: 0.7), width: 3),
        ),
      ),
      blockquotePadding: const EdgeInsets.only(left: 12),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.strokeGlass)),
      ),
      a: TextStyle(
          color: AppColors.accent, decoration: TextDecoration.underline),
      tableBorder: TableBorder.all(color: AppColors.strokeGlass),
      tableHead: const TextStyle(fontWeight: FontWeight.w600),
      tableBody: const TextStyle(fontSize: 12),
    );

/// 玻璃拟态卡片：半透明填充 + 细描边 + 辉光投影。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.margin,
    this.radius,
    this.glowColor,
    this.onTap,
    this.width,
    this.height,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  /// 卡片圆角。null = 跟随全局「界面圆角」设置（UiSettings）。
  final double? radius;
  final Color? glowColor;
  final VoidCallback? onTap;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final r = radius ?? UiSettings.instance.cornerRadius;
    BoxDecoration decoration() => BoxDecoration(
          color: AppColors.surfaceGlass,
          borderRadius: BorderRadius.circular(r),
          border: Border.all(color: AppColors.strokeGlass),
          boxShadow: glowColor != null
              ? [
                  BoxShadow(
                    color: glowColor!.withValues(alpha: 0.22),
                    blurRadius: 28,
                    offset: const Offset(0, 8),
                  ),
                ]
              : [
                  // 暗色主题下是淡黑影；浅色主题换成极淡的蓝灰投影——
                  // 白纸上纯黑影太脏，柔蓝才配玻璃卡。
                  BoxShadow(
                    color: AppColors.cardShadow,
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
        );

    final body = Container(
      width: width,
      height: height,
      margin: margin,
      padding: padding,
      decoration: decoration(),
      // ListTile 会把自己的水波纹画在「最近的 Material 祖先」上。这里如果
      // 少了一层 Material，DecoratedBox 的背景色就会把点击反馈整个盖住
      // （debug 下 Flutter 会直接断言报错）。透明 Material 不改变外观，
      // 但能把 ink 效果还原回来——列表页统一受益。
      child: Material(
        color: Colors.transparent,
        elevation: 0,
        child: child,
      ),
    );

    if (onTap == null) return body;
    // 按压反馈走 MiuixPressable（下沉 + 回弹），不再用 GestureDetector 裸接。
    return MiuixPressable(
      onPressed: onTap,
      borderRadius: BorderRadius.circular(r),
      child: body,
    );
  }
}

/// 霓虹渐变按钮。
class NeonButton extends StatelessWidget {
  const NeonButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.gradient = AppColors.accentGradient,
    this.filled = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
    this.radius = 16,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final List<Color> gradient;
  final bool filled;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final labelStyle = TextStyle(
      color: filled ? Colors.white : AppColors.textPrimary,
      fontSize: 14,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
    );

    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 17, color: filled ? Colors.white : AppColors.accent),
          const SizedBox(width: 8),
        ],
        Text(label, style: labelStyle),
      ],
    );

    // 品牌霓虹按钮：渐变底 / 玻璃描边底，按压反馈走 MiuixPressable
    // （Miuix 的下沉 + 回弹动效），不再依赖 Material 的 InkWell。
    final decoration = BoxDecoration(
      gradient: LinearGradient(
        colors: filled
            ? (enabled ? gradient : [AppColors.bg2, AppColors.bg2])
            : [AppColors.surfaceGlass, AppColors.surfaceGlass],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ),
      borderRadius: BorderRadius.circular(radius),
      border: filled ? null : Border.all(color: AppColors.strokeGlass),
      boxShadow: filled && enabled
          ? [
              BoxShadow(
                color: gradient.first.withValues(alpha: 0.45),
                blurRadius: 22,
                offset: const Offset(0, 6),
              ),
            ]
          : null,
    );

    return MiuixPressable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(radius),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: enabled ? 1 : 0.55,
        child: DecoratedBox(
          decoration: decoration,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 圆形霓虹图标按钮。
class NeonIconButton extends StatelessWidget {
  const NeonIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.gradient = AppColors.accentGradient,
    this.size = 46,
    this.iconSize = 20,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final List<Color> gradient;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    // 圆形霓虹图标按钮：按压反馈走 MiuixPressable
    return MiuixPressable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(size / 2),
      child: Container(
        width: size,
        height: size,
        decoration: ShapeDecoration(
          shape: const CircleBorder(),
          gradient: LinearGradient(
            colors: gradient,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          shadows: [
            BoxShadow(
              color: gradient.first.withValues(alpha: 0.4),
              blurRadius: 18,
            ),
          ],
        ),
        child: Icon(icon, size: iconSize, color: Colors.white),
      ),
    );
  }
}

/// 分区标题。
///
/// v2.2.6 起支持 [icon]：给每个分区一个彩色图标锚点，设置页 / 工具箱页
/// 分区多的时候靠图标快速定位，减轻"一屏八张卡"的割裂感。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.subtitle,
    this.icon,
    this.iconColor,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final IconData? icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: iconColor ?? AppColors.accent),
            const SizedBox(width: 8),
          ],
          Container(
            width: 4,
            height: 18,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: AppColors.neonGradient,
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (subtitle != null) ...[
            const SizedBox(width: 10),
            Text(
              subtitle!,
              style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
            ),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// 子页面统一骨架：星云背景 + Miuix 大标题顶栏 + 正确的内容缩进。
///
/// v2.2.8 之前每个子页面各写一遍 `MiuixScaffold`，两个共性缺陷：
///
/// 1. **不画背景**：`containerColor: Colors.transparent` 且内容里没有
///    [NebulaBackground]，整页直接透出设备窗口底色——Android 深色模式下
///    窗口是纯黑（values-night NormalTheme），于是出现「主界面白的、
///    设置/关于/工具箱/日志全黑」的割裂观感（玻璃卡是 65% 白叠黑底，
///    变成一格格灰方块）。这里统一补上和主界面同款的星云底。
/// 2. **顶栏压内容**：内容构建器全部忽略脚手架回传的 [padding]，
///    硬编码 `top: 8`，大标题与首张卡片重叠、首行点不到。这里统一把
///    `padding.top / padding.bottom` 应用上。
///
/// 用法：把原来 `MiuixScaffold` 的 `topBar` / `content` 换成本组件，
/// [child] 传滚动体（ListView / SingleChildScrollView），左右下边距用
/// [contentPadding] 控制，顶/底边距由脚手架回传值自动叠加。
///
/// 全出血页面（播放页）传 [showTopBar] = false：不画顶栏、不套内容
/// Padding，窗口 inset 由页面自绘的 SafeArea 管理。
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    this.title,
    required this.child,
    this.onBack,
    this.actions,
    this.snackbarHost,
    this.bottomBar,
    this.floatingActionButton,
    this.contentPadding = const EdgeInsets.fromLTRB(20, 4, 20, 24),
    this.largeTitle = true,
    this.showTopBar = true,
  });

  /// 页面标题；[showTopBar] 为 false 时忽略（全出血页面自绘顶栏）。
  final String? title;

  /// 页面滚动体（ListView / SingleChildScrollView / Column）。
  final Widget child;

  /// 返回回调；null = 默认 Navigator.pop。
  final VoidCallback? onBack;

  /// 顶栏右侧动作（MiuixIconButton 等）。
  final List<Widget>? actions;

  final MiuixSnackbarHostState? snackbarHost;
  final Widget? bottomBar;
  final Widget? floatingActionButton;

  /// 内容左右 / 上下（顶栏下方）边距；顶栏与系统底栏的高度由脚手架自动叠加。
  final EdgeInsets contentPadding;

  final bool largeTitle;

  /// 是否显示统一顶栏；false 用于播放页等自绘顶栏的全出血页面。
  final bool showTopBar;

  @override
  Widget build(BuildContext context) {
    return MiuixScaffold(
      containerColor: Colors.transparent,
      snackbarHost: snackbarHost != null
          ? MiuixSnackbarHost(state: snackbarHost!)
          : null,
      bottomBar: bottomBar,
      floatingActionButton: floatingActionButton,
      topBar: showTopBar
          ? MiuixTopAppBar(
              title: title ?? '',
              titleColor: AppColors.skyBlue,
              color: Colors.transparent,
              largeTitle: largeTitle ? null : '',
              navigationIcon: MiuixIconButton(
                onPressed: onBack ?? () => Navigator.of(context).pop(),
                child: Icon(Icons.arrow_back_rounded,
                    color: AppColors.textPrimary, size: 22),
              ),
              actions: actions,
            )
          : null,
      content: showTopBar
          ? (padding) => NebulaBackground(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  contentPadding.left,
                  padding.top + contentPadding.top,
                  contentPadding.right,
                  padding.bottom + contentPadding.bottom,
                ),
                child: child,
              ),
            )
          : (_) => NebulaBackground(child: child),
    );
  }
}

/// 全 App 统一输入框。
///
/// v2.2.8 之前各页面输入框风格五花八门：搜索页/本地音乐是裸
/// [MiuixTextField]（默认底色与主题不搭），关于页密码框是手搓的
/// `Container + TextField`，密钥页 6 处又各写一遍。这里收口成一个组件：
/// 玻璃底 + 主题描边 + 统一文字/光标/标签色，保留 Miuix 浮动标签交互。
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.label = '',
    this.useLabelAsPlaceholder = false,
    this.enabled = true,
    this.readOnly = false,
    this.textStyle,
    this.leadingIcon,
    this.trailingIcon,
    this.singleLine = false,
    this.maxLines,
    this.minLines,
    this.keyboardType,
    this.textInputAction,
    this.obscureText = false,
    this.autofocus = false,
    this.textCapitalization = TextCapitalization.none,
    this.cornerRadius = 14,
    this.insideMargin =
        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// 浮动标签文案（[useLabelAsPlaceholder] = true 时兼作占位符）。
  final String label;
  final bool useLabelAsPlaceholder;
  final bool enabled;
  final bool readOnly;
  final TextStyle? textStyle;
  final Widget? leadingIcon;
  final Widget? trailingIcon;
  final bool singleLine;
  final int? maxLines;
  final int? minLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool obscureText;
  final bool autofocus;
  final TextCapitalization textCapitalization;
  final double cornerRadius;
  final EdgeInsets insideMargin;

  @override
  Widget build(BuildContext context) {
    return MiuixTextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      label: label,
      useLabelAsPlaceholder: useLabelAsPlaceholder,
      enabled: enabled,
      readOnly: readOnly,
      singleLine: singleLine,
      maxLines: maxLines,
      minLines: minLines,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      obscureText: obscureText,
      autofocus: autofocus,
      textCapitalization: textCapitalization,
      cornerRadius: cornerRadius,
      insideMargin: insideMargin,
      leadingIcon: leadingIcon,
      trailingIcon: trailingIcon,
      cursorColor: AppColors.accent,
      textStyle: textStyle ??
          TextStyle(fontSize: 13.5, color: AppColors.textPrimary),
      colors: MiuixTextFieldColors(
        backgroundColor: AppColors.surfaceGlass,
        labelColor: AppColors.textTertiary,
        borderColor: AppColors.strokeGlass,
      ),
    );
  }
}

/// 幽灵徽章（来源标签：QQ / 网易云 / 无损 等）。
class TagBadge extends StatelessWidget {
  const TagBadge(this.text, {super.key, this.color = AppColors.cyan, this.opacity = 0.16});

  final String text;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 空态视图。
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                AppColors.violet.withValues(alpha: 0.28),
                Colors.transparent,
              ]),
            ),
            child: Icon(icon, size: 42, color: AppColors.textTertiary),
          ),
          const SizedBox(height: 18),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 22),
            action!,
          ],
        ],
      ),
    );
  }
}

/// 加载占位（骨架屏）。
class GlassSkeleton extends StatelessWidget {
  const GlassSkeleton({super.key, this.width, this.height = 14, this.radius = 8});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 渐变占位封面（无封面图时的霓虹底纹）。
class GradientCover extends StatelessWidget {
  const GradientCover({
    super.key,
    required this.size,
    this.icon = Icons.music_note_outlined,
    this.gradient = AppColors.accentGradient,
  });

  final double size;
  final IconData icon;
  final List<Color> gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.18),
        gradient: LinearGradient(
          colors: gradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(icon, size: size * 0.42, color: Colors.white.withValues(alpha: 0.85)),
    );
  }
}

/// 圆角裁剪图片（带玻璃边框）。
class FrostedImage extends StatelessWidget {
  const FrostedImage({
    super.key,
    required this.url,
    required this.size,
    this.radius = 14,
    this.fit = BoxFit.cover,
  });

  final String url;
  final double size;
  final double radius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: url.isEmpty
            ? const GradientCover(size: 0) // 不会被使用，size 由父级决定
            : Image.network(
                url,
                fit: fit,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return const Center(
                    child: MiuixCircularProgressIndicator(
                        size: 20, strokeWidth: 2),
                  );
                },
              ),
      ),
    );
  }
}