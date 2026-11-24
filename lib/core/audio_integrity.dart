/// 下载文件完整性快检（针对 QMC 解密流可能出现的「FF 填充坏块」）。
///
/// 背景：QQ 音乐 2 / 酷我加密流经本地中继解密后，极少数情况下（上游 Range
/// 异常、缓存坏块、下载被截断）落盘文件里会夹杂一段连续的 `0xFF`。这种文件
/// 扩展名、大小、头部魔数都可能正常，但播放器一读到坏段就报 CRC mismatch /
/// 无法解码。正常音频内容里不可能出现上千字节连续 `0xFF`，因此用它做快检。
///
/// 只做「快检」——不追求覆盖所有损坏类型，只在明确坏掉时拦截，避免误杀。
library;

import 'dart:io';
import 'dart:typed_data';

class AudioIntegrity {
  AudioIntegrity._();

  /// 判定为损坏的连续 0xFF 字节数阈值。
  ///
  /// 实测：正常 Ogg/FLAC 全曲最长连续 0xFF 只有十几字节（Vorbis lacing 值
  /// 255 偶尔相邻）；坏样本出现 6678 字节连续 FF。取 4096 留足余量。
  static const int badRunThreshold = 4096;

  /// 流式检测文件里是否存在连续 >= [badRunThreshold] 个 0xFF 字节。
  /// 分块读取，整曲只占常数内存。
  static Future<bool> hasCorruptFfRun(
    String path, {
    int threshold = badRunThreshold,
  }) async {
    final f = File(path);
    if (!f.existsSync()) return false;
    const chunkSize = 64 * 1024;
    var run = 0;
    final raf = f.openSync();
    try {
      final buf = Uint8List(chunkSize);
      while (true) {
        final n = raf.readIntoSync(buf);
        if (n <= 0) break;
        for (var i = 0; i < n; i++) {
          if (buf[i] == 0xFF) {
            run++;
            if (run >= threshold) return true;
          } else {
            run = 0;
          }
        }
      }
    } catch (_) {
      // 读不出来交给后续长度/解析校验，这里不误判为损坏
      return false;
    } finally {
      raf.closeSync();
    }
    return false;
  }
}
