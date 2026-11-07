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
///
/// ## 为什么是流式的
/// 早期实现把整首歌一次性读进内存再算：一首 4 分钟的歌在 192 kHz 档下
/// 输出缓冲 703 MB、归一化缓冲 351 MB，再叠加 isolate 消息的深拷贝，峰值
/// 接近 **2.2 GB**——Android 单进程 heap 只有 256~512 MB，必然 OOM。
/// 现在 [ViperStreamProcessor] 逐帧处理：输入是环形窗，输出是定长 OLA
/// 环形缓冲，**内存占用与歌曲长度无关**（常数级，几百 KB）。
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

/// 升频输出回调：交错立体声 PCM（[frames] 帧，即 2×frames 个样本）。
///
/// 回调必须**同步消费**传入的缓冲：实现方会在下一次调用前复用同一块内存。
typedef ViperOutputSink = void Function(Float64List interleaved, int frames);

/// 流式升频处理器。
///
/// 逐帧执行「STFT → 频域带宽扩展 → ISTFT → overlap-add」，输入输出都是
/// 48 kHz → 目标采样率的连续流，**内存占用与音频时长无关**。
///
/// 用法：
/// ```dart
/// final p = ViperStreamProcessor(rate: ViperUpscaleRate.khz192);
/// p.pushStereo(left, right, count, (buf, frames) { /* 写文件 */ });
/// p.flush((buf, frames) { /* 收尾 */ });
/// ```
class ViperStreamProcessor {
  ViperStreamProcessor({
    required this.rate,
    this.tapeEnhance = true,
    this.seed = 0x5EED1234,
  });

  /// 目标采样率档位。
  final ViperUpscaleRate rate;

  /// 是否启用「声音焕新」频响 tilt。
  final bool tapeEnhance;

  /// 确定性相位旋转的随机种子（保证同一输入输出可复现）。
  final int seed;

  /// 解码侧统一采样率。
  static const int baseRate = 48000;

  /// 分析窗长度（48 kHz 域）。
  static const int nLow = 2048;

  /// 分析窗步长（48 kHz 域），50% overlap。
  static const int hopLow = 1024;

  /// 峰值保护上限。
  static const double ceiling = 0.94;

  /// 峰值保护软拐点：低于该幅度完全透明。
  static const double knee = 0.70;

  /// 升频倍率（96k → 2，192k → 4）。
  int get ratio => rate.hz ~/ baseRate;

  /// 目标域窗长度。
  int get nHigh => nLow * ratio;

  /// 目标域步长。
  int get hopHigh => hopLow * ratio;

  /// 目标域半频点 bin（24 kHz）。
  int get kLoMax => nLow >> 1;

  /// 目标域全频点 bin。
  int get kHiMax => nHigh >> 1;

  late final Float64List _wLow = viperHann(nLow);

  /// 目标域的合成归一化窗：分析窗按 ratio 线性拉伸。
  late final Float64List _wSyn = _buildSynWindow();

  late final ViperFft _fftLow = ViperFft(nLow);
  late final ViperFft _fftHigh = ViperFft(nHigh);

  // —— 分析侧工作缓冲（两声道顺序复用）——
  late final Float64List _loRe = Float64List(nLow);
  late final Float64List _loIm = Float64List(nLow);
  late final Float64List _hiRe = Float64List(nHigh);
  late final Float64List _hiIm = Float64List(nHigh);
  late final Float64List _mag = Float64List(kLoMax + 1);
  late final Float64List _env = Float64List(kLoMax + 1);

  // —— 每声道的输入环形窗（保存最近 nLow 个样本）——
  final List<Float64List> _srcBuf = <Float64List>[
    Float64List(nLow),
    Float64List(nLow),
  ];
  final List<int> _wpos = <int>[0, 0];
  final List<int> _recv = <int>[0, 0];

  // —— 每声道的 OLA 累加缓冲 ——
  late final List<Float64List> _outBuf = <Float64List>[
    Float64List(nHigh),
    Float64List(nHigh),
  ];
  late final List<Float64List> _normBuf = <Float64List>[
    Float64List(nHigh),
    Float64List(nHigh),
  ];
  final List<double> _prevEnergy = <double>[0.0, 0.0];

  /// [_outBuf] / [_normBuf] 的 0 号槽对应的全局样本位置。
  int _outBase = 0;

  /// 已经归一化输出到的全局样本位置（不含）。
  int _emitted = 0;

  /// 已完成的分析帧数。
  int _framesDone = 0;

  /// 输出暂存区（交错立体声）。
  late final Float64List _stage = Float64List(4 * hopHigh);
  int _stageFrames = 0;

  /// 已接收的总样本数（单声道计数）。
  int get receivedFrames => _recv[0];

