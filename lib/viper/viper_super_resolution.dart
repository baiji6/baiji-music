/// 本地音频升频引擎（「蝰蛇母带」同构复刻，纯 Dart）。
///
/// ## 与官方算法的关系（务必如实理解）
/// 反编译酷狗 64 位官方 APK 的 `lib/arm64-v8a/libsuperR.so` 可见其真实链路：
/// `ISuperResolution::Create(samplerate, SuperResolutionModelType)` →
/// `CSuperResolutionMTK` → `SuperResolutionEigen::createHannWindow / stft /
/// istft / getBlockSize / getOverlapSize / specToAudioOverlap /
/// process_audio_to_tensor` → `NeuronModel_* / NeuronCompilation_* /
/// NeuronExecution_compute`（`com.mediatek.compiled_network`，联发科 NPU）
/// → 对外 `nsSuperResolution::processS16(void*, short*, int, int)`。
/// 即 **16-bit PCM → Hann 窗 STFT → 频谱张量 → 端侧 DNN 超分 → ISTFT +
/// overlap-add → 96k/192k 24bit**。模型权重由服务端运行时下发
/// （`setModelPath`），且是绑定天玑 NPU 的编译网，**无法移植到本 App**。
///
/// 本模块按**相同骨架**用公开算法复刻，不依赖任何模型权重：
/// 1. 解码侧统一到 48 kHz / 立体声；
/// 2. Hann 窗 STFT（N=2048，hop=1024，50% overlap，与 OLA 的 COLA 一致）；
/// 3. **频域带宽扩展**——因为 `targetRate/48000 == nHigh/nLow`，两个域的
///    bin 频率分辨率完全相同（23.4375 Hz），低频 bins 原样搬过去，缺失的
///    24 kHz 以上 bins 用 SBR / eSBR 思路的子带倍频转置生成：
///    谱包络外推整形 + 确定性相位去相关 + 谱平坦度驱动的音调/噪声混合 +
///    瞬态抑制，并做「声音焕新」式频响 tilt；
/// 4. 一次 ISTFT（N=nLow×ratio）+ 合成窗 OLA，直接得到目标采样率 PCM；
/// 5. 输出 24-bit WAV（见 [ViperWav]）。
///
/// 这是对**公开 BWE/超分原理**的自主实现，不是酷狗闭源 DNN 模型的复刻；
/// 生成的高频是依据低频信号重建的感知近似，并非原始母带中真实存在的
/// 高频信息。UI 与文档都会明确标注这一点。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'viper_fft.dart';
import 'viper_wav.dart';

/// 升频目标采样率。96 kHz 为快速档，192 kHz 为母带档。
enum ViperUpscaleRate {
  khz96(96000, '96 kHz / 24 bit'),
  khz192(192000, '192 kHz / 24 bit');

  const ViperUpscaleRate(this.hz, this.label);

  final int hz;
  final String label;
}

/// 升频结果（含可展示的处理说明）。
class ViperSuperResolution {
  const ViperSuperResolution({
    this.rate = ViperUpscaleRate.khz192,
    this.tapeEnhance = true,
    this.seed = 0x5EED1234,
  });

  final ViperUpscaleRate rate;
  final bool tapeEnhance;
  final int seed;

  /// 算法说明（UI 展示，保持诚实）。
  static const String algorithmNote = 'STFT/OLA + SBR 频域带宽扩展 + 感知焕新，'
      '按酷狗 libsuperR.so 的算法骨架用公开算法自主实现；'
      '非官方 DNN 模型，高频为感知重建而非原始母带信息。';

