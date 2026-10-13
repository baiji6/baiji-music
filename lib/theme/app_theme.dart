import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// 主题令牌快照：暗色 / 浅色两套完整取值。
///
/// v2.2.5 之前 [AppColors] 是一组 `static const` 暗色令牌，全 App 只有
/// 暗色一套皮。现在把**随明暗切换的令牌**收进 [AppPalette]（dark / light
/// 两个 const 实例），与明暗无关的品牌霓虹色（cyan / violet / magenta…）
/// 继续留在 [AppColors] 上保持 const——渐变按钮、封面占位这些地方
/// 两种主题下都用同一组饱和色，不需要切换。
class AppPalette {
  const AppPalette({
    required this.isDark,
    required this.bg0,
    required this.bg1,
    required this.bg2,
    required this.surfaceGlass,
    required this.surfaceGlassStrong,
    required this.strokeGlass,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.skyBlue,
    required this.titleGradient,
    required this.accent,
    required this.accentAlt,
    required this.karaoke,
    required this.lyricUnsung,
    required this.lyricInactive,
    required this.danger,
    required this.success,
    required this.warning,
    required this.cardShadow,
    required this.glowCyan,
    required this.glowViolet,
    required this.glowMagenta,
  });

  final bool isDark;

  // 基底
  final Color bg0; // 最深背景（渐变尾色）
  final Color bg1; // 主背景
  final Color bg2; // 卡片 / 弹层底
  final Color surfaceGlass; // 玻璃填充
  final Color surfaceGlassStrong; // 玻璃填充（强）
  final Color strokeGlass; // 玻璃描边
  final Color cardShadow; // 玻璃卡片投影

  // 文本
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// 标题天蓝：页面大标题 / 分区标题 / TopAppBar 标题统一色。
  final Color skyBlue;

  /// 青色系前景色（图标 / 选中态 / 链接）。暗色下就是品牌青；
  /// 浅色底上 #00E5FF 只有 1.9:1，必须换深青。
  final Color accent;

  /// 品红系前景色（网易云源标识 / 强调文字）。同理，浅色底换深品红。
  final Color accentAlt;

  /// 标题渐变（NeonText 默认）：天蓝 →  Azure，两种主题各自取可读的档位。
  final List<Color> titleGradient;

  // 歌词三色默认值（用户自定义后不再跟随主题）
  final Color karaoke; // 已唱
  final Color lyricUnsung; // 当前行未唱
  final Color lyricInactive; // 非当前行

  // 状态
  final Color danger;
  final Color success;
  final Color warning;

  // 辉光（背景光晕的起止色）
  final List<Color> glowCyan;
  final List<Color> glowViolet;
  final List<Color> glowMagenta;

  /// 深空霓虹（默认主题）。
  static const AppPalette dark = AppPalette(
    isDark: true,
    bg0: Color(0xFF05070D),
    bg1: Color(0xFF0A0F1E),
    bg2: Color(0xFF10182C),
    surfaceGlass: Color(0x14FFFFFF),
    surfaceGlassStrong: Color(0x1FFFFFFF),
    strokeGlass: Color(0x26FFFFFF),
    cardShadow: Color(0x59000000),
    textPrimary: Color(0xFFF2F5FF),
    textSecondary: Color(0xFF9AA6C7),
    textTertiary: Color(0xFF5A6686),
    skyBlue: Color(0xFF7AD1FF),
    titleGradient: [Color(0xFF8ADBFF), Color(0xFF4FA3FF)],
    accent: Color(0xFF00E5FF),
    accentAlt: Color(0xFFFF2E97),
    karaoke: Color(0xFFA8F685),
    lyricUnsung: Color(0xFFF2F5FF),
    lyricInactive: Color(0xFF5A6686),
    danger: Color(0xFFFF5470),
    success: Color(0xFF2EE6A8),
    warning: Color(0xFFFFB74D),
    glowCyan: [Color(0x5500E5FF), Color(0x0000E5FF)],
    glowViolet: [Color(0x557C4DFF), Color(0x007C4DFF)],
    glowMagenta: [Color(0x55FF2E97), Color(0x00FF2E97)],
  );

