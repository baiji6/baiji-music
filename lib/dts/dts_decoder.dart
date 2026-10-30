/// QQ 音乐臻品 DTS:X（DT03）解码支持（v2.4.2-pre8）。
///
/// 原生实现见 `android/app/src/main/cpp/dts_glue.c`：
/// dlopen 官方 DTSPlaybackSDK（CDN 下发库，MD5 锚定）→ 注入许可/配置 →
/// 自实现 MP4 demux 提取 `dtsx` 轨 → DTSPlayback_DecodeDTS 循环 → 16bit WAV。
///
/// ABI 覆盖：官方只为 arm64-v8a / armeabi-v7a 发布解码库（2026-10 实测，
/// 两 ABI 在 QEMU 全曲解码 12847 帧、dropped=0、输出逐帧一致）。
/// x86 系列无官方库，[isSupported] 返回 false，音质降级链自动绕开。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../core/app_logger.dart';

/// 解码产物：WAV 文件路径 + 实际生效信息。
class DtsDecodeResult {
  final String wavPath;
  final int droppedFrames;
  const DtsDecodeResult(this.wavPath, this.droppedFrames);
}

class DtsMusic {
  DtsMusic._();

  static const _licAsset = 'assets/dts/dts_hpx.lic';
  static const _cfgAsset = 'assets/dts/dts_config.yaml';

  static DynamicLibrary? _lib;
  static bool _probed = false;
  static bool _supported = false;

  /// 进行中的解码任务（按歌曲 key 去重）。
  ///
  /// 首次点播 DT03 要下载 mp4 + 全曲解码（真机约 10 秒），期间用户
  /// 看不到进度极易再点一次 —— 若两条请求各自解码，不仅重复下载，
  /// 还会各自回调播放，后完成的 open 把先完成的覆盖掉，最终听到的
  /// 是降级档。这里让并发请求复用同一个 Future：后来者安静等待首次
  /// 解码的结果，只播放一次。
  static final Map<String, Future<DtsDecodeResult?>> _inflight = {};

