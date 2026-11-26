// v2.6.6-fix1 回归：长歌词折两行 + 译文独立居中 + 逐行扫光不串色。
//
// 用像素截图验证三件事：
//   1. 超长主文本在窄视口下折成两行（出现两个垂直文字带）；
//   2. 居中模式下，主文本与译文各自按自身宽度水平居中；
//   3. 两行主文本渲染中途渲染不崩溃（逐行 clip 逻辑走通）。
import 'dart:ui' as ui;

import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/ui/widgets/lite_lyrics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const double _w = 260;
const double _h = 320;

/// 统计非透明像素的行带（每条带 = 一行文字）。
Future<List<Rect>> _bands(WidgetTester tester, Key key) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  late ui.Image image;
  await tester.runAsync(() async {
    image = await boundary.toImage();
  });
  final data = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba));
  if (data == null) return const [];
  final bytes = data.buffer.asUint8List();
  final iw = image.width;
  final ih = image.height;
  final rows = List<int>.filled(ih, 0);
  for (var y = 0; y < ih; y++) {
    var c = 0;
    for (var x = 0; x < iw; x++) {
      if (bytes[(y * iw + x) * 4 + 3] > 40) c++;
    }
    rows[y] = c;
  }
  final out = <Rect>[];
  var start = -1;
  var minX = iw;
  var maxX = -1;
  for (var y = 0; y <= ih; y++) {
    final on = y < ih && rows[y] > 0;
    if (on && start < 0) {
      start = y;
      minX = iw;
      maxX = -1;
    }
    if (on) {
      for (var x = 0; x < iw; x++) {
        if (bytes[(y * iw + x) * 4 + 3] > 40) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
        }
      }
    }
    if (!on && start >= 0) {
      if (maxX >= minX) {
        out.add(Rect.fromLTRB(minX.toDouble(), start.toDouble(),
            maxX + 1.0, y.toDouble()));
      }
      start = -1;
    }
  }
  return out;
}

Future<void> _pumpView(
  WidgetTester tester,
  GlobalKey key,
  Lyrics lyrics, {
  required bool alignLeft,
}) async {
  tester.view.physicalSize = const Size(_w, _h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  LyricSettings.instance.applyForTest(
    alignLeft: alignLeft,
    fontSize: 24,
  );
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: _w,
            height: _h,
            child: LiteLyricsView(
              lyrics: lyrics,
              onSeek: (_) async {},
              positionProvider: () => const Duration(milliseconds: 1500),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  for (var i = 0; i < 45; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('超长歌词折两行 + 逐行扫光不崩溃', (tester) async {
    final lyrics = Lyrics(
      lines: [
        LyricLine(
          startMs: 1000,
          endMs: 6000,
          // 远窄于 _w 的可用宽度，必然折成两行。
          text: '这是一句非常非常非常非常非常非常非常非常非常长的歌词文本',
          words: [
            for (var i = 0; i < 24; i++)
              LyricWord(
                  text: '字', startMs: 1000 + i * 200, endMs: 1200 + i * 200),
          ],
        ),
      ],
      hasWordTiming: true,
    );
    final key = GlobalKey();
    await _pumpView(tester, key, lyrics, alignLeft: true);
    final bands = await _bands(tester, key);
    // 单行 + 译文 = 1 条带；折两行后主文本应出现 2 条带。
    expect(bands.length, greaterThanOrEqualTo(2),
        reason: '超长主文本应折成两行（≥2 条文字带），不能省略成一行');
  });

  testWidgets('居中模式：译文按自身宽度独立居中', (tester) async {
    final lyrics = Lyrics(
      lines: [
        LyricLine(
          startMs: 1000,
          endMs: 6000,
          text: 'an extremely long english lyric line here',
          translation: '中文翻译',
        ),
      ],
      hasWordTiming: false,
    );
    final key = GlobalKey();
    await _pumpView(tester, key, lyrics, alignLeft: false);
    final bands = await _bands(tester, key);
    expect(bands.length, greaterThanOrEqualTo(2),
        reason: '主文本 + 译文应形成两条文字带');
    // 译文带（下方那条）中心应接近视口水平中心，而不是贴主文本起点。
    bands.sort((a, b) => a.top.compareTo(b.top));
    final sub = bands.last;
    expect(sub.center.dx, closeTo(_w / 2, 12.0),
        reason: '译文应按下自身宽度水平居中：${sub.center.dx} vs ${_w / 2}');
  });
}
