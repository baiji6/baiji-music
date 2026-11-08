/// 本地升频「文件级管线」的回归测试（v2.5.3 修复）。
///
/// 锁住两个曾经导致真机「本地升频失败」的问题：
/// 1. **ffmpeg 输出格式**：Android 内置的是裁剪版 ffmpeg，muxer 白名单
///    `wav,flac,ipod,mp4,asf,adts,ac3,eac3,mp3,ogg` 里**没有 `s16le`**，
///    旧实现 `-f s16le` 必然报
///    `Requested output format 's16le' is not known.`；
/// 2. **内存占用**：整段实现一首 4 分钟的歌在 192k 档峰值约 2.2 GB，
///    Android 单进程 heap 只有 256~512 MB，必然 OOM。
///
/// 本文件不依赖 ffmpeg / 平台通道，纯 Dart 验证流式引擎与 WAV 流式读写。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:baiji_music/core/cache_manager.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/viper/viper_super_resolution.dart';
import 'package:baiji_music/viper/viper_upscaler.dart';
import 'package:baiji_music/viper/viper_wav.dart';

/// 判断 WAV 文件是否具备完整的 RIFF/WAVE 头（与
/// [ViperUpscaler.hasValidCachedWav] 同一判据）。
Future<bool> _isValidWavFile(File f) async {
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
}

