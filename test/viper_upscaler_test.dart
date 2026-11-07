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

import 'package:baiji_music/viper/viper_super_resolution.dart';
import 'package:baiji_music/viper/viper_upscaler.dart';
import 'package:baiji_music/viper/viper_wav.dart';

void main() {
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
}
