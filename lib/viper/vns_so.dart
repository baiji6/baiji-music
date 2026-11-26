/// 酷狗「蝰蛇母带」原版 SO 直调引擎（仅 Android arm64-v8a）。
///
/// 直接通过 `dart:ffi` 调用随包内置的 `libvns.so`（JNI 薄封装 + dlopen 加载器），
/// 由它再 `dlopen` 真正含 ViPER Natural Sound DSP 的 `libeffect0.so`。
/// 这是 bai music 5.1 里同款 SO 的原样调用，音质与原 App 逐样本一致。
///
/// ## 为什么只有 Android arm64
/// 这两个 SO 是 Android aarch64 + Bionic libc 的 ELF，桌面 / iOS 无法加载；
/// 且 5.1 包里也只有 `arm64-v8a` 目录带母带引擎。非 arm64 设备 jniLibs 里
/// 根本没有这两个文件 —— 用「文件是否存在 + ELF 魔数」做天然运行时门控，
/// 不可用时调用方自动回退到纯 Dart 的 [ViperStreamProcessor]。
///
/// ## FFI 签名（以 SO 导出符号 + JNI 封装反汇编 + 真机 SO 实测为准）
/// ```c
/// void* vns_stream_open(int inRate, int inCh, int ratio, int channels,
///                       const char* soPath);
/// int   vns_stream_feed(void* st, const short* in, int frames,
///                       float* out, int outCapFloats);   // 返回写出 float 样本数
/// int   vns_stream_flush(void* st, float* out, int outCapFloats);
/// int   vns_stream_out_rate(void* st);
/// void  vns_stream_close(void* st);
/// const char* vns_error(void);
/// ```
/// 注意 1：随包文档里的 Dart 示例把 feed 写成
/// `(st, in, frames, channels, outPtr)` 是**错的** —— 真实第 4 个参数是输出
/// `float*`、第 5 个是容量（见 `Java_com_kgvns_VnsStream_nativeFeed` 调用点
/// 与 `vns_stream_feed` 内对 x3/x4 的使用）。按文档示例调会直接崩溃。
///
/// 注意 2（真机 SO 实测的重要修正）：`vns_stream_open` 的第 4 个参数虽然
/// 在随包文档里叫 `outCh`，但 **SO 实际把它当作升频倍率**（`st[0]`），而
/// `vns_stream_out_rate` 返回 `st[0] * 48000`。实测（48 kHz / stereo 输入）：
///   - 第 4 参 = 2 → 输出 96000、feed 每帧 4 float（2 倍 × 2 声道）
///   - 第 4 参 = 4 → 输出 192000、feed 每帧 8 float（4 倍 × 2 声道）
/// 输出声道恒为 stereo。所以第 4 参必须传 **倍率 = outRate / inRate**，
/// 绝不能传输出采样率或声道数 2 —— 否则 SO 只做 2 倍，而 WAV 头按 192 kHz
/// 声明，会导致成品播放快一倍、时长减半。
library;

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi;

import 'viper_super_resolution.dart' show ViperEngine, ViperOutputSink;

/// SO 引擎探测结果：两个 SO 的绝对路径。
class VnsSoConfig {
  const VnsSoConfig({
    required this.libVnsPath,
    required this.effectSoPath,
  });

  final String libVnsPath;
  final String effectSoPath;
}

/// 探测本机能否直调原版 SO。
///
/// 纯函数（除文件检查外无副作用），供主 isolate 调用后把配置传进子 isolate；
/// 子 isolate 里不能再走 MethodChannel，所以路径必须提前解析。
VnsSoConfig? probeVnsSo(String nativeLibraryDir) {
  if (!Platform.isAndroid || nativeLibraryDir.isEmpty) return null;
  try {
    final lib = '$nativeLibraryDir${Platform.pathSeparator}libvns.so';
    final fx = '$nativeLibraryDir${Platform.pathSeparator}libeffect0.so';
    final a = File(lib), b = File(fx);
    if (!a.existsSync() || !b.existsSync()) return null;
    if (!_isElf(a) || !_isElf(b)) return null;
    return VnsSoConfig(libVnsPath: lib, effectSoPath: fx);
  } catch (_) {
    return null;
  }
}

