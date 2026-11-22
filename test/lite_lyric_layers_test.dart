// 分层渲染的像素级契约测试（v2.6.4）。
//
// v2.6.4 把歌词拆成「静态行层（布局平移）+ 活跃行层（逐帧重绘）」两层，
// 两层必须严格对齐，否则当前行会和相邻行错位、或整体偏出视口。
// 这里直接截图验证三件事：
//   1. 当前行垂直居中（文字块中心 ≈ 视口中心）；
//   2. 居中对齐时水平也居中（左右留白对称）；
//   3. 静态层的相邻行出现在当前行上下方，且间距等于行高。
import 'dart:ui' as ui;

import 'package:baiji_music/core/lyric_settings.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/ui/widgets/lite_lyrics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const double _w = 300;
const double _h = 300;

Lyrics _lyrics() => Lyrics(
      lines: [
        for (var i = 0; i < 5; i++)
          LyricLine(
            startMs: i * 10000,
            endMs: (i + 1) * 10000,
            text: 'AAA$i',
          ),
      ],
      hasWordTiming: false,
    );

/// 截取渲染结果，返回「非透明像素」的包围盒统计。
Future<List<Rect>> _textBands(WidgetTester tester, Key key) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
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

  // 逐行统计「亮像素」数量，得到若干连续的文本带。
  final rows = List<int>.filled(ih, 0);
  for (var y = 0; y < ih; y++) {
    var count = 0;
    for (var x = 0; x < iw; x++) {
      final a = bytes[(y * iw + x) * 4 + 3];
      if (a > 40) count++;
    }
    rows[y] = count;
  }
  final bands = <Rect>[];
  var start = -1;
  for (var y = 0; y < ih; y++) {
    final on = rows[y] > 0;
    if (on && start < 0) start = y;
    if (!on && start >= 0) {
      bands.add(Rect.fromLTRB(0, start.toDouble(), 0, y.toDouble()));
      start = -1;
    }
  }
  if (start >= 0) bands.add(Rect.fromLTRB(0, start.toDouble(), 0, ih.toDouble()));

  // 每段的水平范围。
  final out = <Rect>[];
  for (final b in bands) {
    var minX = iw, maxX = -1;
    for (var y = b.top.toInt(); y < b.bottom.toInt(); y++) {
      for (var x = 0; x < iw; x++) {
        final a = bytes[(y * iw + x) * 4 + 3];
        if (a > 40) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
        }
      }
    }
    if (maxX >= minX) {
      out.add(Rect.fromLTRB(
          minX.toDouble(), b.top, maxX + 1.0, b.bottom));
    }
  }
  return out;
}

void main() {
  testWidgets('分层渲染：垂直居中 + 左对齐贴边 + 行距一致', (tester) async {
    tester.view.physicalSize = const Size(_w, _h);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    LyricSettings.instance.applyForTest(alignLeft: true);
    final key = GlobalKey();
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
                lyrics: _lyrics(),
                onSeek: (_) async {},
                // 停在第 2 行中间
                positionProvider: () => const Duration(milliseconds: 25000),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    // 首帧就位后还有一段指数逼近（tau≈130ms），跑满 ~600ms 再截图
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final bands = await _textBands(tester, key);
    expect(bands.length, greaterThanOrEqualTo(3),
        reason: '至少应看到当前行与上下相邻行');

    // 当前行 = 第 2 行（文本 AAA2），三行里最靠中间的那条。
    bands.sort((a, b) => a.center.dy.compareTo(b.center.dy));
    final mid = bands[bands.length ~/ 2];
    expect(mid.center.dy, closeTo(_h / 2, 3.0), reason: '当前行垂直居中');
    // 默认左对齐：文字左边界 = 安全边距 24
    expect(mid.left, closeTo(24.0, 2.0),
        reason: '左对齐贴安全边距');

    // 相邻行的中心间距 == 行高（两层对齐：静态层布局平移与活跃层画布坐标
    // 必须落在同一个公式上，否则当前行会和上下行错位/重叠）
    final i = bands.indexOf(mid);
    final extent = LyricSettings.instance.fontSize * 1.25 +
        LyricSettings.instance.fontSize * 0.8;
    if (i > 0) {
      final gap = mid.center.dy - bands[i - 1].center.dy;
      expect(gap, closeTo(extent, 3.0), reason: '上一行间距 = 行高');
    }
    if (i + 1 < bands.length) {
      final gap = bands[i + 1].center.dy - mid.center.dy;
      expect(gap, closeTo(extent, 3.0), reason: '下一行间距 = 行高');
    }
  });

  testWidgets('浏览中切行：旧行回到静态层（不出现整行空洞）', (tester) async {
    tester.view.physicalSize = const Size(_w, _h);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    LyricSettings.instance.applyForTest(alignLeft: true);

    final pos = ValueNotifier<Duration>(const Duration(milliseconds: 5000));
    final key = GlobalKey();
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
                lyrics: _lyrics(),
                onSeek: (_) async {},
                positionProvider: () => pos.value,
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    // 1) 正常播到第 1 行：滚动触发的重建会让静态层「跳过当前行」重画一次。
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    pos.value = const Duration(milliseconds: 15000);
    await tester.pump();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // 2) 拖动进入浏览态：此后播放继续切行，但**不会自动滚动**，
    //    静态层没有任何重建机会，只能靠切行重绘信号把旧活跃行画回去。
    await tester.drag(find.byType(LiteLyricsView), const Offset(0, -30));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    pos.value = const Duration(milliseconds: 25000); // 切到第 2 行
    await tester.pump();
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final bands = await _textBands(tester, key);
    bands.sort((a, b) => a.center.dy.compareTo(b.center.dy));
    expect(bands.length, greaterThanOrEqualTo(3));
    final extent = LyricSettings.instance.fontSize * 1.25 +
        LyricSettings.instance.fontSize * 0.8;
    for (var k = 1; k < bands.length; k++) {
      final gap = bands[k].center.dy - bands[k - 1].center.dy;
      expect(gap, lessThan(extent * 1.5),
          reason: '相邻文字带之间不应出现整行空洞（旧活跃行没被画回）');
    }
  });

  testWidgets('分层渲染：居中模式下文字水平居中', (tester) async {
    tester.view.physicalSize = const Size(_w, _h);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    LyricSettings.instance.applyForTest(alignLeft: false);

    final key = GlobalKey();
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
                lyrics: _lyrics(),
                onSeek: (_) async {},
                positionProvider: () => const Duration(milliseconds: 25000),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final bands = await _textBands(tester, key);
    bands.sort((a, b) => a.center.dy.compareTo(b.center.dy));
    final mid = bands[bands.length ~/ 2];
    expect(mid.center.dx, closeTo(_w / 2, 3.0), reason: '文字块左右对称');
  });
}
