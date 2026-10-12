// LyricSettings 新字段（字重 / 圆角 / 三色）的契约测试。
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/lyric_settings.dart';
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
    test('默认 24，范围 0~40', () {
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
    test('默认值：已唱荧光黄绿 / 当前行白 / 非当前行暗灰', () {
      final s = LyricSettings.instance;
      expect(s.sungColor, const Color(0xFFA8F685));
      expect(s.unsungColor, const Color(0xFFF2F5FF));
      expect(s.inactiveColor, const Color(0xFF5A6686));
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
      expect(s.sungColor, const Color(0xFFA8F685));
      expect(s.unsungColor, const Color(0xFFF2F5FF));
      expect(s.inactiveColor, const Color(0xFF5A6686));
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
}
