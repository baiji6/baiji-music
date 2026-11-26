/// baka 解码器统一 Dart 层（v2.6.6）。
///
/// 两个原生 so 由 Rust crate 交叉编译而来（见 tools/native_decoders/）：
///  - `libac4_baka.so`：baka-ac4-core v0.2.2，杜比全景声 AC-4 主解码器；
///  - `libav3a_baka.so`：baka-av3a-core v0.1.2，网易云臻音全景声
///    （Audio Vivid / AV3A）主解码器。UWA 参考解码器仍编在 libmpv 里作备用。
///
/// C ABI（两库一致，见各自 src/lib.rs 顶部注释）：
///   init / open / info / decode_to_wav / close / last_error
///
/// 仅 Android 支持；解码产物为 16bit PCM WAV，复用项目既有的
/// `WavCache` + `TranscodeStreamServer` 边转码边播放管线。
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

/// 解码结果：WAV 路径 + 实际采样率/声道 + 帧数。
class BakaDecodeResult {
  final String wavPath;
  final int sampleRate;
  final int channels;
  final int frames;
  const BakaDecodeResult(this.wavPath, this.sampleRate, this.channels, this.frames);
}

/// 解码器种类（纯枚举，可安全跨 isolate 传递）。
enum BakaKind { ac4, av3a }

/// 各解码器的静态配置——全部用可发送的基本类型描述。
class BakaConfig {
  final BakaKind kind;
  final String tag;
  final String libName;
  final String cacheSubdir;
  final List<String> assetNames;
  const BakaConfig({
    required this.kind,
    required this.tag,
    required this.libName,
    required this.cacheSubdir,
    this.assetNames = const [],
  });
}

/// baka 解码器宿主：探测 + 资产解包 + 缓存 + isolate 解码。
class BakaMusic {
  BakaMusic._();

  static const BakaConfig ac4 = BakaConfig(
    kind: BakaKind.ac4,
    tag: 'BakaAc4',
    libName: 'libac4_baka.so',
    cacheSubdir: 'baka_ac4',
  );
  static const BakaConfig av3a = BakaConfig(
    kind: BakaKind.av3a,
    tag: 'BakaAv3a',
    libName: 'libav3a_baka.so',
    cacheSubdir: 'baka_av3a',
    assetNames: ['model.bin', 'lsf.bin'],
  );

  static final Map<BakaKind, bool> _supported = {};
  static final Map<String, Future<BakaDecodeResult?>?> _inflight = {};

