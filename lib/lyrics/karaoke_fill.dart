/// 逐字卡拉 OK 遮罩渐变构造器（纯逻辑，便于单测）。
///
/// **AMLL（倾听同款渲染库）精确语义移植**。倾听的逐字效果不是"整行
/// 一条渐变"，而是**每个词一条独立的遮罩**：词被唱到时，一条柔和
/// 的亮/暗边界从词的左缘扫到右缘，扫完瞬间恰好等于词唱完。
///
/// 算法（从 amll.js 的 `sp()` / `generateCalcBasedMaskImage()` 还原）：
/// - 羽化宽 `F = wordFadeWidth × 行高`（AMLL 默认 wordFadeWidth = 0.5，
///   即边界过渡带是半个行高——比旧实现"12% 字宽"宽得多，是倾听效果
///   的柔和感来源）；
/// - 对进度 `ratio ∈ (0,1)` 的词，亮/暗边界前沿
///   `front = left + 宽×ratio − F×(1−ratio)`：
///   - `ratio→0` 时 `front→left−F`，整词全暗（开口先暗一瞬，不抢拍）；
///   - `ratio→1` 时 `front→right`，整词全亮（唱完瞬间恰好填满）；
///   - `front` 到 `front+F` 之间是已唱色→未唱色的线性过渡带。
///
/// 输入是每个词在**行内**的水平区间（像素）与该词当前的演唱进度 0~1，
/// 输出可直接喂给 [LinearGradient] 的 `stops`/`colors`（配合
/// `BlendMode.dstIn`：已唱色传不透明白、未唱色传全透明白，只取 alpha）。
/// 保证 stops 严格单调递增且都在 0~1 内。
library;

import 'package:flutter/material.dart';

/// 羽化宽度占行高的比例（AMLL 默认值）。
///
/// AMLL 里词元素高度含 1em 上下 padding，实际过渡带比一个行高还宽；
/// 这里取行高的一半，在常见字号（17~30px）下约 11~20px 的柔和过渡，
/// 既保留倾听的软边扫掠，又不会糊成一团。
const double kKaraokeWordFadeWidth = 0.5;

class KaraokeFill {
  KaraokeFill._();

  /// 构造一行的分段遮罩渐变。
  ///
  /// - [wordSpans]：每个词的水平区间 `[left, right]`（像素，行内坐标）。
  ///   空列表表示该词无文本（如 QRC 罗马音里的纯时间占位项），跳过。
  /// - [ratios]：与 [wordSpans] 等长的演唱进度 0~1。
  /// - [width]：整行内容宽度（归一化用），<= 0 时返回 null。
  /// - [feather]：羽化宽度（像素）。<= 0 时退化为硬边界（内部以亚像素
  ///   epsilon 带实现，保证 stops 严格单调）。由调用方按
  ///   `字号 × 行高倍数 × [kKaraokeWordFadeWidth]` 计算后传入。
  ///
  /// 返回 `(stops, colors)`；没有任何有效词时返回 null。
  static (List<double>, List<Color>)? build({
    required List<List<double>> wordSpans,
    required List<double> ratios,
    required double width,
    required Color sung,
    required Color unsung,
    double feather = 0.0,
  }) {
    if (width <= 0 || wordSpans.isEmpty || wordSpans.length != ratios.length) {
      return null;
    }

    final stops = <double>[];
    final colors = <double>[]; // alpha 序列，末尾统一映射到颜色

    for (var i = 0; i < wordSpans.length; i++) {
      final span = wordSpans[i];
      if (span.isEmpty) continue;
      final l = span[0];
      final r = span[1];
      if (r <= l) continue;
      final ratio = ratios[i].clamp(0.0, 1.0);

      if (ratio <= 0) {
        // 还没开口：整词全暗。
        _put(stops, colors, l, 0, width);
        _put(stops, colors, r, 0, width);
      } else if (ratio >= 1) {
        // 已唱完：整词全亮。
        _put(stops, colors, l, 1, width);
        _put(stops, colors, r, 1, width);
      } else {
        // 正在唱：front 从 left−F 匀速扫到 right，过渡带 [front, front+F]。
        final w = r - l;
        final front = l + w * ratio - feather * (1 - ratio);
        // 渐变 stops 必须严格单调（同位置双停靠点非法）：feather<=0 或过窄时，
        // 若直接停靠会让 front 的"已唱"点被 front+F 的"未唱"点覆盖，硬边界
        // 退化成整词渐变（前沿错位到字宽一半）。用一个随行宽缩放的亚像素
        //  epsilon 过渡带保住阶跃，视觉上不可察觉。
        final minBand = width * 0.002;
        final band = feather > minBand ? feather : minBand;
        _put(stops, colors, l, _alphaAt(l, front, band), width);
        if (front > l) {
          _put(stops, colors, front, 1, width);
        }
        if (front + band < r) {
          _put(stops, colors, front + band, 0, width);
        }
        _put(stops, colors, r, _alphaAt(r, front, band), width);
      }
    }
    if (colors.isEmpty) return null;
    return (
      stops,
      [for (final a in colors) Color.lerp(unsung, sung, a)!],
    );
  }

  /// AMLL 词内任意点的遮罩 alpha：front 之前全亮，front+F 之后全暗，
  /// 之间线性过渡。
  static double _alphaAt(double x, double front, double feather) {
    if (feather <= 0) return x <= front ? 1.0 : 0.0;
    if (x <= front) return 1.0;
    if (x >= front + feather) return 0.0;
    return (front + feather - x) / feather;
  }

  /// 在 `stops` 上放一个归一化停靠点（alpha 序列，保持单调）。
  /// 同一位置后放的覆盖先放的，近似重合的点合并。
  static void _put(
    List<double> stops,
    List<double> alphas,
    double x,
    double a,
    double width,
  ) {
    final s = (x / width).clamp(0.0, 1.0);
    if (alphas.isEmpty) {
      alphas.add(a);
      stops.add(s);
      return;
    }
    final last = stops.last;
    if (s < last - 0.0001) return;
    if ((s - last).abs() <= 0.0001) {
      alphas[alphas.length - 1] = a;
      return;
    }
    alphas.add(a);
    stops.add(s);
  }
}