  /// 白昼玻璃（浅色主题）：白底 + 柔蓝描边 + 低透明度光晕。
  ///
  /// 玻璃填充用半透明白而不是暗色主题的白色低透明度——白纸上需要的是
  /// 「略微提亮的绒面」而不是「挖一个黑洞」；文字全部切到深墨蓝保证对比度。
  static const AppPalette light = AppPalette(
    isDark: false,
    bg0: Color(0xFFE8EFFA),
    bg1: Color(0xFFFFFFFF),
    bg2: Color(0xFFF5F8FE),
    surfaceGlass: Color(0xA6FFFFFF),
    surfaceGlassStrong: Color(0xCCFFFFFF),
    strokeGlass: Color(0x1A274B8F),
    cardShadow: Color(0x14274B8F),
    textPrimary: Color(0xFF101B2E),
    textSecondary: Color(0xFF47566E),
    textTertiary: Color(0xFF64748B),
    // 浅色底上的天蓝要压深一档，否则 #7AD1FF 这种亮度在白底上只有
    // 1.6:1 的对比度，标题会「糊」在背景里。
    skyBlue: Color(0xFF0277BD),
    titleGradient: [Color(0xFF039BE5), Color(0xFF01579B)],
    // 青色/品红前景同理换深档：#00E5FF→#027DA6（4.7:1），
    // #FF2E97→#C2185B（5.8:1）。带透明度的淡色底仍用原亮色。
    accent: Color(0xFF027DA6),
    accentAlt: Color(0xFFC2185B),
    karaoke: Color(0xFF0E9E52),
    lyricUnsung: Color(0xFF12233F),
    lyricInactive: Color(0xFF5D6B84),
    danger: Color(0xFFE5484D),
    success: Color(0xFF0E9F6E),
    warning: Color(0xFFB45309),
    glowCyan: [Color(0x2E00E5FF), Color(0x0000E5FF)],
    glowViolet: [Color(0x247C4DFF), Color(0x007C4DFF)],
    glowMagenta: [Color(0x2AFF2E97), Color(0x00FF2E97)],
  );
}

/// 白姬音乐 · 霓虹未来设计系统
///
/// 设计语言：深空/白昼双基底 + 玻璃拟态（半透明 + 细描边）
/// + 霓虹渐变（青 / 紫 / 品红）+ 辉光。桌面端与移动端共用同一套令牌。
///
/// **主题相关令牌是 getter**（读当前 palette），因此不能出现在 const 上下文
/// 里；品牌霓虹色保持 const，两种主题共用。当前 palette 由
/// [_BaijiMusicAppState] 在构建根节点前写入（见 `main.dart`）。
class AppColors {
  AppColors._();

  static AppPalette _palette = AppPalette.dark;

  /// 当前生效的令牌快照。
  static AppPalette get palette => _palette;

  /// 当前是否深色。
  static bool get isDark => _palette.isDark;

  /// 按系统亮度切换令牌（幂等，重复调用同一亮度不产生任何副作用）。
  static void setBrightness(Brightness brightness) {
    setPalette(brightness == Brightness.dark ? AppPalette.dark : AppPalette.light);
  }

  /// 直接指定令牌快照（测试 / 预览用）。
  static void setPalette(AppPalette palette) {
    if (!identical(palette, _palette)) _palette = palette;
  }

  // ===== 品牌霓虹（与明暗无关，保持 const）=====
  static const Color cyan = Color(0xFF00E5FF);
  static const Color violet = Color(0xFF7C4DFF);
  static const Color magenta = Color(0xFFFF2E97);
  static const Color aqua = Color(0xFF5BF0DA);

  static const List<Color> neonGradient = [cyan, violet, magenta];
  static const List<Color> accentGradient = [cyan, violet];
  static const List<Color> playGradient = [magenta, violet];

  // ===== 基底（跟随主题）=====
  static Color get bg0 => _palette.bg0;
  static Color get bg1 => _palette.bg1;
  static Color get bg2 => _palette.bg2;
  static Color get surfaceGlass => _palette.surfaceGlass;
  static Color get surfaceGlassStrong => _palette.surfaceGlassStrong;
  static Color get strokeGlass => _palette.strokeGlass;
  static Color get cardShadow => _palette.cardShadow;

