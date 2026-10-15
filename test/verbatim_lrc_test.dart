// fix4：Lyrico 写入音频标签的 VERBATIM 逐字歌词格式复现。
//
// Lyrico `appendVerbatimOriginalLine` 产出的格式：一行内每个词各带一个
// `[mm:ss.xx]` 时间戳（标签即分隔符）：
//   [00:01.00]Moon[00:01.50]Halo[00:02.00]崩[00:02.50]
// 解析结果必须是「一行 + 词级时间轴」，而不是每词一行。
import 'package:baiji_music/lyrics/lyric_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('VERBATIM：一行多词多时间戳 → 单行 + 词级时间轴', () {
    const raw = '[ti:Moon Halo]\n'
        '[ar:茶理理子]\n'
        '[00:01.00]Moon[00:01.50]Halo[00:02.00]崩\n'
        '[00:03.00]坏[00:03.50]3[00:04.00]《\n'
        '[00:05.00]薪[00:05.50]炎[00:06.00]永[00:06.50]燃[00:07.00]\n';
    final ly = LyricParser.parse(raw);
    expect(ly.lines.length, 3,
        reason: '3 个物理行 = 3 个歌词行，不能拆成 13 个单字行');
    expect(ly.hasWordTiming, isTrue);
    final first = ly.lines.first;
    expect(first.text, 'MoonHalo崩');
    expect(first.isWordLevel, isTrue);
    expect(first.words.map((w) => w.text).toList(), ['Moon', 'Halo', '崩']);
    expect(first.words.map((w) => w.startMs).toList(), [1000, 1500, 2000]);
    // 词进度：播放到 1.75s 时第二个词唱了一半
    expect(first.words[1].progressAt(1750), closeTo(0.5, 0.01));
  });

  test('VERBATIM：译文（独立原始文本）按时间窗挂到原词行', () {
    const raw = '[00:01.00]Moon[00:01.50]Halo\n';
    final ly = LyricParser.parse(raw,
        translation: '[00:01.00]月光 黎明\n');
    expect(ly.lines.length, 1);
    expect(ly.lines.first.translation, '月光 黎明');
  });

  test('经典 LRC：行首多时间戳仍指向同一句（不拆行）', () {
    const raw = '[00:12.00][00:20.00]Same lyrics\n';
    final ly = LyricParser.parse(raw);
    expect(ly.lines.length, 1);
    expect(ly.lines.first.text, 'Same lyrics');
  });
}
