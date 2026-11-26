// 轻量歌词引擎的纯算法层（v2.6.3）。
//
// 逐字填充算法移植自 BaiMusic 4.7（us/yibai/baimusic）的
// PlayerScreenKt.computeFillOffset —— 线性插值、无 easing / spring / float，
// 每帧 O(字数) 一次算完，远轻于 flutter_lyric 的多层动画系统。
//
// 这里只放**纯函数**，不依赖 Flutter 渲染，便于单测。
library;

import 'dart:math' as math;
import 'dart:ui' show TextAlign;

import 'lyric_model.dart';

/// BaiMusic `computeFillOffset` 的 Dart 移植。
///
/// 返回「已唱字符偏移」浮点值：
/// - 整数部分 = 已唱完的字符数；
/// - 小数部分 = 当前正在演唱字符的进度 [0,1)。
///
/// 例：3.5 表示前 3 个字唱完，第 4 个字唱了一半。
/// 渲染层据此把字符偏移换成像素横坐标，clip 出扫光边界。
///
/// [LyricWord.text] 拼接后即为 [LyricLine.displayText]，故字符偏移可直接
/// 索引整行文本（与 BaiMusic 用 `String.length` 累加一致，均为 UTF-16 长度）。
double computeFillOffset(LyricLine line, int positionMs) {
  final totalChars = line.displayText.length;
  if (totalChars == 0) return 0.0;
  if (positionMs <= line.startMs) return 0.0;

  // 无逐字时间轴：按整行时间线性模拟扫光（等价于引擎的 simulateTiming）。
  if (!line.isWordLevel) {
    final span = line.endMs > line.startMs ? line.endMs - line.startMs : 1;
    return ((positionMs - line.startMs) / span).clamp(0.0, 1.0) * totalChars;
  }

  var acc = 0;
  for (final w in line.words) {
    final len = w.text.length;
    if (positionMs >= w.endMs) {
      // 该字已唱完：整字计入。
      acc += len;
      continue;
    }
    if (positionMs < w.startMs) {
      // 还没唱到该字：返回此前累计。
      return acc.toDouble();
    }
    // 正在唱该字：线性进度 × 字长。
    final span = w.endMs > w.startMs ? w.endMs - w.startMs : 1;
    final p = ((positionMs - w.startMs) / span).clamp(0.0, 1.0);
    return acc + len * p;
  }
  return acc.toDouble();
}

/// 当前播放位置所属的活跃行下标（BaiMusic `LyricParser.currentIndex` 语义）。
///
/// - 位置早于首行 → 0（首行待唱）；
/// - 命中某行 [startMs, endMs) → 该行；
/// - 落在行间空白（前一句已结束、后一句未开始）→ 保持在刚过去的那行；
/// - 晚于末行 → 末行。
/// 空歌词返回 -1。
int activeIndexAt(Lyrics lyrics, int positionMs) {
  final lines = lyrics.lines;
  if (lines.isEmpty) return -1;
  if (positionMs < lines.first.startMs) return 0;
  var lo = 0;
  var hi = lines.length - 1;
  var ans = 0;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (positionMs >= lines[mid].startMs) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}

/// 把字符偏移（可含小数）映射到一行文本的像素横坐标。
///
/// [charEndX] 是长度为 `text.length + 1` 的数组，`charEndX[i]` 表示第 i 个
/// UTF-16 单元结束处的 x（由渲染层用 TextPainter.getOffsetForCaret 预生成）。
/// 小数部分在相邻两个字符边界间线性插值，得到平滑扫光位置。
double fillOffsetToPixel(double charOffset, List<double> charEndX) {
  if (charEndX.isEmpty) return 0.0;
  final n = charEndX.length - 1;
  if (n <= 0) return charEndX.first;
  final off = charOffset.clamp(0.0, n.toDouble());
  final i = off.floor();
  if (i >= n) return charEndX[n];
  final frac = off - i;
  final a = charEndX[i];
  final b = charEndX[i + 1];
  return a + (b - a) * frac;
}