  // ===== 文本（跟随主题）=====
  static Color get textPrimary => _palette.textPrimary;
  static Color get textSecondary => _palette.textSecondary;
  static Color get textTertiary => _palette.textTertiary;

  // ===== 标题天蓝（跟随主题）=====
  static Color get skyBlue => _palette.skyBlue;
  static List<Color> get titleGradient => _palette.titleGradient;

  // ===== 前景强调色（跟随主题）=====
  /// 青色系前景：选中态 / 来源标签 / 链接 / 图标。
  static Color get accent => _palette.accent;

  /// 品红系前景：网易云源标识 / 强调文字。
  static Color get accentAlt => _palette.accentAlt;

  // ===== 歌词三色默认值（跟随主题，用户自定义后以自定义为准）=====
  static Color get karaoke => _palette.karaoke;
  static Color get lyricUnsung => _palette.lyricUnsung;
  static Color get lyricInactive => _palette.lyricInactive;

  // ===== 状态（跟随主题）=====
  static Color get danger => _palette.danger;
  static Color get success => _palette.success;
  static Color get warning => _palette.warning;

  // ===== 辉光（跟随主题）=====
  static List<Color> get glowCyan => _palette.glowCyan;
  static List<Color> get glowViolet => _palette.glowViolet;
  static List<Color> get glowMagenta => _palette.glowMagenta;
}

/// 应用到全 App 的渐变背景（深空 / 白昼 + 角落霓虹光晕）。
///
/// 颜色全部取自当前 [AppPalette]：浅色主题下光晕透明度被压到 15% 左右，
/// 白纸上只留一层极淡的蓝彩，不会变成「彩色污渍」。
class NebulaBackground extends StatelessWidget {
  const NebulaBackground({super.key, required this.child, this.scrollable = false});

