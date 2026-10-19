// AMLL 适配层回归：内部歌词模型 → flutter_lyric 文档 / 预设。
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/lyrics/lyric_amll_adapter.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await KvStore.ensureInit();
    await LyricSettings.instance.load();
  });

  Lyrics sample() => const Lyrics(
        hasWordTiming: true,
        hasTranslation: true,
        lines: [
          LyricLine(
            startMs: 1000,
            endMs: 4000,
            text: '曾许下心愿',
            words: [
              LyricWord(startMs: 1000, endMs: 2000, text: '曾'),
              LyricWord(startMs: 2000, endMs: 3000, text: '许'),
              LyricWord(startMs: 3000, endMs: 4000, text: '下'),
            ],
            translation: 'Once made a wish',
          ),
          // 无译文但有罗马音：罗马音应顶上
          LyricLine(
            startMs: 5000,
            endMs: 7000,
            text: '等待你',
            words: [
              LyricWord(startMs: 5000, endMs: 6000, text: '等'),
              LyricWord(startMs: 6000, endMs: 7000, text: '待'),
            ],
            romanization: 'deng dai',
          ),
          // 无有效行止时间 + 无词级：end 传 null、words 传 null
          LyricLine(startMs: 8000, endMs: 0, text: '制作人：…'),
        ],
      );

  test('文档转换：行数、逐字时间轴、译文/罗马音、无效结束时间', () {
    final doc = toLyricDocument(sample());
    expect(doc.lines.length, 3);

    final l0 = doc.lines[0];
    expect(l0.start, const Duration(milliseconds: 1000));
    expect(l0.end, const Duration(milliseconds: 4000));
    expect(l0.translation, 'Once made a wish');
    expect(l0.words?.length, 3);
    expect(l0.words!.first.start, const Duration(milliseconds: 1000));
    expect(l0.words!.last.end, const Duration(milliseconds: 4000));

    // 罗马音顶替译文
    expect(doc.lines[1].translation, 'deng dai');
    expect(doc.lines[1].words?.length, 2);

    // endMs<=0 → null；非词级 → words null（交给引擎模拟逐字）
    expect(doc.lines[2].end, isNull);
    expect(doc.lines[2].words, isNull);
  });

  test('文档按时间排序（乱序输入也要有序）', () {
    const lyrics = Lyrics(lines: [
      LyricLine(startMs: 9000, endMs: 9500, text: '后'),
      LyricLine(startMs: 1000, endMs: 2000, text: '先'),
    ]);
    final doc = toLyricDocument(lyrics);
    expect(doc.lines.first.start, const Duration(milliseconds: 1000));
    expect(doc.lines.last.start, const Duration(milliseconds: 9000));
  });

  test('预设映射：字号/对齐/三色都来自歌词设置', () async {
    final s = LyricSettings.instance;
    final p = lyricPresetFrom(s);

    // 当前行字号 = 正文字号 × 放大系数
    expect(p.activeTextStyle.fontSize,
        closeTo(s.fontSize * s.activeScale, 0.001));
    expect(p.textStyle.fontSize, s.fontSize);
    expect(p.textAlign, s.textAlign);
    // 已唱色必须喂给逐字高亮，否则逐字效果没有颜色差
    final hl = p.highlight;
    expect(hl, isNot(same(null)));
    // 颜色必须三者互不相同，否则等于没有逐字染色
    expect(p.textStyle.color, isNot(p.activeTextStyle.color));
    expect(p.textStyle.color, isNot(p.highlight.toString().isEmpty ? null : null),
        reason: 'highlight 必须带颜色');
    // 用户停止浏览 5 秒后回到当前行（沿用旧实现）
    expect(p.resumeDelay, const Duration(seconds: 5));
    expect(p.interactive, isTrue);
  });

  test('预设映射：远处行保持可读（不被行过渡的 fade 二次打折）', () {
    // v2.3.0-fix5：appleMusic 预设自带 fade(.45)，非当前行不透明度只有
    // 45%，叠加深色底上的 40% 白文字后远处行几乎不可见（实测有效亮度
    // 不到背景 1.15 倍）。这里锁定自建过渡：远处行 ≥0.88、当前行 =1。
    final p = lyricPresetFrom(LyricSettings.instance);
    final inactive = p.lineTransition.state(false);
    expect(inactive.opacity, greaterThanOrEqualTo(0.88));
    expect(p.lineTransition.state(true).opacity, 1.0);
  });
}