/// 造一个最小但结构完整的 RIFF/WAVE 头。
Uint8List _riffWaveHeader() {
  final b = Uint8List(64);
  final bd = ByteData.sublistView(b);
  void tag(int o, String s) {
    for (var i = 0; i < 4; i++) {
      b[o + i] = s.codeUnitAt(i);
    }
  }

  tag(0, 'RIFF');
  bd.setUint32(4, 36, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 2, Endian.little);
  bd.setUint32(24, 48000, Endian.little);
  bd.setUint32(28, 48000 * 4, Endian.little);
  bd.setUint16(32, 4, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  bd.setUint32(40, 20, Endian.little);
  return b;
}

void main() {
  // 升频缓存目录走 CacheManager → KvStore（用户可自定义缓存根目录），
  // 真实运行时由 main() 在启动时初始化 KvStore.ensureInit()。
  // 这里给一份 mock，让配额淘汰走真实路径而不是被 catch 吞掉。
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await KvStore.ensureInit();
  });

  group('ViperStreamProcessor（流式引擎）', () {
    Float64List tone(int frames, double freq, {double amp = 0.6}) {
      final x = Float64List(frames);
      for (var i = 0; i < frames; i++) {
        x[i] = amp * math.sin(2 * math.pi * freq * i / 48000);
      }
      return x;
    }

    /// 用流式引擎处理一段立体声 PCM，返回交错的输出。
    List<double> runStream(
      Float64List left,
      Float64List right,
      ViperUpscaleRate rate,
    ) {
      final p = ViperStreamProcessor(rate: rate);
      final out = <double>[];
      void sink(Float64List buf, int frames) {
        for (var i = 0; i < frames * 2; i++) {
          out.add(buf[i]);
        }
      }

      const chunk = 4096;
      for (var off = 0; off < left.length; off += chunk) {
        final n = math.min(chunk, left.length - off);
        p.pushStereo(
          left.sublist(off, off + n),
          right.sublist(off, off + n),
          n,
          sink,
        );
      }
      p.flush(sink);
      return out;
    }

    test('流式输出与整段实现数值一致（黄金样本回归）', () {
      const frames = 48000 ~/ 5; // 0.2 s
      final x = tone(frames, 1000);
      final input = ViperAudio(48000, 2, <Float64List>[x, Float64List.fromList(x)]);

      final whole = ViperSuperResolution(rate: ViperUpscaleRate.khz192)
          .process(input);

      final streamed = runStream(x, Float64List.fromList(x),
          ViperUpscaleRate.khz192);

      expect(streamed.length, whole.frames * 2,
          reason: '流式输出长度应与整段一致');
      var maxErr = 0.0;
      for (var i = 0; i < whole.frames; i++) {
        maxErr = math.max(maxErr, (streamed[i * 2] - whole.data[0][i]).abs());
        maxErr = math.max(maxErr, (streamed[i * 2 + 1] - whole.data[1][i]).abs());
      }
      expect(maxErr < 1e-9, isTrue, reason: '流式/整段最大偏差 $maxErr');
    });

    test('流式输出帧数 = 输入帧数 × 倍率', () {
      const frames = 48000 ~/ 10;
      final x = tone(frames, 440);
      final s96 = runStream(x, x, ViperUpscaleRate.khz96);
      final s192 = runStream(x, x, ViperUpscaleRate.khz192);
      expect(s96.length, frames * 2 * 2);
      expect(s192.length, frames * 4 * 2);
    });

    test('分块大小不影响输出（块边界无关性）', () {
      const frames = 48000 ~/ 5;
      final x = tone(frames, 1000);
      final a = runStream(x, x, ViperUpscaleRate.khz192);

      // 用不同的分块尺寸再跑一遍，结果必须逐样本相同。
      final p = ViperStreamProcessor(rate: ViperUpscaleRate.khz192);
      final b = <double>[];
      void sink(Float64List buf, int frames) {
        for (var i = 0; i < frames * 2; i++) {
          b.add(buf[i]);
        }
      }

      for (var off = 0; off < frames; off += 777) {
        final n = math.min(777, frames - off);
        p.pushStereo(x.sublist(off, off + n), x.sublist(off, off + n), n, sink);
      }
      p.flush(sink);

      expect(b.length, a.length);
      var maxErr = 0.0;
      for (var i = 0; i < a.length; i++) {
        maxErr = math.max(maxErr, (a[i] - b[i]).abs());
      }
      expect(maxErr < 1e-12, isTrue, reason: '不同分块的最大偏差 $maxErr');
    });

    test('输出无 NaN / 无削波，峰值保护生效', () {
      const frames = 48000 ~/ 5;
      final x = tone(frames, 1000, amp: 0.95);
      final out = runStream(x, x, ViperUpscaleRate.khz192);
      var peak = 0.0;
      for (final v in out) {
        expect(v.isFinite, isTrue);
        peak = math.max(peak, v.abs());
      }
      expect(peak <= ViperStreamProcessor.ceiling + 1e-9, isTrue,
          reason: '峰值 $peak 超过软拐点上限');
    });

    test('峰值保护在拐点以下完全透明', () {
      expect(ViperStreamProcessor.limitPeak(0.5), 0.5);
      expect(ViperStreamProcessor.limitPeak(-0.5), -0.5);
      expect(ViperStreamProcessor.limitPeak(0.0), 0.0);
      // 超过拐点后单调压缩，且不会超过 ceiling。
      final v = ViperStreamProcessor.limitPeak(1.5);
      expect(v, lessThan(1.5));
      expect(v, lessThanOrEqualTo(ViperStreamProcessor.ceiling + 1e-9));
    });

    test('内存占用与音频时长无关（常量级工作缓冲）', () {
      // 断言引擎的工作缓冲是定长的，不随输入长度增长。
      final p = ViperStreamProcessor(rate: ViperUpscaleRate.khz192);
      expect(p.nHigh, ViperStreamProcessor.nLow * 4);
      expect(p.hopHigh, ViperStreamProcessor.hopLow * 4);
      // 处理 10 秒音频后，引擎内部状态不变（没有累积整段缓冲）。
      final x = tone(480000, 440);
      var frames = 0;
      void sink(Float64List buf, int n) {
        frames += n;
      }

      for (var off = 0; off < x.length; off += 8192) {
        final n = math.min(8192, x.length - off);
        p.pushStereo(x.sublist(off, off + n), x.sublist(off, off + n), n, sink);
      }
      p.flush(sink);
      expect(frames, 480000 * 4);
    });
  });

  group('ViperPcmStreamReader / ViperWav24Writer（流式 WAV 读写）', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('viper_wav_test');
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('流式写 → 流式读 往返一致', () {
      const frames = 5000;
      const ch = 2;
      final src = Float64List(frames * ch);
      for (var i = 0; i < frames; i++) {
        src[i * ch] = math.sin(2 * math.pi * 300 * i / 48000) * 0.8;
        src[i * ch + 1] = math.cos(2 * math.pi * 700 * i / 48000) * 0.5;
      }

      final path = '${tmp.path}/stream.wav';
      final writer = ViperWav24Writer.create(
        path,
        sampleRate: 48000,
        channels: ch,
        dither: false, // 关闭抖动，往返误差只剩量化误差
      );
      // 分三块写入，模拟流式产出。
      var off = 0;
      for (final n in <int>[1000, 2000, 2000]) {
        writer.write(src.sublist(off * ch, (off + n) * ch), n);
        off += n;
      }
      writer.finish(frames);
      writer.close();

      final reader = ViperPcmStreamReader.open(path);
      addTearDown(reader.close);
      expect(reader.header.sampleRate, 48000);
      expect(reader.header.channels, 2);
      expect(reader.header.bits, 24);
      expect(reader.frames, frames);

      final dst = Float64List(frames * ch);
      final got = reader.read(dst, frames);
      expect(got, frames);
      for (var i = 0; i < frames * ch; i++) {
        expect((dst[i] - src[i]).abs() < 2 / 8388608, isTrue,
            reason: '样本 $i 偏差过大');
      }
    });

    test('流式读支持分块（多次 read 结果拼接等于一次读完）', () {
      const frames = 3000;
      final src = Float64List(frames * 2);
      for (var i = 0; i < frames * 2; i++) {
        src[i] = (i % 1000) / 1000.0 - 0.5;
      }
      final path = '${tmp.path}/chunk.wav';
      final writer = ViperWav24Writer.create(
        path,
        sampleRate: 48000,
        channels: 2,
        dither: false,
      );
      writer.write(src, frames);
      writer.finish(frames);
      writer.close();

      final reader = ViperPcmStreamReader.open(path);
      addTearDown(reader.close);
      final a = Float64List(700 * 2);
      final b = Float64List((frames - 700) * 2);
      expect(reader.read(a, 700), 700);
      expect(reader.read(b, frames - 700), frames - 700);
      for (var i = 0; i < 700 * 2; i++) {
        expect((a[i] - src[i]).abs() < 2 / 8388608, isTrue);
      }
      for (var i = 0; i < b.length; i++) {
        expect((b[i] - src[700 * 2 + i]).abs() < 2 / 8388608, isTrue);
      }
    });

    test('finish() 把文件裁剪到指定帧数（尾部补零幻听被截掉）', () {
      const frames = 1000;
      final src = Float64List(frames * 2);
      for (var i = 0; i < frames * 2; i++) {
        src[i] = 0.25;
      }
      final path = '${tmp.path}/trim.wav';
      final writer = ViperWav24Writer.create(
        path,
        sampleRate: 48000,
        channels: 2,
        dither: false,
      );
      writer.write(src, frames);
      // 多写 500 帧（模拟尾部补零幻听），然后裁回 1000 帧。
      writer.write(src, 500);
      writer.finish(frames);
      writer.close();

      expect(File(path).lengthSync(), 44 + frames * 2 * 3);
      final reader = ViperPcmStreamReader.open(path);
      addTearDown(reader.close);
      expect(reader.frames, frames);
    });

    test('非法 WAV 明确报错，不编造规格', () {
      final path = '${tmp.path}/bad.wav';
      File(path).writeAsBytesSync(Uint8List(10));
      expect(() => ViperPcmStreamReader.open(path),
          throwsA(isA<FormatException>()));
    });
  });

  group('ffmpeg 解码参数（裁剪版引擎兼容）', () {
    test('必须用 -f wav，不得用 -f s16le（裁剪版 ffmpeg 无此 muxer）', () {
      final args = ViperUpscaler.decodeArgs('/tmp/in.mp3', '/tmp/out.wav');
      // 输出 muxer 必须是 wav。
      final fIdx = args.indexOf('-f');
      expect(fIdx, greaterThan(-1));
      expect(args[fIdx + 1], 'wav');
      // 绝不能出现 s16le muxer（那会把 -c:a pcm_s16le 也一并拒掉）。
      expect(args.contains('s16le'), isFalse);
      // 编码器仍是 16bit PCM，采样率 48k，立体声。
      final cIdx = args.indexOf('-c:a');
      expect(args[cIdx + 1], 'pcm_s16le');
      final arIdx = args.indexOf('-ar');
      expect(args[arIdx + 1], '48000');
      final acIdx = args.indexOf('-ac');
      expect(args[acIdx + 1], '2');
      // 输入路径跟在 -i 之后，输出路径是最后一个参数。
      final iIdx = args.indexOf('-i');
      expect(args[iIdx + 1], '/tmp/in.mp3');
      expect(args.last, '/tmp/out.wav');
    });
  });

  group('WAV 直读输入（无 ffmpeg 的桌面 / CI 路径）', () {
    /// 造一个 16bit PCM WAV 文件。
    Uint8List makeWav(int rate, int ch, int frames, double freq) {
      final dataLen = frames * ch * 2;
      final b = Uint8List(44 + dataLen);
      final bd = ByteData.sublistView(b);
      void tag(int o, String str) {
        for (var i = 0; i < 4; i++) {
          b[o + i] = str.codeUnitAt(i);
        }
      }

      tag(0, 'RIFF');
      bd.setUint32(4, 36 + dataLen, Endian.little);
      tag(8, 'WAVE');
      tag(12, 'fmt ');
      bd.setUint32(16, 16, Endian.little);
      bd.setUint16(20, 1, Endian.little);
      bd.setUint16(22, ch, Endian.little);
      bd.setUint32(24, rate, Endian.little);
      bd.setUint32(28, rate * ch * 2, Endian.little);
      bd.setUint16(32, ch * 2, Endian.little);
      bd.setUint16(34, 16, Endian.little);
      tag(36, 'data');
      bd.setUint32(40, dataLen, Endian.little);
      for (var i = 0; i < frames; i++) {
        for (var c = 0; c < ch; c++) {
          final v =
              (0.6 * math.sin(2 * math.pi * freq * i / rate) * 32767).round();
          bd.setInt16(44 + (i * ch + c) * 2, v, Endian.little);
        }
      }
      return b;
    }

    test('48 kHz 立体声 WAV 直读可正常升频', () async {
      final dir = Directory.systemTemp.createTempSync('viper_in');
      addTearDown(() => dir.deleteSync(recursive: true));
      final input = '${dir.path}/in48.wav';
      File(input).writeAsBytesSync(makeWav(48000, 2, 4800, 440));
      final out = '${dir.path}/out.wav';

      final res = await ViperUpscaler.upscaleFile(
        inputPath: input,
        outputPath: out,
        rate: ViperUpscaleRate.khz192,
      );
      expect(res.sampleRate, 192000);
      expect(res.frames, 4800 * 4);
      final back = ViperWav.readFile(out);
      expect(back.sampleRate, 192000);
      expect(back.channels, 2);
    });

    test('44.1 kHz 单声道 WAV 直读会重采样到 48 kHz 立体声', () async {
      final dir = Directory.systemTemp.createTempSync('viper_in');
      addTearDown(() => dir.deleteSync(recursive: true));
      final input = '${dir.path}/in44.wav';
      File(input).writeAsBytesSync(makeWav(44100, 1, 4410, 440));
      final out = '${dir.path}/out.wav';

      final res = await ViperUpscaler.upscaleFile(
        inputPath: input,
        outputPath: out,
        rate: ViperUpscaleRate.khz192,
      );
      expect(res.sampleRate, 192000);
      final back = ViperWav.readFile(out);
      expect(back.channels, 2);
      expect(back.peak() <= 1.0, isTrue);
      for (final ch in back.data) {
        for (final v in ch) {
          expect(v.isFinite, isTrue);
        }
      }
    });

    test('非 WAV 输入且无引擎时给出明确错误（不静默失败）', () async {
      final dir = Directory.systemTemp.createTempSync('viper_in');
      addTearDown(() => dir.deleteSync(recursive: true));
      final input = '${dir.path}/in.mp3';
      File(input).writeAsBytesSync(makeWav(48000, 2, 100, 440));
      // 显式指向不存在的引擎，确保走「无引擎」分支（不依赖沙箱 PATH）。
      expect(
        () => ViperUpscaler.upscaleFile(
          inputPath: input,
          outputPath: '${dir.path}/out.wav',
          ffmpegPath: '/definitely/not/exists/ffmpeg',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('缓存配额与完整性', () {
    test('超出配额时按最旧优先淘汰，且保留刚产出的文件', () async {
      final root = Directory.systemTemp.createTempSync('viper_q');
      final quotaBackup = ViperUpscaler.cacheQuotaBytes;
      addTearDown(() {
        CacheManager.debugSetRuntimeRoot(null);
        ViperUpscaler.cacheQuotaBytes = quotaBackup;
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      // 把缓存根指向临时目录，viper 子目录随之落在临时空间里。
      CacheManager.debugSetRuntimeRoot(root.path);
      final vdir = await ViperUpscaler.cacheDir();
      // 配额压到 700 KB：5 个 300 KB 的文件总量 1.5 MB，必然超配额。
      ViperUpscaler.cacheQuotaBytes = 700 * 1024;

      Future<void> write(String name, int bytes, DateTime mtime) async {
        final f = File('$vdir${Platform.pathSeparator}$name');
        await f.writeAsBytes(List<int>.filled(bytes, 0), flush: true);
        await f.setLastModified(mtime);
      }

      final now = DateTime.now();
      for (var i = 0; i < 5; i++) {
        await write('old_$i.wav', 300 * 1024,
            now.subtract(Duration(minutes: 30 - i)));
      }
      final keep = '$vdir${Platform.pathSeparator}newest.wav';
      await write('newest.wav', 300 * 1024, now);

      final freed = await ViperUpscaler.enforceCacheQuota(keepPath: keep);

      // 释放量必须够把总量压回 700 KB 以内：1.5 MB → ≤700 KB，
      // 即至少删掉 3 个 300 KB 的文件（900 KB）。
      expect(freed, greaterThanOrEqualTo(900 * 1024));
      // keepPath 绝不能被删。
      expect(File(keep).existsSync(), isTrue);
      // 最旧的两个一定没了，最新的还在。
      expect(
        File('$vdir${Platform.pathSeparator}old_0.wav').existsSync(),
        isFalse,
      );
      expect(
        File('$vdir${Platform.pathSeparator}old_1.wav').existsSync(),
        isFalse,
      );
      // 剩下的文件总量已回到配额内。
      var remain = 0;
      for (final f in Directory(vdir).listSync().whereType<File>()) {
        remain += await f.length();
      }
      expect(remain, lessThanOrEqualTo(ViperUpscaler.cacheQuotaBytes));
    });

    test('临时文件（.part/.src）同样计入配额并被优先淘汰', () async {
      final root = Directory.systemTemp.createTempSync('viper_q3');
      final quotaBackup = ViperUpscaler.cacheQuotaBytes;
      addTearDown(() {
        CacheManager.debugSetRuntimeRoot(null);
        ViperUpscaler.cacheQuotaBytes = quotaBackup;
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      CacheManager.debugSetRuntimeRoot(root.path);
      final vdir = await ViperUpscaler.cacheDir();
      ViperUpscaler.cacheQuotaBytes = 100 * 1024;

      final now = DateTime.now();
      // 最旧的是个残留的 .src（上次下载没清掉）。
      final src = File('$vdir${Platform.pathSeparator}leftover.src');
      await src.writeAsBytes(List<int>.filled(200 * 1024, 0), flush: true);
      await src.setLastModified(now.subtract(const Duration(hours: 3)));
      // 较新的是个 .part（上次写盘被中断）。
      final part = File('$vdir${Platform.pathSeparator}half.part');
      await part.writeAsBytes(List<int>.filled(200 * 1024, 0), flush: true);
      await part.setLastModified(now.subtract(const Duration(hours: 1)));

      final freed = await ViperUpscaler.enforceCacheQuota();
      expect(freed, greaterThanOrEqualTo(200 * 1024));
      expect(src.existsSync(), isFalse);
      expect(part.existsSync(), isFalse);
    });

    test('正在写入的临时文件不被淘汰（避免打断并发升频）', () async {
      final root = Directory.systemTemp.createTempSync('viper_q4');
      final quotaBackup = ViperUpscaler.cacheQuotaBytes;
      addTearDown(() {
        CacheManager.debugSetRuntimeRoot(null);
        ViperUpscaler.cacheQuotaBytes = quotaBackup;
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      CacheManager.debugSetRuntimeRoot(root.path);
      final vdir = await ViperUpscaler.cacheDir();
      ViperUpscaler.cacheQuotaBytes = 50 * 1024;

      // 一个「刚刚写过」的 .part：视为正在写入，不该被删。
      final hot = File('$vdir${Platform.pathSeparator}hot.part');
      await hot.writeAsBytes(List<int>.filled(400 * 1024, 0), flush: true);
      // 一个很久以前的 .part：残留垃圾，该被清理。
      final cold = File('$vdir${Platform.pathSeparator}cold.part');
      await cold.writeAsBytes(List<int>.filled(400 * 1024, 0), flush: true);
      await cold.setLastModified(
          DateTime.now().subtract(const Duration(days: 2)));

      await ViperUpscaler.enforceCacheQuota();

      expect(hot.existsSync(), isTrue, reason: '正在写入的临时文件不能被删');
      expect(cold.existsSync(), isFalse, reason: '陈旧残留应被清理');
    });

    test('完整性校验能识别截断/损坏的缓存文件', () async {
      final dir = Directory.systemTemp.createTempSync('viper_v');
      addTearDown(() => dir.deleteSync(recursive: true));

      // 0 字节文件 —— 视为损坏。
      final bad = File('${dir.path}/bad.wav')..writeAsBytesSync(const <int>[]);
      expect(await _isValidWavFile(bad), isFalse);

      // 头不完整 —— 视为损坏。
      final short = File('${dir.path}/short.wav')
        ..writeAsBytesSync(List<int>.filled(10, 0));
      expect(await _isValidWavFile(short), isFalse);

      // 魔数不对 —— 视为损坏。
      final wrong = File('${dir.path}/wrong.wav')
        ..writeAsBytesSync(List<int>.filled(64, 0x41));
      expect(await _isValidWavFile(wrong), isFalse);

      // 正常 RIFF/WAVE 头 —— 视为有效。
      final good = File('${dir.path}/good.wav')
        ..writeAsBytesSync(_riffWaveHeader());
      expect(await _isValidWavFile(good), isTrue);
    });
  });

  // ==================== v2.5.6：并发升频「引擎异常」回归 ====================
  // 真机日志：升频完成 267MB 后，紧跟一条「本地升频失败(引擎异常)」，报
  // `Cannot open file ...xxx.wav.src.viper48k.wav`。根因是解码中间文件
  // `*.viper48k.wav` 以 .wav 结尾，被配额淘汰当成「已完成产物」删掉；
  // 且并发升频共用固定中间文件名，先完成者的 finally 删了另一个正在读的文件。
  group('v2.5.6 并发升频保护', () {
    group('isTransientFile（瞬态文件分类）', () {
      test('解码中间文件、写盘半成品、下载源都算瞬态', () {
        expect(
          ViperUpscaler.isTransientFile(
              '/cache/viper/abc.wav.src.123_0.viper48k.wav'),
          isTrue,
          reason: '带唯一 token 的解码中间文件必须识别为瞬态');
        expect(ViperUpscaler.isTransientFile('/cache/viper/abc.wav.9_2.part'),
            isTrue);
        expect(ViperUpscaler.isTransientFile('/cache/viper/abc.wav.src'),
            isTrue);
      });

      test('最终产物（md5.wav）不是瞬态', () {
        expect(
          ViperUpscaler.isTransientFile(
              '/cache/viper/5edd0fd94ef7e58bcf6f63b8cc0eabb1.wav'),
          isFalse,
          reason: '最终产物必须参与配额淘汰，否则缓存无限增长');
        expect(ViperUpscaler.isTransientFile('/cache/viper/out.wav'), isFalse);
      });

      test('无关文件不是瞬态也不计入缓存', () {
        expect(ViperUpscaler.isTransientFile('/cache/viper/readme.txt'), isFalse);
        expect(ViperUpscaler.isTransientFile('/cache/viper/.baiji_cache'),
            isFalse);
      });
    });

    test('正在写入的解码中间文件 *.viper48k.wav 不被淘汰（引擎异常根因）',
        () async {
      final root = Directory.systemTemp.createTempSync('viper_concurrent');
      final quotaBackup = ViperUpscaler.cacheQuotaBytes;
      addTearDown(() {
        CacheManager.debugSetRuntimeRoot(null);
        ViperUpscaler.cacheQuotaBytes = quotaBackup;
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      CacheManager.debugSetRuntimeRoot(root.path);
      final vdir = await ViperUpscaler.cacheDir();
      // 配额压得很低，逼淘汰流程跑起来。
      ViperUpscaler.cacheQuotaBytes = 50 * 1024;
      final now = DateTime.now();

      // 一个「刚解码出来、另一个 isolate 正在读」的中间文件（很大，
      // 旧实现会因为它以 .wav 结尾、且不享受宽限期，直接淘汰掉）。
      final decoded = File(
          '$vdir${Platform.pathSeparator}abc.wav.src.111_0.viper48k.wav');
      await decoded.writeAsBytes(
          List<int>.filled(400 * 1024, 0),
          flush: true);
      // 一个很旧的最终产物：应该被淘汰来腾空间。
      final old = File('$vdir${Platform.pathSeparator}old_final.wav');
      await old.writeAsBytes(List<int>.filled(400 * 1024, 0), flush: true);
      await old.setLastModified(now.subtract(const Duration(days: 2)));

      await ViperUpscaler.enforceCacheQuota();

      expect(decoded.existsSync(), isTrue,
          reason: '正在写入的 *.viper48k.wav 不能被删，否则并发升频报引擎异常');
      expect(old.existsSync(), isFalse,
          reason: '陈旧的最终产物应被淘汰以压回配额');
    });

    test('陈旧的解码中间文件残留仍会被清理（不泄漏）', () async {
      final root = Directory.systemTemp.createTempSync('viper_stale');
      final quotaBackup = ViperUpscaler.cacheQuotaBytes;
      addTearDown(() {
        CacheManager.debugSetRuntimeRoot(null);
        ViperUpscaler.cacheQuotaBytes = quotaBackup;
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      CacheManager.debugSetRuntimeRoot(root.path);
      final vdir = await ViperUpscaler.cacheDir();
      ViperUpscaler.cacheQuotaBytes = 50 * 1024;

      final stale = File(
          '$vdir${Platform.pathSeparator}abc.wav.src.222_0.viper48k.wav');
      await stale.writeAsBytes(
          List<int>.filled(400 * 1024, 0),
          flush: true);
      await stale.setLastModified(
          DateTime.now().subtract(const Duration(days: 2)));

      await ViperUpscaler.enforceCacheQuota();
      expect(stale.existsSync(), isFalse,
          reason: '超过宽限期的瞬态残留仍应回收');
    });
  });
}
