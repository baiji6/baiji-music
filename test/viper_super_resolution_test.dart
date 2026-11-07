/// 本地升频引擎（纯 Dart DSP）离线单测。
///
/// 不依赖 ffmpeg / path_provider / isolate，只测算法与 WAV 编解码本身。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:baiji_music/viper/viper_fft.dart';
import 'package:baiji_music/viper/viper_super_resolution.dart';
import 'package:baiji_music/viper/viper_wav.dart';

void main() {
  group('ViperFft', () {
    test('正逆变换往返还原实信号', () {
      const n = 2048;
      final fft = ViperFft(n);
      final re = Float64List(n);
      final im = Float64List(n);
      final expected = Float64List(n);
      for (var i = 0; i < n; i++) {
        final v = math.sin(2 * math.pi * 97 * i / n) +
            0.3 * math.cos(2 * math.pi * 431 * i / n);
        re[i] = v;
        expected[i] = v;
      }
      fft.transform(re, im);
      fft.transform(re, im, inverse: true);
      var maxErr = 0.0;
      for (var i = 0; i < n; i++) {
        maxErr = math.max(maxErr, (re[i] - expected[i]).abs());
        expect(im[i].abs() < 1e-9, isTrue);
      }
      expect(maxErr < 1e-10, isTrue, reason: '往返误差 $maxErr');
    });

    test('Hann 窗 50% overlap 满足常数叠加（COLA，Σw=1）', () {
      const n = 2048;
      final w = viperHann(n);
      final sum = Float64List(n);
      for (var shift = -n ~/ 2; shift <= n; shift += n ~/ 2) {
        for (var i = 0; i < n; i++) {
          final p = shift + i;
          if (p >= 0 && p < n) sum[p] += w[i];
        }
      }
      // 内部区域严格等于 1（矩形合成窗按 Σw 归一化的前提）。
      // 注意：Σw² 在 50% overlap 下并非 COLA（残留 0.25·cos(4πi/N)），
      // 所以实现里绝不能改回「Hann 合成 + Σw² 归一化」。
      for (var i = n ~/ 4; i < n * 3 ~/ 4; i++) {
        expect(sum[i], closeTo(1.0, 1e-9));
      }
    });
  });

  group('ViperWav', () {
    test('24-bit PCM 往返（采样率/声道/帧数/幅值）', () {
      const frames = 512;
      final left = Float64List(frames);
      final right = Float64List(frames);
      for (var i = 0; i < frames; i++) {
        left[i] = 0.5 * math.sin(2 * math.pi * 40 * i / frames);
        right[i] = -0.25 * math.cos(2 * math.pi * 17 * i / frames);
      }
      final src = ViperAudio(48000, 2, <Float64List>[left, right]);
      final bytes = ViperWav.encode24(src, dither: false);
      expect(bytes.length, 44 + frames * 2 * 3);
      final back = ViperWav.readBytes(bytes);
      expect(back.sampleRate, 48000);
      expect(back.channels, 2);
      expect(back.frames, frames);
      // 24 bit 量化误差上限 1 LSB（2^-23）。
      for (var i = 0; i < frames; i++) {
        expect((back.data[0][i] - left[i]).abs() < 2 / 8388608, isTrue);
        expect((back.data[1][i] - right[i]).abs() < 2 / 8388608, isTrue);
      }
    });

    test('非法文件明确报错，不编造规格', () {
      expect(() => ViperWav.readBytes(Uint8List(10)),
          throwsA(isA<FormatException>()));
    });
  });

  group('ViperSuperResolution', () {
    Float64List tone(int frames, double freq, {double amp = 0.6}) {
      final x = Float64List(frames);
      for (var i = 0; i < frames; i++) {
        x[i] = amp * math.sin(2 * math.pi * freq * i / 48000);
      }
      return x;
    }

    test('192k 档：采样率/时长/低频主频保持，无 NaN 无削波', () {
      const frames = 48000 ~/ 5; // 0.2 s
      final x = tone(frames, 1000);
      final input = ViperAudio(48000, 2, <Float64List>[x, Float64List.fromList(x)]);
      final out = ViperSuperResolution(rate: ViperUpscaleRate.khz192)
          .process(input);

      expect(out.sampleRate, 192000);
      expect(out.channels, 2);
      expect(out.frames, frames * 4);
      expect(out.peak() <= 1.0, isTrue, reason: '峰值 ${out.peak()}');
      for (final ch in out.data) {
        for (final v in ch) {
          expect(v.isFinite, isTrue);
        }
      }

      // 输出仍应是 1 kHz 主导：用过零率粗估频率（192k 下 1kHz 每周期 192 点）。
      final y = out.data[0];
      var crossings = 0;
      for (var i = 1; i < y.length; i++) {
        if ((y[i - 1] < 0 && y[i] >= 0) || (y[i - 1] >= 0 && y[i] < 0)) {
          crossings++;
        }
      }
      final estimatedHz = crossings / 2 * 192000 / y.length;
      expect(estimatedHz, closeTo(1000, 60), reason: '估算主频 $estimatedHz');

      // 逐周期峰值稳定性：锁住「Σw² 归一化→约 33% 周期性幅度调制」的回归。
      const cycle = 192; // 192000 / 1000
      final peaks = <double>[];
      for (var s = cycle * 10;
          s + cycle <= y.length - cycle * 10;
          s += cycle) {
        var p = 0.0;
        for (var i = s; i < s + cycle; i++) {
          p = math.max(p, y[i].abs());
        }
        peaks.add(p);
      }
      final minP = peaks.reduce(math.min);
      final maxP = peaks.reduce(math.max);
      expect((maxP - minP) / maxP < 0.05, isTrue,
          reason: '逐周期峰值波动 ${(maxP - minP) / maxP}');
    });

    test('96k 档：帧数为 2 倍，算法说明如实标注非官方 DNN', () {
      const frames = 48000 ~/ 10;
      final x = tone(frames, 440);
      final input = ViperAudio(48000, 2, <Float64List>[x, Float64List.fromList(x)]);
      final out = ViperSuperResolution(rate: ViperUpscaleRate.khz96)
          .process(input);
      expect(out.sampleRate, 96000);
      expect(out.frames, frames * 2);
      expect(ViperSuperResolution.algorithmNote, contains('非官方 DNN 模型'));
    });

    test('宽带信号：24 kHz 以上生成可测的重建高频能量', () {
      const frames = 48000 ~/ 10;
      // 多正弦混合，覆盖 1.5~14 kHz 的「富谐波」低频带，供 SBR 转置。
      final x = Float64List(frames);
      var seed = 12345;
      double rnd() {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        return seed / 0x7FFFFFFF;
      }

      for (var i = 0; i < frames; i++) {
        var v = 0.0;
        for (var h = 1; h <= 14; h++) {
          v += 0.05 * math.sin(2 * math.pi * (1000.0 * h) * i / 48000 + h);
        }
        v += 0.02 * (rnd() * 2 - 1);
        x[i] = v;
      }
      final input = ViperAudio(48000, 2, <Float64List>[x, Float64List.fromList(x)]);
      final out = ViperSuperResolution(rate: ViperUpscaleRate.khz192)
          .process(input);

      // 取中段 8192 点做 FFT（192k 域 bin 分辨率 23.4375 Hz），
      // 检查 30 kHz 附近（bin≈1280）有非零能量。
      const n = 8192;
      final re = Float64List(n);
      final im = Float64List(n);
      final w = viperHann(n);
      final off = out.frames ~/ 3;
      for (var i = 0; i < n; i++) {
        re[i] = out.data[0][off + i] * w[i];
      }
      ViperFft(n).transform(re, im);
      var hiEnergy = 0.0;
      for (var k = 1100; k < 1400; k++) {
        hiEnergy += re[k] * re[k] + im[k] * im[k];
      }
      expect(hiEnergy > 1e-8, isTrue, reason: '24kHz 以上重建能量 $hiEnergy');
    });

    test('取消回调可提前终止', () {
      const frames = 48000 ~/ 5;
      final x = tone(frames, 1000);
      final input = ViperAudio(48000, 2, <Float64List>[x, Float64List.fromList(x)]);
      expect(
        () => ViperSuperResolution().process(input, isCancelled: () => true),
        throwsA(isA<ViperCancelled>()),
      );
    });
  });
}
