import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// 玻璃拟态卡片：半透明填充 + 细描边 + 辉光投影。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.margin,
    this.radius = 22,
    this.glowColor,
    this.onTap,
    this.width,
    this.height,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final Color? glowColor;
  final VoidCallback? onTap;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    BoxDecoration decoration() => BoxDecoration(
          color: AppColors.surfaceGlass,
          borderRadius: BorderRadius.circular(radius),
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
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
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
    return GestureDetector(
      onTap: onTap,
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
          Icon(icon, size: 17, color: filled ? Colors.white : AppColors.cyan),
          const SizedBox(width: 8),
        ],
        Text(label, style: labelStyle),
      ],
    );

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: filled
          ? BorderSide.none
          : const BorderSide(color: AppColors.strokeGlass),
    );

    if (!filled) {
      return OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: padding,
          shape: shape,
          backgroundColor: AppColors.surfaceGlass,
          side: const BorderSide(color: AppColors.strokeGlass),
        ),
        child: child,
      );
    }

    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: ShapeDecoration(
          gradient: LinearGradient(
            colors: enabled ? gradient : [AppColors.bg2, AppColors.bg2],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          shape: shape,
          shadows: enabled
              ? [
                  BoxShadow(
                    color: gradient.first.withValues(alpha: 0.45),
                    blurRadius: 22,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: BorderRadius.circular(radius),
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
    return Material(
      color: Colors.transparent,
      child: Ink(
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
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: Icon(icon, size: iconSize, color: Colors.white),
        ),
      ),
    );
  }
}

/// 分区标题。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
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
              style: const TextStyle(color: AppColors.textTertiary, fontSize: 12),
            ),
          ],
          const Spacer(),
          ?trailing,
        ],
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
              style: const TextStyle(
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
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                },
              ),
      ),
    );
  }
}