// 逐字渲染像素级回归（AMLL / 倾听同款语义）。
//
// 直接调用生产代码 measureKaraokeLine + KaraokePainter 离屏绘制，
// 逐像素断言：
//   1. 词中时刻的亮/暗边界位置与羽化宽度（front = l + w·ratio − F·(1−ratio)，
//      F = 0.5 × 行高）；
//   2. 逐词独立（已唱词全亮、未唱词全暗，边界不互相渗透）；
//   3. 换行后每个视觉行独立遮罩（2.3.0 修复的核心主张）；
//   4. 居中 / 右对齐时墨迹落在正确位置（fix1 的 _dx 补偿不回归）。
//
// 说明：
// - 颜色用纯绿（已唱）/ 纯红（未唱），逐像素断言可精确到个位数像素；
// - 文本用拉丁字母：Ahem 测试字体只覆盖 245 个 codepoint（无 CJK），
//   每个字形是宽 1em 的实心盒，坐标可精确计算；
// - image.toByteData() 必须包在 tester.runAsync 里——fakeAsync 下
//   栅格读取的 future 永不完成，直接 await 会挂死（探针实测）。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:baiji_music/ui/widgets/karaoke_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 已唱 = 纯绿，未唱 = 纯红（直接传给 measureKaraokeLine，
/// 不走 LyricSettings，避开可读性回退）。
const Color _sung = Color(0xFF00FF00);
const Color _unsung = Color(0xFFFF0000);

const double _fontSize = 24.0;
const double _height = 1.32;

/// 羽化宽度 = 24 × 1.32 × 0.5 = 15.84（AMLL wordFadeWidth=0.5）。
const double _feather = _fontSize * _height * 0.5;

/// 「ABCDE」五个单字词，每个 1000ms，每词宽 1em = 24px。
LyricLine _fiveWords() {
  const chars = ['A', 'B', 'C', 'D', 'E'];
  return LyricLine(
    startMs: 0,
    endMs: 5000,
    text: chars.join(),
    words: [
      for (var i = 0; i < chars.length; i++)
        LyricWord(startMs: i * 1000, endMs: (i + 1) * 1000, text: chars[i]),
    ],
  );
}

class _Frame {
  _Frame(this.data, this.width, this.height, this.rows);
  final ByteData data;
  final int width;
  final int height;

  /// measureKaraokeLine 量出的视觉行（断言用）。
  final List<KaraokeRow> rows;
}

/// 离屏绘制一帧（真实生产代码路径）。
Future<_Frame> _renderFrame({
  required LyricLine line,
  required int posMs,
  required double maxWidth,
  required WidgetTester tester,
  TextAlign align = TextAlign.left,
  double fontSize = _fontSize,
  double height = _height,
}) async {
  final layout = measureKaraokeLine(
    words: line.words,
    maxWidth: maxWidth,
    fontSize: fontSize,
    height: height,
    align: align,
    weight: FontWeight.w400,
    sungColor: _sung,
    unsungColor: _unsung,
  );
  final ratios = [
    for (final w in line.words) w.progressAt(posMs),
  ];
  final painter =
      layout.painter(ratios: ratios, align: align, maxWidth: maxWidth);
  final h = layout.unsungPainter.height;
  final recorder = ui.PictureRecorder();
  painter.paint(ui.Canvas(recorder), Size(maxWidth, h));
  final image =
      await recorder.endRecording().toImage(maxWidth.toInt(), h.ceil());
  // runAsync 给真实事件循环；内层 ! 把 toByteData 的 ByteData? 拍实，
  // 外层 ! 拍实 runAsync 的 T?。
  final data =
      (await tester.runAsync(() async => (await image.toByteData())!))!;
  image.dispose();
  return _Frame(data, maxWidth.toInt(), h.ceil(), layout.rows);
}