  static bool isSupported(BakaConfig cfg) {
    final cached = _supported[cfg.kind];
    if (cached != null) return cached;
    if (!Platform.isAndroid) return _supported[cfg.kind] = false;
    try {
      final lib = DynamicLibrary.open(cfg.libName);
      lib.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          _initFn(cfg.kind));
      AppLog.i('BakaMusic', '${cfg.tag} 原生链路可用');
      return _supported[cfg.kind] = true;
    } catch (e) {
      AppLog.w('BakaMusic', '${cfg.libName} 加载失败: $e');
      return _supported[cfg.kind] = false;
    }
  }

  static String _initFn(BakaKind k) => k == BakaKind.ac4 ? 'ac4baka_init' : 'av3abaka_init';
  static String _openFn(BakaKind k) => k == BakaKind.ac4 ? 'ac4baka_open' : 'av3abaka_open';
  static String _infoFn(BakaKind k) => k == BakaKind.ac4 ? 'ac4baka_info' : 'av3abaka_info';
  static String _decodeFn(BakaKind k, {required bool stream}) {
    if (k == BakaKind.ac4) {
      return stream ? 'ac4baka_decode_to_stream' : 'ac4baka_decode_to_wav';
    }
    return stream ? 'av3abaka_decode_to_stream' : 'av3abaka_decode_to_wav';
  }
  static String _closeFn(BakaKind k) => k == BakaKind.ac4 ? 'ac4baka_close' : 'av3abaka_close';

  static Pointer<Uint8> _cstr(String s) {
    final units = utf8.encode(s);
    final p = malloc<Uint8>(units.length + 1);
    final list = p.asTypedList(units.length + 1);
    list.setRange(0, units.length, units);
    list[units.length] = 0;
    return p;
  }

  /// 把 assets 里的模型文件解包到私有缓存目录，返回路径列表。
  static Future<List<String>> _ensureAssets(BakaConfig cfg) async {
    if (cfg.assetNames.isEmpty) return const [];
    final dir = await getApplicationCacheDirectory();
    final d = Directory('${dir.path}${Platform.pathSeparator}${cfg.cacheSubdir}');
    if (!d.existsSync()) d.createSync(recursive: true);
    final paths = <String>[];
    for (final name in cfg.assetNames) {
      final p = '${d.path}${Platform.pathSeparator}$name';
      final f = File(p);
      if (!f.existsSync() || f.lengthSync() == 0) {
        final data = await rootBundle.load('assets/av3a/$name');
        f.writeAsBytesSync(data.buffer.asUint8List(), flush: true);
      }
      paths.add(p);
    }
    return paths;
  }

  static Future<String> wavPathFor(BakaConfig cfg, String key) async {
    final dir = await getApplicationCacheDirectory();
    final d = Directory('${dir.path}${Platform.pathSeparator}${cfg.cacheSubdir}');
    if (!d.existsSync()) d.createSync(recursive: true);
    return '${d.path}${Platform.pathSeparator}${cfg.cacheSubdir}_$key.wav';
  }

  static Future<bool> hasCachedWav(BakaConfig cfg, String key) async =>
      WavCache.isValidCache(File(await wavPathFor(cfg, key)), tag: cfg.tag);

  static Future<void> clearCache(BakaConfig cfg, String key) async {
    final dir = await getApplicationCacheDirectory();
    final base = '${dir.path}${Platform.pathSeparator}${cfg.cacheSubdir}';
    for (final name in [
      '${cfg.cacheSubdir}_$key.wav',
      '${cfg.cacheSubdir}_$key.wav.part',
      '${cfg.cacheSubdir}_$key.mp4',
    ]) {
      final f = File('$base${Platform.pathSeparator}$name');
      if (f.existsSync()) f.deleteSync();
    }
  }

  static Future<BakaDecodeResult?>? waitOngoing(BakaConfig cfg, String key) =>
      _inflight['${cfg.tag}_$key'];

  /// 流式解码：下载 mp4 + 原生解码，边写 PCM 到 [outPath]，供 TranscodeStreamServer
  /// tail 后推给播放器实现「边转码边播放」。返回 0 成功，非 0 失败。
  ///
  /// 原生 decode_to_wav 会先写 44B WAV 头再逐帧追加 PCM；调用方预创建
  /// [outPath] 后即可开流。失败时清理源文件。
  static Future<int> decodeToStreamFile(
    BakaConfig cfg,
    String url,
    String key,
    String outPath, {
    void Function(int pct, String stage)? onProgress,
  }) async {
    if (!isSupported(cfg)) return -1;
    final assets = await _ensureAssets(cfg);
    final dir = (await wavPathFor(cfg, key)).replaceAll('.wav', '');
    final srcPath = '$dir.stream.mp4';
    try {
      onProgress?.call(0, 'download');
      await _download(url, srcPath,
          onProgress: (p) => onProgress?.call((p * 0.25).round(), 'download'));
      onProgress?.call(25, 'decode');
      final sw = Stopwatch()..start();
      final res = await Isolate.run(() => _nativeDecode(
            kind: cfg.kind,
            libName: cfg.libName,
            mp4Path: srcPath,
            wavPath: outPath,
            assetPaths: assets,
            stream: true,
          ));
      sw.stop();
      if (res == null) return -1;
      AppLog.i(cfg.tag, '流式解码完成 ${sw.elapsedMilliseconds}ms');
      onProgress?.call(100, 'done');
      return 0;
    } catch (e) {
      AppLog.w(cfg.tag, '流式解码异常: $e');
      return -1;
    } finally {
      try {
        final f = File(srcPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  /// 下载 mp4 到缓存并解码成 WAV（整曲）。同 key 并发复用同一任务。
  static Future<BakaDecodeResult?> decodeToWav(
    BakaConfig cfg,
    String url,
    String key, {
    void Function(int pct, String stage)? onProgress,
  }) async {
    if (!isSupported(cfg)) return null;
    final ck = '${cfg.tag}_$key';
    final existing = _inflight[ck];
    if (existing != null) {
      try {
        return await existing;
      } catch (_) {
        return null;
      }
    }
    final task = _decodeGuarded(cfg, url, key, onProgress: onProgress);
    _inflight[ck] = task;
    try {
      return await task;
    } catch (e) {
      AppLog.e(cfg.tag, '解码链路异常: $e');
      return null;
    } finally {
      _inflight.remove(ck);
    }
  }

  static Future<BakaDecodeResult?> _decodeGuarded(
    BakaConfig cfg,
    String url,
    String key, {
    void Function(int pct, String stage)? onProgress,
  }) async {
    final assets = await _ensureAssets(cfg);
    final wavPath = await wavPathFor(cfg, key);
    final part = WavCache.partPath(wavPath);
    if (await hasCachedWav(cfg, key)) {
      final srCh = _readWavInfo(File(wavPath));
      onProgress?.call(100, 'cached');
      return BakaDecodeResult(wavPath, srCh.$1, srCh.$2, 0);
    }
    final partFile = File(part);
    if (partFile.existsSync()) partFile.deleteSync();
    final mp4Path = wavPath.replaceAll('.wav', '.mp4');
    try {
      await _download(url, mp4Path,
          onProgress: (p) => onProgress?.call((p * 0.2).round(), 'download'));
    } catch (e) {
      AppLog.w(cfg.tag, 'mp4 下载失败: $e');
      return null;
    }
    final sw = Stopwatch()..start();
    final res = await Isolate.run(() => _nativeDecode(
          kind: cfg.kind,
          libName: cfg.libName,
          mp4Path: mp4Path,
          wavPath: part,
          assetPaths: assets,
          stream: false,
        ));
    sw.stop();
    if (res == null) {
      AppLog.w(cfg.tag, '原生解码失败');
      return null;
    }
    if (!await WavCache.commit(part, wavPath, tag: cfg.tag)) {
      AppLog.w(cfg.tag, '解码产物不完整');
      return null;
    }
    AppLog.i(cfg.tag, '解码完成 ${sw.elapsedMilliseconds}ms → $wavPath');
    onProgress?.call(100, 'done');
    return BakaDecodeResult(wavPath, res.$1, res.$2, res.$3);
  }

  static (int, int) _readWavInfo(File f) {
    try {
      final b = f.readAsBytesSync().sublist(0, 28);
      final ch = b[22] | (b[23] << 8);
      final rate = b[24] | (b[25] << 8) | (b[26] << 16) | (b[27] << 24);
      return (rate, ch);
    } catch (_) {
      return (48000, 2);
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
      if (resp.statusCode != 200) throw HttpException('HTTP ${resp.statusCode}');
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

  /// isolate 内同步调用原生 C ABI：init → open → decode_to_wav → close。
  /// 返回 (sampleRate, channels, frames)，null = 失败。
  @pragma('vm:entry-point')
  static (int, int, int)? _nativeDecode({
    required BakaKind kind,
    required String libName,
    required String mp4Path,
    required String wavPath,
    required List<String> assetPaths,
    required bool stream,
  }) {
    DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open(libName);
    } catch (_) {
      return null;
    }
    final init = lib.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        _initFn(kind));
    final close = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
        _closeFn(kind));
    final decode = lib.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Void>, Pointer<Void>)>(
        _decodeFn(kind, stream: stream));
    final info = lib.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>),
        int Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>)>(
        _infoFn(kind));

    final h = init();
    final mp4P = _cstr(mp4Path);
    final wavP = _cstr(wavPath);
    final extraP = <Pointer<Uint8>>[];
    try {
      final int orc;
      if (kind == BakaKind.av3a) {
        // av3abaka_open(h, mp4, model, lsf, mcr=null, hoa=null)
        final a0 = _cstr(assetPaths[0]);
        final a1 = _cstr(assetPaths[1]);
        extraP.addAll([a0, a1]);
        final open = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>,
                Pointer<Uint8>, Pointer<Uint8>),
            int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>,
                Pointer<Uint8>, Pointer<Uint8>)>(_openFn(kind));
        orc = open(h, mp4P, a0, a1, nullptr, nullptr);
      } else {
        // ac4baka_open(h, mp4)
        final open = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint8>),
            int Function(Pointer<Void>, Pointer<Uint8>)>(_openFn(kind));
        orc = open(h, mp4P);
      }
      if (orc != 0) return null;
      final rc = decode(h, wavP, nullptr, nullptr);
      if (rc != 0) return null;
      final rateP = malloc<Int32>();
      final chP = malloc<Int32>();
      final frP = malloc<Int32>();
      try {
        info(h, rateP, chP, frP);
        return (rateP.value, chP.value, frP.value);
      } finally {
        malloc.free(rateP);
        malloc.free(chP);
        malloc.free(frP);
      }
    } catch (_) {
      return null;
    } finally {
      close(h);
      malloc.free(mp4P);
      malloc.free(wavP);
      for (final p in extraP) {
        malloc.free(p);
      }
    }
  }
}
