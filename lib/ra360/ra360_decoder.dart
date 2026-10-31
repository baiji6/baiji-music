/// QQ 音乐索尼 360RA（RA01-04）解码支持（v2.4.2-pre11）。
///
/// 原生实现见 `android/app/src/main/cpp/ra360_glue.cpp`：
/// dlopen 官方 qm_native_decoder_360ra.so（CDN 下发库，MD5 锚定于
/// QQ 音乐 APK 内置 `assets/so_info.json`）→ setCoefPath 注入标准 BRIR
/// 系数 → init(自实现 IDataSource) → decode 循环 → 48kHz/32bit/2ch WAV。
///
/// 系数链路（2026-10-31 全链路 QEMU 验证通过）：
/// 1. BRIR riff 官方资产（`assets/ra360/brir_standard.riff`，QQ 音乐 CDN
///    `dldir1v6.qq.com/music/assets/5cfa7a1434ed8e7e13fbba77b68d1768`）解包
/// 2. 按 Sony SAL SDK 语义解析 RIFF→BRIR→`h13 ` 块 → hrtf13.hki
/// 3. 写 config 文件（内容=hki 相对路径行；native 端
///    sia_virtualizer_getHandle 会读 config 首行再拼 appRoot 加载）
///
/// ABI 覆盖：官方只为 arm64-v8a 下发 decoder（QQ 音乐 so_info.json 仅此
/// ABI），armeabi-v7a / x86 系 [isSupported] 返回 false，降级链自动绕开。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../core/app_logger.dart';

/// 解码产物：WAV 文件路径。
class Ra360DecodeResult {
  final String wavPath;
  const Ra360DecodeResult(this.wavPath);
}

class Ra360Music {
  Ra360Music._();

  static const _brirAsset = 'assets/ra360/brir_standard.riff';
  static const _spkAsset = 'assets/ra360/spkl001_5_1_ITUR_VBAP3.arb';

  static const _hkiName = 'com.sony.360ra.hrtf13.standard.hki';
  static const _configName = 'com.sony.360ra.hrtf13.config';

  static DynamicLibrary? _lib;
  static bool _probed = false;
  static bool _supported = false;
  static bool _coefReady = false;

  /// 进行中的解码任务（按歌曲 key 去重，同 [DtsMusic] 语义）。
  static final Map<String, Future<Ra360DecodeResult?>> _inflight = {};

