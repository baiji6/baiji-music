/// 本地升频的文件级管线：解码 → [ViperStreamProcessor] → 24-bit WAV。
///
/// 复用项目既有的 ffmpeg CLI 通道（`libffmpeg_exec.so` / PATH / 手动指定）
/// 把任意输入（MP3 / FLAC / M4A / 在线直链）解码成 48 kHz / 16 bit / 立体声
/// PCM，再交给纯 Dart 升频引擎。
///
/// ## 关键约束（v2.5.3 修复）
/// 1. **ffmpeg 输出格式**：Android 内置的是**裁剪版 ffmpeg**，muxer 白名单为
///    `wav,flac,ipod,mp4,asf,adts,ac3,eac3,mp3,ogg`，**不含 `s16le`**。
///    旧实现用 `-f s16le` 导出裸 PCM，真机上必然报
///    `Requested output format 's16le' is not known.`，于是每次都走
///    「本地升频失败 → 降级播放原始 320k」。现在改为 `-f wav` 落临时文件，
///    再用 [ViperPcmStreamReader] 从 WAV 里流式取 PCM。
/// 2. **内存**：整段实现一首 4 分钟的歌在 192 kHz 档下峰值接近 2.2 GB，
///    Android 单进程 heap 只有 256~512 MB，必然 OOM。现在全链路是
///    **流式**的：解码产物落磁盘 → 分块读 → 逐帧升频 → 分块写 24bit WAV，
///    内存占用与歌曲长度无关（常数级）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import '../core/app_logger.dart' show AppLog;
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

  /// 缓存是否存在且**完整可用**。
  ///
  /// 单看「文件存在」不够：进程被系统杀掉 / 存储写满 / 用户手动清理时，
  /// 可能留下 0 字节或截断的 `.wav`。这种文件一旦被当成有效缓存命中，
  /// 播放器会拿到损坏音频却毫无提示。
  ///
  /// 判据：文件存在、长度不小于一个最小 WAV 头（44 字节），且头部
  /// 的 RIFF/WAVE 魔数正确。
  static Future<bool> hasValidCachedWav(String key, ViperUpscaleRate rate) async {
    final f = File(await wavPathFor(key, rate));
    try {
      if (!await f.exists()) return false;
      if (await f.length() < 44) return false;
      final raf = await f.open();
      try {
        final head = await raf.read(12);
        if (head.length < 12) return false;
        String tag(int o) => String.fromCharCodes(head.sublist(o, o + 4));
        return tag(0) == 'RIFF' && tag(8) == 'WAVE';
      } finally {
        await raf.close();
      }
    } catch (err) {
      AppLog.w('ViperUpscaler', '缓存校验失败: $err');
      return false;
    }
  }

  /// 升频缓存目录的容量上限（字节）。
  ///
  /// 192 kHz / 24 bit / 立体声的产物很大：一首 4 分钟的歌约 **264 MB**。
  /// 用户连续升频几首就会把手机存储吃满，后续升频写盘失败、缓存命中也
  /// 因为没有空间而无法落盘——最终表现还是「本地升频失败」。
  ///
  /// 因此在每次产出新缓存后按「最旧优先」淘汰，把目录压回上限内。
  /// 默认 2 GB：够放 7~8 首歌，又不至于把手机撑满。
  static int cacheQuotaBytes = 2 * 1024 * 1024 * 1024;

  /// 按「最旧优先」淘汰升频缓存，直到目录体积回到 [cacheQuotaBytes] 以内。
  ///
  /// - 只删**已完成的产物**（`.wav`）与**残留的临时文件**（`.part` / `.src`），
  ///   不会碰正在写入的文件（`.part` 在写完前不会被改名）。
  /// - [keepPath] 是刚产出的文件，保证它不被淘汰（否则刚算完就删了）。
  /// - 删不掉的条目（占用中 / 权限不足）直接跳过，不影响其它文件。
  /// - 返回释放的字节数。
  static Future<int> enforceCacheQuota({String? keepPath}) async {
    final quota = cacheQuotaBytes;
    try {
      final dir = Directory(await cacheDir());
      if (!await dir.exists()) return 0;

      // 收集候选：产物与临时文件都算，占空间。
      final entries = <File>[];
      // keepPath 不删，但**必须计入总量**——否则「保留下来的那个文件」
      // 本身就能把目录顶出配额，淘汰结束后目录依然超限。
      var total = 0;
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File) continue;
        final p = e.path;
        final isProduct = p.endsWith('.wav') ||
            p.endsWith('.part') ||
            p.endsWith('.src');
        if (!isProduct) continue;
        total += await e.length();
        if (p == keepPath) continue;
        entries.add(e);
      }
      if (entries.isEmpty && total <= quota) return 0;

      // 先算总占用。
      final sizes = <File, int>{};
      for (final f in entries) {
        sizes[f] = await f.length();
      }
      if (total <= quota) return 0;

      // 最旧优先（按最后修改时间）。
      entries.sort((a, b) =>
          a.statSync().modified.compareTo(b.statSync().modified));

      var freed = 0;
      // 剩余占用单独记账：不要既递减 total 又累加 freed 再拿两者相减，
      // 那会把已释放的量扣两次，导致提前 break、淘汰不彻底
      // （目录仍然超配额 → 后续升频照样写盘失败）。
      var remaining = total;
      for (final f in entries) {
        if (remaining <= quota) break;
        final len = sizes[f] ?? 0;
        try {
          await f.delete();
          freed += len;
          remaining -= len;
        } catch (err) {
          // 占用中删不掉：跳过，继续淘汰下一个。
          AppLog.w('ViperUpscaler', '淘汰缓存失败 ${f.path}: $err');
        }
      }
      if (freed > 0) {
        AppLog.i('ViperUpscaler',
            '升频缓存超出上限，已淘汰最旧文件释放 ${(freed / 1048576).toStringAsFixed(1)} MB');
      }
      return freed;
    } catch (err) {
      // 拿不到缓存目录（极端情况）或遍历失败：不阻断升频主流程，
      // 只是这轮不做淘汰。用户仍可在设置里手动「清理缓存」。
      AppLog.w('ViperUpscaler', '缓存配额淘汰未执行: $err');
      return 0;
    }
  }

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

    // —— 1) 解码到 48 kHz / 16 bit / 立体声 WAV（落磁盘，不占内存）——
    final exe = ffmpegPath ?? await resolveFfmpeg();
    String? decoded;
    String source = inputPath;
    if (exe != null) {
      decoded = '$inputPath.viper48k.wav';
      await _decodeTo48kWav(
        exe,
        inputPath,
        decoded,
        onProgress: (p) => onProgress?.call(p * 0.10),
        isCancelled: isCancelled,
      );
      source = decoded;
    } else {
      // 没有引擎时只允许直接读 WAV（桌面 / CI 常见，测试用短 WAV）。
      if (!inputPath.toLowerCase().endsWith('.wav')) {
        throw StateError(
            '未找到 ffmpeg 引擎，无法解码音频。请在设置/工具箱里指定 ffmpeg 路径，'
            '或改用 WAV 输入。');
      }
    }
    if (isCancelled?.call() == true) throw const ViperCancelled();
    onProgress?.call(0.10);

    try {
      // —— 2) 在独立 isolate 里流式升频并落盘 ——
      // 先写临时文件，成功后再原子改名到目标路径：避免中途取消/崩溃留下
      // 半成品被当成有效缓存命中（播放链路会直接读缓存文件）。
      final tmpOut = '$outputPath.part';
      try {
        final res = await _runStreamInIsolate(
          source,
          tmpOut,
          rate: rate,
          tapeEnhance: tapeEnhance,
          onProgress: (p) => onProgress?.call(0.10 + p * 0.88),
          isCancelled: isCancelled,
        );
        if (isCancelled?.call() == true) throw const ViperCancelled();
        final outFile = File(outputPath);
        if (await outFile.exists()) await outFile.delete();
        await File(tmpOut).rename(outputPath);
        onProgress?.call(1.0);
        sw.stop();
        // 产物可达数百 MB，产出后立刻把缓存目录压回配额内（最旧优先淘汰）。
        unawaited(enforceCacheQuota(keepPath: outputPath));
        return ViperUpscaleResult(
          wavPath: outputPath,
          sampleRate: res.sampleRate,
          bitDepth: 24,
          channels: 2,
          frames: res.frames,
          bytes: res.bytes,
          elapsed: sw.elapsed,
        );
      } finally {
        try {
          final f = File(tmpOut);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    } finally {
      if (decoded != null) {
        try {
          final f = File(decoded);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
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

  /// 构造 ffmpeg 解码参数：任意输入 → 48 kHz / 16 bit / 立体声 WAV。
  ///
  /// 关键点：**必须用 `-f wav`**。
  ///
  /// Android 内置的裁剪版 ffmpeg（`libffmpeg_exec.so`）在构建时显式限定了
  /// 能力白名单（见 ffmpeg 构建脚本）：
  /// - `MUXERS=wav,flac,ipod,mp4,asf,adts,ac3,eac3,mp3,ogg`
  /// - `ENCODERS=pcm_s16le,pcm_s24le,pcm_s32le,flac,aac,wmav2,libmp3lame,libvorbis,ac3,eac3`
  ///
  /// 其中**没有 `s16le` muxer**。旧实现用 `-f s16le` 导出裸 PCM，真机上
  /// 必然报 `Requested output format 's16le' is not known.`，于是每次升频
  /// 都失败、静默降级回原始 320k（就是用户截图里看到的提示）。
  /// `-f wav` + `-c:a pcm_s16le` 是这套白名单下唯一可行的 PCM 输出组合。
  @visibleForTesting
  static List<String> decodeArgs(String inputPath, String outputPath) =>
      <String>[
        '-hide_banner',
        '-loglevel', 'error',
        '-nostdin',
        '-y',
        '-i', inputPath,
        '-vn', // 丢掉视频/封面流，只保留音频
        '-map', '0:a:0',
        '-ac', '2',
        '-ar', '48000',
        '-c:a', 'pcm_s16le',
        '-f', 'wav', // 裁剪版 ffmpeg 支持的 muxer 里必须用 wav
        outputPath,
      ];

  /// 用 ffmpeg 把任意输入解码成 48 kHz / 16 bit / 立体声 WAV。
  static Future<void> _decodeTo48kWav(
    String exe,
    String inputPath,
    String outputPath, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    onProgress?.call(0.05);
    final Process proc;
    try {
      proc = await Process.start(exe, decodeArgs(inputPath, outputPath));
    } on ProcessException catch (e) {
      // 引擎文件不存在 / 不可执行 / 无权限：包装成可读错误，
      // 否则用户只会看到 dart:io 的原始英文异常。
      throw StateError('无法启动解码引擎（$exe）：${e.message}');
    }
    final errBuf = StringBuffer();
    // stderr 必须持续消费，否则管道写满会让 ffmpeg 卡死。
    final errDone = proc.stderr.transform(const Utf8Decoder()).forEach((s) {
      errBuf.write(s);
    });
    final code = await proc.exitCode;
    await errDone;
    if (isCancelled?.call() == true) throw const ViperCancelled();
    if (code != 0) {
      final err = errBuf.toString().trim();
      throw StateError('ffmpeg 解码失败 ($code): '
          '${err.isEmpty ? '未知错误' : err}');
    }
    onProgress?.call(1.0);
  }

  /// 在独立 isolate 里跑流式升频，进度经 SendPort 回传。
  ///
  /// isolate 只接收**路径与参数**（几十字节），不传任何音频数据，
  /// 因此不存在 isolate 消息深拷贝带来的内存翻倍。
  static Future<_StreamResult> _runStreamInIsolate(
    String sourceWav,
    String outputPath, {
    required ViperUpscaleRate rate,
    required bool tapeEnhance,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final port = ReceivePort();
    final iso = await Isolate.spawn<_StreamArgs>(
      _streamIsolateEntry,
      _StreamArgs(
        port.sendPort,
        sourceWav,
        outputPath,
        rate,
        tapeEnhance,
      ),
    );
    _StreamResult? out;
    String? error;
    try {
      await for (final msg in port) {
        if (msg is double) {
          // isolate 在算，UI 侧随时可以叫停（进度每 ~170ms 回传一次）。
          if (isCancelled?.call() == true) {
            throw const ViperCancelled();
          }
          onProgress?.call(msg);
        } else if (msg is _StreamResult) {
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

/// isolate 侧的升频产物摘要。
class _StreamResult {
  const _StreamResult(this.frames, this.bytes, this.sampleRate);

  final int frames;
  final int bytes;
  final int sampleRate;
}

/// isolate 入口参数（只含不可变的小对象）。
class _StreamArgs {
  const _StreamArgs(
    this.port,
    this.sourceWav,
    this.outputPath,
    this.rate,
    this.tapeEnhance,
  );

  final SendPort port;
  final String sourceWav;
  final String outputPath;
  final ViperUpscaleRate rate;
  final bool tapeEnhance;
}

/// isolate 内执行体：分块读 PCM → 逐帧升频 → 分块写 24bit WAV。
///
/// 全程使用同步文件 IO（isolate 里没有事件循环压力），内存占用与音频
/// 时长无关：输入按 [ViperPcmStreamReader] 的块读，输出按
/// [ViperWav24Writer] 的块写，中间只有定长的 DSP 工作缓冲。
void _streamIsolateEntry(_StreamArgs args) {
  try {
    final reader = ViperPcmStreamReader.open(args.sourceWav);
    ViperWav24Writer? writer;
    try {
      final header = reader.header;
      final totalIn = reader.frames;

      // 非 48 kHz / 非立体声的输入（只有「无 ffmpeg 且直接读 WAV」时才会
      // 出现）走整段路径：先统一到 48 kHz 立体声再整段升频。
      if (header.sampleRate != ViperStreamProcessor.baseRate ||
          header.channels != 2) {
        final res = _wholeFileFallback(args, reader, header);
        args.port.send(res);
        return;
      }

      final processor = ViperStreamProcessor(
        rate: args.rate,
        tapeEnhance: args.tapeEnhance,
      );
      writer = ViperWav24Writer.create(
        args.outputPath,
        sampleRate: args.rate.hz,
        channels: 2,
      );

      // 每块 8192 帧（约 170 ms @48k），兼顾 IO 与进度回传频率。
      const chunk = 8192;
      final interleaved = Float64List(chunk * 2);
      final left = Float64List(chunk);
      final right = Float64List(chunk);
      var read = 0;

      void sink(Float64List buf, int frames) {
        writer!.write(buf, frames);
      }

      while (true) {
        final n = reader.read(interleaved, chunk);
        if (n <= 0) break;
        // 交错 → 分离左右声道。
        for (var i = 0; i < n; i++) {
          left[i] = interleaved[i * 2];
          right[i] = interleaved[i * 2 + 1];
        }
        processor.pushStereo(left, right, n, sink);
        read += n;
        args.port.send(totalIn > 0 ? read / totalIn : 1.0);
      }
      processor.flush(sink);

      final outFrames = read * processor.ratio;
      writer.finish(outFrames);
      writer.close();
      writer = null;
      args.port.send(_StreamResult(outFrames, outFrames * 2 * 3 + 44,
          args.rate.hz));
    } finally {
      reader.close();
      try {
        writer?.close();
      } catch (_) {}
    }
  } catch (e) {
    args.port.send('$e');
  }
}

/// 无 ffmpeg 且源 WAV 不是 48 kHz / 立体声时的整段兜底路径。
///
/// 触发条件极窄（桌面 / CI 直读 WAV），此处允许整段处理；
/// 生产路径（Android）永远走上面的流式分支。
_StreamResult _wholeFileFallback(
  _StreamArgs args,
  ViperPcmStreamReader reader,
  ViperWavHeader header,
) {
  final frames = reader.frames;
  final ch = header.channels;
  final left = Float64List(frames);
  final right = Float64List(frames);
  final scratch = Float64List(8192 * ch);
  var got = 0;
  while (got < frames) {
    final n = reader.read(scratch, 8192);
    if (n <= 0) break;
    for (var i = 0; i < n; i++) {
      final l = scratch[i * ch];
      left[got + i] = l;
      right[got + i] = ch == 1 ? l : scratch[i * ch + 1];
    }
    got += n;
  }
  final audio = ViperAudio(header.sampleRate, 2,
      <Float64List>[left.sublist(0, got), right.sublist(0, got)]);
  final out = ViperSuperResolution(
    rate: args.rate,
    tapeEnhance: args.tapeEnhance,
  ).process(audio);
  final bytes = ViperWav.encode24(out);
  File(args.outputPath).writeAsBytesSync(bytes, flush: true);
  return _StreamResult(out.frames, bytes.length, args.rate.hz);
}