  /// 把 [input] 升频到 [rate]，返回新的 [ViperAudio]。
  ///
  /// [onProgress] 返回 0..1；[isCancelled] 返回 true 时提前终止并抛
  /// [ViperCancelled]。输入任意采样率/声道数，输出 2 声道（单声道复制，
  /// 多声道取前两路）。
  ViperAudio process(
    ViperAudio input, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) {
    final targetRate = rate.hz;
    const baseRate = 48000;
    final ratio = targetRate ~/ baseRate; // 2 (96k) 或 4 (192k)
    const nLow = 2048;
    const hopLow = 1024;
    final nHigh = nLow * ratio;
    final hopHigh = hopLow * ratio;

    // 1) 统一到 48 kHz；主路径由 ffmpeg 直接输出 48k，这里只是兜底。
    final base = <Float64List>[];
    for (var c = 0; c < math.min(2, input.channels); c++) {
      final src = input.data[c];
      base.add(input.sampleRate == baseRate
          ? src
          : _resample(src, input.sampleRate, baseRate));
    }
    while (base.length < 2) {
      base.add(Float64List.fromList(base.first));
    }

    final srcLen = base[0].length;
    if (srcLen == 0) return ViperAudio(targetRate, 2, [Float64List(0), Float64List(0)]);

    // 分析窗用 Hann；合成窗用矩形（1.0），归一化逐点累加分析窗。
    //
    // 为什么不用「Hann 分析 + Hann 合成」：周期 Hann 在 50% overlap 下
    // Σw 是常数 1，但 Σw² 不是（残留 0.25·cos(4πi/N) 的波动），用 w²
    // 归一化会带来约 33% 的周期性幅度调制，听感上是明显的周期性颤抖。
    // 矩形合成 + Σw 归一化才是严格 COLA（完美重构）。
    final wLow = viperHann(nLow);
    final wSyn = Float64List(nHigh);
    for (var j = 0; j < nHigh; j++) {
      final t = j / ratio;
      final i0 = t.floor();
      final f = t - i0;
      wSyn[j] = i0 + 1 < nLow
          ? wLow[i0] * (1 - f) + wLow[i0 + 1] * f
          : wLow[nLow - 1];
    }
    final fftLow = ViperFft(nLow);
    final fftHigh = ViperFft(nHigh);
    final binRes = baseRate / nLow; // 23.4375 Hz/bin，两个域一致
    final kLoMax = nLow >> 1; // 1024 → 24 kHz
    final kHiMax = nHigh >> 1;

    final numFrames = math.max(1, ((srcLen - nLow) / hopLow).ceil() + 1);
    final outLen = (numFrames - 1) * hopHigh + nHigh;
    final outCh = <Float64List>[];
    final norm = Float64List(outLen);

    // 缓冲复用，避免每帧分配。
    final loRe = Float64List(nLow);
    final loIm = Float64List(nLow);
    final hiRe = Float64List(nHigh);
    final hiIm = Float64List(nHigh);
    final mag = Float64List(kLoMax + 1);
    final env = Float64List(kLoMax + 1);

    var nextProgress = 0.05;
    for (var ch = 0; ch < 2; ch++) {
      if (isCancelled?.call() == true) throw const ViperCancelled();
      final src = base[ch];
      final out = Float64List(outLen);
      norm.fillRange(0, outLen, 0.0);
      var prevEnergy = 0.0;

      for (var f = 0; f < numFrames; f++) {
        if ((f & 127) == 0 && isCancelled?.call() == true) {
          throw const ViperCancelled();
        }
        final start = f * hopLow;

        // --- STFT 分析 ---
        var energy = 0.0;
        for (var i = 0; i < nLow; i++) {
          final idx = start + i;
          final v = idx < srcLen ? src[idx] : 0.0;
          energy += v * v;
          loRe[i] = v * wLow[i];
          loIm[i] = 0.0;
        }
        energy /= nLow;
        final transient = prevEnergy > 1e-12 && energy > prevEnergy * 3.0;
        prevEnergy = energy;

        fftLow.transform(loRe, loIm);

        for (var k = 0; k <= kLoMax; k++) {
          mag[k] = math.sqrt(loRe[k] * loRe[k] + loIm[k] * loIm[k]);
        }
        _smoothEnvelope(mag, env, kLoMax);
        final flatness = _spectralFlatness(mag, kLoMax);

        // --- 构造目标分辨率频谱 ---
        hiRe.fillRange(0, nHigh, 0.0);
        hiIm.fillRange(0, nHigh, 0.0);

        // 低 0~24 kHz：原样搬移，乘 ratio 补偿 IFFT 的 1/N 归一化。
        for (var k = 0; k <= kLoMax; k++) {
          final tilt = tapeEnhance ? _tapeTilt(k * binRes, ch) : 1.0;
          hiRe[k] = loRe[k] * ratio * tilt;
          hiIm[k] = loIm[k] * ratio * tilt;
        }
        hiIm[0] = 0.0;
        hiIm[kLoMax] = 0.0; // Nyquist bin 必须是实数

        // 24 kHz 以上：SBR 频域带宽扩展。
        _extendHigh(
          loRe: loRe,
          loIm: loIm,
          hiRe: hiRe,
          hiIm: hiIm,
          env: env,
          mag: mag,
          kLoMax: kLoMax,
          kHiMax: kHiMax,
          nHigh: nHigh,
          binRes: binRes,
          ratio: ratio,
          flatness: flatness,
          transient: transient,
          frame: f,
          channel: ch,
        );

        // 负频率共轭镜像，保证 IFFT 输出为实数。
        for (var k = 1; k < kHiMax; k++) {
          hiRe[nHigh - k] = hiRe[k];
          hiIm[nHigh - k] = -hiIm[k];
        }

        // --- ISTFT + 合成窗 OLA ---
        fftHigh.transform(hiRe, hiIm, inverse: true);
        final oh = f * hopHigh;
        for (var i = 0; i < nHigh; i++) {
          out[oh + i] += hiRe[i]; // 矩形合成窗
          norm[oh + i] += wSyn[i]; // Σ 分析窗 = 1（COLA）
        }

        if (onProgress != null && f % 64 == 0) {
          final p = 0.05 +
              0.9 * ((ch * numFrames + f) / (2 * numFrames));
          if (p >= nextProgress) {
            onProgress(math.min(0.95, p));
            nextProgress = p + 0.02;
          }
        }
      }

      // OLA 归一化。
      for (var i = 0; i < outLen; i++) {
        final n = norm[i];
        out[i] = n > 1e-9 ? out[i] / n : 0.0;
      }
      final wanted = math.min(outLen, srcLen * ratio);
      outCh.add(Float64List.sublistView(out, 0, wanted));
    }
    onProgress?.call(1.0);
    return ViperAudio(targetRate, 2, outCh);
  }

