import 'package:baiji_music/lyrics/karaoke_fill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _sung = Color(0xFF2EE6A8);
const _unsung = Color(0xFFF2F5FF);

void main() {
  group('KaraokeFill 逐字遮罩（AMLL/倾听语义）', () {
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

    test('feather=0 硬切：前沿 = left + 宽×ratio，右侧全未唱', () {
      // 字 [0, 20] 唱到一半 → front = 10（归一化 0.25）。
      // feather=0 用亚像素 epsilon 带保住阶跃（渐变 stops 必须严格单调，
      // 同位置双停靠点非法），视觉上仍是硬切。
      final built = KaraokeFill.build(
        wordSpans: const [
          [0.0, 20.0],
        ],
        ratios: const [0.5],
        width: 40.0,
        sung: _sung,
        unsung: _unsung,
        feather: 0,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      // 0=字左(已唱)；0.25=前沿(已唱)；0.252=epsilon 带右缘(未唱)；0.5=字右(未唱)
      expect(stops.length, 4);
      expect(stops[0], 0.0);
      expect(stops[1], 0.25);
      expect(stops[2], closeTo(0.25, 0.005));
      expect(stops[3], 0.5);
      expect(colors, [_sung, _sung, _unsung, _unsung]);
    });

    test('羽化带：front = l + w·ratio − F·(1−ratio)，带宽恒为 F', () {
      // 字 [0, 20] 唱到一半，F=4 → front = 0 + 10 − 2 = 8，带 = [8, 12]
      final built = KaraokeFill.build(
        wordSpans: const [
          [0.0, 20.0],
        ],
        ratios: const [0.5],
        width: 40.0,
        sung: _sung,
        unsung: _unsung,
        feather: 4,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      // 0=字左(亮)；0.2(=8/40)=front(亮)；0.3(=12/40)=front+F(暗)；
      // 0.5=字右(暗)。8→12 之间由渐变线性过渡，带宽恰为 F。
      expect(stops, [0.0, 0.2, 0.3, 0.5]);
      expect(colors, [_sung, _sung, _unsung, _unsung]);
      // 渐变可直接构造（stops 严格单调）
      expect(() => LinearGradient(
            colors: colors,
            stops: stops,
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ), returnsNormally);
    });

    test('开口瞬间（ratio→0）：front→left−F，整词几乎全暗不抢拍', () {
      // 字 [0, 20]，F=4，ratio=0.01 → front = 0.2 − 3.96 = −3.76
      final built = KaraokeFill.build(
        wordSpans: const [
          [0.0, 20.0],
        ],
        ratios: const [0.01],
        width: 40.0,
        sung: _sung,
        unsung: _unsung,
        feather: 4,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      // 字左缘 alpha 仅 ~0.06，front+F=0.24 之后全暗
      expect(stops.first, 0.0);
      expect(stops[1], closeTo(0.24 / 40, 0.001));
      expect(colors[1], _unsung);
      expect(colors[0], isNot(_unsung)); // 极少量已唱色
      expect(colors[0], isNot(_sung));
      expect(colors.last, _unsung);
    });

    test('唱完瞬间（ratio→1）：front→right，字末 alpha≈1 恰好填满', () {
      // 字 [0, 20]，F=4，ratio=0.99 → front = 19.8 − 0.04 = 19.76
      final built = KaraokeFill.build(
        wordSpans: const [
          [0.0, 20.0],
        ],
        ratios: const [0.99],
        width: 40.0,
        sung: _sung,
        unsung: _unsung,
        feather: 4,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      // front=19.76 全亮；front+F=23.76 超出词右缘，字末 alpha=(23.76−20)/4=0.94
      expect(stops[1], closeTo(19.76 / 40, 0.001));
      expect(colors[1], _sung);
      expect(colors.last, isNot(_unsung));
      expect(colors.last, isNot(_sung));
      // 99% 进度时字末已基本唱满（更靠近已唱色）
      expect(
        (colors.last.r - _sung.r).abs(),
        lessThan((colors.last.r - _unsung.r).abs()),
      );
    });

    test('前字唱完、后字未唱、第三字进行中：组合状态（硬切）', () {
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
        feather: 0,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      // 0=字0左(已唱)；0.25=字0末/字1左(未唱)；0.5=字2左(已唱)；
      // 0.625=字2前沿=25(已唱)；0.627=epsilon 带右缘(未唱)；1.0=字2末(未唱)
      expect(stops.length, 6);
      expect(stops[0], 0.0);
      expect(stops[1], 0.25);
      expect(stops[2], 0.5);
      expect(stops[3], 0.625);
      expect(stops[4], closeTo(0.625, 0.005));
      expect(stops[5], 1.0);
      expect(colors, [_sung, _unsung, _sung, _sung, _unsung, _unsung]);
    });

    test('逐词独立：前词唱完的绿色不会渗入未唱的后词', () {
      // 两个词都有过渡带，但词 1 未唱——词 0 的羽化右缘不得越过词边界
      final built = KaraokeFill.build(
        wordSpans: const [
          [0.0, 20.0],
          [20.0, 40.0],
        ],
        ratios: const [0.5, 0.0],
        width: 40.0,
        sung: _sung,
        unsung: _unsung,
        feather: 4,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      // 词 0：front=8，带 [8,12]；词 1 整体未唱
      expect(stops, [0.0, 0.2, 0.3, 0.5, 1.0]);
      expect(colors, [_sung, _sung, _unsung, _unsung, _unsung]);
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
        feather: 0,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      expect(stops.length, 4);
      expect(stops[0], 0.0);
      expect(stops[1], 0.25);
      expect(stops[3], 0.5);
      expect(colors, [_sung, _sung, _unsung, _unsung]);
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
        feather: 0,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      expect(stops.first, inExclusiveRange(-0.001, 0.001));
      expect(stops.last, lessThanOrEqualTo(1.0));
      // 字 1 front=40（归一化 1.0）：0~0.5 已唱、之后未唱
      expect(stops, [0.0, 0.5, 1.0]);
      expect(colors, [_sung, _sung, _unsung]);
      for (var i = 1; i < stops.length; i++) {
        expect(stops[i], greaterThan(stops[i - 1]));
      }
    });

    test('进度极小（刚开始唱）也至少放一个停靠点，不会整字丢失', () {
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
      expect(colors.first, isNot(_unsung));
      expect(colors, contains(_unsung));
      for (var i = 1; i < stops.length; i++) {
        expect(stops[i], greaterThan(stops[i - 1]));
      }
    });

    test('多词全进行中：stops 严格单调且颜色都在两色之间', () {
      final built = KaraokeFill.build(
        wordSpans: const [
          [0.0, 15.0],
          [15.0, 30.0],
          [30.0, 45.0],
        ],
        ratios: const [0.3, 0.6, 0.9],
        width: 45.0,
        sung: _sung,
        unsung: _unsung,
        feather: 6,
      );
      expect(built, isNotNull);
      final (stops, colors) = built!;
      for (var i = 1; i < stops.length; i++) {
        expect(stops[i], greaterThan(stops[i - 1]));
      }
      // 逐通道显式检查：两色 lerp 的产物各通道值都介于 unsung 与 sung 之间
      for (final c in colors) {
        for (final pair in [
          (c.r, _unsung.r, _sung.r),
          (c.g, _unsung.g, _sung.g),
          (c.b, _unsung.b, _sung.b),
        ]) {
          final (v, a, b) = pair;
          final lo = a < b ? a : b;
          final hi = a > b ? a : b;
          expect(v, inInclusiveRange(lo, hi));
        }
      }
    });
  });
}
