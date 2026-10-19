// LyricSettings 新字段（字重 / 圆角 / 三色）的契约测试。
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // 每个用例从干净存储开始：单例不重建，必须显式清掉上一个用例的残留
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await KvStore.ensureInit();
    await KvStore.instance.clear();
    await LyricSettings.instance.load();
  });

  group('LyricSettings 字重', () {
    test('默认 800，可调范围 300~900', () {
      final s = LyricSettings.instance;
      expect(s.weight, LyricSettings.defaultWeight);
      expect(LyricSettings.minWeight, 300);
      expect(LyricSettings.maxWeight, 900);
      expect(s.activeWeight, FontWeight.w800);
    });

    test('越界值被钳制', () async {
      final s = LyricSettings.instance;
      await s.setWeight(2000);
      expect(s.weight, LyricSettings.maxWeight);
      expect(s.activeWeight, FontWeight.w900);
      await s.setWeight(10);
      expect(s.weight, LyricSettings.minWeight);
      expect(s.activeWeight, FontWeight.w300);
    });

    test('非当前行字重始终比当前行轻一档且不过界', () {
      final s = LyricSettings.instance;
      expect(s.weight, 800);
      expect(s.inactiveWeight, FontWeight.w500);
      // w300 时不能再轻（clamp 到 300）
      // w900 时最多到 w600
      expect(
        FontWeight.values.indexOf(s.inactiveWeight),
        lessThan(FontWeight.values.indexOf(s.activeWeight)),
      );
    });
  });

  group('LyricSettings 圆角', () {
    test('默认 0（AMLL 全幅歌词底），范围 0~40', () {
      final s = LyricSettings.instance;
      expect(s.corner, LyricSettings.defaultCorner);
      expect(LyricSettings.minCorner, 0.0);
      expect(LyricSettings.maxCorner, 40.0);
    });

    test('越界值被钳制', () async {
      final s = LyricSettings.instance;
      await s.setCorner(999);
      expect(s.corner, LyricSettings.maxCorner);
      await s.setCorner(-5);
      expect(s.corner, LyricSettings.minCorner);
    });
  });

  group('LyricSettings 三色', () {
    test('默认值：已唱纯白 / 当前行 60% 白 / 非当前行 40% 白（AMLL 参考）', () {
      final s = LyricSettings.instance;
      expect(s.sungColor, const Color(0xFFFFFFFF));
      expect(s.unsungColor, const Color(0x99FFFFFF));
      expect(s.inactiveColor, const Color(0x66FFFFFF));
    });

    test('自定义颜色即时生效并可重置', () async {
      final s = LyricSettings.instance;
      await s.setSungColor(const Color(0xFFFF0000));
      await s.setUnsungColor(const Color(0xFF00FF00));
      await s.setInactiveColor(const Color(0xFF0000FF));
      expect(s.sungColor, const Color(0xFFFF0000));
      expect(s.unsungColor, const Color(0xFF00FF00));
      expect(s.inactiveColor, const Color(0xFF0000FF));
      await s.resetColors();
      expect(s.sungColor, const Color(0xFFFFFFFF));
      expect(s.unsungColor, const Color(0x99FFFFFF));
      expect(s.inactiveColor, const Color(0x66FFFFFF));
    });

    test('load 能从存储恢复（序列化 round-trip）', () async {
      final s = LyricSettings.instance;
      // 绕过 setter 直接写存储，验证 load 真的在读盘解析而不是吃内存
      await KvStore.instance.setString('lyric_view:sung_color', '#123456');
      await KvStore.instance.setString('lyric_view:unsung_color', '#ABCDEF');
      await KvStore.instance.setString('lyric_view:inactive_color', '#0F0F0F');
      await s.load();
      expect(s.sungColor, const Color(0xFF123456));
      expect(s.unsungColor, const Color(0xFFABCDEF));
      expect(s.inactiveColor, const Color(0xFF0F0F0F));
    });

    test('非法存储值回退默认而不是崩溃', () async {
      final s = LyricSettings.instance;
      await KvStore.instance.setString('lyric_view:sung_color', 'not-a-color');
      await s.load();
      expect(s.sungColor, LyricSettings.defaultSungColor);
    });
  });

  // #80 逐行歌词高亮隐身回归：浅色主题下深色调的浅色字对比度不足，
  // 当前行整个隐身。ensureReadable 要在不可读时自动回退、可读时原样保留。
  group('LyricSettings 可读性保障（#80）', () {
    test('浅底 + 浅色字 → 回退墨色（视频实测 1.5:1 隐身场景）', () {
      const bg = Color(0xFFFCFBFE);
      // 视频里的隐身当前行色
      expect(LyricSettings.ensureReadable(const Color(0xFFD1D0D3), bg),
          LyricSettings.inkOnLight);
      // 深色调的默认未唱色（近白）
      expect(LyricSettings.ensureReadable(const Color(0xFFF2F5FF), bg),
          LyricSettings.inkOnLight);
      // 纯白字
      expect(LyricSettings.ensureReadable(Colors.white, bg),
          LyricSettings.inkOnLight);
    });

    test('深底 + 深色字 → 回退纸色', () {
      const bg = Color(0xFF0A0F1E);
      expect(LyricSettings.ensureReadable(const Color(0xFF101B2E), bg),
          LyricSettings.textOnDark);
    });

    test('对比度足够时原样保留自定义色', () {
      const bg = Color(0xFFFCFBFE);
      // 灰蓝（≈5:1）在浅底上保留
      expect(LyricSettings.ensureReadable(const Color(0xFF5A6686), bg),
          const Color(0xFF5A6686));
      // 深底上纯白 / 60% 白都保留
      const darkBg = Color(0xFF0A0F1E);
      expect(LyricSettings.ensureReadable(Colors.white, darkBg), Colors.white);
      expect(LyricSettings.ensureReadable(const Color(0x99FFFFFF), darkBg),
          const Color(0x99FFFFFF));
    });

    test('readableXxx 跟随当前色板：默认三色始终可读不被改写', () {
      final s = LyricSettings.instance;
      // 测试环境默认深色板：三色默认值在深底上全部可读，应原样返回
      expect(s.readableUnsungColor, s.unsungColor);
      expect(s.readableInactiveColor, s.inactiveColor);
      expect(s.readableSungColor, s.sungColor);
    });

    test('自定义浅色未唱色在深色板下保留、语义上等价于浅底回退墨色', () async {
      final s = LyricSettings.instance;
      await s.setUnsungColor(Colors.white);
      // 当前（深色板）bg1 上白字可读 → 保留
      expect(s.readableUnsungColor, Colors.white);
      // 同一个自定义白字放到浅底 → 不可读，回退墨色
      expect(LyricSettings.ensureReadable(Colors.white, const Color(0xFFFFFFFF)),
          LyricSettings.inkOnLight);
      await s.resetColors();
    });

    // v2.2.9-fix1 回归：首发的对比度保障把不可读的已唱/未唱色兜到
    // 同一个墨色，填充渐变两端同色 → 卡拉 OK 染色整个隐形。
    test('浅底 + 深色调已唱/未唱都不可读 → 已唱回退主题绿，与未唱墨色不同', () async {
      final s = LyricSettings.instance;
      // 模拟深色主题下调的两把浅色，切到浅色板（测试默认深色板，
      // 直接用 ensureReadable 的浅底语义 + 分层回退语义验证）
      await s.setSungColor(const Color(0xFFF2F5FF)); // 浅色"已唱"
      await s.setUnsungColor(const Color(0xFFD1D0D3)); // 浅色"未唱"
      final bg = const Color(0xFFFCFBFE); // 浅底
      // 各自按主题默认色回退：已唱 → 绿（浅色板 karaoke），
      // 未唱 → 墨（浅色板 lyricUnsung）。两者必然不同色。
      final sung = LyricSettings.resolveReadableForTest(
          s.sungColor, const Color(0xFF0E9E52), bg);
      final unsung = LyricSettings.resolveReadableForTest(
          s.unsungColor, const Color(0xFF12233F), bg);
      expect(sung, isNot(unsung),
          reason: '已唱/未唱回退后必须不同色，否则卡拉 OK 染色隐形');
      expect(sung, const Color(0xFF0E9E52));
      expect(unsung, const Color(0xFF12233F));
      await s.resetColors();
    });

    test('已唱色与未唱色解析后同色 → 强制主题强调色拉开层次', () async {
      final s = LyricSettings.instance;
      // 深色板下两把都设为可读的白：各自可读、却彼此相同
      await s.setSungColor(Colors.white);
      await s.setUnsungColor(Colors.white);
      // 未唱保留白色；已唱检测到与未唱同色 → 逃逸到主题强调色
      // （v2.3.0-fix5：主题已唱色默认已是白，兜不住同色碰撞）
      expect(s.readableUnsungColor, Colors.white);
      expect(s.readableSungColor, AppColors.accent);
      expect(s.readableSungColor, isNot(s.readableUnsungColor));
      await s.resetColors();
    });
  });
}
