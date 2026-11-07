/// 基 2 迭代复数 FFT（Cooley–Tukey），供本地升频的 STFT / ISTFT 使用。
///
/// 酷狗 `libsuperR.so` 的升频链路用 `CkFftRealForward / CkFftComplexForward`
/// 做频域分析（`SuperResolutionEigen::stft / istft`）。这里是同一位置的纯
/// Dart 实现：预计算位反转表与旋转因子，原地变换，`Float64List` 存取，
/// 不依赖任何 native 库或第三方包，可跑在 App 支持的全部平台。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 原地复数 FFT。[re]/[im] 长度必须等于 [size]（2 的幂）。
class ViperFft {
  ViperFft(this.size)
      : assert(size >= 2 && (size & (size - 1)) == 0,
            'FFT 点数必须是 2 的幂'),
        _levels = _bitLength(size) {
    final half = size >> 1;
    _cos = Float64List(half);
    _sin = Float64List(half);
    for (var k = 0; k < half; k++) {
      final a = 2.0 * math.pi * k / size;
      _cos[k] = math.cos(a);
      _sin[k] = math.sin(a);
    }
    _rev = Uint32List(size);
    for (var i = 0; i < size; i++) {
      _rev[i] = _reverseBits(i, _levels);
    }
  }

  /// 变换点数（2 的幂）。
  final int size;
  final int _levels;
  late final Float64List _cos;
  late final Float64List _sin;
  late final Uint32List _rev;

  /// 正变换 / 逆变换。逆变换在结尾按 1/N 归一化。
  ///
  /// 旋转因子按 `exp(∓2πi·k/N)` 索引：正变换取 `cos−i·sin`，
  /// 逆变换取 `cos+i·sin`。
  void transform(Float64List re, Float64List im, {bool inverse = false}) {
    for (var i = 0; i < size; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }

    for (var len = 2; len <= size; len <<= 1) {
      final half = len >> 1;
      final step = size ~/ len;
      for (var base = 0; base < size; base += len) {
        for (var j = 0; j < half; j++) {
          final idx = j * step;
          final wr = _cos[idx];
          final wi = inverse ? _sin[idx] : -_sin[idx];
          final p = base + j;
          final q = p + half;
          final ar = re[q];
          final ai = im[q];
          final tr = ar * wr - ai * wi;
          final ti = ar * wi + ai * wr;
          re[q] = re[p] - tr;
          im[q] = im[p] - ti;
          re[p] += tr;
          im[p] += ti;
        }
      }
    }

    if (inverse) {
      final inv = 1.0 / size;
      for (var i = 0; i < size; i++) {
        re[i] *= inv;
        im[i] *= inv;
      }
    }
  }

  static int _bitLength(int n) {
    var l = 0;
    while (n > 1) {
      n >>= 1;
      l++;
    }
    return l;
  }

  static int _reverseBits(int v, int levels) {
    var r = 0;
    for (var i = 0; i < levels; i++) {
      r = (r << 1) | (v & 1);
      v >>= 1;
    }
    return r;
  }
}

/// 周期 Hann 窗（满足 50% overlap 的常数叠加，供 OLA 使用）。
Float64List viperHann(int n) {
  final w = Float64List(n);
  final d = 2.0 * math.pi / n;
  for (var i = 0; i < n; i++) {
    w[i] = 0.5 * (1.0 - math.cos(d * i));
  }
  return w;
}