  final Widget child;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final p = AppColors.palette;
    final bg = DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.topRight,
          radius: 1.6,
          colors: [p.bg1, p.bg0],
          stops: const [0.0, 1.0],
        ),
      ),
      child: Stack(
        children: [
          // 右上角青色光晕
          Positioned(
            top: -160,
            right: -120,
            child: _GlowOrb(size: 420, colors: p.glowCyan, blur: 90),
          ),
          // 左下角品红光晕
          Positioned(
            bottom: -180,
            left: -140,
            child: _GlowOrb(size: 480, colors: p.glowMagenta, blur: 100),
          ),
          // 中部偏右紫色光晕（弱）
          Positioned(
            top: 320,
            right: -200,
            child: _GlowOrb(size: 380, colors: p.glowViolet, blur: 80),
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

  /// Material 主题（深色，默认）。
  ///
  /// [seed] 非空时以莫奈壁纸种子取色（开启莫奈取色后由根组件传入）。
  static ThemeData dark({Brightness brightness = Brightness.dark, Color? seed}) =>
      _material(brightness: brightness, seed: seed);

  /// Material 主题（浅色）。
  static ThemeData light({Color? seed}) =>
      _material(brightness: Brightness.light, seed: seed);

  static ThemeData _material({required Brightness brightness, Color? seed}) {
    final p = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;
    final seedColor = seed ?? AppColors.violet;
    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
      primary: seedColor,
      secondary: AppColors.accent,
      surface: p.bg1,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bg1,
      fontFamilyFallback: const ['PingFang SC', 'Noto Sans CJK SC', 'Microsoft YaHei', 'HarmonyOS Sans'],
    );

    return base.copyWith(
      textTheme: base.textTheme
          .apply(
            bodyColor: p.textPrimary,
            displayColor: p.textPrimary,
          )
          .copyWith(
            headlineLarge: base.textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              // 标题天蓝：大标题 / 分区标题（SectionHeader 走 titleLarge）
              color: p.skyBlue,
            ),
            headlineMedium: base.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: p.skyBlue,
            ),
            titleLarge: base.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: p.skyBlue,
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
          color: p.skyBlue,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
        systemOverlayStyle: null,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.bg2.withValues(alpha: 0.82),
        indicatorColor: AppColors.violet.withValues(alpha: 0.35),
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.textSecondary),
        ),
        iconTheme: WidgetStatePropertyAll(
          IconThemeData(color: p.textSecondary, size: 22),
        ),
      ),
      dividerTheme: DividerThemeData(color: p.strokeGlass),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: p.surfaceGlass,
        side: BorderSide(color: p.strokeGlass),
        labelStyle: TextStyle(color: p.textSecondary, fontSize: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.bg2,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: p.strokeGlass),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.bg2,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: AppColors.accent),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: p.bg2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.strokeGlass),
        ),
        textStyle: TextStyle(color: p.textPrimary, fontSize: 12),
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

  /// Miuix 配色（品牌覆写版）。
  ///
  /// 以 [AppColors.violet]（或莫奈壁纸种子）跑 Monet 取色，再把与品牌强相关的
  /// 一组角色覆写到白姬的玻璃令牌上，保证 Miuix 组件（导航栏 / 偏好项 / 滑块 /
  /// 开关 / 对话框）长在 App 既有视觉体系里，而不是默认 Miuix 紫。
  ///
  /// [seed] 非空 = 莫奈取色生效：primary 一族交给壁纸种子派生，结构性令牌
  /// （背景 / 表面 / 文本 / 描边）仍然是白姬自己的，两种主题都成立。
  static MiuixColors miuixColors({required Brightness brightness, Color? seed}) {
    final dark = brightness == Brightness.dark;
    final p = dark ? AppPalette.dark : AppPalette.light;
    final colors = miuixColorsFromSeed(
      seed: seed ?? AppColors.violet,
      paletteStyle: MiuixThemePaletteStyle.vibrant,
      dark: dark,
    ).copy(
      // 基底：深空 / 白昼 + 玻璃
      background: p.bg1,
      onBackground: p.textPrimary,
      onBackgroundVariant: p.textSecondary,
      surface: p.bg1,
      onSurface: p.textPrimary,
      surfaceVariant: p.bg2,
      onSurfaceSecondary: p.textSecondary,
      onSurfaceVariantSummary: p.textTertiary,
      onSurfaceVariantActions: p.textSecondary,
      surfaceContainer: p.bg2,
      onSurfaceContainer: p.textPrimary,
      onSurfaceContainerVariant: p.textSecondary,
      surfaceContainerHigh: p.bg2,
      onSurfaceContainerHigh: p.textPrimary,
      surfaceContainerHighest: p.bg2,
      onSurfaceContainerHighest: p.textPrimary,
      outline: p.strokeGlass,
      dividerLine: p.strokeGlass,
      // 状态
      error: p.danger,
      onError: Colors.white,
    );
    if (seed != null) return colors; // 莫奈取色：primary 一族跟随壁纸
    return colors.copy(
      // 霓虹主色（品牌覆写）
      primary: AppColors.violet,
      onPrimary: Colors.white,
      primaryVariant: AppColors.accentAlt,
      secondary: AppColors.accent,
      onSecondary: AppPalette.dark.bg0,
      secondaryContainer: p.bg2,
      onSecondaryContainer: p.textPrimary,
    );
  }

  /// Miuix 主题（暗色 · 霓虹桥接）。兼容旧调用签名（默认深色、无种子）。
  static MiuixThemeData miuix({Brightness brightness = Brightness.dark, Color? seed}) {
    final colors = miuixColors(brightness: brightness, seed: seed);
    return brightness == Brightness.dark
        ? MiuixThemeData.dark(colors: colors)
        : MiuixThemeData.light(colors: colors);
  }
}

/// 渐变文字（标题默认走天蓝渐变）。
class NeonText extends StatelessWidget {
  const NeonText(
    this.text, {
    super.key,
    this.style,
    this.gradient,
    this.textAlign,
    this.maxLines,
  });

  final String text;
  final TextStyle? style;

  /// 渐变着色；null = 跟随当前主题的天蓝渐变（[AppColors.titleGradient]）。
  ///
  /// 不能给 const 默认值：主题切换时两套渐变不同，而 Dart 的默认参数值
  /// 必须是编译期常量。
  final List<Color>? gradient;
  final TextAlign? textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final s = style ?? Theme.of(context).textTheme.titleLarge!;
    return ShaderMask(
      shaderCallback: (bounds) => LinearGradient(
        colors: gradient ?? AppColors.titleGradient,
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
