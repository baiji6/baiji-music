// v2.5.8-fix1：解码产物 WAV 缓存完整性校验与原子落盘回归测试。
//
// 复现的线上问题：NAC 原生解码要 1~2 分钟，期间最终 wav 已 fopen 但开头
// 还是 44 字节全 0 占位头；旧 hasCachedWav 只看 existsSync()，于是重复
// 点播命中半成品，media_kit 报 `Failed to recognize file format.`。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:baiji_music/core/wav_cache.dart';

/// 构造一个标准 44 字节头 + [dataBytes] 字节静音 PCM 的 WAV。
Uint8List _wav(int dataBytes, {int declaredDataBytes = -1}) {
  final declared = declaredDataBytes < 0 ? dataBytes : declaredDataBytes;
  final b = Uint8List(44 + dataBytes);
  final bd = ByteData.sublistView(b);
  void tag(int off, String s) {
    for (var i = 0; i < 4; i++) {
      b[off + i] = s.codeUnitAt(i);
    }
  }

  tag(0, 'RIFF');
  bd.setUint32(4, 36 + declared, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little); // PCM
  bd.setUint16(22, 2, Endian.little); // 2ch
  bd.setUint32(24, 44100, Endian.little);
  bd.setUint32(28, 44100 * 2 * 2, Endian.little);
  bd.setUint16(32, 4, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  bd.setUint32(40, declared, Endian.little);
  return b;
}

void main() {
  group('WavCache.isValidBytes', () {
    test('完整的标准 PCM WAV 通过', () {
      final b = _wav(1000);
      expect(WavCache.isValidBytes(b, length: b.length), isTrue);
    });

    test('native 的占位头（44 字节全 0）被拒绝', () {
      // 解码刚开始：native 先写 44 字节全 0，随后追加 PCM。
      final b = Uint8List(44 + 8000); // 全 0
      expect(WavCache.isValidBytes(b, length: b.length), isFalse);
    });

    test('RIFF 头合法但 PCM 未写完（data 声明超出实际长度）被拒绝', () {
      final b = _wav(1000, declaredDataBytes: 90000);
      expect(WavCache.isValidBytes(b, length: b.length), isFalse,
          reason: '解码中途回填过头也会被拒，宁可重新解码');
    });

    test('data size 为 0 / 文件过短被拒绝', () {
      expect(WavCache.isValidBytes(_wav(0), length: 44), isFalse);
      final tiny = Uint8List(10);
      expect(WavCache.isValidBytes(tiny, length: 10), isFalse);
    });

    test('RIFF/WAVE 魔数不符被拒绝', () {
      final b = _wav(1000);
      b[0] = 0x58; // 'X' 破坏 RIFF
      expect(WavCache.isValidBytes(b, length: b.length), isFalse);
    });
  });

  group('WavCache 落盘', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('wav_cache_test_'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('commit 把完整 .part 原子改名为最终 wav', () async {
      final part = '${dir.path}${Platform.pathSeparator}x.wav.part';
      final dest = '${dir.path}${Platform.pathSeparator}x.wav';
      File(part).writeAsBytesSync(_wav(2048));
      expect(await WavCache.commit(part, dest), isTrue);
      expect(File(dest).existsSync(), isTrue);
      expect(File(part).existsSync(), isFalse);
      expect(WavCache.isValidFile(File(dest)), isTrue);
    });

    test('commit 拒绝半成品并清理 .part，最终路径不出现坏文件', () async {
      final part = '${dir.path}${Platform.pathSeparator}x.wav.part';
      final dest = '${dir.path}${Platform.pathSeparator}x.wav';
      File(part).writeAsBytesSync(Uint8List(44 + 4096)); // 全 0 占位头
      expect(await WavCache.commit(part, dest), isFalse);
      expect(File(part).existsSync(), isFalse);
      expect(File(dest).existsSync(), isFalse,
          reason: '最终路径绝不能出现半成品，否则下次缓存命中又会播坏文件');
    });

    test('isValidCache 清掉历史残文件，让它下次重新解码', () async {
      final f = File('${dir.path}${Platform.pathSeparator}old.wav');
      f.writeAsBytesSync(Uint8List(44 + 100)); // 无 RIFF 头
      expect(await WavCache.isValidCache(f), isFalse);
      expect(f.existsSync(), isFalse);
    });

    test('isValidCache 保留完整缓存', () async {
      final f = File('${dir.path}${Platform.pathSeparator}good.wav');
      f.writeAsBytesSync(_wav(1024));
      expect(await WavCache.isValidCache(f), isTrue);
      expect(f.existsSync(), isTrue);
    });
  });
}
