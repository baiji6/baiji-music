import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/lyrics/lyric_parser.dart';
import 'package:baiji_music/lyrics/lyric_serializer.dart';
import 'package:flutter_test/flutter_test.dart';

Lyrics _sample() => Lyrics(
      hasWordTiming: true,
      lines: <LyricLine>[
        LyricLine(
          startMs: 12340,
          endMs: 15600,
          text: '窗外的麻雀',
          words: const <LyricWord>[
            LyricWord(startMs: 12340, endMs: 12560, text: '窗'),
            LyricWord(startMs: 12560, endMs: 12880, text: '外'),
            LyricWord(startMs: 12880, endMs: 13100, text: '的'),
            LyricWord(startMs: 13100, endMs: 14300, text: '麻'),
            LyricWord(startMs: 14300, endMs: 15600, text: '雀'),
          ],
        ),
        // 只有整行时间、没有逐字数据的行
        const LyricLine(startMs: 20000, endMs: 24000, text: '在电线杆上多嘴'),
        // 空行应被丢弃
        const LyricLine(startMs: 30000, endMs: 31000, text: '   '),
      ],
    );

void main() {
  test('逐行 LRC：格式与时间正确，空行被丢弃', () {
    final out = LyricSerializer.toLineLrc(_sample());
    final lines = out.trim().split('\n');
    expect(lines.length, 2);
    expect(lines[0], '[00:12.34]窗外的麻雀');
    expect(lines[1], '[00:20.00]在电线杆上多嘴');
  });

  test('逐字 LRC：行首时间 + 行内每字时间', () {
    final out = LyricSerializer.toWordLrc(_sample());
    final lines = out.trim().split('\n');
    expect(lines[0], '[00:12.34]<00:12.34>窗<00:12.56>外<00:12.88>的'
        '<00:13.10>麻<00:14.30>雀');
    // 无逐字数据的行退化为整行
    expect(lines[1], '[00:20.00]在电线杆上多嘴');
  });

  test('逐字 LRC 能被解析器原样还原（往返一致）', () {
    final src = _sample();
    final text = LyricSerializer.toWordLrc(src);
    final back = LyricParser.parse(text);

    expect(back.length, 2);
    expect(back.hasWordTiming, isTrue);

    final l0 = back[0];
    expect(l0.startMs, 12340);
    expect(l0.displayText, '窗外的麻雀');
    expect(l0.isWordLevel, isTrue);
    expect(l0.words.length, 5);
    for (var i = 0; i < 5; i++) {
      expect(l0.words[i].text, src[0].words[i].text, reason: '第 $i 个字');
      // 百分秒精度，误差应在 10ms 内
      expect((l0.words[i].startMs - src[0].words[i].startMs).abs(),
          lessThanOrEqualTo(10),
          reason: '第 $i 个字的起始时间');
    }
  });

  test('超过一小时的歌词也能正确格式化', () {
    final lrc = Lyrics(lines: <LyricLine>[
      const LyricLine(startMs: 3723450, endMs: 3725000, text: '返场'),
    ]);
    expect(LyricSerializer.toLineLrc(lrc).trim(), '[62:03.45]返场');
  });

  test('toLrc 按 wordLevel 分派', () {
    final src = _sample();
    expect(LyricSerializer.toLrc(src, wordLevel: false),
        isNot(contains('<')));
    expect(LyricSerializer.toLrc(src, wordLevel: true), contains('<00:12.34>'));
  });
}
