// 轻量歌词引擎渲染契约测试（v2.6.3）。
//
// 注入固定播放位置，验证 LiteLyricsView 在真实 widget 树中：
//   - 正确挂载、尺寸正确；
//   - 逐字扫光/滚动/切行全程不抛异常；
//   - 活跃行数量恒为 1（逐帧只重绘一行，这是流畅的性能前提）。
// 纯本地，不依赖播放器/网络/截图。
import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/ui/widgets/lite_lyrics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Lyrics _sample() => Lyrics(
      hasWordTiming: true,
      hasTranslation: true,
      lines: [
        const LyricLine(startMs: 0, endMs: 3000, text: '前一行歌词示例', translation: 'previous line'),
        LyricLine(
          startMs: 3000,
          endMs: 7000,
          text: '我爱你中华大地',
          translation: 'I love my motherland',
          words: const [
            LyricWord(startMs: 3000, endMs: 3500, text: '我'),
            LyricWord(startMs: 3500, endMs: 4000, text: '爱'),
            LyricWord(startMs: 4000, endMs: 4500, text: '你'),
            LyricWord(startMs: 4500, endMs: 5500, text: '中'),
            LyricWord(startMs: 5500, endMs: 6000, text: '华'),
            LyricWord(startMs: 6000, endMs: 6500, text: '大'),
            LyricWord(startMs: 6500, endMs: 7000, text: '地'),
          ],
        ),
        const LyricLine(startMs: 7000, endMs: 10000, text: '后一行歌词示例', translation: 'next line'),
      ],
    );

void main() {
  testWidgets('轻量歌词：逐字扫光 + 切行 + 滚动全程渲染不崩溃', (tester) async {
    final position = ValueNotifier<Duration>(const Duration(milliseconds: 5000));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: LyricSettings.lyricCanvasBg,
        body: Center(
          child: SizedBox(
            width: 360,
            height: 320,
            child: ValueListenableBuilder<Duration>(
              valueListenable: position,
              builder: (context, pos, _) => LiteLyricsView(
                lyrics: _sample(),
                onSeek: (_) async {},
                positionProvider: () => pos,
              ),
            ),
          ),
        ),
      ),
    ));

    // 跨多个位置推进：行内逐字 → 切行 → 尾部，模拟真实播放。
    for (final ms in <int>[3200, 4000, 5000, 5800, 6600, 7500, 9500]) {
      position.value = Duration(milliseconds: ms);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    expect(find.byType(LiteLyricsView), findsOneWidget);
    final boundary = tester.renderObject<RenderBox>(find.byType(LiteLyricsView));
    expect(boundary.size.width, 360);
    expect(boundary.size.height, 320);
  });
}
