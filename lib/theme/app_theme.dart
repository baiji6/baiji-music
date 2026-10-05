import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// 白姬音乐 · 霓虹未来设计系统
///
/// 设计语言：暗色深空基底 + 玻璃拟态（半透明 + 模糊 + 细描边）
/// + 霓虹渐变（青 / 紫 / 品红）+ 辉光。桌面端与移动端共用同一套令牌。
class AppColors {
  AppColors._();

  // 基底
  static const Color bg0 = Color(0xFF05070D); // 最深背景
  static const Color bg1 = Color(0xFF0A0F1E); // 主背景
  static const Color bg2 = Color(0xFF10182C); // 卡片底
  static const Color surfaceGlass = Color(0x14FFFFFF); // 玻璃填充
  static const Color surfaceGlassStrong = Color(0x1FFFFFFF);
  static const Color strokeGlass = Color(0x26FFFFFF); // 玻璃描边

  // 霓虹
  static const Color cyan = Color(0xFF00E5FF);
  static const Color violet = Color(0xFF7C4DFF);
  static const Color magenta = Color(0xFFFF2E97);
  static const Color aqua = Color(0xFF5BF0DA);

  static const List<Color> neonGradient = [cyan, violet, magenta];
  static const List<Color> accentGradient = [cyan, violet];
  static const List<Color> playGradient = [magenta, violet];

  // 文本
  static const Color textPrimary = Color(0xFFF2F5FF);
  static const Color textSecondary = Color(0xFF9AA6C7);
  static const Color textTertiary = Color(0xFF5A6686);

  // 状态
  static const Color danger = Color(0xFFFF5470);
  static const Color success = Color(0xFF2EE6A8);
  static const Color warning = Color(0xFFFFB74D);

  // 辉光
  static const List<Color> glowCyan = [Color(0x5500E5FF), Color(0x0000E5FF)];
  static const List<Color> glowViolet = [Color(0x557C4DFF), Color(0x007C4DFF)];
  static const List<Color> glowMagenta = [Color(0x55FF2E97), Color(0x00FF2E97)];
}

/// 应用到全 App 的渐变背景（深空 + 角落霓虹光晕）。
class NebulaBackground extends StatelessWidget {
  const NebulaBackground({super.key, required this.child, this.scrollable = false});

  final Widget child;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final bg = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.topRight,
          radius: 1.6,
          colors: [AppColors.bg1, AppColors.bg0],
          stops: [0.0, 1.0],
        ),
      ),
      child: Stack(
        children: [
          // 右上角青色光晕
          Positioned(
            top: -160,
            right: -120,
            child: _GlowOrb(
              size: 420,
              colors: AppColors.glowCyan,
              blur: 90,
            ),
          ),
          // 左下角品红光晕
          Positioned(
            bottom: -180,
            left: -140,
            child: _GlowOrb(
              size: 480,
              colors: AppColors.glowMagenta,
              blur: 100,
            ),
          ),
          // 中部偏右紫色光晕（弱）
          Positioned(
            top: 320,
            right: -200,
            child: _GlowOrb(
              size: 380,
              colors: AppColors.glowViolet,
              blur: 80,
            ),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );

    if (scrollable) {
      return CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [SliverFillRemaining(hasScrollBody: false, child: bg)],
      );
    }
    return bg;
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.size, required this.colors, required this.blur});

  final double size;
  final List<Color> colors;
  final double blur;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: colors, stops: const [0.0, 1.0]),
      ),
    );
  }
}

/// 全局主题工厂。
class AppTheme {
  AppTheme._();

  static ThemeData dark({Brightness brightness = Brightness.dark}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.violet,
      brightness: brightness,
      primary: AppColors.violet,
      secondary: AppColors.cyan,
      surface: AppColors.bg1,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bg1,
      fontFamilyFallback: const ['PingFang SC', 'Noto Sans CJK SC', 'Microsoft YaHei', 'HarmonyOS Sans'],
    );

    return base.copyWith(
      textTheme: base.textTheme
          .apply(
            bodyColor: AppColors.textPrimary,
            displayColor: AppColors.textPrimary,
          )
          .copyWith(
            headlineLarge: base.textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
            headlineMedium: base.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            titleLarge: base.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            titleMedium: base.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            bodyMedium: base.textTheme.bodyMedium?.copyWith(
              height: 1.4,
            ),
          ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
        systemOverlayStyle: null,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.bg2.withValues(alpha: 0.82),
        indicatorColor: AppColors.violet.withValues(alpha: 0.35),
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
        ),
        iconTheme: WidgetStatePropertyAll(
          IconThemeData(color: AppColors.textSecondary, size: 22),
        ),
      ),
      dividerTheme: const DividerThemeData(color: AppColors.strokeGlass),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: AppColors.surfaceGlass,
        side: const BorderSide(color: AppColors.strokeGlass),
        labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.bg2,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.strokeGlass),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.bg2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.cyan),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.bg2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.strokeGlass),
        ),
        textStyle: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// 渐变文字。
class NeonText extends StatelessWidget {
  const NeonText(
    this.text, {
    super.key,
    this.style,
    this.gradient = AppColors.neonGradient,
    this.textAlign,
    this.maxLines,
  });

  final String text;
  final TextStyle? style;
  final List<Color> gradient;
  final TextAlign? textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final s = style ?? Theme.of(context).textTheme.titleLarge!;
    return ShaderMask(
      shaderCallback: (bounds) => LinearGradient(
        colors: gradient,
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(bounds),
      child: Text(
        text,
        style: s.copyWith(color: Colors.white),
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: maxLines != null ? TextOverflow.ellipsis : null,
      ),
    );
  }
}