  /// 推入 48 kHz 立体声 PCM（左右各 [count] 个样本）。
  ///
  /// 内部会按需处理整帧，完成的输出通过 [sink] 回调送出。
  void pushStereo(
    Float64List left,
    Float64List right,
    int count,
    ViperOutputSink sink,
  ) {
    for (var i = 0; i < count; i++) {
      final l = _srcBuf[0];
      final r = _srcBuf[1];
      var wp = _wpos[0];
      l[wp] = left[i];
      wp = (wp + 1) % nLow;
      _wpos[0] = wp;
      _recv[0]++;
      wp = _wpos[1];
      r[wp] = right[i];
      wp = (wp + 1) % nLow;
      _wpos[1] = wp;
      _recv[1]++;

      // 窗口填满即可开一帧（帧窗口长度 nLow，步长 hopLow）。
      while (_framesDone * hopLow + nLow <= _recv[0]) {
        _processFrame(sink);
        _framesDone++;
      }
    }
  }

  /// 结束推流：补零冲刷尾部帧并输出剩余样本。
  ///
  /// [sink] 会收到全部剩余输出；输出总帧数 = 输入帧数 × ratio。
  void flush(ViperOutputSink sink) {
    final srcLen = _recv[0];
    final numFrames = _planFrames(srcLen);
    while (_framesDone < numFrames) {
      _processFrame(sink);
      _framesDone++;
    }
    // 尾部：最后几帧只被一帧覆盖（归一化量不足），与整段实现一致。
    final totalOut = math.min(srcLen * ratio, (numFrames + 1) * hopHigh);
    while (_emitted < totalOut) {
      _emitOne(sink);
    }
    _flushStage(sink);
  }

  /// 分析帧总数：与整段实现保持一致（含尾部补零帧）。
  static int _planFrames(int srcLen) {
    final n = (((srcLen - nLow) / hopLow).ceil() + 1);
    return n < 1 ? 1 : n;
  }

  void _processFrame(ViperOutputSink sink) {
    final f = _framesDone;
    for (var ch = 0; ch < 2; ch++) {
      _analyze(ch, f);
      _synthesize(ch);
    }
    _emitReady(f, sink);
  }

  /// 取第 [ch] 声道的分析窗样本（越界补零）。
  double _windowSample(int ch, int f, int n) {
    final gi = f * hopLow + n;
    final recv = _recv[ch];
    if (gi >= recv) return 0.0;
    final oldest = recv - nLow;
    final idx = (_wpos[ch] + gi - oldest) % nLow;
    return _srcBuf[ch][idx];
  }

  void _analyze(int ch, int f) {
    var energy = 0.0;
    for (var i = 0; i < nLow; i++) {
      final v = _windowSample(ch, f, i);
      energy += v * v;
      _loRe[i] = v * _wLow[i];
      _loIm[i] = 0.0;
    }
    energy /= nLow;
    final transient =
        _prevEnergy[ch] > 1e-12 && energy > _prevEnergy[ch] * 3.0;
    _prevEnergy[ch] = energy;

    _fftLow.transform(_loRe, _loIm);

    for (var k = 0; k <= kLoMax; k++) {
      _mag[k] = math.sqrt(_loRe[k] * _loRe[k] + _loIm[k] * _loIm[k]);
    }
    _smoothEnvelope(_mag, _env, kLoMax);
    final flatness = _spectralFlatness(_mag, kLoMax);

    // —— 构造目标分辨率频谱 ——
    _hiRe.fillRange(0, nHigh, 0.0);
    _hiIm.fillRange(0, nHigh, 0.0);

    final binRes = baseRate / nLow; // 23.4375 Hz/bin，两个域一致
    for (var k = 0; k <= kLoMax; k++) {
      final tilt = tapeEnhance ? _tapeTilt(k * binRes, ch) : 1.0;
      _hiRe[k] = _loRe[k] * ratio * tilt;
      _hiIm[k] = _loIm[k] * ratio * tilt;
    }
    _hiIm[0] = 0.0;
    _hiIm[kLoMax] = 0.0; // Nyquist bin 必须是实数

    // 24 kHz 以上：SBR 频域带宽扩展。
    _extendHigh(
      loRe: _loRe,
      loIm: _loIm,
      hiRe: _hiRe,
      hiIm: _hiIm,
      env: _env,
      mag: _mag,
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
      _hiRe[nHigh - k] = _hiRe[k];
      _hiIm[nHigh - k] = -_hiIm[k];
    }
  }

  void _synthesize(int ch) {
    _fftHigh.transform(_hiRe, _hiIm, inverse: true);
    final out = _outBuf[ch];
    final norm = _normBuf[ch];
    // 当前基址恰好是本帧起点（上一帧收尾时已对齐）。
    for (var i = 0; i < nHigh; i++) {
      out[i] += _hiRe[i];
      norm[i] += _wSyn[i];
    }
  }

  /// 帧 [f] 处理完后，把已经完备的输出区间归一化写出。
  void _emitReady(int f, ViperOutputSink sink) {
    final limit = (f + 1) * hopHigh;
    while (_emitted < limit) {
      _emitOne(sink);
    }
    // 剩余未输出的尾巴搬到缓冲起点，为下一帧腾出空间。
    final shift = limit - _outBase;
    if (shift > 0) {
      for (var ch = 0; ch < 2; ch++) {
        final out = _outBuf[ch];
        final norm = _normBuf[ch];
        _shiftTail(out, shift);
        _shiftTail(norm, shift);
      }
      _outBase = limit;
    }
  }

