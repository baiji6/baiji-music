// 下载完整性快检测试：连续 0xFF 坏块检测。
//
// 真实坏样本（唐汉霄 - 就是哪吒.ogg）offset 85 起有 6678 字节连续 FF，
// ffprobe 报 CRC mismatch；正常 Ogg/FLAC 全曲最长连续 FF 仅十几字节。
import 'dart:io';
import 'dart:typed_data';

import 'package:baiji_music/core/audio_integrity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('短 FF 段不算损坏', () async {
    final dir = Directory.systemTemp.createTempSync('integ_ok_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final data = Uint8List(4096 * 2)..fillRange(0, 4096 * 2, 0x11);
    // 模拟 Vorbis lacing：零散 255 相邻，最多十几连
    for (var i = 100; i < 120; i++) {
      data[i] = 0xFF;
    }
    final f = File('${dir.path}${Platform.pathSeparator}a.ogg')
      ..writeAsBytesSync(data);
    expect(await AudioIntegrity.hasCorruptFfRun(f.path), isFalse);
  });

  test('长 FF 段判定为损坏（真实坏样本特征）', () async {
    final dir = Directory.systemTemp.createTempSync('integ_bad_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final data = Uint8List(20000)..fillRange(0, 20000, 0x33);
    // 头部正常 Ogg 魔数 + 中间 6678 字节 FF（复刻坏样本）
    for (var i = 85; i < 85 + 6678; i++) {
      data[i] = 0xFF;
    }
    final f = File('${dir.path}${Platform.pathSeparator}bad.ogg')
      ..writeAsBytesSync(data);
    expect(await AudioIntegrity.hasCorruptFfRun(f.path), isTrue);
  });

  test('阈值边界与不存在文件', () async {
    final dir = Directory.systemTemp.createTempSync('integ_edge_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}${Platform.pathSeparator}edge.bin')
      ..writeAsBytesSync(Uint8List(8192)..fillRange(0, 8192, 0xFF));
    // 8192 连续 FF：默认阈值 4096 命中
    expect(await AudioIntegrity.hasCorruptFfRun(f.path), isTrue);
    // 自定义更高阈值不命中
    expect(
        await AudioIntegrity.hasCorruptFfRun(f.path, threshold: 16384),
        isFalse);
    expect(
        await AudioIntegrity.hasCorruptFfRun('${dir.path}/nope'),
        isFalse);
  });

  test('跨读取块边界的 FF 段仍能识别', () async {
    final dir = Directory.systemTemp.createTempSync('integ_cross_');
    addTearDown(() => dir.deleteSync(recursive: true));
    // 让 FF 段跨越 64KiB 读取块边界
    final data = Uint8List(70 * 1024)..fillRange(0, 70 * 1024, 0x22);
    for (var i = 60 * 1024; i < 60 * 1024 + 5000; i++) {
      data[i] = 0xFF;
    }
    final f = File('${dir.path}${Platform.pathSeparator}cross.bin')
      ..writeAsBytesSync(data);
    expect(await AudioIntegrity.hasCorruptFfRun(f.path), isTrue);
  });
}
