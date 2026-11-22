// 繁体 → 简体歌词转换测试（v2.6.4）。
//
// 表数据来自 OpenCC（TSCharacters / TSPhrases）裁剪，测试固化三件事：
//   1. 常用繁体字能正确转简体；
//   2. 「一繁对多简 / 会误伤」的字有词组保护（乾隆 / 著名 / 瞭解 / 藉口）；
//   3. 等长替换——逐字时间轴的下标与时间完全不变，扫光不会错位。
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/lyrics/trad_to_simp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tradToSimp 单字', () {
    test('常用繁体转简体', () {
      expect(tradToSimp('我們的愛'), '我们的爱');
      expect(tradToSimp('時間'), '时间');
      expect(tradToSimp('後來'), '后来');
      expect(tradToSimp('頭髮亂了'), '头发乱了');
      expect(tradToSimp('關於'), '关于');
      expect(tradToSimp('鐘聲'), '钟声');
      expect(tradToSimp('乾淨'), '干净');
      expect(tradToSimp('一隻貓'), '一只猫');
      expect(tradToSimp('裡面'), '里面');
      expect(tradToSimp('鬱悶'), '郁闷');
    });

    test('台湾用字：妳 / 牠 / 祂 / 著', () {
      expect(tradToSimp('妳好嗎'), '你好吗');
      expect(tradToSimp('牠走了'), '它走了');
      expect(tradToSimp('祂說'), '他说');
      expect(tradToSimp('我想著你'), '我想着你');
      expect(tradToSimp('穿著大衣'), '穿着大衣');
    });

    test('一繁对多简靠词组消歧', () {
      expect(tradToSimp('乾隆皇帝'), '乾隆皇帝'); // 人名不能变「干隆」
      expect(tradToSimp('乾坤'), '乾坤');
      expect(tradToSimp('乾淨'), '干净');
      expect(tradToSimp('瞭解這件事'), '了解这件事');
      expect(tradToSimp('一目瞭然'), '一目了然');
      expect(tradToSimp('藉口'), '借口');
      expect(tradToSimp('憑藉'), '凭借');
    });

    test('「著」读 zhù 的词被保护', () {
      expect(tradToSimp('著名的著作'), '著名的著作');
      expect(tradToSimp('顯著'), '显著');
      expect(tradToSimp('著作權'), '著作权');
      expect(tradToSimp('土著'), '土著');
    });

    test('简体原文零改动', () {
      const s = '我们的爱情故事';
      expect(tradToSimp(s), s);
      // 整份歌词层面才要求「同对象」：纯简体歌词不会重建任何行对象，
      // 见下面 tradToSimpLyrics 的 identical 断言。
      expect(tradToSimpLyrics(const Lyrics(lines: [
        LyricLine(startMs: 0, endMs: 1, text: '我们的爱情故事'),
      ])).lines.single.text, s);
    });

    test('空串与非中文原样返回', () {
      expect(tradToSimp(''), '');
      expect(tradToSimp('hello world'), 'hello world');
      expect(tradToSimp('123 ♪'), '123 ♪');
    });

    test('emoji / 非 BMP 字符不被破坏', () {
      expect(tradToSimp('我們的愛 🎵'), '我们的爱 🎵');
      expect(tradToSimp('🎵'), '🎵');
    });

    test('转换等长（逐字下标可复用）', () {
      const samples = [
        '我們的愛',
        '乾隆皇帝',
        '瞭解這件事',
        '妳好嗎',
        '頭髮亂了',
        '鬱悶的夜晚',
      ];
      for (final s in samples) {
        expect(tradToSimp(s).length, s.length, reason: s);
      }
    });
  });

  group('tradToSimpLyrics', () {
    const line = LyricLine(
      startMs: 1000,
      endMs: 4000,
      text: '我想著妳',
      words: [
        LyricWord(startMs: 1000, endMs: 1600, text: '我'),
        LyricWord(startMs: 1600, endMs: 2200, text: '想'),
        LyricWord(startMs: 2200, endMs: 2800, text: '著'),
        LyricWord(startMs: 2800, endMs: 3400, text: '妳'),
      ],
    );

    test('逐字文本转换后时间与长度不变', () {
      const src = Lyrics(lines: [line], hasWordTiming: true);
      final out = tradToSimpLyrics(src);
      final l = out.lines.single;
      expect(l.displayText, '我想着你');
      expect(l.words.length, 4);
      expect(l.words.map((w) => w.text).join(), '我想着你');
      for (var i = 0; i < 4; i++) {
        expect(l.words[i].startMs, line.words[i].startMs);
        expect(l.words[i].endMs, line.words[i].endMs);
      }
      expect(out.hasWordTiming, isTrue);
    });

    test('译文一并转换', () {
      const src = Lyrics(lines: [
        LyricLine(
          startMs: 0,
          endMs: 1000,
          text: '我們的愛',
          translation: '我們的愛情',
        ),
      ]);
      final out = tradToSimpLyrics(src);
      expect(out.lines.single.translation, '我们的爱情');
    });

    test('整份歌词都不需要转换时返回原对象', () {
      const src = Lyrics(lines: [
        LyricLine(startMs: 0, endMs: 1000, text: '我们的爱'),
      ]);
      expect(identical(tradToSimpLyrics(src), src), isTrue);
    });

    test('空歌词安全', () {
      expect(identical(tradToSimpLyrics(Lyrics.empty), Lyrics.empty), isTrue);
    });

    test('表规模合理（防止误删数据）', () {
      final stats = debugTableStats();
      expect(stats.chars, greaterThan(2500));
      expect(stats.phrases, greaterThan(250));
    });
  });
}