/// 播放位置的**平滑时钟**（v2.6.4）。
///
/// 为什么需要它：`media_kit` 的 `player.state.position` 来自原生层的位置事件，
/// 实测约每 180~250ms 才更新一次（不是每帧）。直接拿它算逐字填充，扫光边界
/// 会「停 5 帧、跳 20px」，真机观感就是一卡一卡。
///
/// 做法：本地用帧时间按倍速外推（每帧连续），播放器上报只做**大偏差兜底**。
///
/// v2.6.4 的关键修正——**不再按比例「柔性校准」小漂移**：
/// 上报值本身就是「若干毫秒前的位置」，两次上报之间外推值必然线性领先于
/// 上报值（形成 -0~-200ms 的锯齿）。上一版对 >45ms 的漂移每次吸收 35%，
/// 等于每 200ms 把扫光往回拽一次——这才是「还是一卡一卡」的真凶。
/// 现在 ±[ignoreDriftMs] 内一律视为上报相位噪声、完全不动，外推即绝对平滑；
/// 中等偏差（卡顿恢复）用限速追赶摊平到十几帧，超大偏差（seek/切歌）硬对齐。
class SmoothPlaybackClock {
  Duration _pos = Duration.zero;
  int _lastUs = 0;
  bool _playing = false;
  bool _primed = false;
  double _rate = 1.0;

  /// 待消化的位置偏差（毫秒，正 = 外推落后于上报）。
  double _catchUpMs = 0;

  /// 视为「上报相位噪声」、完全忽略的漂移阈值（毫秒）。
  ///
  /// 必须大于播放器的位置上报周期（实测 180~250ms），否则每个上报周期都会
  /// 触发一次修正，重新引入周期性回拽。
  static const int ignoreDriftMs = 260;

  /// 视为 seek / 切歌、直接硬对齐的漂移阈值（毫秒）。
  static const int hardDriftMs = 900;

  /// 追赶中等偏差时允许的最大速度调整比例（1.0 = ±100%）。
  static const double catchUpRatio = 0.25;

  bool get playing => _playing;

  /// 当前平滑位置（每帧调用一次，内部按帧间隔推进）。
  Duration positionAt(int nowUs) {
    if (!_primed) return Duration.zero;
    if (!_playing) return _pos;
    final dtUs = nowUs - _lastUs;
    if (dtUs <= 0) return _pos;
    _lastUs = nowUs;
    final baseMs = dtUs / 1000.0 * _rate;
    var advance = baseMs;
    if (_catchUpMs != 0) {
      // 限速消化：每帧最多改动 25% 的播放速度，视觉上不可察觉；
      // clamp 到 ±60% base 保证 net 前进量恒为正（位置绝不回退）。
      final maxFix = math.max(baseMs * catchUpRatio, 0.05);
      final fix = _catchUpMs.clamp(-maxFix, maxFix);
      advance += fix;
      _catchUpMs -= fix;
      if (_catchUpMs.abs() < 0.05) _catchUpMs = 0;
    }
    _pos += Duration(microseconds: (advance * 1000).round());
    return _pos;
  }

  /// 用播放器上报的真实位置校准。
  ///
  /// [hard] 为 true（seek / 切歌 / 首次）时直接对齐，不做平滑。
  void sync(
    Duration actual, {
    required int nowUs,
    required bool playing,
    double rate = 1.0,
    bool hard = false,
  }) {
    _rate = rate <= 0 ? 1.0 : rate;
    if (!_primed || hard || playing != _playing) {
      _pos = actual;
      _lastUs = nowUs;
      _playing = playing;
      _primed = true;
      _catchUpMs = 0;
      return;
    }
    if (!playing) {
      _pos = actual;
      _lastUs = nowUs;
      _catchUpMs = 0;
      return;
    }
    final driftMs = (actual - _pos).inMicroseconds / 1000.0;
    if (driftMs.abs() >= hardDriftMs) {
      _pos = actual;
      _lastUs = nowUs;
      _catchUpMs = 0;
    } else if (driftMs.abs() > ignoreDriftMs) {
      // 卡顿恢复等中等偏差：交给 positionAt 限速消化，不瞬间跳。
      _catchUpMs = driftMs;
    }
    // ±ignoreDriftMs 内：上报相位锯齿，保持本地连续时钟，一个字节都不动。
  }