bool _isElf(File f) {
  try {
    final raf = f.openSync();
    try {
      final h = raf.readSync(4);
      return h.length == 4 &&
          h[0] == 0x7F &&
          h[1] == 0x45 &&
          h[2] == 0x4C &&
          h[3] == 0x46;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return false;
  }
}

// ===== dart:ffi 绑定 =====

typedef _OpenC = ffi.Pointer<ffi.Void> Function(
    ffi.Int32, ffi.Int32, ffi.Int32, ffi.Int32, ffi.Pointer<ffi.Uint8>);
typedef _OpenDart = ffi.Pointer<ffi.Void> Function(
    int, int, int, int, ffi.Pointer<ffi.Uint8>);
typedef _FeedC = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Int16>,
    ffi.Int32,
    ffi.Pointer<ffi.Float>,
    ffi.Int32);
typedef _FeedDart = int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int16>,
    int, ffi.Pointer<ffi.Float>, int);
typedef _FlushC = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, ffi.Int32);
typedef _FlushDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, int);
typedef _RateC = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _RateDart = int Function(ffi.Pointer<ffi.Void>);
typedef _CloseC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _CloseDart = void Function(ffi.Pointer<ffi.Void>);
typedef _ErrorC = ffi.Pointer<ffi.Uint8> Function();
typedef _ErrorDart = ffi.Pointer<ffi.Uint8> Function();

/// 把目标采样率换算成 SO 第 4 参要传的升频倍率。
///
/// 真机实测（48 kHz 输入）：倍率 2 → 96 kHz、倍率 4 → 192 kHz，输出恒 stereo。
/// 这个函数独立出来便于回归测试：曾经误传输出声道数 2，导致 192k 档只升 2 倍、
/// 而 WAV 头按 192 kHz 声明，成品播放快一倍、时长减半。
int vnsSoRatio(int outRate, int inRate) {
  if (inRate <= 0) return 0;
  return outRate ~/ inRate;
}

/// SO 直调升频引擎；接口与纯 Dart 引擎一致，可在流式管线里互换。
class VnsSoEngine implements ViperEngine {
  VnsSoEngine._(
    this._st,
    this._feed,
    this._flush,
    this._close,
    this._errorFn,
    this._effectPtr,
    this.inRate,
    this.inCh,
    this.outRate,
  );

  final ffi.Pointer<ffi.Void> _st;
  final _FeedDart _feed;
  final _FlushDart _flush;
  final _CloseDart _close;
  final _ErrorDart _errorFn;
  final ffi.Pointer<ffi.Uint8> _effectPtr;

  final int inRate;
  final int inCh;
  final int outRate;

  @override
  int get ratio => outRate ~/ inRate;

  String get _lastError {
    try {
      final p = _errorFn();
      return p == ffi.nullptr ? '未知错误' : p.cast<ffi.Utf8>().toDartString();
    } catch (_) {
      return '未知错误';
    }
  }

  /// 打开 SO 流。任何一步失败都抛 [StateError]，由调用方回退纯 Dart 引擎。
  factory VnsSoEngine.open({
    required VnsSoConfig config,
    required int inRate,
    int inCh = 2,
    required int outRate,
  }) {
    try {
      final lib = ffi.DynamicLibrary.open(config.libVnsPath);
      final open = lib.lookupFunction<_OpenC, _OpenDart>('vns_stream_open');
      final feed = lib.lookupFunction<_FeedC, _FeedDart>('vns_stream_feed');
      final flush = lib.lookupFunction<_FlushC, _FlushDart>('vns_stream_flush');
      final rate = lib.lookupFunction<_RateC, _RateDart>('vns_stream_out_rate');
      final close = lib.lookupFunction<_CloseC, _CloseDart>('vns_stream_close');
      final error = lib.lookupFunction<_ErrorC, _ErrorDart>('vns_error');

      // 真机实测：第 4 个参数是升频倍率，不是输出采样率/声道数。
      // out_rate = ratio * 48000，feed 每帧输出 ratio*2 个 float（固定 stereo）。
      // 必须传倍率（192k/48k=4），传 2 只会得到 96k 导致成品快一倍。
      final ratio = vnsSoRatio(outRate, inRate);
      if (ratio < 1) {
        throw StateError('升频倍率非法: outRate=$outRate inRate=$inRate');
      }
      final effectPtr = _toNativeUtf8(config.effectSoPath);
      // soPath 是最后一个参数（nativeOpen 反汇编 @0x8554: w0..w3, x4）。
      // 真机实测：第 3 参 outRate 被 SO 忽略（传 192000/96000 均同）；真正
      // 决定 out_rate 与升频倍率的是第 4 参（文档误标为 outCh，实为 ratio）。
      final st = open(inRate, inCh, outRate, ratio, effectPtr);
      if (st == ffi.nullptr) {
        ffi.malloc.free(effectPtr);
        throw StateError('vns_stream_open 失败（dlopen libeffect0.so 或参数非法）');
      }
      final actual = rate(st);
      return VnsSoEngine._(st, feed, flush, close, error, effectPtr,
          inRate, inCh, actual);
    } catch (e) {
      throw StateError('蝰蛇母带 SO 初始化失败: $e');
    }
  }