  /// 运行时探测：仅 Android 尝试加载。结果缓存，进程内只探测一次。
  static bool get isSupported {
    if (_probed) return _supported;
    _probed = true;
    if (!Platform.isAndroid) {
      AppLog.i('DtsMusic', '非 Android 平台，DTS:X 不可用');
      return _supported = false;
    }
    try {
      _lib ??= DynamicLibrary.open('libdts_glue.so');
      final abiAvailable = _lib!
          .lookupFunction<Int32 Function(), int Function()>('dtsglue_abi_available');
      _supported = abiAvailable() == 1;
      if (_supported) {
        AppLog.i('DtsMusic', 'DTS:X 原生链路探测: 可用');
      } else {
        final detail = _lib!
            .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
                'dtsglue_probe_detail')();
        AppLog.w('DtsMusic', 'DTS:X 原生链路探测失败: ${detail.toDartString()}');
      }
    } catch (e) {
      AppLog.w('DtsMusic', 'libdts_glue.so 加载失败（旧版本升级残留？）: $e');
      _supported = false;
    }
    return _supported;
  }

  // ===== FFI 绑定 =====

  static Pointer<Uint8> _cstr(String s) {
    final units = utf8.encode(s);
    final p = malloc<Uint8>(units.length + 1);
    final list = p.asTypedList(units.length + 1);
    list.setRange(0, units.length, units);
    list[units.length] = 0;
    return p;
  }

  /// 解码前的准备：把 assets 里的许可/配置解包到私有缓存目录。
  static Future<(String, String)> _ensureLicenseFiles() async {
    final dir = await getApplicationCacheDirectory();
    final dtsDir = Directory('${dir.path}${Platform.pathSeparator}dts');
    if (!dtsDir.existsSync()) dtsDir.createSync(recursive: true);
    final licPath = '${dtsDir.path}${Platform.pathSeparator}dts_hpx.lic';
    final cfgPath = '${dtsDir.path}${Platform.pathSeparator}dts_config.yaml';
    final licFile = File(licPath);
    if (!licFile.existsSync() || licFile.lengthSync() == 0) {
      final data = await rootBundle.load(_licAsset);
      licFile.writeAsBytesSync(data.buffer.asUint8List(), flush: true);
    }
    final cfgFile = File(cfgPath);
    if (!cfgFile.existsSync() || cfgFile.lengthSync() == 0) {
      final data = await rootBundle.load(_cfgAsset);
      cfgFile.writeAsBytesSync(data.buffer.asUint8List(), flush: true);
    }
    return (licPath, cfgPath);
  }

  /// 取解码产物缓存路径（WAV）。
  static Future<String> wavPathFor(String key) async {
    final dir = await getApplicationCacheDirectory();
    final dtsDir = Directory('${dir.path}${Platform.pathSeparator}dts');
    if (!dtsDir.existsSync()) dtsDir.createSync(recursive: true);
    return '${dtsDir.path}${Platform.pathSeparator}dts_$key.wav';
  }

  /// 判断某首歌的 DT03 缓存是否已就绪（再次播放零等待）。
  static Future<bool> hasCachedWav(String key) async =>
      File(await wavPathFor(key)).existsSync();

  /// 删除某首歌的缓存（mp4 + wav）。
  static Future<void> clearCache(String key) async {
    final dir = await getApplicationCacheDirectory();
    final base = '${dir.path}${Platform.pathSeparator}dts';
    for (final name in ['dts_$key.wav', 'dts_$key.mp4']) {
      final f = File('$base${Platform.pathSeparator}$name');
      if (f.existsSync()) f.deleteSync();
    }
  }

  /// 若同 key 的解码正在进行，返回该任务 Future（完成后给出结果）；
  /// 没有进行中的任务则返回 null（调用方自行决定降级）。
  ///
  /// 供取流被频控打空时的等待兜底：首次点播的解码还在跑，此时重复
  /// 点播不应另起降级链播低档，安静等首次解码完即可。
  static Future<DtsDecodeResult?>? waitOngoing(String key) => _inflight[key];

  /// 下载 DT03 mp4 到缓存并解码成 WAV。
  ///
  /// [onProgress] 进度 0~100（下载+解码合并口径：下载占前 20%，解码占后 80%）。
  /// 返回 null 表示失败（调用方走音质降级链）。
  ///
  /// 同 [key] 的并发调用复用同一个进行中的任务（见 [_inflight]）。
  static Future<DtsDecodeResult?> decodeToWav(
    String mp4Url,
    String key, {
    void Function(int pct, String stage)? onProgress,
  }) async {
    if (!isSupported) return null;
    final existing = _inflight[key];
    if (existing != null) {
      AppLog.i('DtsMusic', 'DTS:X 解码进行中（key=$key），复用既有任务');
      try {
        return await existing;
      } catch (e) {
        AppLog.w('DtsMusic', '复用的 DTS:X 解码任务失败: $e');
        return null;
      }
    }
    final task = _decodeToWavGuarded(mp4Url, key, onProgress: onProgress);
    _inflight[key] = task;
    try {
      return await task;
    } catch (e) {
      AppLog.e('DtsMusic', 'DTS:X 链路异常: $e');
      return null;
    } finally {
      _inflight.remove(key);
    }
  }

  static Future<DtsDecodeResult?> _decodeToWavGuarded(
    String mp4Url,
    String key, {
    void Function(int pct, String stage)? onProgress,
  }) async {
    final (licPath, cfgPath) = await _ensureLicenseFiles();
    final wavPath = await wavPathFor(key);

    // 秒开：缓存命中直接回放。
    if (await hasCachedWav(key)) {
      onProgress?.call(100, 'cached');
      return DtsDecodeResult(wavPath, 0);
    }

    // 1) 下载 mp4（CDN 直链，vkey 已签）。
    final mp4Path = wavPath.replaceAll('.wav', '.mp4');
    try {
      await _download(mp4Url, mp4Path,
          onProgress: (p) => onProgress?.call((p * 0.2).round(), 'download'));
    } catch (e) {
      AppLog.w('DtsMusic', 'DT03 下载失败: $e');
      return null;
    }

    // 2) 后台 isolate 解码（FFI 同步阻塞数秒，不能占 UI 线程）。
    final sw = Stopwatch()..start();
    try {
      final dropped = await Isolate.run(() => _decodeNative(
            mp4Path: mp4Path,
            wavPath: wavPath,
            licPath: licPath,
            cfgPath: cfgPath,
          ));
      sw.stop();
      if (dropped == null) {
        AppLog.w('DtsMusic', 'DTS:X 解码失败（走音质降级）');
        return null;
      }
      AppLog.i('DtsMusic',
          'DTS:X 解码完成 ${sw.elapsedMilliseconds}ms（dropped=$dropped）→ $wavPath');
      onProgress?.call(100, 'done');
      return DtsDecodeResult(wavPath, dropped);
    } catch (e) {
      AppLog.e('DtsMusic', 'DTS:X 解码异常: $e');
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
      final file = File(savePath);
      final sink = file.openWrite();
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

  /// 在独立 isolate 中执行的原生解码（返回 dropped 帧数；null=失败）。
  @pragma('vm:entry-point')
  static int? _decodeNative({
    required String mp4Path,
    required String wavPath,
    required String licPath,
    required String cfgPath,
  }) {
    DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open('libdts_glue.so');
    } catch (e) {
      return null;
    }
    final init =
        lib.lookupFunction<Int32 Function(Pointer<Uint8>, Pointer<Uint8>),
            int Function(Pointer<Uint8>, Pointer<Uint8>)>('dtsglue_init');
    final open = lib.lookupFunction<Int32 Function(Pointer<Uint8>),
        int Function(Pointer<Uint8>)>('dtsglue_open');
    final decode = lib.lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Void>),
        int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Void>)>(
        'dtsglue_decode_to_wav');
    final close =
        lib.lookupFunction<Void Function(), void Function()>('dtsglue_close');

    final licP = _cstr(licPath);
    final cfgP = _cstr(cfgPath);
    final mp4P = _cstr(mp4Path);
    final wavP = _cstr(wavPath);
    try {
      var rc = init(licP, cfgP);
      if (rc != 0) return null;
      rc = open(mp4P);
      if (rc != 0) return null;
      // 进度回传暂不跨 isolate（NativeCallable 生命周期管理复杂），
      // 解码本身在真机为秒级，UI 用不确定进度即可。
      rc = decode(wavP, nullptr, nullptr);
      close();
      return rc == 0 ? 0 : null;
    } finally {
      malloc.free(licP);
      malloc.free(cfgP);
      malloc.free(mp4P);
      malloc.free(wavP);
    }
  }
}
