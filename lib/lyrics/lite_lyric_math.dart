// 轻量歌词引擎的纯算法层（v2.6.3）。
//
// 逐字填充算法移植自 BaiMusic 4.7（us/yibai/baimusic）的
// PlayerScreenKt.computeFillOffset —— 线性插值、无 easing / spring / float，
// 每帧 O(字数) 一次算完，远轻于 flutter_lyric 的多层动画系统。
//
// 这里只放**纯函数**，不依赖 Flutter 渲染，便于单测。
library;

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
