/// QQ 音乐 NAC（TL01）神经音频解码支持（v2.4.2-pre12）。
///
/// 原生实现见 `android/app/src/main/cpp/nac_glue.cpp`：
///   NAC 容器解析 → 10bit codes 解包（LSB-first + 转置）
///     → MNN 推理（官方 libMNN_dl.so，流式 buffer 回灌）
///     → 复数谱 freq → ISTFT（Hann 512 / hop 256 / OLA）
///     → 44.1kHz / 16bit / 立体声 WAV
///
/// 与 DTS:X / 360RA 同构：原生解码 → WAV 缓存 → 本地播放，
/// 失败时沿音质降级链自动绕开。
///
/// ABI 覆盖：官方只为 arm64-v8a 下发 MNN 引擎库，armeabi-v7a / x86 系
/// [isSupported] 返回 false。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../core/app_logger.dart';
import '../core/wav_cache.dart';

/// 解码产物：WAV 文件路径。
class NacDecodeResult {
  final String wavPath;
  const NacDecodeResult(this.wavPath);
}

class NacMusic {
  NacMusic._();

  /// 神经解码模型（QQ 音乐 CDN；文件名与 NAC 容器参数 cb22/257 吻合）。
  static const _modelAsset = 'assets/nac/7187332.mnn';
  static const _modelName = '7187332.mnn';

  static DynamicLibrary? _lib;
  static bool _probed = false;
  static bool _supported = false;
  static String? _modelPath;

  /// 进行中的解码任务（按歌曲 key 去重，同 [DtsMusic] 语义）。
  static final Map<String, Future<NacDecodeResult?>> _inflight = {};

