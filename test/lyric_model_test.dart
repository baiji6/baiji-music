import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// 逐字歌词的数据契约。
///
/// 2.2.2 的回归教训：实现「整行放大」时把染色链路一起删了，
/// 逐字歌词因此消失——但**放大和染色是两条独立的链路**。
/// 这里锁住 [LyricWord.progressAt] 的行为，确保渲染层拿得到逐字进度。
void main() {
  const words = [
    LyricWord(startMs: 1000, endMs: 1500, text: '你'),
    LyricWord(startMs: 1500, endMs: 2000, text: '好'),
  ];
  const line = LyricLine(
    startMs: 1000,
    endMs: 2000,
    text: '你好',
    words: words,
  );

  group('LyricWord.progressAt', () {
    test('未开始 → 0', () {
      expect(words[0].progressAt(500), 0.0);
      expect(words[0].progressAt(1000), 0.0);
    });

    test('进行中 → 0~1 线性插值', () {
      expect(words[0].progressAt(1250), closeTo(0.5, 1e-9));
    });

    test('已结束 → 1', () {
      expect(words[0].progressAt(1500), 1.0);
      expect(words[0].progressAt(9999), 1.0);
    });

    test('零时长（起止相同）→ 不做除零', () {
      const z = LyricWord(startMs: 100, endMs: 100, text: '啊');
      // 位置正好在起点：按"还没开始"处理
      expect(z.progressAt(100), 0.0);
      // 越过起点就该唱完，不能是NaN
      expect(z.progressAt(101).isFinite, isTrue);
    });

    test('倒挂的起止时间 → 不抛异常也不 NaN', () {
      // 脏数据（end < start）不该让 UI 崩掉。具体取什么值不重要，
      // 重要的是结果在 0~1 之间且有限。
      const bad = LyricWord(startMs: 500, endMs: 100, text: 'x');
      for (final pos in [0, 300, 500, 600, 99999]) {
        final v = bad.progressAt(pos);
        expect(v.isFinite, isTrue, reason: '位置 $pos');
        expect(v, inInclusiveRange(0.0, 1.0), reason: '位置 $pos');
      }
    });
  });

  group('LyricWord.isHighlightedAt', () {
    test('过了起点就算唱过', () {
      expect(words[0].isHighlightedAt(999), isFalse);
      expect(words[0].isHighlightedAt(1000), isTrue);
    });
  });

  group('LyricLine.isWordLevel', () {
    test('多个字 → true（走逐字渲染）', () {
      expect(line.isWordLevel, isTrue);
    });

    test('只有一个字 → false（按整行渲染）', () {
      const single = LyricLine(
        startMs: 0,
        endMs: 100,
        text: '啊',
        words: [LyricWord(startMs: 0, endMs: 100, text: '啊')],
      );
      expect(single.isWordLevel, isFalse);
    });

    test('没有逐字数据 → false', () {
      const plain = LyricLine(startMs: 0, endMs: 100, text: '纯逐行歌词');
      expect(plain.isWordLevel, isFalse);
      expect(plain.displayText, '纯逐行歌词');
    });
  });

  group('逐字数据完整性', () {
    test('逐字拼接起来等于整行文本', () {
      expect(line.displayText, '你好');
    });

    test('逐字时间轴必须能区分相邻的字', () {
      // 两个字的progress 在各自区间内独立推进，这是染色能"跟着唱"的前提。
      // 1600 落在第二个字 1500~2000 区间内 → 100/500 = 0.2
      expect(words[0].progressAt(1600), 1.0);
      expect(words[1].progressAt(1600), closeTo(0.2, 1e-9));
    });

    test('isActiveAt 判定当前行', () {
      expect(line.isActiveAt(1500), isTrue);
      expect(line.isActiveAt(2100), isFalse);
      expect(line.isActiveAt(900), isFalse);
    });
  });
}