  /// 运行时探测：仅 Android（arm64）尝试加载，进程内只探测一次。
  static bool get isSupported {
    if (_probed) return _supported;
    _probed = true;
    if (!Platform.isAndroid) {
      AppLog.i('Ra360Music', '非 Android 平台，360RA 不可用');
      return _supported = false;
    }
    try {
      _lib ??= DynamicLibrary.open('libra360_glue.so');
      final abi = _lib!
          .lookupFunction<Int32 Function(), int Function()>(
              'ra360glue_abi_available');
      _supported = abi() == 1;
      if (_supported) {
        AppLog.i('Ra360Music', '360RA 原生链路探测: 可用');
      } else {
        final detail = _lib!
            .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
                'ra360glue_probe_detail')();
        AppLog.w('Ra360Music', '360RA 原生链路探测失败: ${detail.toDartString()}');
      }
    } catch (e) {
      AppLog.w('Ra360Music', 'libra360_glue.so 加载失败（旧包或非官方 ABI）: $e');
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

  /// 系数工作目录（appRoot）：`<cache>/ra360/`。
  static Future<String> _coefRoot() async {
    final dir = await getApplicationCacheDirectory();
    final d = Directory('${dir.path}${Platform.pathSeparator}ra360');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.path;
  }

  /// 解包并生成系数三件套（幂等）：hki + config（+spk 备用）。
  ///
  /// RIFF 布局：`RIFF` → `BRIR` → 块遍历（tag + u32 LE size + payload），
  /// 取 `h13 ` 块（Sony HRTF13 标准系数，文件头魔数 `hki2`）。
  static Future<void> _ensureCoefFiles() async {
    if (_coefReady) return;
    final root = await _coefRoot();
    final coefDir = Directory('$root${Platform.pathSeparator}coef');
    if (!coefDir.existsSync()) coefDir.createSync(recursive: true);

    final hkiPath = '${coefDir.path}${Platform.pathSeparator}$_hkiName';
    final hkiFile = File(hkiPath);
    if (!hkiFile.existsSync() || hkiFile.lengthSync() < 16) {
      final riff = await rootBundle.load(_brirAsset);
      final b = riff.buffer.asUint8List(riff.offsetInBytes, riff.lengthInBytes);
      final hki = _extractH13(b);
      hkiFile.writeAsBytesSync(hki, flush: true);
      AppLog.i('Ra360Music', 'BRIR 提取完成: $_hkiName ${hki.length}B');
    }

    // config：native 读首行得到 hki 相对路径（相对 appRoot）
    final cfgFile = File('${coefDir.path}${Platform.pathSeparator}$_configName');
    final want = 'coef/$_hkiName\n';
    if (!cfgFile.existsSync() || cfgFile.readAsStringSync() != want) {
      cfgFile.writeAsStringSync(want, flush: true);
    }

    // spk（扬声器 VBAP 参数）备用解包；当前 decode 链路不强制要求
    final spkPath = '${coefDir.path}${Platform.pathSeparator}'
        'spkl001_5_1_ITUR_VBAP3.arb';
    if (!File(spkPath).existsSync()) {
      final spk = await rootBundle.load(_spkAsset);
      File(spkPath).writeAsBytesSync(
          spk.buffer.asUint8List(spk.offsetInBytes, spk.lengthInBytes),
          flush: true);
    }
    _coefReady = true;
  }

  /// 从 RIFF/BRIR 容器提取 `h13 ` 块。
  static Uint8List _extractH13(Uint8List b) {
    if (b.length < 16 ||
        b[0] != 0x52 || b[1] != 0x49 || b[2] != 0x46 || b[3] != 0x46 ||
        b[8] != 0x42 || b[9] != 0x52 || b[10] != 0x49 || b[11] != 0x52) {
      throw const FormatException('brir riff 魔数不符');
    }
    var p = 12;
    final end = 8 + ByteData.view(b.buffer, b.offsetInBytes).getUint32(4, Endian.little);
    while (p + 8 <= end && p + 8 <= b.length) {
      final tag = String.fromCharCodes(b.sublist(p, p + 4));
      final sz = ByteData.view(b.buffer, b.offsetInBytes).getUint32(p + 4, Endian.little);
      if (tag == 'h13 ') {
        final out = Uint8List(sz);
        out.setRange(0, sz, b.sublist(p + 8, p + 8 + sz));
        return out;
      }
      p += 8 + sz + (sz & 1);
    }
    throw const FormatException('brir riff 内无 h13 块');
  }

  /// 取解码产物缓存路径（WAV）。
  static Future<String> wavPathFor(String key) async {
    final root = await _coefRoot();
    return '$root${Platform.pathSeparator}ra360_$key.wav';
  }

  /// 判断某首歌的 360RA 缓存是否已就绪（再次播放零等待）。
  static Future<bool> hasCachedWav(String key) async =>
      File(await wavPathFor(key)).existsSync();

  /// 删除某首歌的缓存（mp4 + wav）。
  static Future<void> clearCache(String key) async {
    final root = await _coefRoot();
    for (final name in ['ra360_$key.wav', 'ra360_$key.mp4']) {
      final f = File('$root${Platform.pathSeparator}$name');
      if (f.existsSync()) f.deleteSync();
    }
  }

  /// 若同 key 的解码正在进行，返回该任务 Future（同 [DtsMusic.waitOngoing]）。
  static Future<Ra360DecodeResult?>? waitOngoing(String key) => _inflight[key];

  /// 下载 RA0x mp4 到缓存并解码成 WAV（binaural 48k/32bit）。
  ///
  /// [onProgress] 进度 0~100（下载占前 20%，解码占后 80%）；360RA 全曲
  /// 真机解码约数秒到数十秒。返回 null 表示失败（调用方走音质降级链）。
  static Future<Ra360DecodeResult?> decodeToWav(
    String mp4Url,
    String key, {
    void Function(int pct, String stage)? onProgress,
  }) async {
    if (!isSupported) return null;
    final existing = _inflight[key];
    if (existing != null) {
      AppLog.i('Ra360Music', '360RA 解码进行中（key=$key），复用既有任务');
      try {
        return await existing;
      } catch (e) {
        AppLog.w('Ra360Music', '复用的 360RA 解码任务失败: $e');
        return null;
      }
    }
    final task = _decodeToWavGuarded(mp4Url, key, onProgress: onProgress);
    _inflight[key] = task;
    try {
      return await task;
    } catch (e) {
      AppLog.e('Ra360Music', '360RA 链路异常: $e');
      return null;
    } finally {
      _inflight.remove(key);
    }
  }

  static Future<Ra360DecodeResult?> _decodeToWavGuarded(
    String mp4Url,
    String key, {
    void Function(int pct, String stage)? onProgress,
  }) async {
    await _ensureCoefFiles();
    final wavPath = await wavPathFor(key);

    // 秒开：缓存命中直接回放。
    if (await hasCachedWav(key)) {
      onProgress?.call(100, 'cached');
      return Ra360DecodeResult(wavPath);
    }

    // 1) 下载 MHA1 mp4（CDN 直链，vkey 已签）。
    final mp4Path = wavPath.replaceAll('.wav', '.mp4');
    try {
      await _download(mp4Url, mp4Path,
          onProgress: (p) => onProgress?.call((p * 0.2).round(), 'download'));
    } catch (e) {
      AppLog.w('Ra360Music', 'RA0x 下载失败: $e');
      return null;
    }

    // 2) 后台 isolate 解码（FFI 同步阻塞，不能占 UI 线程）。
    final root = await _coefRoot();
    final sw = Stopwatch()..start();
    try {
      final ok = await Isolate.run(() => _decodeNative(
            mp4Path: mp4Path,
            wavPath: wavPath,
            appRoot: root,
          ));
      sw.stop();
      if (ok == null) {
        AppLog.w('Ra360Music', '360RA 解码失败（走音质降级）');
        return null;
      }
      AppLog.i('Ra360Music', '360RA 解码完成 ${sw.elapsedMilliseconds}ms → $wavPath');
      onProgress?.call(100, 'done');
      return Ra360DecodeResult(wavPath);
    } catch (e) {
      AppLog.e('Ra360Music', '360RA 解码异常: $e');
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

  /// 在独立 isolate 中执行的原生解码（返回 wavPath；null=失败）。
  @pragma('vm:entry-point')
  static String? _decodeNative({
    required String mp4Path,
    required String wavPath,
    required String appRoot,
  }) {
    DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open('libra360_glue.so');
    } catch (_) {
      return null;
    }
    final init = lib.lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>,
            Pointer<Uint8>),
        int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>,
            Pointer<Uint8>)>('ra360glue_init');
    final open = lib.lookupFunction<Int32 Function(Pointer<Uint8>),
        int Function(Pointer<Uint8>)>('ra360glue_open');
    final decode = lib.lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Uint8>, Pointer<Void>, Pointer<Void>)>(
        'ra360glue_decode_to_wav');

    final appP = _cstr(appRoot);
    final cfgP = _cstr('coef/$_configName');
    final cpP = _cstr('coef/com.sony.360ra.cp.config'); // 缺文件不阻塞
    final spkP = _cstr('');
    final mp4P = _cstr(mp4Path);
    final wavP = _cstr(wavPath);
    try {
      var rc = init(appP, cfgP, cpP, spkP);
      if (rc != 0) return null;
      rc = open(mp4P);
      if (rc != 0) return null;
      rc = decode(wavP, nullptr, nullptr);
      return rc == 0 ? wavPath : null;
    } finally {
      malloc.free(appP);
      malloc.free(cfgP);
      malloc.free(cpP);
      malloc.free(spkP);
      malloc.free(mp4P);
      malloc.free(wavP);
    }
  }
}