  /// 丢弃全部状态（切歌 / 重新加载时调用）。
  void reset() {
    _pos = Duration.zero;
    _lastUs = 0;
    _playing = false;
    _primed = false;
    _rate = 1.0;
    _catchUpMs = 0;
  }
}

/// 让第 [index] 行**垂直居中**于视口所需的滚动偏移。
///
/// 内容坐标里第 i 行占 [i*extent, (i+1)*extent)，行中心 = i*extent + extent/2。
/// 要让行中心落在视口中心，需要把内容上移 `行中心 - 视口高/2`。
/// 首行会得到负值（内容整体下移），这样第一行也能居中，不会贴在顶部。
double centeredScrollOffset(int index, double extent, double viewportHeight) =>
    index * extent + extent / 2 - viewportHeight / 2;

/// 把视口内的局部 y 换算成命中的行下标（点击跳转用）。
///
/// [scroll] 为当前滚动偏移，[localY] 为视口内纵坐标；越界返回 -1。
int lineIndexAtScroll(
  double scroll,
  double localY,
  double extent,
  int lineCount,
) {
  if (lineCount <= 0 || extent <= 0) return -1;
  final contentY = scroll + localY;
  final i = (contentY / extent).floor();
  if (i < 0 || i >= lineCount) return -1;
  return i;
}

/// 一行文本在视口中的起始 x（水平对齐的唯一真源）。
///
/// 居中必须按**实测文本宽度**算，不能靠 `TextPainter(textAlign: center)`：
/// v2.6.3 同时用了 textAlign 居中排版和「(容器宽-文本宽)/2」偏移，两者叠加
/// 使文字整体左偏 24dp（真机视频可量到），故本函数是唯一的对齐入口。
double lineStartX({
  required double viewportWidth,
  required double textWidth,
  required TextAlign align,
  double sidePad = 24.0,
}) {
  final w = textWidth.clamp(0.0, math.max(viewportWidth - sidePad * 2, 0.0));
  return switch (align) {
    TextAlign.center => (viewportWidth - w) / 2,
    TextAlign.right => viewportWidth - sidePad - w,
    _ => sidePad,
  };
}

/// 由每行高度生成「行顶部在内容坐标系的累积位置」（v2.6.6-fix1）。
///
/// tops[i] 是第 i 行的顶部 y，tops[i+1]-tops[i] == heights[i]。短行用基础
/// 行高、长行（主文本或译文换行）用更高值，从而实现「长歌词占两行、短行
/// 保持紧凑」而不再全部省略成一行。
List<double> buildLineTops(List<double> heights) {
  final tops = List<double>.filled(heights.length, 0.0);
  var acc = 0.0;
  for (var i = 0; i < heights.length; i++) {
    tops[i] = acc;
    acc += heights[i];
  }
  return tops;
}

/// 动态行高版：让第 [index] 行垂直居中于视口所需的滚动偏移。
double scrollOffsetForLine(
  List<double> tops,
  List<double> heights,
  int index,
  double viewportHeight,
) {
  if (index < 0 || index >= tops.length) return 0.0;
  return tops[index] + heights[index] / 2 - viewportHeight / 2;
}

/// 动态行高版：视口局部 y → 命中行下标（点击跳转用），越界 -1。
int lineIndexAtY(
  List<double> tops,
  List<double> heights,
  double scroll,
  double localY,
) {
  final n = tops.length;
  if (n <= 0) return -1;
  final contentY = scroll + localY;
  var lo = 0;
  var hi = n - 1;
  var ans = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (tops[mid] <= contentY) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  if (ans < 0) return -1;
  if (contentY >= tops[ans] + heights[ans]) return -1;
  return ans;
}

