// 音频转码核心回归测试（离线，纯逻辑 + 可注入的假 ffmpeg）。
//
// 覆盖 v2.4.7 新增的转码服务层：参数校验、特殊格式嗅探、wavOnly 锁定、
// ffmpeg 参数构造、输出路径去重、ffmpeg 路径探测优先级。
// 真实 ffmpeg 端到端转码在沙箱单独验证（CI runner 不保证装了完整 ffmpeg，
// 因此不把它放进会跑在 CI 里的单元测试，避免 flaky）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baiji_music/core/audio_transcoder.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _args(TranscodeOptions options) => buildFfmpegArgs(
      inputPath: '/in/song.flac',
      outputPath: '/out/song.${options.format.extension}',
      options: options,
    );

void main() {
  group('TranscodeFormat', () {
    test('扩展名反查覆盖所有输出格式（含 mp4 / ac3 / eac3）', () {
      for (final f in TranscodeFormat.values) {
        expect(TranscodeFormat.fromExtension(f.extension), f);
        expect(TranscodeFormat.fromExtension('.${f.extension}'), f);
      }
      expect(TranscodeFormat.fromExtension('MP4'), TranscodeFormat.mp4);
      expect(TranscodeFormat.fromExtension('bin'), isNull);
    });

    test('位深 / 无损 / AC-3 家族语义', () {
      expect(TranscodeFormat.wav.supportsBitDepth, isTrue);
      expect(TranscodeFormat.flac.supportsBitDepth, isTrue);
      expect(TranscodeFormat.mp3.supportsBitDepth, isFalse);
      expect(TranscodeFormat.wav.isLossless, isTrue);
      expect(TranscodeFormat.flac.isLossless, isTrue);
      expect(TranscodeFormat.mp4.isLossless, isFalse);
      expect(TranscodeFormat.ac3.isAc3Family, isTrue);
      expect(TranscodeFormat.eac3.isAc3Family, isTrue);
      expect(TranscodeFormat.aac.isAc3Family, isFalse);
    });
  });

  group('TranscodeOptions.validate', () {
    test('默认参数合法', () {
      expect(const TranscodeOptions().validate(), isNull);
    });

    test('声道数越界报错，0 表示保持源', () {
      expect(const TranscodeOptions(channels: 9).validate(), isNotNull);
      expect(const TranscodeOptions(channels: -1).validate(), isNotNull);
      expect(const TranscodeOptions(channels: 8).validate(), isNull);
    });

    test('采样率越界报错', () {
      expect(const TranscodeOptions(sampleRate: 4000).validate(), isNotNull);
      expect(const TranscodeOptions(sampleRate: 400000).validate(), isNotNull);
      expect(const TranscodeOptions(sampleRate: 384000).validate(), isNull);
    });

    test('位深只对 WAV / FLAC 校验', () {
      expect(
        const TranscodeOptions(format: TranscodeFormat.wav, bitDepth: 20)
            .validate(),
        isNotNull,
      );
      expect(
        const TranscodeOptions(format: TranscodeFormat.mp3, bitDepth: 20)
            .validate(),
        isNull,
      );
    });

    test('码率越界报错', () {
      expect(const TranscodeOptions(bitrateKbps: 16).validate(), isNotNull);
      expect(const TranscodeOptions(bitrateKbps: 2000).validate(), isNotNull);
      expect(const TranscodeOptions(bitrateKbps: 320).validate(), isNull);
    });

    test('copyWith 只覆盖传入字段', () {
      const o = TranscodeOptions(
          format: TranscodeFormat.flac, channels: 2, sampleRate: 96000);
      final c = o.copyWith(format: TranscodeFormat.mp3);
      expect(c.format, TranscodeFormat.mp3);
      expect(c.channels, 2);
      expect(c.sampleRate, 96000);
    });
  });

  group('detectSpecialFormat（特殊音质识别）', () {
    test('独立扩展名直接命中', () {
      expect(detectSpecialFormat('/x/a.nac'), SpecialFormat.nac);
      expect(detectSpecialFormat('/x/a.ac3'), SpecialFormat.ac3);
      expect(detectSpecialFormat('/x/a.eac3'), SpecialFormat.eac3);
      expect(detectSpecialFormat('/x/a.ec3'), SpecialFormat.eac3);
      expect(detectSpecialFormat('/x/a.av3a'), SpecialFormat.av3a);
      expect(detectSpecialFormat('/x/a.mha1'), SpecialFormat.ra360);
      expect(detectSpecialFormat('/x/a.mhm1'), SpecialFormat.ra360);
      expect(detectSpecialFormat('/x/a.dtsx'), SpecialFormat.dts);
    });

    test('MP4 靠 fourcc 细分音质', () {
      List<int> mp4Head(String cc) => utf8.encode('____ftyp____${cc}____');
      expect(
        detectSpecialFormat('/x/a.mp4', head: mp4Head('dtsx')),
        SpecialFormat.dts,
      );
      expect(
        detectSpecialFormat('/x/a.mp4', head: mp4Head('mha1')),
        SpecialFormat.ra360,
      );
      expect(
        detectSpecialFormat('/x/a.mp4', head: mp4Head('mhm1')),
        SpecialFormat.ra360,
      );
      expect(
        detectSpecialFormat('/x/a.mp4', head: mp4Head('av3a')),
        SpecialFormat.av3a,
      );
      expect(
        detectSpecialFormat('/x/a.mp4', head: mp4Head('ac-3')),
        SpecialFormat.ac3,
      );
      expect(
        detectSpecialFormat('/x/a.mp4', head: mp4Head('ec-3')),
        SpecialFormat.eac3,
      );
    });

    test('MP4 文件名带音质标记也能识别', () {
      expect(
        detectSpecialFormat('/x/xxx_dt03_xxx.mp4'),
        SpecialFormat.dts,
      );
      expect(
        detectSpecialFormat('/x/xxx_ra01_xxx.m4a'),
        SpecialFormat.ra360,
      );
      expect(
        detectSpecialFormat('/x/xxx_av3a_xxx.mp4'),
        SpecialFormat.av3a,
      );
    });

    test('无 fourcc 的 MP4 归为普通 mp4，且不是 wavOnly', () {
      final sp = detectSpecialFormat('/x/a.mp4', head: utf8.encode('____ftypisom'));
      expect(sp, SpecialFormat.mp4);
      expect(sp!.wavOnly, isFalse);
    });

    test('裸流同步字识别 DTS / AC-3', () {
      expect(
        detectSpecialFormat('/x/raw.bin',
            head: const [0x7F, 0xFE, 0x80, 0x01, 0x00]),
        SpecialFormat.dts,
      );
      expect(
        detectSpecialFormat('/x/raw.bin', head: const [0x0B, 0x77, 0x01, 0x00]),
        SpecialFormat.ac3,
      );
    });

    test('普通音频不误判', () {
      expect(detectSpecialFormat('/x/a.mp3'), isNull);
      expect(detectSpecialFormat('/x/a.flac'), isNull);
      expect(detectSpecialFormat('/x/a.wav'), isNull);
    });

    test('wavOnly 恰好是 DTS / 360RA / NAC / AV3A 四种', () {
      expect(SpecialFormat.wavOnlyFormats.length, 4);
      expect(
        SpecialFormat.wavOnlyFormats,
        containsAll(<SpecialFormat>[
          SpecialFormat.dts,
          SpecialFormat.ra360,
          SpecialFormat.nac,
          SpecialFormat.av3a,
        ]),
      );
    });
  });

  group('effectiveOptions（wavOnly 锁定 WAV）', () {
    test('DTS / 360RA / NAC / AV3A 强制 WAV', () {
      for (final path in ['/x/a.nac', '/x/a.dtsx', '/x/a.mha1', '/x/a.av3a']) {
        final e = effectiveOptions(
            path, const TranscodeOptions(format: TranscodeFormat.mp3));
        expect(e.format, TranscodeFormat.wav, reason: path);
      }
    });

    test('已选 WAV 时保持其它参数不变', () {
      final e = effectiveOptions(
        '/x/a.nac',
        const TranscodeOptions(
          format: TranscodeFormat.wav,
          channels: 2,
          sampleRate: 48000,
        ),
      );
      expect(e.channels, 2);
      expect(e.sampleRate, 48000);
    });

    test('mp4 / ac3 / eac3 / 普通格式不锁定', () {
      expect(
        effectiveOptions('/x/a.mp4',
                const TranscodeOptions(format: TranscodeFormat.ogg))
            .format,
        TranscodeFormat.ogg,
      );
      expect(
        effectiveOptions('/x/a.ac3',
                const TranscodeOptions(format: TranscodeFormat.flac))
            .format,
        TranscodeFormat.flac,
      );
      expect(
        effectiveOptions('/x/a.mp3',
                const TranscodeOptions(format: TranscodeFormat.mp3))
            .format,
        TranscodeFormat.mp3,
      );
    });
  });

  group('buildFfmpegArgs', () {
    test('基础链路：输入 / 丢视频 / 只取第一条音轨 / 进度 / 输出', () {
      final a = _args(const TranscodeOptions());
      expect(a, containsAllInOrder(<String>['-i', '/in/song.flac']));
      expect(a, containsAllInOrder(<String>['-vn', '-map', '0:a:0']));
      expect(a, containsAllInOrder(<String>['-c:a', 'pcm_s16le']));
      expect(a, containsAllInOrder(<String>['-f', 'wav']));
      expect(a, containsAllInOrder(<String>['-progress', 'pipe:1']));
      expect(a, contains('-nostdin'));
      expect(a, contains('-nostats'));
      expect(a.last, '/out/song.wav');
    });

    test('WAV 位深映射 16 / 24 / 32', () {
      expect(
        _args(const TranscodeOptions(bitDepth: 16)),
        containsAllInOrder(<String>['-c:a', 'pcm_s16le']),
      );
      expect(
        _args(const TranscodeOptions(bitDepth: 24)),
        containsAllInOrder(<String>['-c:a', 'pcm_s24le']),
      );
      expect(
        _args(const TranscodeOptions(bitDepth: 32)),
        containsAllInOrder(<String>['-c:a', 'pcm_s32le']),
      );
    });

    test('FLAC 24bit 用 s32 + 有效位深标注', () {
      final a = _args(const TranscodeOptions(
          format: TranscodeFormat.flac, bitDepth: 24));
      expect(a, containsAllInOrder(<String>['-c:a', 'flac']));
      expect(a, containsAllInOrder(<String>['-sample_fmt', 's32']));
      expect(a, containsAllInOrder(<String>['-bits_per_raw_sample', '24']));
    });

    test('自定义声道数 / 采样率', () {
      final a = _args(const TranscodeOptions(channels: 6, sampleRate: 48000));
      expect(a, containsAllInOrder(<String>['-ac', '6']));
      expect(a, containsAllInOrder(<String>['-ar', '48000']));
    });

    test('有损格式码率；无损格式忽略码率', () {
      expect(
        _args(const TranscodeOptions(
            format: TranscodeFormat.mp3, bitrateKbps: 320)),
        containsAllInOrder(<String>['-b:a', '320k']),
      );
      final lossless = _args(const TranscodeOptions(
          format: TranscodeFormat.flac, bitrateKbps: 320));
      expect(lossless, isNot(contains('-b:a')));
    });

    test('mp4 / ac3 / eac3 输出走对应 muxer 与编码器', () {
      const cases = <TranscodeFormat, List<String>>{
        TranscodeFormat.mp4: ['-c:a', 'aac', '-f', 'mp4'],
        TranscodeFormat.ac3: ['-c:a', 'ac3', '-f', 'ac3'],
        TranscodeFormat.eac3: ['-c:a', 'eac3', '-f', 'eac3'],
      };
      cases.forEach((fmt, expected) {
        expect(_args(TranscodeOptions(format: fmt)),
            containsAllInOrder(expected), reason: fmt.name);
        expect(_args(TranscodeOptions(format: fmt)).last,
            '/out/song.${fmt.extension}');
      });
    });

    test('所有格式都显式指定容器（避免扩展名推断漂移）', () {
      for (final f in TranscodeFormat.values) {
        final a = _args(TranscodeOptions(format: f));
        expect(a.contains('-f'), isTrue, reason: f.name);
        expect(a[a.indexOf('-f') + 1].isNotEmpty, isTrue);
      }
    });
  });

  group('resolveOutputPath（同名不覆盖）', () {
    test('同名追加 (2)/(3)', () async {
      final dir = await Directory.systemTemp.createTemp('baiji_transcode_test_');
      try {
        final sep = Platform.pathSeparator;
        File('${dir.path}${sep}song.wav').writeAsStringSync('x');
        final p2 = resolveOutputPath(
            '/in/song.flac', dir.path, TranscodeFormat.wav);
        expect(p2, endsWith('song(2).wav'));
        File(p2).writeAsStringSync('x');
        final p3 = resolveOutputPath(
            '/in/song.flac', dir.path, TranscodeFormat.wav);
        expect(p3, endsWith('song(3).wav'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('无同名时直接用原名', () async {
      final dir = await Directory.systemTemp.createTemp('baiji_transcode_test_');
      try {
        final p = resolveOutputPath(
            '/in/song.flac', dir.path, TranscodeFormat.mp3);
        expect(p, endsWith('song.mp3'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('TranscodeProgress / TranscodeResult', () {
    test('百分比按总时长计算并夹到 1.0', () {
      expect(const TranscodeProgress(processedMs: 500, totalMs: 1000).percent,
          0.5);
      expect(const TranscodeProgress(processedMs: 2000, totalMs: 1000).percent,
          1.0);
      expect(const TranscodeProgress(processedMs: 100).percent, isNull);
      expect(const TranscodeProgress(processedMs: 100, totalMs: 0).percent,
          isNull);
    });

    test('结果对象字段', () {
      const ok = TranscodeResult.success('/out/a.wav');
      expect(ok.ok, isTrue);
      expect(ok.outputPath, '/out/a.wav');
      expect(ok.error, isNull);
      const bad = TranscodeResult.failure('boom');
      expect(bad.ok, isFalse);
      expect(bad.outputPath, isNull);
      expect(bad.error, 'boom');
    });
  });

  group('FfmpegLocator（路径探测优先级）', () {
    test('手动指定路径优先命中，不再查 PATH', () async {
      final loc = FfmpegLocator(
        overridePath: '/opt/ffmpeg',
        environment: <String, String>{},
        fileExists: (p) => p == '/opt/ffmpeg',
        pathProbe: () async => '/usr/bin/ffmpeg',
      );
      expect(await loc.resolve(), '/opt/ffmpeg');
    });

    test('环境变量 BAIJI_FFMPEG 会被 trim', () async {
      final loc = FfmpegLocator(
        environment: <String, String>{'BAIJI_FFMPEG': '  /env/ffmpeg  '},
        fileExists: (p) => p == '/env/ffmpeg',
        pathProbe: () async => null,
      );
      expect(await loc.resolve(), '/env/ffmpeg');
    });

    test('手动路径不存在时明确返回 null（不静默回退）', () async {
      final loc = FfmpegLocator(
        overridePath: '/bad/ffmpeg',
        environment: <String, String>{},
        fileExists: (p) => false,
        pathProbe: () async => '/usr/bin/ffmpeg',
      );
      expect(await loc.resolve(), isNull);
    });

    test('随包内置目录命中', () async {
      final candidates = FfmpegLocator.bundledCandidates();
      final loc = FfmpegLocator(
        environment: <String, String>{},
        fileExists: (p) => candidates.contains(p),
        pathProbe: () async => null,
      );
      expect(await loc.resolve(), candidates.first);
    });

    test('全部未命中时回退 PATH 探测', () async {
      final loc = FfmpegLocator(
        environment: <String, String>{},
        fileExists: (p) => false,
        pathProbe: () async => '/usr/local/bin/ffmpeg',
      );
      expect(await loc.resolve(), '/usr/local/bin/ffmpeg');
    });

    test('PATH 也没有时返回 null', () async {
      final loc = FfmpegLocator(
        environment: <String, String>{},
        fileExists: (p) => false,
        pathProbe: () async => null,
      );
      expect(await loc.resolve(), isNull);
    });
  });

  test('输入扩展名白名单覆盖特殊格式与常见容器', () {
    expect(
      kSupportedInputExtensions,
      containsAll(<String>[
        'mp4', 'ac3', 'eac3', 'ec3', 'av3a', 'nac', 'dts', 'dtsx',
        'mha1', 'mhm1', 'flac', 'wav', 'mp3', 'ogg', 'm4a',
      ]),
    );
  });

  // v2.4.8：Android 随包内置 ffmpeg 引擎 + 特殊格式解绑硬依赖。
  group('内置引擎探测与 ffmpeg 解绑', () {
    test('extraCandidates（Android nativeLibraryDir）优先于随包 bin 与 PATH',
        () async {
      const bundled = '/data/app/lib/arm64/libffmpeg_exec.so';
      final loc = FfmpegLocator(
        extraCandidates: const [bundled],
        environment: <String, String>{},
        fileExists: (p) => p == bundled,
        pathProbe: () async => '/usr/bin/ffmpeg',
      );
      expect(await loc.resolve(), bundled);
    });

    test('内置引擎不存在时继续回退 PATH', () async {
      final loc = FfmpegLocator(
        extraCandidates: const ['/missing/libffmpeg_exec.so'],
        environment: <String, String>{},
        fileExists: (p) => false,
        pathProbe: () async => '/usr/bin/ffmpeg',
      );
      expect(await loc.resolve(), '/usr/bin/ffmpeg');
    });

    test('手动指定仍优先于内置引擎', () async {
      final loc = FfmpegLocator(
        overridePath: '/manual/ffmpeg',
        extraCandidates: const ['/bundled/libffmpeg_exec.so'],
        environment: <String, String>{},
        fileExists: (p) => true,
        pathProbe: () async => null,
      );
      expect(await loc.resolve(), '/manual/ffmpeg');
    });

    test('无 ffmpeg 时特殊格式直出 WAV 仍成功', () async {
      final dir = await Directory.systemTemp.createTemp('baiji_nullff_');
      try {
        final input = File('${dir.path}${Platform.pathSeparator}song.nac');
        await input.writeAsBytes(const [1, 2, 3, 4]);
        var called = false;
        final tc = AudioTranscoder(
          ffmpegPath: null,
          specialDecoder: (fmt, src, target) async {
            called = true;
            expect(fmt, SpecialFormat.nac);
            await File(target).writeAsBytes(const [0, 0]);
            return target;
          },
        );
        final res = await tc.transcode(
          inputPath: input.path,
          outputDir: '${dir.path}${Platform.pathSeparator}out',
          // wavOnly 源会把非 WAV 请求自动锁定为 WAV
          options: const TranscodeOptions(
            format: TranscodeFormat.mp3,
            channels: 0,
            sampleRate: 0,
            bitDepth: 16,
            bitrateKbps: 0,
          ),
        );
        expect(called, isTrue);
        expect(res.ok, isTrue, reason: res.error);
        expect(res.outputPath, endsWith('.wav'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    /// 构造标准 44.1k/16bit/2ch s16 PCM WAV（非静音），模拟三个自研解码器
    /// `decodeLocalToWav` 的产物规格。不依赖 ffprobe，CI runner 也能跑。
    List<int> pcmWav() {
      const rate = 44100;
      const ch = 2;
      const frames = 4410; // 0.1s，足够覆盖头部与 PCM 判定
      final dataLen = frames * ch * 2;
      final b = <int>[];
      void u32(int v) => b.addAll(
          [v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
      void u16(int v) => b.addAll([v & 255, (v >> 8) & 255]);
      b.addAll('RIFF'.codeUnits);
      u32(36 + dataLen);
      b.addAll('WAVE'.codeUnits);
      b.addAll('fmt '.codeUnits);
      u32(16);
      u16(1); // PCM
      u16(ch);
      u32(rate);
      u32(rate * ch * 2);
      u16(ch * 2);
      u16(16);
      b.addAll('data'.codeUnits);
      u32(dataLen);
      for (var i = 0; i < frames * ch; i++) {
        b.addAll(const [0x00, 0x40]); // 非零样本 → 非静音
      }
      return b;
    }

    for (final c in <(String, SpecialFormat)>[
      ('track.dtshd', SpecialFormat.dts),
      ('track.mha1', SpecialFormat.ra360),
      ('track.nac', SpecialFormat.nac),
    ]) {
      test('解绑后 ${c.$1} 无 ffmpeg 直出标准 PCM WAV（可播放）', () async {
        final dir = await Directory.systemTemp.createTemp('baiji_wav_');
        try {
          final input = File('${dir.path}${Platform.pathSeparator}${c.$1}');
          await input.writeAsBytes(const [1, 2, 3, 4]);
          var calls = 0;
          SpecialFormat? got;
          final tc = AudioTranscoder(
            ffmpegPath: null,
            specialDecoder: (fmt, src, target) async {
              calls++;
              got = fmt;
              await File(target).writeAsBytes(pcmWav());
              return target;
            },
          );
          final res = await tc.transcode(
            inputPath: input.path,
            outputDir: '${dir.path}${Platform.pathSeparator}out',
            options: const TranscodeOptions(format: TranscodeFormat.flac),
          );
          expect(calls, 1, reason: '应只调用一次自研解码器，不触碰 ffmpeg');
          expect(got, c.$2);
          expect(res.ok, isTrue, reason: res.error);
          expect(res.outputPath, endsWith('.wav'),
              reason: 'wavOnly 应把非 WAV 请求锁定回 WAV');
          final bytes = await File(res.outputPath!).readAsBytes();
          expect(bytes.length, greaterThan(44));
          expect(String.fromCharCodes(bytes, 0, 4), 'RIFF');
          expect(String.fromCharCodes(bytes, 8, 12), 'WAVE');
          expect(String.fromCharCodes(bytes, 12, 16), 'fmt ');
          // fmt chunk：audio_format=1(PCM)、channels=2、rate=44100、bits=16
          final rd = ByteData.sublistView(Uint8List.fromList(bytes));
          expect(rd.getUint16(20, Endian.little), 1);
          expect(rd.getUint16(22, Endian.little), 2);
          expect(rd.getUint32(24, Endian.little), 44100);
          expect(rd.getUint16(34, Endian.little), 16);
          expect(String.fromCharCodes(bytes, 36, 40), 'data');
          expect(bytes.sublist(44).any((v) => v != 0), isTrue,
              reason: 'PCM 数据全零即静音，不算可播放');
        } finally {
          dir.deleteSync(recursive: true);
        }
      });
    }

    test('自研解码器返回 null（真机不可用）时给出精确错误而非假成功', () async {
      final dir = await Directory.systemTemp.createTemp('baiji_nullff_');
      try {
        final input = File('${dir.path}${Platform.pathSeparator}song.nac');
        await input.writeAsBytes(const [1, 2, 3, 4]);
        final tc = AudioTranscoder(
          ffmpegPath: null,
          specialDecoder: (fmt, src, target) async => null,
        );
        final res = await tc.transcode(
          inputPath: input.path,
          outputDir: '${dir.path}${Platform.pathSeparator}out',
          options: const TranscodeOptions(),
        );
        expect(res.ok, isFalse);
        expect(res.error, contains('内置解码器不可用'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('无 ffmpeg 且要求自定义采样率时明确报错，不白解码一遍', () async {
      final dir = await Directory.systemTemp.createTemp('baiji_nullff_');
      try {
        final input = File('${dir.path}${Platform.pathSeparator}song.nac');
        await input.writeAsBytes(const [1, 2, 3, 4]);
        var called = false;
        final tc = AudioTranscoder(
          ffmpegPath: null,
          specialDecoder: (fmt, src, target) async {
            called = true;
            return target;
          },
        );
        final res = await tc.transcode(
          inputPath: input.path,
          outputDir: '${dir.path}${Platform.pathSeparator}out',
          options: const TranscodeOptions(
            format: TranscodeFormat.wav,
            channels: 0,
            sampleRate: 48000,
            bitDepth: 16,
            bitrateKbps: 0,
          ),
        );
        expect(called, isFalse);
        expect(res.ok, isFalse);
        expect(res.error, contains('自定义声道'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('无 ffmpeg 时普通格式返回可操作错误而不是抛异常', () async {
      final dir = await Directory.systemTemp.createTemp('baiji_nullff_');
      try {
        final input = File('${dir.path}${Platform.pathSeparator}song.flac');
        await input.writeAsBytes(const [1, 2, 3, 4]);
        final tc = AudioTranscoder(ffmpegPath: null);
        final res = await tc.transcode(
          inputPath: input.path,
          outputDir: '${dir.path}${Platform.pathSeparator}out',
          options: const TranscodeOptions(
            format: TranscodeFormat.mp3,
            channels: 0,
            sampleRate: 0,
            bitDepth: 16,
            bitrateKbps: 128,
          ),
        );
        expect(res.ok, isFalse);
        expect(res.error, contains('没有可用的 ffmpeg'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
