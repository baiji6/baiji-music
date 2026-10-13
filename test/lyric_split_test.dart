// v2.2.6 分句拆行回归。
//
// 需求背景：QQ 的 QRC 会把两个分句放进同一行同一个时间片
// （「而那些昨日 依然缤纷着 / 它们都有我 细心收藏着」），
// 渲染时整行同步染色——两句被当成一句处理。解析层现在按行内
// 显著停顿拆行，复刻网易云等播放器的人工分行效果。
import 'package:baiji_music/lyrics/lyric_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一行 QRC：`[起始,时长]字(偏移,时长)字...`，字间隔由 [gapMs] 指定
/// （cutIndex 处的间隔单独给 [bigGapMs]，用于制造分句气口）。
/// 偏移是「上一字结束 → 下一字开始」的间隔 + 本字之前的累计。
String _qrc(List<String> chars, int startMs, int lineDur,
    {int gapMs = 250, int? bigGapMs, int? bigGapIndex}) {
  final sb = StringBuffer('[$startMs,$lineDur]');
  var offset = 0;
  for (var i = 0; i < chars.length; i++) {
    if (i > 0) {
      // 字时长 250：偏移增量 = 间隔 + 250
      offset += 250 + (i == bigGapIndex ? bigGapMs! : gapMs);
    }
    sb.write('${chars[i]}($offset,250)');
  }
  return sb.toString();
}

void main() {
  group('分句拆行（QRC 一行两句）', () {
    test('行内大气口拆成两行，各自独立起止时间', () {
      // 11 字 + 9 字，中间 900ms 气口
      final raw = _qrc(
        ['而', '那', '些', '昨', '日', '依', '然', '缤', '纷', '着', '它',
         '们', '都', '有', '我', '细', '心', '收', '藏', '着'],
        0,
        8000,
        bigGapMs: 900,
        bigGapIndex: 10,
      );
      final lyrics = LyricParser.parse(raw);
      expect(lyrics.isNotEmpty, true);
      expect(lyrics.length, 2, reason: '应拆成两行');

      final a = lyrics[0];
      final b = lyrics[1];
      expect(a.text, '而那些昨日依然缤纷着');
      expect(b.text, '它们都有我细心收藏着');
      // 第一行唱到气口前为止，第二行从气口后开始
      expect(a.startMs, 0);
      expect(a.endMs, greaterThan(b.startMs - 100));
      expect(a.endMs, lessThan(b.startMs));
      expect(b.endMs, 8000);
      // 拆完仍是逐字（卡拉 OK 继续生效）
      expect(a.isWordLevel, true);
      expect(b.isWordLevel, true);
      expect(lyrics.hasWordTiming, true);
      // 行时间不重叠、有序
      expect(a.endMs <= b.startMs, true);
    });

    test('译文只挂第一段，不重复', () {
      final raw = _qrc(
        ['而', '那', '些', '昨', '日', '依', '然', '缤', '纷', '着', '它',
         '们', '都', '有', '我', '细', '心', '收', '藏', '着'],
        0,
        8000,
        bigGapMs: 900,
        bigGapIndex: 10,
      );
      final lyrics = LyricParser.parse(
        raw,
        translation: '[00:00.00]那些昨日都有我收藏',
      );
      expect(lyrics.length, 2);
      expect(lyrics[0].translation, isNotNull);
      expect(lyrics[1].translation, isNull);
    });

    test('字间小停顿（250ms）不拆', () {
      final raw = _qrc(
        ['飞', '向', '避', '风', '的', '海', '港'],
        0,
        3000,
      );
      final lyrics = LyricParser.parse(raw);
      expect(lyrics.length, 1);
      expect(lyrics[0].text, '飞向避风的海港');
    });

    test('相对停顿（慢歌、绝对间隔不足 800ms）也拆', () {
      // 字均间隔 120ms，中位 120；第 6 字后 640ms ≥ 5×120 且 ≥ 500
      final raw = _qrc(
        ['慢', '慢', '走', '走', '停', '下', '来', '歇', '一', '会'],
        0,
        4000,
        gapMs: 120,
        bigGapMs: 640,
        bigGapIndex: 6,
      );
      final lyrics = LyricParser.parse(raw);
      expect(lyrics.length, 2);
      expect(lyrics[0].text, '慢慢走走停下');
      expect(lyrics[1].text, '来歇一会');
    });

    test('切点会把行尾锯成单字时不拆（保整）', () {
      // 大气口出现在最后一个字之前：右段只有 1 字，放弃该切点
      final raw = _qrc(
        ['一', '二', '三', '四', '五', '六', '七', '八', '九', '十'],
        0,
        4000,
        gapMs: 200,
        bigGapMs: 900,
        bigGapIndex: 9,
      );
      final lyrics = LyricParser.parse(raw);
      expect(lyrics.length, 1);
    });

    test('普通 LRC（无逐字）长行不拆', () {
      const raw = '[00:10.00]而那些昨日依然缤纷着它们都有我细心收藏着\n'
          '[00:20.00]下一句';
      final lyrics = LyricParser.parse(raw);
      expect(lyrics.length, 2);
      expect(lyrics[0].text, '而那些昨日依然缤纷着它们都有我细心收藏着');
      expect(lyrics[0].isWordLevel, false);
    });

    test('多个气口最多拆三段', () {
      // 两处 900ms 气口 → 三段
      final raw2 = '[0,9000]'
          '一(0,250)二(450,250)三(900,250)四(1350,250)五(1800,250)'
          '六(2950,250)七(3400,250)八(3850,250)九(4300,250)十(4750,250)'
          '十(5900,250)一(6350,250)二(6800,250)';
      final lyrics = LyricParser.parse(raw2);
      expect(lyrics.length, 3);
      expect(lyrics[0].text, '一二三四五');
      expect(lyrics[1].text, '六七八九十');
      expect(lyrics[2].text, '十一二');
      // 拆出的行连续覆盖原行时间范围
      expect(lyrics[0].startMs, 0);
      expect(lyrics[2].endMs, 9000);
      for (var i = 0; i < lyrics.length - 1; i++) {
        expect(lyrics[i].endMs, lessThan(lyrics[i + 1].startMs));
      }
    });
  });
}