  /// SBR / eSBR 频域带宽扩展：从低频子带倍频转置出高频 bins。
  ///
  /// - `srcBin = k / m`，取使源 bin 落在 1.5~18 kHz 的最小整数倍频 m，
  ///   保持谐波结构（而非简单频谱搬移）；
  /// - 目标谱包络按 `m` 做 4.5 dB/oct 衰减外推，并把增益钳在 1.3 以内，
  ///   避免把编码噪声放大成刺耳的「沙沙」声；
  /// - 确定性相位去相关 + 谱平坦度驱动的噪声混合，抑制复制带来的金属声；
  /// - 32 kHz 以上逐步 taper 到 0（48 kHz 以上不生成内容：人耳不可闻，
  ///   且避免超声能量过载）；瞬态帧整体压低高频注入，防 pre-echo。
  void _extendHigh({
    required Float64List loRe,
    required Float64List loIm,
    required Float64List hiRe,
    required Float64List hiIm,
    required Float64List env,
    required Float64List mag,
    required int kLoMax,
    required int kHiMax,
    required int nHigh,
    required double binRes,
    required int ratio,
    required double flatness,
    required bool transient,
    required int frame,
    required int channel,
  }) {
    final sMin = (1500 / binRes).round(); // ≈64 (1.5 kHz)
    final sMax = math.min(kLoMax - 2, (18000 / binRes).round()); // ≈768
    final transientGain = transient ? 0.55 : 1.0;
    final noiseMix = math.min(0.45, 0.12 + 0.45 * flatness);

    for (var k = kLoMax + 1; k <= kHiMax; k++) {
      final freq = k * binRes;
      if (freq >= 48000) break; // 48 kHz 以上不生成，保持静默

      // 倍频转置：找最小 m 使 srcBin 落进富谐波的低频带。
      var m = 2;
      while (m <= 12 && k / m > sMax) {
        m++;
      }
      final s = k / m;
      if (s < sMin || s >= kLoMax) continue;

      final s0 = s.floor();
      final t = s - s0;
      final srcRe = loRe[s0] * (1 - t) + loRe[s0 + 1] * t;
      final srcIm = loIm[s0] * (1 - t) + loIm[s0 + 1] * t;
      final srcMag = math.sqrt(srcRe * srcRe + srcIm * srcIm);

      // 谱包络外推：倍频每翻一番衰减 4.5 dB。
      final targetEnv = env[s0] * math.pow(10.0, -4.5 * math.log(m) / math.log(2) / 20).toDouble();
      final shaped = math.min(1.3, targetEnv / (srcMag + 1e-9));

      // 32 kHz 起平滑收尾（taper 到 48 kHz 归零）。
      var taper = 1.0;
      if (freq > 32000) {
        final u = (freq - 32000) / 16000.0;
        taper = math.pow(math.max(0.0, 1.0 - u), 1.5).toDouble();
      }
      final tilt = tapeEnhance ? _tapeTilt(freq, channel) : 1.0;
      final gain = shaped * taper * tilt * transientGain;

      // 确定性相位旋转：去相关，避免整段复制产生梳状/金属染色。
      final phi = 2 * math.pi * _hash01(k, frame, channel, seed);
      final cp = math.cos(phi);
      final sp = math.sin(phi);
      final rr = srcRe * cp - srcIm * sp;
      final ri = srcRe * sp + srcIm * cp;

      // 音调/噪声混合：噪声型帧补一点去相关噪声底，音调型帧保持转置。
      final n1 = _hash01(k, frame, channel + 7, seed ^ 0xA5A5);
      final n2 = _hash01(k, frame, channel + 11, seed ^ 0x3C3C);
      final nPhi = 2 * math.pi * n1;
      final nAmp = (env[s0] + 1e-9) * taper * noiseMix * n2;

      final scale = ratio * gain;
      hiRe[k] = rr * scale + math.cos(nPhi) * nAmp * ratio;
      hiIm[k] = ri * scale + math.sin(nPhi) * nAmp * ratio;
      hiRe[nHigh - k] = hiRe[k];
      hiIm[nHigh - k] = -hiIm[k];
    }
  }

