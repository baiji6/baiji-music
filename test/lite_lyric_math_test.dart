// 轻量歌词引擎算法契约测试（v2.6.3）。
//
// 固化 BaiMusic computeFillOffset 移植语义：字符级线性填充、行索引定位、
// 字符偏移→像素映射。纯离线，不依赖 Flutter 渲染与网络。
import 'package:baiji_music/lyrics/lite_lyric_math.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:flutter_test/flutter_test.dart';

LyricLine wordLine() => const LyricLine(
      startMs: 1000,
      endMs: 5000,
      text: '我爱你中华',
      words: [
        LyricWord(startMs: 1000, endMs: 2000, text: '我'),
        LyricWord(startMs: 2000, endMs: 3000, text: '爱'),
        LyricWord(startMs: 3000, endMs: 4000, text: '你'),
        LyricWord(startMs: 4000, endMs: 4500, text: '中'),
        LyricWord(startMs: 4500, endMs: 5000, text: '华'),
      ],
    );

void main() {
  group('computeFillOffset（BaiMusic 线性逐字）', () {
    final line = wordLine();

    test('行首之前 = 0', () {
      expect(computeFillOffset(line, 999), 0.0);
      expect(computeFillOffset(line, 1000), 0.0);
    });

    test('每个字唱完 = 整数字符数', () {
      expect(computeFillOffset(line, 2000), 1.0);
      expect(computeFillOffset(line, 3000), 2.0);
      expect(computeFillOffset(line, 4000), 3.0);
    });

    test('字唱到一半 = 线性小数进度', () {
      // 第 1 字 1000~2000，1500 唱一半 → 0.5
      expect(computeFillOffset(line, 1500), closeTo(0.5, 1e-9));
      // 第 3 字 3000~4000，3500 → 2 + 0.5 = 2.5
      expect(computeFillOffset(line, 3500), closeTo(2.5, 1e-9));
    });

    test('行尾之后 = 全部字符', () {
      expect(computeFillOffset(line, 5000), 5.0);
      expect(computeFillOffset(line, 99999), 5.0);
    });

    test('字时长为 0 也不会除零（返回该字起点整数位）', () {
      const zero = LyricLine(
        startMs: 0,
        endMs: 100,
        text: 'ab',
        words: [
          LyricWord(startMs: 0, endMs: 0, text: 'a'),
          LyricWord(startMs: 0, endMs: 100, text: 'b'),
        ],
      );
      // 第一个字 end==start==0，position>行起点后 >= end → 直接计入 1。
      expect(computeFillOffset(zero, 1), greaterThanOrEqualTo(1.0));
    });

    test('非词级行按整行时间线性模拟', () {
      const plain = LyricLine(startMs: 0, endMs: 1000, text: 'abcd');
      expect(computeFillOffset(plain, 0), 0.0);
      expect(computeFillOffset(plain, 500), 2.0);
      expect(computeFillOffset(plain, 1000), 4.0);
      expect(computeFillOffset(plain, 2000), 4.0);
    });

    test('空文本恒为 0', () {
      const empty = LyricLine(startMs: 0, endMs: 100, text: '');
      expect(computeFillOffset(empty, 50), 0.0);
    });
  });

  group('activeIndexAt（BaiMusic currentIndex 语义）', () {
    final lyrics = Lyrics(lines: [
      const LyricLine(startMs: 1000, endMs: 2000, text: 'a'),
      const LyricLine(startMs: 2000, endMs: 3000, text: 'b'),
      const LyricLine(startMs: 3000, endMs: 4000, text: 'c'),
    ]);

    test('空歌词 = -1', () {
      expect(activeIndexAt(Lyrics.empty, 1000), -1);
    });

    test('首行之前 = 0（首行待唱）', () {
      expect(activeIndexAt(lyrics, 0), 0);
      expect(activeIndexAt(lyrics, 999), 0);
    });

    test('命中行起点 = 该行', () {
      expect(activeIndexAt(lyrics, 2000), 1);
      expect(activeIndexAt(lyrics, 3000), 2);
    });

    test('行间空白保持上一行', () {
      // 假设行2 end=2500，位置 2600 未到行3 start=3000 → 保持行1(index=1)
      final gap = Lyrics(lines: [
        const LyricLine(startMs: 1000, endMs: 2000, text: 'a'),
        const LyricLine(startMs: 3000, endMs: 4000, text: 'b'),
      ]);
      expect(activeIndexAt(gap, 2500), 0);
    });

    test('末行之后 = 末行', () {
      expect(activeIndexAt(lyrics, 99999), 2);
    });
  });

  group('字符偏移→像素映射', () {
    test('buildCharEndX 单调不减（抗 getOffsetForCaret 回退）', () {
      final x = buildCharEndX(3, (i) => [0.0, 10.0, 8.0, 30.0][i]);
      expect(x[0], 0.0);
      expect(x[1], 10.0);
      expect(x[2], 10.0); // 8 被钳到前一个 10
      expect(x[3], 30.0);
    });

    test('整数偏移 = 对应字符边界', () {
      final x = [0.0, 10.0, 20.0, 30.0];
      expect(fillOffsetToPixel(0, x), 0.0);
      expect(fillOffsetToPixel(2, x), 20.0);
      expect(fillOffsetToPixel(3, x), 30.0);
    });

    test('小数偏移 = 相邻边界线性插值', () {
      final x = [0.0, 10.0, 20.0, 30.0];
      expect(fillOffsetToPixel(1.5, x), 15.0);
      expect(fillOffsetToPixel(0.25, x), 2.5);
    });

    test('越界钳制', () {
      final x = [0.0, 10.0, 20.0];
      expect(fillOffsetToPixel(-1, x), 0.0);
      expect(fillOffsetToPixel(99, x), 20.0);
      expect(fillOffsetToPixel(2, <double>[0.0]), 0.0);
    });
  });
}
