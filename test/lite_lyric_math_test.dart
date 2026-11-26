// 轻量歌词引擎算法契约测试（v2.6.3）。
//
// 固化 BaiMusic computeFillOffset 移植语义：字符级线性填充、行索引定位、
// 字符偏移→像素映射。纯离线，不依赖 Flutter 渲染与网络。
import 'dart:ui' show TextAlign;

import 'package:baiji_music/lyrics/lite_lyric_math.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:flutter_test/flutter_test.dart';

LyricLine wordLine() => const LyricLine(
      startMs: 1000,
      endMs: 5000,
      text: '我爱你中华',
      words: [
        LyricWord(startMs: 1000, endMs: 2000, text: '我'),
        LyricWord(startMs: 2000, endMs: 3000, text: '爱'),
        LyricWord(startMs: 3000, endMs: 4000, text: '你'),
        LyricWord(startMs: 4000, endMs: 4500, text: '中'),
        LyricWord(startMs: 4500, endMs: 5000, text: '华'),
      ],
    );

void main() {
  group('computeFillOffset（BaiMusic 线性逐字）', () {
    final line = wordLine();

    test('行首之前 = 0', () {
      expect(computeFillOffset(line, 999), 0.0);
      expect(computeFillOffset(line, 1000), 0.0);
    });

    test('每个字唱完 = 整数字符数', () {
      expect(computeFillOffset(line, 2000), 1.0);
      expect(computeFillOffset(line, 3000), 2.0);
      expect(computeFillOffset(line, 4000), 3.0);
    });

    test('字唱到一半 = 线性小数进度', () {
      // 第 1 字 1000~2000，1500 唱一半 → 0.5
      expect(computeFillOffset(line, 1500), closeTo(0.5, 1e-9));
      // 第 3 字 3000~4000，3500 → 2 + 0.5 = 2.5
      expect(computeFillOffset(line, 3500), closeTo(2.5, 1e-9));
    });

    test('行尾之后 = 全部字符', () {
      expect(computeFillOffset(line, 5000), 5.0);
      expect(computeFillOffset(line, 99999), 5.0);
    });

    test('字时长为 0 也不会除零（返回该字起点整数位）', () {
      const zero = LyricLine(
        startMs: 0,
        endMs: 100,
        text: 'ab',
        words: [
          LyricWord(startMs: 0, endMs: 0, text: 'a'),
          LyricWord(startMs: 0, endMs: 100, text: 'b'),
        ],
      );
      // 第一个字 end==start==0，position>行起点后 >= end → 直接计入 1。
      expect(computeFillOffset(zero, 1), greaterThanOrEqualTo(1.0));
    });

    test('非词级行按整行时间线性模拟', () {
      const plain = LyricLine(startMs: 0, endMs: 1000, text: 'abcd');
      expect(computeFillOffset(plain, 0), 0.0);
      expect(computeFillOffset(plain, 500), 2.0);
      expect(computeFillOffset(plain, 1000), 4.0);
      expect(computeFillOffset(plain, 2000), 4.0);
    });

    test('空文本恒为 0', () {
      const empty = LyricLine(startMs: 0, endMs: 100, text: '');
      expect(computeFillOffset(empty, 50), 0.0);
    });
  });

  group('activeIndexAt（BaiMusic currentIndex 语义）', () {
    final lyrics = Lyrics(lines: [
      const LyricLine(startMs: 1000, endMs: 2000, text: 'a'),
      const LyricLine(startMs: 2000, endMs: 3000, text: 'b'),
      const LyricLine(startMs: 3000, endMs: 4000, text: 'c'),
    ]);

    test('空歌词 = -1', () {
      expect(activeIndexAt(Lyrics.empty, 1000), -1);
    });

    test('首行之前 = 0（首行待唱）', () {
      expect(activeIndexAt(lyrics, 0), 0);
      expect(activeIndexAt(lyrics, 999), 0);
    });

    test('命中行起点 = 该行', () {
      expect(activeIndexAt(lyrics, 2000), 1);
      expect(activeIndexAt(lyrics, 3000), 2);
    });

    test('行间空白保持上一行', () {
      // 假设行2 end=2500，位置 2600 未到行3 start=3000 → 保持行1(index=1)
      final gap = Lyrics(lines: [
        const LyricLine(startMs: 1000, endMs: 2000, text: 'a'),
        const LyricLine(startMs: 3000, endMs: 4000, text: 'b'),
      ]);
      expect(activeIndexAt(gap, 2500), 0);
    });

    test('末行之后 = 末行', () {
      expect(activeIndexAt(lyrics, 99999), 2);
    });
  });

  group('字符偏移→像素映射', () {
    test('buildCharEndX 单调不减（抗 getOffsetForCaret 回退）', () {
      final x = buildCharEndX(3, (i) => [0.0, 10.0, 8.0, 30.0][i]);
      expect(x[0], 0.0);
      expect(x[1], 10.0);
      expect(x[2], 10.0); // 8 被钳到前一个 10
      expect(x[3], 30.0);
    });

    test('整数偏移 = 对应字符边界', () {
      final x = [0.0, 10.0, 20.0, 30.0];
      expect(fillOffsetToPixel(0, x), 0.0);
      expect(fillOffsetToPixel(2, x), 20.0);
      expect(fillOffsetToPixel(3, x), 30.0);
    });

    test('小数偏移 = 相邻边界线性插值', () {
      final x = [0.0, 10.0, 20.0, 30.0];
      expect(fillOffsetToPixel(1.5, x), 15.0);
      expect(fillOffsetToPixel(0.25, x), 2.5);
    });

    test('越界钳制', () {
      final x = [0.0, 10.0, 20.0];
      expect(fillOffsetToPixel(-1, x), 0.0);
      expect(fillOffsetToPixel(99, x), 20.0);
      expect(fillOffsetToPixel(2, <double>[0.0]), 0.0);
    });
  });

  group('SmoothPlaybackClock（每帧连续播放时钟）', () {
    int us(int v) => v * 1000; // 毫秒 → 微秒

    test('播放中每 16ms 线性外推，位置连续单调', () {
      final c = SmoothPlaybackClock();
      c.sync(Duration.zero, nowUs: us(0), playing: true);
      // 播放器 200ms 才上报一次；中间每帧都要有连续位置。
      var last = -1;
      for (var t = 0; t <= 200; t += 16) {
        final p = c.positionAt(us(t)).inMilliseconds;
        expect(p, greaterThanOrEqualTo(last));
        last = p;
      }
      expect(last, 192);
      // 200ms 处应推进到 200ms（每分钟 60 帧的连续性由 16ms 步进验证）
      expect(c.positionAt(us(200)).inMilliseconds, 200);
    });

    test('上报相位锯齿（-200ms）完全不修正，外推绝对平滑', () {
      final c = SmoothPlaybackClock();
      c.sync(Duration.zero, nowUs: us(0), playing: true);
      // 200ms 时上报的仍是 0（播放器 200ms 上报一次，值滞后 200ms）。
      // 这是相位噪声不是漂移：一点都不能往回拽。
      c.sync(Duration.zero, nowUs: us(200), playing: true);
      expect(c.positionAt(us(216)).inMilliseconds, 216);
      // 400ms 时上报 200ms（同样滞后 200ms），位置依旧连续
      c.sync(const Duration(milliseconds: 200), nowUs: us(400), playing: true);
      expect(c.positionAt(us(416)).inMilliseconds, 416);
    });

    test('真实上报序列下每帧严格单调且速度恒定（核心回归）', () {
      final c = SmoothPlaybackClock();
      c.sync(Duration.zero, nowUs: us(0), playing: true);
      var last = -1;
      // 每 200ms 上报一次，值恒定滞后 200ms；中间按 16.7ms 出帧
      for (var frame = 0; frame <= 120; frame++) {
        final tUs = (frame * 16667);
        final tMs = tUs ~/ 1000;
        // 每到 200ms 边界，播放器上报 200ms 之前的位置
        if (tMs % 200 < 17) {
          final reported = tMs - 200;
          c.sync(Duration(milliseconds: reported < 0 ? 0 : reported),
              nowUs: tUs, playing: true);
        }
        final p = c.positionAt(tUs).inMilliseconds;
        expect(p, greaterThanOrEqualTo(last), reason: 'frame $frame');
        last = p;
      }
      // 2 秒后位置应等于 2 秒（滞后被完整保留，从未被拽回）
      expect(last, inInclusiveRange(1990, 2010));
    });

    test('中等漂移限速追赶，位置不回退', () {
      final c = SmoothPlaybackClock();
      c.sync(Duration.zero, nowUs: us(0), playing: true);
      // 时钟先正常推进到 500ms
      expect(c.positionAt(us(500)).inMilliseconds, 500);
      // 此刻上报只有 200ms（漂移 -300ms：卡顿/缓冲恢复）
      c.sync(const Duration(milliseconds: 200),
          nowUs: us(500), playing: true);
      var last = 500;
      // 之后每帧减速追赶，但绝不回退
      for (var t = 516; t <= 1500; t += 16) {
        final p = c.positionAt(us(t)).inMilliseconds;
        expect(p, greaterThanOrEqualTo(last));
        last = p;
      }
      // 每帧最多减速 25%，约 1.2s 追平；1s 时应已收回大半偏差
      expect(last, inInclusiveRange(1200, 1300));
    });

    test('超过硬阈值（seek）立即对齐', () {
      final c = SmoothPlaybackClock();
      c.sync(Duration.zero, nowUs: us(0), playing: true);
      c.sync(const Duration(seconds: 60), nowUs: us(100), playing: true);
      expect(c.positionAt(us(100)).inMilliseconds, 60000);
      expect(c.positionAt(us(200)).inMilliseconds, 60100);
    });

    test('暂停后位置冻结，恢复播放从冻结处继续', () {
      final c = SmoothPlaybackClock();
      c.sync(Duration.zero, nowUs: us(0), playing: true);
      c.sync(const Duration(milliseconds: 100),
          nowUs: us(100), playing: false);
      expect(c.positionAt(us(900)).inMilliseconds, 100);
      c.sync(const Duration(milliseconds: 100),
          nowUs: us(1000), playing: true);
      expect(c.positionAt(us(1100)).inMilliseconds, 200);
    });

    test('倍速 2.0 时按倍速外推', () {
      final c = SmoothPlaybackClock();
      c.sync(Duration.zero, nowUs: us(0), playing: true, rate: 2.0);
      expect(c.positionAt(us(100)).inMilliseconds, 200);
    });

    test('reset 清空状态', () {
      final c = SmoothPlaybackClock();
      c.sync(const Duration(seconds: 10), nowUs: us(0), playing: true);
      c.reset();
      expect(c.positionAt(us(500)), Duration.zero);
      expect(c.playing, isFalse);
    });
  });

  group('居中与命中（自绘滚动）', () {
    test('centeredScrollOffset：行中心精确落在视口中心', () {
      // 行高 60，视口 300；第 2 行内容中心 = 2*60+30 = 150。
      expect(centeredScrollOffset(2, 60, 300), 150 - 150);
      // 第 5 行：5*60+30 = 330 → 需滚到 330-150 = 180
      expect(centeredScrollOffset(5, 60, 300), 180);
    });

    test('centeredScrollOffset：首行为负值（也能居中，不贴顶）', () {
      expect(centeredScrollOffset(0, 60, 300), -120);
    });

    test('lineIndexAtScroll：滚动 + 局部 y 命中正确行', () {
      // 滚动 180，点击视口 y=90 → 内容 y=270 → 第 4 行
      expect(lineIndexAtScroll(180, 90, 60, 10), 4);
      expect(lineIndexAtScroll(180, 0, 60, 10), 3);
      expect(lineIndexAtScroll(180, 90, 60, 4), -1);
      expect(lineIndexAtScroll(0, 0, 60, 0), -1);
    });

    test('lineStartX：居中时左右留白严格对称', () {
      // 视口 360、文本 200 → 起始 80，右端 280，两侧各 80。
      expect(lineStartX(viewportWidth: 360, textWidth: 200, align: TextAlign.center), 80);
      // 文本正好等于可用宽度（360-48=312）→ 起点 24，两侧各 24。
      expect(lineStartX(viewportWidth: 360, textWidth: 312, align: TextAlign.center), 24);
    });

    test('lineStartX：左/右对齐贴安全边距', () {
      expect(lineStartX(viewportWidth: 360, textWidth: 200, align: TextAlign.left), 24);
      expect(lineStartX(viewportWidth: 360, textWidth: 200, align: TextAlign.right), 136);
    });

    test('lineStartX：文本超宽时按可用宽度钳制，不越界', () {
      final x = lineStartX(viewportWidth: 360, textWidth: 999, align: TextAlign.center);
      expect(x, 24); // (360-312)/2
    });
  });

  // ===== v2.6.6-fix1：动态行高 + 两行逐字分段 =====
  group('动态行高几何', () {
    test('buildLineTops：累积位置逐行累加', () {
      final tops = buildLineTops([50, 50, 70]);
      expect(tops, [0, 50, 100]);
    });

    test('scrollOffsetForLine：让第 i 行中心落在视口中心', () {
      final tops = buildLineTops([50, 50, 70]);
      final heights = [50.0, 50.0, 70.0];
      // 第 1 行中心 = 50+25=75，视口高 300 → 目标 75-150=-75。
      expect(scrollOffsetForLine(tops, heights, 1, 300), -75);
    });

    test('lineIndexAtY：按动态高度命中，长行占更多空间', () {
      final tops = buildLineTops([50, 100, 50]);
      final heights = [50.0, 100.0, 50.0];
      expect(lineIndexAtY(tops, heights, 0, 10), 0);
      expect(lineIndexAtY(tops, heights, 0, 60), 1);
      expect(lineIndexAtY(tops, heights, 0, 160), 2);
      expect(lineIndexAtY(tops, heights, 0, 210), -1); // 越界
    });

    test('visibleLineRange：返回覆盖区间的半开行范围', () {
      final tops = buildLineTops([50, 50, 50, 50]);
      final r = visibleLineRange(tops, 60, 130);
      expect(r.start, lessThanOrEqualTo(1));
      expect(r.end, greaterThanOrEqualTo(3));
    });
  });

  group('两行逐字分段', () {
    test('buildRowSegments：caret 按行归类，字符区间连续不重叠', () {
      // 6 个字符：前 3 个在第 0 行（top=0,h=20），后 3 个在第 1 行（top=20,h=20）。
      final segs = buildRowSegments(
        textLength: 6,
        caretX: (i) => (i % 3) * 10.0,
        caretY: (i) => i < 3 ? 5.0 : 25.0,
        rowTops: [0.0, 20.0],
        rowHeights: [20.0, 20.0],
        rowWidths: [30.0, 30.0],
      );
      expect(segs.length, 2);
      expect(segs[0].startChar, 0);
      expect(segs[0].endChar, 3);
      expect(segs[0].charCount, 3);
      expect(segs[0].localX, [0, 10, 20]);
      expect(segs[1].startChar, 3);
      expect(segs[1].endChar, 7); // 含末尾 offset=6 的 caret
      expect(segs[1].localX.first, 0);
    });

    test('逐行渲染语义：第一行唱满前不进入第二行', () {
      // 复刻 _paintLine 的判定：local=(fill-start).clamp(0,charCount)。
      final segs = buildRowSegments(
        textLength: 6,
        caretX: (i) => (i % 3) * 10.0,
        caretY: (i) => i < 3 ? 5.0 : 25.0,
        rowTops: [0.0, 20.0],
        rowHeights: [20.0, 20.0],
        rowWidths: [30.0, 30.0],
      );
      bool rowActive(int seg, double fill) {
        final local = (fill - segs[seg].startChar)
            .clamp(0.0, segs[seg].charCount.toDouble());
        return local > 0;
      }
      // fill=2.5（第一行唱到第 3 字一半）：只有第一行渲染。
      expect(rowActive(0, 2.5), true);
      expect(rowActive(1, 2.5), false);
      // fill=3.5（第一行唱满，第二行唱到第 1 字）：两行都渲染，
      // 第一行 local==charCount → 整行满亮（保持不灰）。
      expect(rowActive(0, 3.5), true);
      expect(rowActive(1, 3.5), true);
      final local0 = (3.5 - segs[0].startChar)
          .clamp(0.0, segs[0].charCount.toDouble());
      expect(local0, segs[0].charCount); // 第一行满，不变灰
    });
  });
}
