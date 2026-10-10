import 'dart:typed_data';

import 'package:baiji_music/decrypt/audio_detect.dart';
import 'package:flutter_test/flutter_test.dart';

/// 音频格式探测，行为对齐 um-react `util/audioType.ts`。
///
/// 这层校验是解密流程的**最后一道闸**：密钥错、偏移错都会产出随机字节，
/// 探测不出来才能报错，否则用户拿到的是"能播放的噪声"。
void main() {
  Uint8List b(List<int> v) => Uint8List.fromList(v);

  group('detectAudioFormat', () {
    test('ID3 → mp3，且 needMore != 0（合法头部标志）', () {
      final r = detectAudioFormat(b([0x49, 0x44, 0x33, 0x03, 0x00, 0x00]));
      expect(r.extension, 'mp3');
      expect(r.needMore, isNot(0));
    });

    test('fLaC → flac', () {
      expect(detectAudioFormat(b('fLaC'.codeUnits)).extension, 'flac');
    });

    test('ftyp isom → m4a', () {
      final data = b([
        0x00, 0x00, 0x00, 0x20, //
        0x66, 0x74, 0x79, 0x70, // ftyp
        0x69, 0x73, 0x6F, 0x6D, // isom
      ]);
      expect(detectAudioFormat(data).extension, 'm4a');
    });

    test('ftyp mp42 → m4a', () {
      final data = b([
        0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, //
        0x6D, 0x70, 0x34, 0x32, // mp42
      ]);
      expect(detectAudioFormat(data).extension, 'm4a');
    });

    test('OggS → ogg', () {
      expect(detectAudioFormat(b('OggS'.codeUnits)).extension, 'ogg');
    });

    test('RIFF....WAVE → wav', () {
      final data = b([
        0x52, 0x49, 0x46, 0x46, // RIFF
        0x24, 0x08, 0x00, 0x00, // size
        0x57, 0x41, 0x56, 0x45, // WAVE
      ]);
      expect(detectAudioFormat(data).extension, 'wav');
    });

    test('ASF GUID → wma', () {
      final data = b([
        0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, //
        0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
      ]);
      expect(detectAudioFormat(data).extension, 'wma');
    });

    test('FRM8....DSD → dff', () {
      final data = b([
        0x46, 0x52, 0x4D, 0x38, // FRM8
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
        0x44, 0x53, 0x44, 0x20, // DSD
      ]);
      expect(detectAudioFormat(data).extension, 'dff');
    });

    test('裸 mp3 帧同步字 → mp3', () {
      // 0xFF 0xFB： MPEG1 Layer3
      expect(detectAudioFormat(b([0xFF, 0xFB, 0x90, 0x00])).extension, 'mp3');
    });

    test('随机字节 → bin（会被校验拦下）', () {
      final noise = Uint8List.fromList(
          List<int>.generate(64, (i) => (i * 37 + 11) & 0xFF));
      expect(detectAudioFormat(noise).extension, 'bin');
    });

    test('全零 → bin', () {
      expect(detectAudioFormat(Uint8List(64)).extension, 'bin');
    });

    test('空数据 → bin', () {
      expect(detectAudioFormat(Uint8List(0)).extension, 'bin');
    });

    test('认不出时 needMore 恒为 0（否则会被当成合法头部）', () {
      // needMore 非 0 的唯一含义是"头部已确认合法"（ID3）。
      // 未识别格式若也返回非 0，任何随机字节都会被 isDataLooksLikeAudio
      // 判成音频，解密校验就白做了。
      final r = detectAudioFormat(b([0x01, 0x02, 0x03]));
      expect(r.extension, 'bin');
      expect(r.needMore, 0);
    });

    test('ID3 是唯一 needMore 非 0 的情形', () {
      expect(detectAudioFormat(b('ID3'.codeUnits)).needMore, isNot(0));
      for (final sig in ['fLaC', 'OggS']) {
        expect(detectAudioFormat(sig.codeUnits).needMore, 0);
      }
    });
  });

  group('isDataLooksLikeAudio', () {
    test('少于 0x20 字节一律 false', () {
      expect(isDataLooksLikeAudio(Uint8List(8)), isFalse);
      expect(isDataLooksLikeAudio(Uint8List(0)), isFalse);
    });

    test('ID3 头部 → true', () {
      final data = Uint8List(0x40);
      data[0] = 0x49;
      data[1] = 0x44;
      data[2] = 0x33;
      expect(isDataLooksLikeAudio(data), isTrue);
    });

    test('fLaC → true', () {
      final data = Uint8List(0x40);
      data.setRange(0, 4, 'fLaC'.codeUnits);
      expect(isDataLooksLikeAudio(data), isTrue);
    });

    test('随机噪声 → false', () {
      // 刻意避开 0xFF：随机字节里只要凑巧出现 0xFF Ex 就会被判成 mp3 帧头，
      // 那种"运气"不是我们要测的东西。这里要验证的是**解密失败产出的
      // 那种连续噪声**会被拦下。
      final noise = Uint8List.fromList(
          List<int>.generate(0x40, (i) => (i * 91 + 7) & 0x7F));
      expect(isDataLooksLikeAudio(noise), isFalse);
    });

    test('解密失败产出的高熵噪声 → false', () {
      // 模拟真实场景：错误密钥解出来的就是均匀分布的随机字节。
      // 用固定 LCG 生成，保证可复现。
      var seed = 0x2A2A2A2A;
      final noise = Uint8List.fromList(List<int>.generate(0x100, (i) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        return (seed >> 16) & 0xFF;
      }));
      // 前提：这串噪声确实不含任何已知格式的签名
      expect(detectAudioFormat(noise).extension, 'bin');
      expect(isDataLooksLikeAudio(noise), isFalse);
    });
  });

  group('mimeType', () {
    test('已知格式返回对应 MIME', () {
      expect(const AudioFormat('mp3').mimeType, 'audio/mpeg');
      expect(const AudioFormat('flac').mimeType, 'audio/flac');
      expect(const AudioFormat('m4a').mimeType, 'audio/mp4');
    });

    test('未知格式回落 octet-stream', () {
      expect(const AudioFormat('bin').mimeType, 'application/octet-stream');
    });
  });
}