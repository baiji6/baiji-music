// v2.2.5 主题系统回归：浅色令牌 / 天蓝标题 / 莫奈取色开关 / 歌词三色跟随主题。
//
// 覆盖：
// 1) AppPalette.light 的取值契约（白底 + 深墨文字 + 深天蓝标题）；
// 2) AppColors.setBrightness 切换后 getter 全部换挡，且可还原；
// 3) 浅色主题下标题天蓝与白底的对比度足够（不会「糊」在背景里）；
// 4) NeonText 默认渐变 = 天蓝渐变；
// 5) AppTheme.light() / miuix(brightness: light) 产出浅色主题数据；
// 6) 莫奈开关：ThemeController 持久化 + 种子注入后 primary 跟随种子；
// 7) 歌词三色未自定义时跟随主题，自定义后优先，重置后回到主题默认。
import 'dart:math' as math;

import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/core/theme_controller.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WCAG 相对亮度。
double _luminance(Color c) {
  double lin(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// HSL 色相（0~360）。
double _hue(Color c) {
  final r = c.r, g = c.g, b = c.b;
  final max = [r, g, b].reduce(math.max);
  final min = [r, g, b].reduce(math.min);
  final d = max - min;
  if (d == 0) return 0;
  double h;
  if (max == r) {
    h = (g - b) / d % 6;
  } else if (max == g) {
    h = (b - r) / d + 2;
  } else {
    h = (r - g) / d + 4;
  }
  h *= 60;
  return h < 0 ? h + 360 : h;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await KvStore.ensureInit();
    await KvStore.instance.clear();
    await LyricSettings.instance.load();
    await ThemeController.instance.load();
    // 每个用例从暗色令牌出发
    AppColors.setBrightness(Brightness.dark);
  });

  group('AppPalette.light 取值契约', () {
    test('白底 + 深墨文字 + 深天蓝标题', () {
      final p = AppPalette.light;
      expect(p.isDark, false);
      expect(p.bg1, const Color(0xFFFFFFFF)); // 主背景纯白
      expect(p.bg1.computeLuminance(), greaterThan(0.9));
      // 正文三级色亮度递减（白底上必须明显深于背景）
      expect(_luminance(p.textPrimary), lessThan(0.05));
      expect(_luminance(p.textSecondary), lessThan(0.2));
      expect(_luminance(p.textTertiary), lessThan(0.35));
      // 标题天蓝压深档
      expect(p.skyBlue, const Color(0xFF0277BD));
      // 青色/品红前景也换深档
      expect(_luminance(p.accent), lessThan(0.3));
      expect(_luminance(p.accentAlt), lessThan(0.2));
    });

    test('暗色令牌保持 v2.2.4 原值', () {
      final p = AppPalette.dark;
      expect(p.isDark, true);
      expect(p.bg1, const Color(0xFF0A0F1E));
      expect(p.textPrimary, const Color(0xFFF2F5FF));
      expect(p.skyBlue, const Color(0xFF7AD1FF));
      // 暗色下前景色就是品牌亮色
      expect(p.accent, AppColors.cyan);
      expect(p.accentAlt, AppColors.magenta);
    });

    test('浅色标题天蓝 vs 白底对比度 >= 4.5，暗色天蓝 vs 深空底 >= 4.5', () {
      expect(_contrast(AppPalette.light.skyBlue, AppPalette.light.bg1),
          greaterThanOrEqualTo(4.5));
      expect(_contrast(AppPalette.dark.skyBlue, AppPalette.dark.bg1),
          greaterThanOrEqualTo(4.5));
    });

    test('浅色正文三级色 vs 白底对比度均 >= 4.5', () {
      final p = AppPalette.light;
      expect(_contrast(p.textPrimary, p.bg1), greaterThanOrEqualTo(4.5));
      expect(_contrast(p.textSecondary, p.bg1), greaterThanOrEqualTo(4.5));
      expect(_contrast(p.textTertiary, p.bg1), greaterThanOrEqualTo(4.5));
    });

    test('浅色前景强调色 vs 白底对比度 >= 3（图标/大字号线）', () {
      final p = AppPalette.light;
      expect(_contrast(p.accent, p.bg1), greaterThanOrEqualTo(3.0));
      expect(_contrast(p.accentAlt, p.bg1), greaterThanOrEqualTo(3.0));
      // 浅色已唱绿（大字歌词）也要可读
      expect(_contrast(p.karaoke, p.bg1), greaterThanOrEqualTo(3.0));
      expect(_contrast(p.lyricUnsung, p.bg1), greaterThanOrEqualTo(4.5));
    });
  });

  group('AppColors.setBrightness 换挡', () {
    test('切浅色后所有主题令牌换挡，切回后还原', () {
      // 暗色基线
      expect(AppColors.bg1, const Color(0xFF0A0F1E));
      expect(AppColors.isDark, true);

      AppColors.setBrightness(Brightness.light);
      expect(AppColors.isDark, false);
      expect(AppColors.bg1, const Color(0xFFFFFFFF));
      expect(AppColors.textPrimary, const Color(0xFF101B2E));
      expect(AppColors.skyBlue, const Color(0xFF0277BD));
      expect(AppColors.accent, const Color(0xFF027DA6));
      expect(AppColors.accentAlt, const Color(0xFFC2185B));
      expect(AppColors.karaoke, const Color(0xFF0E9E52));
      // 品牌霓虹色不受明暗影响
      expect(AppColors.cyan, const Color(0xFF00E5FF));
      expect(AppColors.neonGradient, const [AppColors.cyan, AppColors.violet, AppColors.magenta]);

      AppColors.setBrightness(Brightness.dark);
      expect(AppColors.bg1, const Color(0xFF0A0F1E));
      expect(AppColors.textPrimary, const Color(0xFFF2F5FF));
    });

    test('幂等：重复设置同一亮度不改变取值', () {
      AppColors.setBrightness(Brightness.light);
      final a = AppColors.palette;
      AppColors.setBrightness(Brightness.light);
      expect(identical(AppColors.palette, a), true);
    });

    test('NebulaBackground 在浅色令牌下用白底渐变', () {
      AppColors.setBrightness(Brightness.light);
      final bg = NebulaBackground(child: const SizedBox());
      expect(bg, isA<NebulaBackground>());
      // 渐变起止色取自 palette（白 → 柔蓝灰）
      expect(AppColors.palette.bg1, const Color(0xFFFFFFFF));
      expect(AppColors.palette.bg0, const Color(0xFFE8EFFA));
    });
  });

  group('主题工厂', () {
    test('AppTheme.light() 产出浅色 Material 主题，标题天蓝', () {
      final t = AppTheme.light();
      expect(t.brightness, Brightness.light);
      expect(t.scaffoldBackgroundColor, const Color(0xFFFFFFFF));
      expect(t.textTheme.titleLarge?.color, const Color(0xFF0277BD));
      expect(t.textTheme.headlineLarge?.color, const Color(0xFF0277BD));
      expect(t.appBarTheme.titleTextStyle?.color, const Color(0xFF0277BD));
    });

    test('AppTheme.dark() 仍是深色，标题天蓝（亮档）', () {
      final t = AppTheme.dark();
      expect(t.brightness, Brightness.dark);
      expect(t.scaffoldBackgroundColor, const Color(0xFF0A0F1E));
      expect(t.textTheme.titleLarge?.color, const Color(0xFF7AD1FF));
    });

    test('莫奈种子注入 ColorScheme', () {
      const seed = Color(0xFF1B5E20); // 绿色壁纸种子
      final t = AppTheme.light(seed: seed);
      expect(t.colorScheme.primary, seed);
      final td = AppTheme.dark(seed: seed);
      expect(td.colorScheme.primary, seed);
    });

    test('miuix(brightness: light) 产出浅色 Miuix 主题且背景为白', () {
      final m = AppTheme.miuix(brightness: Brightness.light);
      expect(m.brightness, Brightness.light);
      expect(m.colors.background, const Color(0xFFFFFFFF));
      expect(m.colors.onSurface, const Color(0xFF101B2E));
      // 品牌覆写：无种子时 primary 仍是品牌紫
      expect(m.colors.primary, AppColors.violet);
    });

    test('miuix 莫奈种子：primary 跟随种子色相，结构令牌仍是白姬玻璃', () {
      const seed = Color(0xFF0D47A1); // 深蓝种子
      final m = AppTheme.miuix(brightness: Brightness.light, seed: seed);
      // miuixColorsFromSeed 会对种子做色调和谐化，primary 不再是种子原值，
      // 但必须落在种子色相附近（±40°），且接管品牌紫。
      expect(m.colors.primary, isNot(AppColors.violet));
      expect((_hue(m.colors.primary) - _hue(seed)).abs(), lessThan(40));
      // 结构令牌不被种子接管
      expect(m.colors.background, const Color(0xFFFFFFFF));
      expect(m.colors.surfaceContainer, const Color(0xFFF5F8FE));
      expect(m.colors.outline, AppPalette.light.strokeGlass);
      // 不开莫奈时回到品牌紫
      final plain = AppTheme.miuix(brightness: Brightness.light);
      expect(plain.colors.primary, AppColors.violet);
    });

    test('NeonText 默认渐变 = 当前主题天蓝渐变', () {
      AppColors.setBrightness(Brightness.light);
      const w = NeonText('x');
      expect(w.gradient, isNull); // null = 跟随主题
      // 默认值在 build 时解析：直接验证两套渐变的成员
      expect(AppColors.titleGradient.first, const Color(0xFF039BE5));
      expect(AppColors.titleGradient.last, const Color(0xFF01579B));
      AppColors.setBrightness(Brightness.dark);
      expect(AppColors.titleGradient.first, const Color(0xFF8ADBFF));
      expect(AppColors.titleGradient.last, const Color(0xFF4FA3FF));
    });
  });

  group('ThemeController 莫奈开关', () {
    test('默认关闭', () {
      expect(ThemeController.instance.monet, false);
      expect(ThemeController.instance.seed, isNull);
    });

    test('开启后持久化，重新 load 能恢复', () async {
      await ThemeController.instance.setMonet(true);
      expect(ThemeController.instance.monet, true);
      expect(KvStore.instance.getBool('appearance_monet'), true);
      // 模拟重启：单例还在，重新 load 读盘
      await ThemeController.instance.load();
      expect(ThemeController.instance.monet, true);
      // 关闭后落盘
      await ThemeController.instance.setMonet(false);
      expect(KvStore.instance.getBool('appearance_monet'), false);
      await ThemeController.instance.load();
      expect(ThemeController.instance.monet, false);
    });

    test('开关变化会通知监听者', () async {
      var notified = 0;
      void listener() => notified++;
      ThemeController.instance.addListener(listener);
      await ThemeController.instance.setMonet(true);
      await ThemeController.instance.setMonet(true); // 重复设置不再通知
      ThemeController.instance.removeListener(listener);
      expect(notified, 1);
      await ThemeController.instance.setMonet(false);
    });

    test('测试环境无平台通道：壁纸种子解析为 null（回退品牌紫）', () async {
      final seed = await MonetSeed.resolve();
      expect(seed, isNull);
      // 开启莫奈后 seed 仍为 null → 主题用品牌紫，不崩
      await ThemeController.instance.setMonet(true);
      expect(ThemeController.instance.seed, isNull);
      final m = AppTheme.miuix(
        brightness: Brightness.dark,
        seed: ThemeController.instance.seed,
      );
      expect(m.colors.primary, AppColors.violet);
      await ThemeController.instance.setMonet(false);
    });
  });

  group('歌词三色跟随主题', () {
    test('未自定义时跟随当前主题默认', () async {
      await LyricSettings.instance.resetColors();
      AppColors.setBrightness(Brightness.light);
      expect(LyricSettings.instance.unsungColor, const Color(0xFF12233F));
      expect(LyricSettings.instance.inactiveColor, const Color(0xFF5D6B84));
      expect(LyricSettings.instance.sungColor, const Color(0xFF0E9E52));
      AppColors.setBrightness(Brightness.dark);
      // v2.3.0-fix5：深色板三色对齐 AMLL 参考视频（白 / 60%白 / 40%白）
      expect(LyricSettings.instance.unsungColor, const Color(0x99FFFFFF));
      expect(LyricSettings.instance.sungColor, const Color(0xFFFFFFFF));
    });

    test('自定义后不跟随主题；重置后回到主题默认', () async {
      await LyricSettings.instance.resetColors();
      await LyricSettings.instance.setSungColor(const Color(0xFFFF0000));
      AppColors.setBrightness(Brightness.light);
      expect(LyricSettings.instance.sungColor, const Color(0xFFFF0000));
      // 未自定义的两个仍跟随主题
      expect(LyricSettings.instance.unsungColor, const Color(0xFF12233F));
      await LyricSettings.instance.resetColors();
      expect(LyricSettings.instance.sungColor, const Color(0xFF0E9E52));
      AppColors.setBrightness(Brightness.dark);
    });

    test('自定义值可跨 load 恢复', () async {
      await LyricSettings.instance.setUnsungColor(const Color(0xFF123456));
      await LyricSettings.instance.load();
      expect(LyricSettings.instance.unsungColor, const Color(0xFF123456));
      await LyricSettings.instance.resetColors();
    });
  });
}