  /// 运行时探测：仅 Android（arm64）尝试加载，进程内只探测一次。
  static bool get isSupported {
    if (_probed) return _supported;
    _probed = true;
    if (!Platform.isAndroid) {
      AppLog.i('NacMusic', '非 Android 平台，NAC 不可用');
      return _supported = false;
    }
    try {
      _lib ??= DynamicLibrary.open('libnac_glue.so');
      final abi = _lib!
          .lookupFunction<Int32 Function(), int Function()>(
              'nacglue_abi_available');
      _supported = abi() == 1;
      if (_supported) {
        AppLog.i('NacMusic', 'NAC 原生链路探测: 可用');
      } else {
        final detail = _lib!
            .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
                'nacglue_probe_detail')();
        AppLog.w('NacMusic', 'NAC 原生链路探测失败: ${detail.toDartString()}');
      }
    } catch (e) {
      AppLog.w('NacMusic', 'libnac_glue.so 加载失败（旧包或非官方 ABI）: $e');
      _supported = false;
    }
    return _supported;
  }

  // ===== FFI 基础 =====

  static Pointer<Uint8> _cstr(String s) {
    final units = utf8.encode(s);
    final p = malloc<Uint8>(units.length + 1);
    final list = p.asTypedList(units.length + 1);
    list.setRange(0, units.length, units);
    list[units.length] = 0;
    return p;
  }

  /// 工作目录（模型与缓存）：`<cache>/nac/`。
  static Future<String> _workRoot() async {
    final dir = await getApplicationCacheDirectory();
    final d = Directory('${dir.path}${Platform.pathSeparator}nac');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.path;
  }

  /// 解包神经解码模型（幂等）。
  static Future<String> _ensureModel() async {
    if (_modelPath != null) return _modelPath!;
    final root = await _workRoot();
    final f = File('$root${Platform.pathSeparator}$_modelName');
    if (!f.existsSync() || f.lengthSync() < 1024) {
      final data = await rootBundle.load(_modelAsset);
      f.writeAsBytesSync(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true);
    }
    _modelPath = f.path;
    AppLog.i('NacMusic', 'NAC 模型就绪: ${f.path} ${f.lengthSync()}B');
    return f.path;
  }

  /// 取解码产物缓存路径（WAV）。
  static Future<String> wavPathFor(String key) async {
    final root = await _workRoot();
    return '$root${Platform.pathSeparator}nac_$key.wav';
  }

  /// 判断某首歌的 NAC 缓存是否已就绪（再次播放零等待）。
  ///
  /// v2.5.8-fix1：不能只看文件是否存在——原生解码器边解码边写最终路径，
  /// 中途的文件开头是 44 字节全 0，播了会报 `Failed to recognize file
  /// format.`；被中断留下的残文件同理。这里校验 WAV 完整性并自动清理残文件。
  static Future<bool> hasCachedWav(String key) async => WavCache.isValidCache(
        File(await wavPathFor(key)),
        tag: 'NacMusic',
      );

  /// 删除某首歌的缓存（wav / 半成品 / nac）。
  static Future<void> clearCache(String key) async {
    final root = await _workRoot();
    for (final name in [
      'nac_$key.wav',
      'nac_$key.wav.part',
      'nac_$key.nac',
    ]) {
      final f = File('$root${Platform.pathSeparator}$name');
      if (f.existsSync()) f.deleteSync();
    }
  }

  /// 若同 key 的解码正在进行，返回该任务 Future（同 [DtsMusic.waitOngoing]）。
  static Future<NacDecodeResult?>? waitOngoing(String key) => _inflight[key];

  /// 转码工具用：把**本地** .nac 直接解成指定 WAV（v2.4.7）。
  /// 复用 [decodeToWav] 同一套 FFI，只是跳过下载与缓存 key。
  static Future<String?> decodeLocalToWav(
    String sourcePath,
    String wavPath,
  ) async {
    if (!isSupported) return null;
    final modelPath = await _ensureModel();
    final part = WavCache.partPath(wavPath);
    try {
      // 上次解码若被中断，先清掉半成品，避免 native 以 "wb" 覆盖时残留。
      final partFile = File(part);
      if (partFile.existsSync()) partFile.deleteSync();
      final out = await Isolate.run(() => _decodeNative(
            nacPath: sourcePath,
            wavPath: part,
            modelPath: modelPath,
          ));
      if (out == null) return null;
      if (!await WavCache.commit(part, wavPath, tag: 'NacMusic')) return null;
      return wavPath;
    } catch (e) {
      AppLog.w('NacMusic', '本地转 WAV 失败: $e');
      return null;
    }
  }

  /// 下载 .nac 到缓存并解码成 WAV（44.1k/16bit/2ch）。
  ///
  /// [onProgress] 进度 0~100（下载占前 10%，解码占后 90%）。
  /// 返回 null 表示失败（调用方走音质降级链）。
  static Future<NacDecodeResult?> decodeToWav(
    String nacUrl,
    String key, {
    void Function(int pct, String stage)? onProgress,
  }) async {
    if (!isSupported) return null;
    final existing = _inflight[key];
    if (existing != null) {
      AppLog.i('NacMusic', 'NAC 解码进行中（key=$key），复用既有任务');
      try {
        return await existing;
      } catch (e) {
        AppLog.w('NacMusic', '复用的 NAC 解码任务失败: $e');
        return null;
      }
    }
    final task = _decodeToWavGuarded(nacUrl, key, onProgress: onProgress);
    _inflight[key] = task;
    try {
      return await task;
    } catch (e) {
      AppLog.e('NacMusic', 'NAC 链路异常: $e');
      return null;
    } finally {
      _inflight.remove(key);
    }
  }

  static Future<NacDecodeResult?> _decodeToWavGuarded(
    String nacUrl,
    String key, {
    void Function(int pct, String stage)? onProgress,
  }) async {
    final modelPath = await _ensureModel();
    final wavPath = await wavPathFor(key);
    final part = WavCache.partPath(wavPath);

    // 秒开：只有**完整**的缓存才直接回放（残文件会在 hasCachedWav 里清掉）。
    if (await hasCachedWav(key)) {
      onProgress?.call(100, 'cached');
      return NacDecodeResult(wavPath);
    }
    // 清掉上次中断留下的半成品，避免与新解码的写入混在一起。
    final partFile = File(part);
    if (partFile.existsSync()) partFile.deleteSync();

    // 1) 下载 .nac（CDN 直链，vkey 已签）
    final nacPath = wavPath.replaceAll('.wav', '.nac');
    try {
      await _download(nacUrl, nacPath,
          onProgress: (p) => onProgress?.call((p * 0.1).round(), 'download'));
    } catch (e) {
      AppLog.w('NacMusic', 'NAC 下载失败: $e');
      return null;
    }

    // 2) 后台 isolate 解码（FFI 同步阻塞，不能占 UI 线程）
    final sw = Stopwatch()..start();
    try {
      final ok = await Isolate.run(() => _decodeNative(
            nacPath: nacPath,
            wavPath: part,
            modelPath: modelPath,
          ));
      sw.stop();
      if (ok == null) {
        AppLog.w('NacMusic', 'NAC 解码失败（走音质降级）');
        return null;
      }
      // v2.5.8-fix1：解码先写 .part，校验完整后才原子替换最终 wav。
      // 否则解码进行中（NAC 需 1~2 分钟）最终路径上的半成品会被缓存命中。
      if (!await WavCache.commit(part, wavPath, tag: 'NacMusic')) {
        AppLog.w('NacMusic', 'NAC 解码产物不完整（走音质降级）');
        return null;
      }
      AppLog.i('NacMusic', 'NAC 解码完成 ${sw.elapsedMilliseconds}ms -> $wavPath');
      onProgress?.call(100, 'done');
      return NacDecodeResult(wavPath);
    } catch (e) {
      AppLog.e('NacMusic', 'NAC 解码异常: $e');
      return null;
    }
  }

  static Future<void> _download(String url, String savePath,
      {void Function(int pct)? onProgress}) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader,
          'Dalvik/2.1.0 (Linux; U; Android 14)');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength;
      final sink = File(savePath).openWrite();
      var received = 0;
      await for (final chunk in resp) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0 && onProgress != null) {
          onProgress((received * 100 / total).clamp(0, 100).round());
        }
      }
      await sink.flush();
      await sink.close();
    } finally {
      client.close(force: true);
    }
  }

  /// 在独立 isolate 中执行的原生解码（返回 wavPath；null=失败）。
  @pragma('vm:entry-point')
  static String? _decodeNative({
    required String nacPath,
    required String wavPath,
    required String modelPath,
  }) {
    DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open('libnac_glue.so');
    } catch (_) {
      return null;
    }
    final init = lib.lookupFunction<Int32 Function(Pointer<Uint8>),
        int Function(Pointer<Uint8>)>('nacglue_init');
    final open = lib.lookupFunction<Int32 Function(Pointer<Uint8>),
        int Function(Pointer<Uint8>)>('nacglue_open');
    final decode = lib.lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Uint8>, Pointer<Void>, Pointer<Void>)>(
        'nacglue_decode_to_wav');

    final modelP = _cstr(modelPath);
    final nacP = _cstr(nacPath);
    final wavP = _cstr(wavPath);
    try {
      var rc = init(modelP);
      if (rc != 0) return null;
      rc = open(nacP);
      if (rc != 0) return null;
      rc = decode(wavP, nullptr, nullptr);
      return rc == 0 ? wavPath : null;
    } finally {
      malloc.free(modelP);
      malloc.free(nacP);
      malloc.free(wavP);
    }
  }
}