/// 主文本折行后的一行渲染段（v2.6.6-fix1）。
///
/// [startChar]/[endChar] 是该行覆盖的 UTF-16 字符区间（end 不含），
/// [localX] 长度 = endChar-startChar+1，是各字符边界相对行首的 x。
/// 逐字扫光据此把「全行字符偏移」拆成每行局部偏移，实现按时间顺序逐行渲染。
class LyricRowSegment {
  LyricRowSegment({
    required this.startChar,
    required this.endChar,
    required this.localX,
    required this.top,
    required this.height,
    required this.width,
  });

  int startChar;
  int endChar;
  List<double> localX;
  final double top;
  final double height;
  final double width;

  int get charCount => endChar - startChar;
}

/// 把 caret 坐标按行 top/height 归类，构建每行的字符段（纯函数，便于单测）。
///
/// [caretX]/[caretY] 由渲染层用 TextPainter.getOffsetForCaret 注入；
/// [rowTops]/[rowHeights]/[rowWidths] 来自 computeLineMetrics()。
List<LyricRowSegment> buildRowSegments({
  required int textLength,
  required double Function(int) caretX,
  required double Function(int) caretY,
  required List<double> rowTops,
  required List<double> rowHeights,
  required List<double> rowWidths,
}) {
  if (rowTops.isEmpty) return const [];
  final segs = <LyricRowSegment>[];
  for (var r = 0; r < rowTops.length; r++) {
    segs.add(LyricRowSegment(
      startChar: -1,
      endChar: -1,
      localX: <double>[],
      top: rowTops[r],
      height: rowHeights[r],
      width: r < rowWidths.length ? rowWidths[r] : 0.0,
    ));
  }
  for (var i = 0; i <= textLength; i++) {
    final y = caretY(i);
    var r = 0;
    for (; r < rowTops.length - 1; r++) {
      if (y < rowTops[r] + rowHeights[r]) break;
    }
    final seg = segs[r];
    if (seg.startChar < 0) seg.startChar = i;
    seg.endChar = i + 1;
    seg.localX.add(caretX(i));
  }
  // 去掉没有字符的空行。
  return segs.where((s) => s.startChar >= 0).toList();
}

/// 动态行高版：内容 y 区间 [from, to] 覆盖的半开行范围 [start, end)。
({int start, int end}) visibleLineRange(
  List<double> tops,
  int fromY,
  int toY,
) {
  final n = tops.length;
  if (n <= 0) return (start: 0, end: 0);
  // 第一个顶部 >= fromY 的行，再往前退一行（缓冲）。
  var lo = 0;
  var hi = n;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (tops[mid] < fromY) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final start = (lo - 1).clamp(0, n - 1);
  // 第一个顶部 > toY 的行。
  lo = 0;
  hi = n;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (tops[mid] <= toY) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final end = (lo + 1).clamp(start + 1, n);
  return (start: start, end: end);
}

/// 为整行文本预生成每个 UTF-16 单元结束处的 x 坐标。
///
/// [measure] 由渲染层注入（依赖 TextPainter），返回第 i 个单元结束处的 x。
/// 抽成函数便于在纯 Dart 环境下用假 measure 做单测。
List<double> buildCharEndX(int utf16Length, double Function(int) measure) {
  final result = List<double>.filled(utf16Length + 1, 0.0);
  for (var i = 0; i <= utf16Length; i++) {
    result[i] = measure(i);
  }
  // 保证单调不减，避免 getOffsetForCaret 在换行/emoji 处偶发回退造成扫光倒退。
  for (var i = 1; i < result.length; i++) {
    if (result[i] < result[i - 1]) result[i] = result[i - 1];
  }
  return result;
}
