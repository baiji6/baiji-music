/// 本地升频的文件级管线：解码 → [ViperSuperResolution] → 24-bit WAV。
///
/// 复用项目既有的 ffmpeg CLI 通道（`libffmpeg_exec.so` / PATH / 手动指定）
/// 把任意输入（MP3 / FLAC / M4A / 加密格式解密后的文件 / 在线直链）解码成
/// 48 kHz / 16 bit / 立体声裸 PCM，再交给纯 Dart 升频引擎。升频在独立
/// isolate 里跑（一首歌可能数十秒到数分钟），进度通过 SendPort 回传，
/// 不阻塞 UI。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';

import '../core/audio_transcoder.dart' show FfmpegLocator;
import '../core/cache_manager.dart' show CacheManager;
import 'viper_super_resolution.dart';
import 'viper_wav.dart';

/// 一次升频的产物信息。
class ViperUpscaleResult {
  const ViperUpscaleResult({
    required this.wavPath,
    required this.sampleRate,
    required this.bitDepth,
    required this.channels,
    required this.frames,
    required this.bytes,
    required this.elapsed,
  });

  final String wavPath;
  final int sampleRate;
  final int bitDepth;
  final int channels;
  final int frames;
  final int bytes;
  final Duration elapsed;

  double get durationSeconds =>
      sampleRate > 0 ? frames / sampleRate : 0;
}

class ViperUpscaler {
  const ViperUpscaler._();

  static const MethodChannel _nativeChannel = MethodChannel('baiji/native');

  /// Android 内置 ffmpeg 候选（`nativeLibraryDir/libffmpeg_exec.so`）。
  static Future<List<String>> androidEngineCandidates() async {
    if (!Platform.isAndroid) return const <String>[];
    try {
      final dir = await _nativeChannel.invokeMethod<String>('nativeLibraryDir');
      if (dir == null || dir.isEmpty) return const <String>[];
      return <String>['$dir${Platform.pathSeparator}libffmpeg_exec.so'];
    } catch (_) {
      return const <String>[];
    }
  }

  /// 解析可用的 ffmpeg 可执行文件；找不到返回 null。
  static Future<String?> resolveFfmpeg({String? overridePath}) async =>
      FfmpegLocator(
        overridePath: overridePath,
        extraCandidates: await androidEngineCandidates(),
      ).resolve();

  /// 升频缓存目录名，与 `CacheManager.viperDirName` 一致（可被清理缓存清掉）。
  static const String dirName = 'viper';

  /// 升频缓存目录（播放链路复用，命中即跳过重复计算）。
  ///
  /// 走 [CacheManager.subDir] 才能跟随用户自定义的缓存根目录。
  static Future<String> cacheDir() async =>
      (await CacheManager.subDir(dirName)).path;

  /// 同一首歌 + 目标采样率对应一份缓存，key 用 md5 避免文件名非法字符。
  static Future<String> wavPathFor(String key, ViperUpscaleRate rate) async {
    final digest = crypto.md5.convert('$key|${rate.hz}'.codeUnits).toString();
    return '${await cacheDir()}${Platform.pathSeparator}$digest.wav';
  }

  static Future<bool> hasCachedWav(String key, ViperUpscaleRate rate) async =>
      File(await wavPathFor(key, rate)).existsSync();

