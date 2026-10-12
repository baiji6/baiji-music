import 'package:baiji_music/lyrics/karaoke_fill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _sung = Color(0xFF2EE6A8);
const _unsung = Color(0xFFF2F5FF);

void main() {
  group('KaraokeFill 逐字填充分段渐变', () {
    test('所有字都没唱：整行只有未唱色', () {
      final built = KaraokeFill.build(
        wordSpans: const [
          [0.0, 20.0],
          [20.0, 40.0],
        ],
        ratios: const [0.0, 0.0],
        width: 40.0,
        sung: _sung,
        unsung: _unsung,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      // 同色相邻点不合并也无所谓（视觉等价），关键是没有任何已唱色
      expect(colors, everyElement(_unsung));
      expect(stops.first, 0.0);
    });

    test('所有字已唱完：整行只有已唱色', () {
      final built = KaraokeFill.build(
        wordSpans: const [
          [0.0, 20.0],
          [20.0, 40.0],
        ],
        ratios: const [1.0, 1.0],
        width: 40.0,
        sung: _sung,
        unsung: _unsung,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      expect(colors, everyElement(_sung));
      expect(stops.first, 0.0);
    });

    test('正在唱的字：填充前沿把字切成左绿右白', () {
      // 第 1 个字 [0, 20]，唱到一半
      final built = KaraokeFill.build(
        wordSpans: const [
          [0.0, 20.0],
        ],
        ratios: const [0.5],
        width: 40.0,
        sung: _sung,
        unsung: _unsung,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      // 0 -> sung, 0.5(=10/40) -> sung, 0.5(=20/40) -> unsung
      expect(stops, [0.0, 0.25, 0.5]);
      expect(colors, [_sung, _sung, _unsung]);
      // 渐变可直接构造（stops 严格单调）
      expect(() => LinearGradient(
            colors: colors,
            stops: stops,
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ), returnsNormally);
    });

    test('前字唱完、后字未唱、第三字进行中：组合状态', () {
      // [0,10] 唱完；[10,20] 未唱；[20,40] 唱到 1/4
      final built = KaraokeFill.build(
        wordSpans: const [
          [0.0, 10.0],
          [10.0, 20.0],
          [20.0, 40.0],
        ],
        ratios: const [1.0, 0.0, 0.25],
        width: 40.0,
        sung: _sung,
        unsung: _unsung,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      // 0=字0左(绿)；10/40=字1左(白)；20/40=字2左(绿)；25/40=填充前沿(绿)；40/40=字2末(白)
      expect(stops, [0.0, 0.25, 0.5, 0.625, 1.0]);
      expect(colors, [_sung, _unsung, _sung, _sung, _unsung]);
    });

    test('空文本字（QRC 罗马音占位）被跳过且下标仍对齐', () {
      final built = KaraokeFill.build(
        wordSpans: const [
          [],
          [0.0, 20.0],
        ],
        ratios: const [0.5, 0.5],
        width: 40.0,
        sung: _sung,
        unsung: _unsung,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      expect(stops, [0.0, 0.25, 0.5]);
      expect(colors, [_sung, _sung, _unsung]);
    });

    test('行宽 <= 0 或没有有效字时返回 null', () {
      expect(
        KaraokeFill.build(
          wordSpans: const [
            [0.0, 20.0]
          ],
          ratios: const [0.5],
          width: 0,
          sung: _sung,
          unsung: _unsung,
        ),
        isNull,
      );
      expect(
        KaraokeFill.build(
          wordSpans: const [
            [],
            [],
          ],
          ratios: const [0.5, 0.5],
          width: 40.0,
          sung: _sung,
          unsung: _unsung,
        ),
        isNull,
      );
      expect(
        KaraokeFill.build(
          wordSpans: const [],
          ratios: const [],
          width: 40.0,
          sung: _sung,
          unsung: _unsung,
        ),
        isNull,
      );
    });

    test('spans 与 ratios 长度不一致返回 null（防错位）', () {
      expect(
        KaraokeFill.build(
          wordSpans: const [
            [0.0, 20.0],
            [20.0, 40.0],
          ],
          ratios: const [0.5],
          width: 40.0,
          sung: _sung,
          unsung: _unsung,
        ),
        isNull,
      );
    });

    test('零宽字（r <= l）被跳过', () {
      final built = KaraokeFill.build(
        wordSpans: const [
          [0.0, 0.0],
          [0.0, 20.0],
        ],
        ratios: const [1.0, 1.0],
        width: 40.0,
        sung: _sung,
        unsung: _unsung,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      expect(colors, everyElement(_sung));
    });

    test('越界坐标被钳制到 0~1（换行/测量异常时不出非法渐变）', () {
      final built = KaraokeFill.build(
        wordSpans: const [
          [-5.0, 20.0],
          [20.0, 60.0],
        ],
        ratios: const [1.0, 0.5],
        width: 40.0,
        sung: _sung,
        unsung: _unsung,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      expect(stops.first, inExclusiveRange(-0.001, 0.001));
      expect(stops.last, lessThanOrEqualTo(1.0));
      // 单调
      for (var i = 1; i < stops.length; i++) {
        expect(stops[i], greaterThan(stops[i - 1]));
      }
    });

    test('进度极小（刚开始唱）也至少放一个已唱点，不会整字丢失', () {
      final built = KaraokeFill.build(
        wordSpans: const [
          [0.0, 20.0],
          [20.0, 40.0],
        ],
        ratios: const [0.0001, 0.0],
        width: 40.0,
        sung: _sung,
        unsung: _unsung,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      expect(colors.first, _sung);
      expect(colors, contains(_unsung));
    });
  });
}