  /// 「声音焕新」式频响 tilt：低频略厚、高频略亮，左右声道差 3% 制造宽度。
  double _tapeTilt(double freq, int channel) {
    double t;
    if (freq < 120) {
      t = 1.015;
    } else if (freq < 3000) {
      t = 1.0;
    } else if (freq < 12000) {
      t = 1.0 + 0.022 * (freq - 3000) / 9000.0;
    } else {
      t = 1.022;
    }
    final d = t - 1.0;
    return 1.0 + d * (channel == 0 ? 1.03 : 0.97);
  }

  /// 双向一阶平滑，得到谱包络。
  static void _smoothEnvelope(
      Float64List mag, Float64List env, int kMax) {
    var acc = mag[0];
    for (var k = 0; k <= kMax; k++) {
      acc = 0.72 * acc + 0.28 * mag[k];
      env[k] = acc;
    }
    acc = env[kMax];
    for (var k = kMax; k >= 0; k--) {
      acc = 0.72 * acc + 0.28 * env[k];
      env[k] = acc;
    }
  }

  /// 谱平坦度（几何均值/算术均值），0=纯音调，1=纯噪声。
  static double _spectralFlatness(Float64List mag, int kMax) {
    final from = (1500 / 23.4375).round();
    final to = math.min(kMax, (18000 / 23.4375).round());
    var sumLog = 0.0;
    var sumLin = 0.0;
    var n = 0;
    for (var k = from; k <= to; k++) {
      final p = mag[k] * mag[k] + 1e-12;
      sumLog += math.log(p);
      sumLin += p;
      n++;
    }
    if (n == 0 || sumLin <= 0) return 0.5;
    return math.min(1.0, math.max(0.0, math.exp(sumLog / n) / (sumLin / n)));
  }

  static double _hash01(int a, int b, int c, int seed) {
    var h = (a * 2654435761) ^ (b * 40503) ^ (c * 2246822519) ^ seed;
    h &= 0xFFFFFFFF;
    h ^= h >>> 16;
    h = (h * 0x7FEB352D) & 0xFFFFFFFF;
    h ^= h >>> 15;
    h = (h * 0x846CA68B) & 0xFFFFFFFF;
    h ^= h >>> 16;
    return (h & 0xFFFFFF) / 0xFFFFFF;
  }

  /// 兜底重采样：窗化 sinc（Blackman）插值，主路径由 ffmpeg 直接给 48k。
  static Float64List _resample(Float64List src, int srcRate, int dstRate) {
    if (srcRate == dstRate) return src;
    final ratio = dstRate / srcRate;
    final outLen = (src.length * ratio).floor();
    final out = Float64List(outLen);
    const half = 24;
    final cutoff = ratio < 1.0 ? ratio : 1.0;
    const twoPi = 2 * math.pi;
    for (var i = 0; i < outLen; i++) {
      final pos = i / ratio;
      final center = pos.floor();
      var acc = 0.0;
      var wsum = 0.0;
      for (var k = center - half; k <= center + half + 1; k++) {
        if (k < 0 || k >= src.length) continue;
        final t = pos - k;
        final s = t.abs() < 1e-9
            ? cutoff
            : math.sin(math.pi * t * cutoff) / (math.pi * t);
        final u = (t + half) / (2 * half);
        final w = 0.42 - 0.5 * math.cos(twoPi * u) + 0.08 * math.cos(4 * math.pi * u);
        final h = s * w;
        acc += src[k] * h;
        wsum += h;
      }
      out[i] = wsum.abs() > 1e-9 ? acc / wsum : 0.0;
    }
    return out;
  }
}

/// 用户取消升频任务。
class ViperCancelled implements Exception {
  const ViperCancelled();

  @override
  String toString() => '升频任务已取消';
}