  /// 一次性分配的输出缓冲容量（float 个数）。
  ///
  /// SO 内部按 2048 帧块做 DSP，对输出容量要求偏保守（反汇编经验公式约
  /// `frames*4.4*ratio + ratio*16384`），这里留足冗余避免真机返回 -2。
  /// 缓冲按块复用，与歌曲长度无关。
  int capacityFor(int frames) => frames * 64 + 524288;

  /// 推入 48 kHz 立体声 PCM（左右各 [count] 个样本），输出直接写 [sink]。
  @override
  void pushStereo(
    Float64List left,
    Float64List right,
    int count,
    ViperOutputSink sink,
  ) {
    if (count <= 0) return;
    final cap = capacityFor(count);
    final inPtr = ffi.malloc<ffi.Int16>(count * inCh);
    final outPtr = ffi.malloc<ffi.Float>(cap);
    try {
      final iv = inPtr.asTypedList(count * inCh);
      for (var i = 0; i < count; i++) {
        var l = (left[i] * 32767.0).round();
        var r = (right[i] * 32767.0).round();
        if (l < -32768) l = -32768;
        if (l > 32767) l = 32767;
        if (r < -32768) r = -32768;
        if (r > 32767) r = 32767;
        iv[i * 2] = l;
        if (inCh > 1) iv[i * 2 + 1] = r;
      }
      // got = 写出的交错 float 样本数（见 vns_stream_feed 返回累加逻辑）。
      final got = _feed(_st, inPtr, count, outPtr, cap);
      if (got < 0) throw StateError('vns_stream_feed 失败: $_lastError');
      final samples = got > cap ? cap : got;
      _emit(outPtr.asTypedList(samples), samples, sink);
    } finally {
      ffi.malloc.free(inPtr);
      ffi.malloc.free(outPtr);
    }
  }

  /// 冲刷尾部缓冲。
  @override
  void flush(ViperOutputSink sink) {
    final cap = capacityFor(2048);
    final outPtr = ffi.malloc<ffi.Float>(cap);
    try {
      final got = _flush(_st, outPtr, cap);
      if (got < 0) throw StateError('vns_stream_flush 失败: $_lastError');
      final samples = got > cap ? cap : got;
      _emit(outPtr.asTypedList(samples), samples, sink);
    } finally {
      ffi.malloc.free(outPtr);
    }
  }

  void _emit(Float32List src, int samples, ViperOutputSink sink) {
    if (samples <= 0) return;
    final frames = samples ~/ inCh;
    if (frames <= 0) return;
    final use = frames * inCh;
    final dst = Float64List(use);
    for (var i = 0; i < use; i++) {
      dst[i] = src[i];
    }
    sink(dst, frames);
  }

  void close() {
    try {
      _close(_st);
    } catch (_) {}
    try {
      ffi.malloc.free(_effectPtr);
    } catch (_) {}
  }
}

ffi.Pointer<ffi.Uint8> _toNativeUtf8(String s) {
  final units = s.codeUnits; // 路径为 ASCII（/data/app/...），逐字节拷贝即可
  final p = ffi.malloc<ffi.Uint8>(units.length + 1);
  final list = p.asTypedList(units.length + 1);
  for (var i = 0; i < units.length; i++) {
    list[i] = units[i] > 255 ? 0 : units[i];
  }
  list[units.length] = 0;
  return p;
}

/// 便于上层日志展示的版本标识。
const String vnsSoEngineTag = 'vns-so/arm64-v8a';