/// 像素的 0~255 分量（Color 的 r/g/b/a 是归一化 double，断言不便）。
class _Px {
  _Px(this.r, this.g, this.b, this.a);
  final int r;
  final int g;
  final int b;
  final int a;
  @override
  String toString() => '($r,$g,$b,$a)';
}

_Px _px(_Frame f, int x, int y) {
  final o = (y * f.width + x) * 4;
  return _Px(
    f.data.getUint8(o),
    f.data.getUint8(o + 1),
    f.data.getUint8(o + 2),
    f.data.getUint8(o + 3),
  );
}

/// 非透明像素的外接盒。
Rect _inkBounds(_Frame f) {
  var minX = 1 << 30, maxX = -1, minY = 1 << 30, maxY = -1;
  for (var y = 0; y < f.height; y++) {
    for (var x = 0; x < f.width; x++) {
      if (_px(f, x, y).a > 8) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  return Rect.fromLTRB(minX.toDouble(), minY.toDouble(), maxX.toDouble(),
      maxY.toDouble());
}

/// 判定像素偏向：G=已唱绿，R=未唱红，?=其他。
String _classify(_Px c) {
  if (c.a < 8) return ' ';
  if (c.g > 100 && c.r < 100) return 'G';
  if (c.r > 100 && c.g < 100) return 'R';
  return '?';
}

/// 词盒内是否存在接近目标色的墨迹。
///
/// Ahem 字形内部有半透明十字结构，单点采样会采到结构像素（绿/红
/// 混合），扫描整盒找纯色墨迹对结构免疫。
bool _hasColorIn(_Frame f, Rect box, int r, int g, int b,
    {int tol = 30}) {
  for (var y = box.top.toInt(); y <= box.bottom.toInt(); y++) {
    for (var x = box.left.toInt(); x <= box.right.toInt(); x++) {
      final p = _px(f, x, y);
      if ((p.r - r).abs() <= tol &&
          (p.g - g).abs() <= tol &&
          (p.b - b).abs() <= tol) {
        return true;
      }
    }
  }
  return false;
}

void main() {
  // ===== 1. 词中时刻：AMLL 边界公式 =====
  testWidgets('词中时刻：front=l+w·ratio−F·(1−ratio)，羽化宽=半个行高',
      (tester) async {
    final f = await _renderFrame(
        line: _fiveWords(), posMs: 2500, maxWidth: 200, tester: tester);
    // 布局 sanity：5 个词、单视觉行
    expect(f.rows.length, 1, reason: '200px 宽放得下 5 个 24px 字');
    expect(f.rows.first.wordIndexes, [0, 1, 2, 3, 4]);

    // posMs=2500：A/B 已唱完（全绿），C ratio=0.5，D/E 未唱（全红）。
    // C 词盒 [48, 72]：front = 48 + 24·0.5 − F·(1−0.5)，过渡带 [front, front+F]
    // （AMLL 几何：过渡带宽恒等于 F，与词宽无关）。
    final front = 48 + 24 * 0.5 - _feather * (1 - 0.5);
    final bandEnd = front + _feather;
    final y = (_inkBounds(f).center.dy).round();
    expect(_px(f, 12, y).g, greaterThan(200), reason: 'A=已唱绿');
    expect(_px(f, 12, y).r, lessThan(60));
    expect(_px(f, 36, y).g, greaterThan(200), reason: 'B=已唱绿');
    // C：front 之前纯绿
    expect(_px(f, (front - 2).round(), y).g, greaterThan(200),
        reason: 'C 左缘（front 前）全亮');
    // 过渡带中点 x=front+F/2：alpha=0.5 → 红绿各半
    final midX = (front + _feather / 2).round();
    final mid = _px(f, midX, y);
    expect((mid.r - 128).abs(), lessThan(20),
        reason: '过渡带中点($midX)红分量≈128');
    expect((mid.g - 128).abs(), lessThan(20),
        reason: '过渡带中点($midX)绿分量≈128');
    // 过渡带右缘之后：纯未唱红
    expect(_px(f, (bandEnd + 2).round(), y).r, greaterThan(200),
        reason: 'C 右缘（带后）全暗');
    expect(_px(f, (bandEnd + 2).round(), y).g, lessThan(60));
    // 未唱词全红
    expect(_px(f, 84, y).r, greaterThan(200), reason: 'D=未唱红');
    expect(_px(f, 108, y).r, greaterThan(200), reason: 'E=未唱红');

    // 羽化宽度：带内线性过渡。近前端 alpha 高 → 以绿为主
    final near = _px(f, (front + 3).round(), y);
    expect(near.g, greaterThan(180), reason: '带内近前端仍以绿为主');
    expect(near.r, lessThan(90));
    // 近后端 alpha 低 → 以红为主
    final far = _px(f, (bandEnd - 1).round(), y);
    expect(far.r, greaterThan(200), reason: '带内近后端已以红为主');
    expect(far.g, lessThan(90));
    // 50% 交叉点应落在带中心 front+F/2 附近（±4px）
    var cross = -1;
    for (var x = front.round(); x <= (bandEnd + 4).round(); x++) {
      if (_px(f, x, y).g < _px(f, x, y).r) {
        cross = x;
        break;
      }
    }
    expect(cross, greaterThan(front.round() + 3), reason: '50% 交叉点≈带中心');
    expect(cross, lessThan(bandEnd.round() - 3));
  });

  // ===== 2. 逐词独立：前一词唱完不渗色到下一词 =====
  testWidgets('逐词独立：词边界处绿→红硬切换', (tester) async {
    // posMs=1000：A 恰好唱完（ratio=1），B 未开口（ratio=0）。
    final f = await _renderFrame(
        line: _fiveWords(), posMs: 1000, maxWidth: 200, tester: tester);
    // 词盒（Ahem 每词 1em=24px 宽）：A=[0,24] B=[24,48]
    const boxA = Rect.fromLTRB(0, 0, 24, 31);
    const boxB = Rect.fromLTRB(24, 0, 48, 31);
    expect(_hasColorIn(f, boxA, 0, 255, 0), isTrue, reason: 'A 词盒内应有纯已唱绿');
    expect(_hasColorIn(f, boxB, 255, 0, 0), isTrue, reason: 'B 词盒内应有纯未唱红');
    // 关键：A 唱完的绿色不渗入未唱的 B（B 盒内没有任何绿墨）
    expect(_hasColorIn(f, boxB, 0, 255, 0), isFalse,
        reason: '已唱词的绿色不渗入未唱词');
  });

  // ===== 3. 换行：每个视觉行独立遮罩 =====
  testWidgets('换行：视觉行独立遮罩（第二行从 x=0 重新扫掠）', (tester) async {
    // 60px 宽 → 5 个 24px 字换行成 [AB][CD][E] 三个视觉行。
    final f = await _renderFrame(
        line: _fiveWords(), posMs: 2500, maxWidth: 60, tester: tester);
    expect(f.rows.length, 3, reason: '60px 宽应换行成 3 个视觉行');
    expect(f.rows[0].wordIndexes, [0, 1]);
    expect(f.rows[1].wordIndexes, [2, 3]);
    expect(f.rows[2].wordIndexes, [4]);

    // posMs=2500：行1（A/B）全唱完 → 整行绿；
    // 行2：C ratio=0.5（front = 0 + 24·0.5 − F·0.5，带 [front, front+F]），
    // D 未唱 → 红；行3（E）未唱 → 红。
    final front2 = 24 * 0.5 - _feather * 0.5;
    final bandEnd2 = front2 + _feather;
    final lineH = _fontSize * _height; // 31.68
    int rowY(int r) => (r * lineH + lineH / 2).round();
    // 行1：全绿
    expect(_classify(_px(f, 12, rowY(0))), 'G', reason: '行1 左字全绿');
    expect(_classify(_px(f, 36, rowY(0))), 'G', reason: '行1 右字全绿');
    // 行2：C 的扫掠在**本行** x≈0 起步（不是接在行1 内容后面）
    expect(_classify(_px(f, 1, rowY(1))), 'G', reason: '行2 C 左缘（front 前）全亮');
    final mid2 = _px(f, (front2 + _feather / 2).round(), rowY(1));
    expect((mid2.r - 128).abs(), lessThan(25), reason: '行2 过渡带中点');
    expect((mid2.g - 128).abs(), lessThan(25));
    expect(_classify(_px(f, (bandEnd2 + 2).round(), rowY(1))), 'R',
        reason: '行2 C 右缘全暗');
    expect(_classify(_px(f, 36, rowY(1))), 'R', reason: '行2 D 未唱');
    // 行3：未唱
    expect(_classify(_px(f, 12, rowY(2))), 'R', reason: '行3 未唱');
  });

  // ===== 4. 对齐：_dx 补偿后墨迹居中/右对齐 =====
  testWidgets('对齐：center/right 下墨迹落在正确位置', (tester) async {
    final line = LyricLine(
      startMs: 0,
      endMs: 1000,
      text: 'AB',
      words: const [
        LyricWord(startMs: 0, endMs: 500, text: 'A'),
        LyricWord(startMs: 500, endMs: 1000, text: 'B'),
      ],
    );
    // 全部唱完 → 整行纯绿，用墨迹盒判对齐
    for (final (align, expectLeft) in [
      (TextAlign.left, 0.0),
      (TextAlign.center, 126.0),
      (TextAlign.right, 252.0),
    ]) {
      final f = await _renderFrame(
          line: line, posMs: 1000, maxWidth: 300, align: align, tester: tester);
      final ink = _inkBounds(f);
      expect(ink.left, closeTo(expectLeft, 2.0),
          reason: '$align 墨迹左缘应≈$expectLeft');
      expect(ink.right, closeTo(expectLeft + 48, 2.0),
          reason: '$align 墨迹右缘应≈${expectLeft + 48}（文本宽 48）');
    }
  });

  // ===== 5. 整行唱完 / 未唱 =====
  testWidgets('整行未唱全红、整行唱完全绿', (tester) async {
    final unsung = await _renderFrame(
        line: _fiveWords(), posMs: 0, maxWidth: 200, tester: tester);
    final sung = await _renderFrame(
        line: _fiveWords(), posMs: 9999, maxWidth: 200, tester: tester);
    for (var i = 0; i < 5; i++) {
      final box = Rect.fromLTRB(i * 24.0, 0, (i + 1) * 24.0, 31);
      expect(_hasColorIn(unsung, box, 255, 0, 0), isTrue,
          reason: '未唱行第${i + 1}词应全红');
      expect(_hasColorIn(unsung, box, 0, 255, 0), isFalse,
          reason: '未唱行第${i + 1}词不应有绿');
      expect(_hasColorIn(sung, box, 0, 255, 0), isTrue,
          reason: '唱完行第${i + 1}词应全绿');
      expect(_hasColorIn(sung, box, 255, 0, 0), isFalse,
          reason: '唱完行第${i + 1}词不应有红');
    }
  });

  // ===== 6. 诊断：把一帧渲染成 ASCII 图（排查像素断言失败时看） =====
  testWidgets('诊断：词中时刻 ASCII 墨迹图', (tester) async {
    final f = await _renderFrame(
        line: _fiveWords(), posMs: 2500, maxWidth: 200, tester: tester);
    final sb = StringBuffer('\n');
    for (var y = 0; y < f.height; y++) {
      for (var x = 0; x < f.width; x++) {
        sb.write(_classify(_px(f, x, y)));
      }
      sb.write('\n');
    }
    debugPrint('词中时刻墨迹图（G=已唱绿 R=未唱红）:$sb');
  });
}
