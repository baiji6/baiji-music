// 音频容器魔数嗅探测试。
//
// QQ 音乐 2 下载扩展名校正依赖本工具：加密直链文件名前缀会在服务端
// 降级时与真实容器错位，落盘后必须按解密出的真实魔数定后缀。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baiji_music/core/audio_format_sniffer.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List head(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('魔数识别', () {
    test('常见容器头', () {
      expect(AudioFormatSniffer.detectExt(head('fLaC\x00\x00\x00\x22')),
          '.flac');
      expect(
          AudioFormatSniffer.detectExt(head('OggS\x00\x02\x00\x00')), '.ogg');
      expect(AudioFormatSniffer.detectExt(head('ID3\x04\x00\x00')), '.mp3');
      expect(
          AudioFormatSniffer.detectExt(head('RIFF\x00\x00\x00\x00WAVE')),
          '.wav');
      // ftyp 在偏移 4
      expect(
          AudioFormatSniffer.detectExt(head('\x00\x00\x00\x18ftypM4A ')),
          '.mp4');
    });

    test('MP3 裸帧与 AAC ADTS', () {
      expect(AudioFormatSniffer.detectExt(Uint8List.fromList([0xFF, 0xFB, 0x90, 0x00])),
          '.mp3');
      expect(AudioFormatSniffer.detectExt(Uint8List.fromList([0xFF, 0xF1, 0x50, 0x80])),
          '.aac');
    });

    test('识别不出返回空串', () {
      expect(AudioFormatSniffer.detectExt(Uint8List(16)), isEmpty);
      expect(AudioFormatSniffer.detectExt(Uint8List(1)), isEmpty);
    });
  });

  group('同容器判定', () {
    test('MP4 家族等价，避免无谓改名', () {
      expect(AudioFormatSniffer.sameContainer('.mp4', '.m4a'), isTrue);
      expect(AudioFormatSniffer.sameContainer('.m4a', '.mp4'), isTrue);
      expect(AudioFormatSniffer.sameContainer('.MP4', '.mp4'), isTrue);
    });
    test('不同容器不等价', () {
      expect(AudioFormatSniffer.sameContainer('.ogg', '.flac'), isFalse);
      expect(AudioFormatSniffer.sameContainer('.mp4', '.ogg'), isFalse);
      expect(AudioFormatSniffer.sameContainer('.flac', '.flac'), isTrue);
    });
  });

  group('文件探测与扩展名校正', () {
    test('detectExtOfFile 读真实文件头', () {
      final dir = Directory.systemTemp.createTempSync('sniff_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}${Platform.pathSeparator}x.bin')
        ..writeAsBytesSync(head('OggS\x00\x02'));
      expect(AudioFormatSniffer.detectExtOfFile(f.path), '.ogg');
      final g = File('${dir.path}${Platform.pathSeparator}empty.bin')
        ..writeAsBytesSync(Uint8List(0));
      expect(AudioFormatSniffer.detectExtOfFile(g.path), isEmpty);
      expect(AudioFormatSniffer.detectExtOfFile('${dir.path}/nope'), isEmpty);
    });

    test('内容是 MP4 却存成 .ogg → 校正为 .mp4（杜比档回归）', () {
      final dir = Directory.systemTemp.createTempSync('fixext_');
      addTearDown(() => dir.deleteSync(recursive: true));
      // ftyp 在偏移 4 的 MP4 内容，被错误命名为 .ogg
      final f = File('${dir.path}${Platform.pathSeparator}song.ogg')
        ..writeAsBytesSync(head('\x00\x00\x00\x18ftypM4A \x00\x00\x00\x00'));
      final fixed = AudioFormatSniffer.correctExtOfFile(f.path);
      expect(fixed, endsWith('.mp4'));
      expect(File(fixed).existsSync(), isTrue);
      expect(f.existsSync(), isFalse, reason: '旧后缀文件应已被改名');
    });

    test('内容是 fLaC 却存成 .ogg → 校正为 .flac', () {
      final dir = Directory.systemTemp.createTempSync('fixext2_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}${Platform.pathSeparator}song.ogg')
        ..writeAsBytesSync(head('fLaC\x00\x00\x00\x22'));
      expect(AudioFormatSniffer.correctExtOfFile(f.path), endsWith('.flac'));
    });

    test('后缀正确或同容器时不改名', () {
      final dir = Directory.systemTemp.createTempSync('fixext3_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = File('${dir.path}${Platform.pathSeparator}a.ogg')
        ..writeAsBytesSync(head('OggS\x00\x02'));
      expect(AudioFormatSniffer.correctExtOfFile(a.path), a.path);
      // m4a 与 mp4 同容器，不来回改
      final b = File('${dir.path}${Platform.pathSeparator}b.m4a')
        ..writeAsBytesSync(head('\x00\x00\x00\x18ftypM4A '));
      expect(AudioFormatSniffer.correctExtOfFile(b.path), b.path);
    });

    test('改名遇重名时加 (1) 去重', () {
      final dir = Directory.systemTemp.createTempSync('fixext4_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}${Platform.pathSeparator}song.ogg')
          .writeAsBytesSync(head('\x00\x00\x00\x18ftypM4A '));
      File('${dir.path}${Platform.pathSeparator}song.mp4')
          .writeAsBytesSync(Uint8List.fromList([1, 2, 3]));
      final fixed = AudioFormatSniffer.correctExtOfFile(
          '${dir.path}${Platform.pathSeparator}song.ogg');
      expect(fixed, endsWith('song (1).mp4'));
      expect(File('${dir.path}${Platform.pathSeparator}song.mp4')
          .readAsBytesSync(), [1, 2, 3]);
    });
  });
}