  /// 把 [buf] 从 [shift] 开始的内容整体前移 [shift] 位，尾部清零。
  ///
  /// Dart 的 `Float64List` 没有 `copyWithin`，用 `setRange` 等价实现
  /// （`setRange` 的源与目标允许重叠，语义与 `copyWithin` 一致）。
  static void _shiftTail(Float64List buf, int shift) {
    final n = buf.length;
    if (shift <= 0 || shift >= n) return;
    buf.setRange(0, n - shift, buf, shift);
    buf.fillRange(n - shift, n, 0.0);
  }

  /// 归一化并写出下一个输出样本（交错双声道）。
  void _emitOne(ViperOutputSink sink) {
    final idx = _emitted - _outBase;
    var v0 = 0.0;
    var v1 = 0.0;
    if (idx >= 0 && idx < nHigh) {
      final n0 = _normBuf[0][idx];
      final n1 = _normBuf[1][idx];
      v0 = n0 > 1e-9 ? _outBuf[0][idx] / n0 : 0.0;
      v1 = n1 > 1e-9 ? _outBuf[1][idx] / n1 : 0.0;
    }
    v0 = limitPeak(v0);
    v1 = limitPeak(v1);
    _stage[_stageFrames * 2] = v0;
    _stage[_stageFrames * 2 + 1] = v1;
    _stageFrames++;
    _emitted++;
    if (_stageFrames >= hopHigh) {
      _flushStage(sink);
    }
  }

  void _flushStage(ViperOutputSink sink) {
    if (_stageFrames == 0) return;
    sink(_stage, _stageFrames);
    _stageFrames = 0;
  }

  /// 峰值保护：超过 [knee] 后平滑压到 [ceiling] 以内。
  ///
  /// 语义与旧实现一致（旧实现是「整首歌统一乘 headroom/peak」），但改成
  /// 逐样本软拐点：低于拐点完全透明，只削真正的峰值，且不需要为了求全局
  /// 峰值把整首歌在内存里跑两遍。
  static double limitPeak(double v) {
    final a = v.abs();
    if (a <= knee) return v;
    final x = (a - knee) / (ceiling - knee);
    final y = knee + (ceiling - knee) * (1.0 - math.exp(-x));
    return v < 0 ? -y : y;
  }

  Float64List _buildSynWindow() {
    final w = Float64List(nHigh);
    for (var j = 0; j < nHigh; j++) {
      final t = j / ratio;
      final i0 = t.floor();
      final f = t - i0;
      w[j] = i0 + 1 < nLow
          ? _wLow[i0] * (1 - f) + _wLow[i0 + 1] * f
          : _wLow[nLow - 1];
    }
    return w;
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
      final targetEnv =
          env[s0] * math.pow(10.0, -4.5 * math.log(m) / math.log(2) / 20).toDouble();
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
}

/// 整段（非流式）升频封装：把整段 PCM 交给 [ViperStreamProcessor]。
///
/// 仅供离线分析与测试使用；生产路径请用流式版本，避免大内存占用。
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
    // 1) 统一到 48 kHz / 立体声。
    final base = <Float64List>[];
    for (var c = 0; c < math.min(2, input.channels); c++) {
      final src = input.data[c];
      base.add(input.sampleRate == ViperStreamProcessor.baseRate
          ? src
          : _resample(src, input.sampleRate, ViperStreamProcessor.baseRate));
    }
    while (base.length < 2) {
      base.add(Float64List.fromList(base.first));
    }
    final srcLen = base[0].length;
    if (srcLen == 0) {
      return ViperAudio(
          rate.hz, 2, <Float64List>[Float64List(0), Float64List(0)]);
    }

    // 2) 流式处理。
    final processor = ViperStreamProcessor(
      rate: rate,
      tapeEnhance: tapeEnhance,
      seed: seed,
    );
    final total = srcLen * processor.ratio;
    final outL = Float64List(total);
    final outR = Float64List(total);
    var written = 0;

    void sink(Float64List buf, int frames) {
      for (var i = 0; i < frames; i++) {
        final p = written + i;
        if (p >= total) break;
        outL[p] = buf[i * 2];
        outR[p] = buf[i * 2 + 1];
      }
      written += frames;
      if (onProgress != null) {
        onProgress(math.min(1.0, written / total));
      }
    }

    const chunk = 8192;
    for (var off = 0; off < srcLen; off += chunk) {
      if (isCancelled?.call() == true) throw const ViperCancelled();
      final n = math.min(chunk, srcLen - off);
      processor.pushStereo(
        base[0].sublist(off, off + n),
        base[1].sublist(off, off + n),
        n,
        sink,
      );
    }
    if (isCancelled?.call() == true) throw const ViperCancelled();
    processor.flush(sink);
    onProgress?.call(1.0);
    return ViperAudio(rate.hz, 2, <Float64List>[outL, outR]);
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