  /// 把本地文件升频，写到 [outputPath]（父目录需存在）。
  static Future<ViperUpscaleResult> upscaleFile({
    required String inputPath,
    required String outputPath,
    ViperUpscaleRate rate = ViperUpscaleRate.khz192,
    bool tapeEnhance = true,
    String? ffmpegPath,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final sw = Stopwatch()..start();
    if (isCancelled?.call() == true) throw const ViperCancelled();

    final pcm = await _decodeTo48k(
      inputPath,
      ffmpegPath: ffmpegPath,
      onProgress: (p) => onProgress?.call(p * 0.12),
    );
    if (isCancelled?.call() == true) throw const ViperCancelled();
    onProgress?.call(0.12);

    final audio = await _runInIsolate(
      pcm,
      rate: rate,
      tapeEnhance: tapeEnhance,
      onProgress: (p) => onProgress?.call(0.12 + p * 0.83),
    );
    if (isCancelled?.call() == true) throw const ViperCancelled();

    final bytes = ViperWav.encode24(audio);
    await File(outputPath).writeAsBytes(bytes, flush: true);
    onProgress?.call(1.0);
    sw.stop();
    return ViperUpscaleResult(
      wavPath: outputPath,
      sampleRate: audio.sampleRate,
      bitDepth: 24,
      channels: audio.channels,
      frames: audio.frames,
      bytes: bytes.length,
      elapsed: sw.elapsed,
    );
  }

  /// 在线直链：先下载到临时文件，再走 [upscaleFile]。
  static Future<ViperUpscaleResult> upscaleUrl({
    required String url,
    required String outputPath,
    required Future<String> Function() download,
    ViperUpscaleRate rate = ViperUpscaleRate.khz192,
    bool tapeEnhance = true,
    String? ffmpegPath,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    // [download] 由调用方注入（播放器已有 Dio 下载与缓存策略），返回临时
    // 文件路径；用完后由本方法删除，避免在线直链污染升频缓存目录。
    final tmp = await download();
    try {
      return await upscaleFile(
        inputPath: tmp,
        outputPath: outputPath,
        rate: rate,
        tapeEnhance: tapeEnhance,
        ffmpegPath: ffmpegPath,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    } finally {
      try {
        final f = File(tmp);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// 解码成 48 kHz / 16 bit / 2ch 的 [ViperAudio]。
  static Future<ViperAudio> _decodeTo48k(
    String inputPath, {
    String? ffmpegPath,
    void Function(double progress)? onProgress,
  }) async {
    final exe = ffmpegPath ?? await resolveFfmpeg();
    onProgress?.call(0.15);

    // 没有 ffmpeg 时，允许直接读 WAV（桌面/CI 常见，测试用短 WAV）。
    if (exe == null) {
      if (inputPath.toLowerCase().endsWith('.wav')) {
        return ViperWav.readFile(inputPath);
      }
      throw StateError(
          '未找到 ffmpeg 引擎，无法解码音频。请在设置/工具箱里指定 ffmpeg 路径，'
          '或改用 WAV 输入。');
    }

    final tmp = '$inputPath.viper48k.pcm';
    try {
      final result = await Process.run(exe, <String>[
        '-y', '-hide_banner', '-loglevel', 'error',
        '-i', inputPath,
        '-vn', '-ac', '2', '-ar', '48000',
        '-f', 's16le', '-acodec', 'pcm_s16le', tmp,
      ]);
      if (result.exitCode != 0) {
        throw StateError('ffmpeg 解码失败 (${result.exitCode}): '
            '${(result.stderr as String?)?.trim() ?? ''}');
      }
      onProgress?.call(0.8);
      final raw = await File(tmp).readAsBytes();
      final frames = raw.length ~/ 4; // 2ch × 16bit
      final left = Float64List(frames);
      final right = Float64List(frames);
      final bd = ByteData.sublistView(raw);
      for (var i = 0; i < frames; i++) {
        left[i] = bd.getInt16(i * 4, Endian.little) / 32768.0;
        right[i] = bd.getInt16(i * 4 + 2, Endian.little) / 32768.0;
      }
      return ViperAudio(48000, 2, <Float64List>[left, right]);
    } finally {
      try {
        final f = File(tmp);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// 在独立 isolate 里跑 DSP，进度经 SendPort 回传。
  static Future<ViperAudio> _runInIsolate(
    ViperAudio pcm, {
    required ViperUpscaleRate rate,
    required bool tapeEnhance,
    void Function(double progress)? onProgress,
  }) async {
    final port = ReceivePort();
    final iso = await Isolate.spawn<_IsolateMsg>(
      _isolateEntry,
      _IsolateMsg(port.sendPort,
          _IsolateArgs(pcm, rate, tapeEnhance, onProgress != null)),
    );
    ViperAudio? out;
    String? error;
    try {
      await for (final msg in port) {
        if (msg is double) {
          onProgress?.call(msg);
        } else if (msg is ViperAudio) {
          out = msg;
          break;
        } else if (msg is String) {
          error = msg;
          break;
        }
      }
    } finally {
      port.close();
      iso.kill(priority: Isolate.immediate);
    }
    if (error != null) throw StateError('升频失败: $error');
    if (out == null) throw StateError('升频 isolate 未返回结果');
    return out;
  }
}

class _IsolateArgs {
  const _IsolateArgs(this.audio, this.rate, this.tapeEnhance, this.report);

  final ViperAudio audio;
  final ViperUpscaleRate rate;
  final bool tapeEnhance;
  final bool report;
}

class _IsolateMsg {
  const _IsolateMsg(this.port, this.args);

  final SendPort port;
  final _IsolateArgs args;
}

void _isolateEntry(_IsolateMsg msg) {
  try {
    final audio = ViperSuperResolution(
      rate: msg.args.rate,
      tapeEnhance: msg.args.tapeEnhance,
    ).process(
      msg.args.audio,
      onProgress: msg.args.report ? (p) => msg.port.send(p) : null,
    );
    msg.port.send(audio);
  } catch (e) {
    msg.port.send('$e');
  }
}
