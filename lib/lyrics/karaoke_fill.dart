/// 逐字卡拉 OK 填充的分段渐变构造器（纯逻辑，便于单测）。
///
/// 严格对照视频效果：每个字在自己的起止时间内**从左往右逐渐填满**——
/// 字的左半是已唱色、右半是未唱色，填充边界是一条竖线，随播放推进扫过
/// 整个字，直到该字结束才完全变成已唱色。**不是**整字一起渐变跳色。
///
/// 输入是每个字在行内的水平区间（像素）与该字当前的演唱进度 0~1，
/// 输出可直接喂给 [LinearGradient] 的 `stops`/`colors`：
/// - 已唱完的字：整段区间都是已唱色；
/// - 一个字还没唱的字：整段区间都是未唱色；
/// - 正在唱的字：区间内 `[left, left + 宽度×进度)` 是已唱色，其余未唱色。
///
/// 字与字之间的空隙颜色跟随前一字的末态（空格通常本身就归属某个字的
/// 文本，真正的空隙只在字距层面出现，视觉上无感）。
library;

import 'package:flutter/material.dart';

class KaraokeFill {
  KaraokeFill._();

  /// 构造分段渐变。
  ///
  /// - [wordSpans]：每个字的水平区间 `[left, right]`（像素）。空列表表示
  ///   该字无文本（如 QRC 罗马音里的纯时间占位项），跳过。
  /// - [ratios]：与 [wordSpans] 等长的演唱进度 0~1。
  /// - [width]：整行内容宽度（归一化用），<= 0 时返回 null。
  ///
  /// 返回 `(stops, colors)`；没有任何有效字时返回 null。
  /// 保证 stops 严格单调递增且都在 0~1 内，可直接构造 [LinearGradient]。
  static (List<double>, List<Color>)? build({
    required List<List<double>> wordSpans,
    required List<double> ratios,
    required double width,
    required Color sung,
    required Color unsung,
  }) {
    if (width <= 0 || wordSpans.isEmpty || wordSpans.length != ratios.length) {
      return null;
    }

    final stops = <double>[];
    final colors = <Color>[];

    for (var i = 0; i < wordSpans.length; i++) {
      final span = wordSpans[i];
      if (span.isEmpty) continue;
      final l = span[0];
      final r = span[1];
      if (r <= l) continue;
      final ratio = ratios[i];
      if (ratio <= 0) {
        // 一个字都还没唱：整字保持未唱色。
        _put(stops, colors, l, unsung, width);
      } else if (ratio >= 1) {
        // 已经唱完：整字已唱色。
        _put(stops, colors, l, sung, width);
        _put(stops, colors, r, sung, width);
      } else {
        // 正在唱：左边界起就是已唱色，填充前沿处切回未唱色。
        _put(stops, colors, l, sung, width);
        _put(stops, colors, l + (r - l) * ratio, sung, width);
        _put(stops, colors, r, unsung, width);
      }
    }
    if (colors.isEmpty) return null;
    return (stops, colors);
  }

  /// 在 `stops/colors` 上放一个归一化停靠点。同一位置后放的覆盖先放的，
  /// 近似重合的点合并——保证产出的是严格单调的合法渐变。
  static void _put(
    List<double> stops,
    List<Color> colors,
    double x,
    Color c,
    double width,
  ) {
    final s = (x / width).clamp(0.0, 1.0);
    if (colors.isEmpty) {
      colors.add(c);
      stops.add(s);
      return;
    }
    final last = stops.last;
    if (s < last - 0.0001) return;
    if ((s - last).abs() <= 0.0001) {
      colors[colors.length - 1] = c;
      return;
    }
    colors.add(c);
    stops.add(s);
  }
}
