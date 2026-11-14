// 解码产物 WAV 缓存：完整性校验 + 原子落盘（v2.5.8-fix1）。
//
// **背景**：DTS:X / 360RA / NAC 三个原生解码器都是「先 fopen(最终 wav,
// "wb")，写 44 字节占位头，边解码边追加 PCM，最后 fseek(0) 回填 RIFF
// 头」。NAC 一次解码要 1~2 分钟，期间最终路径上的文件**已经存在但不可播**
// （开头是 44 字节全 0）。旧版 `hasCachedWav` 只判断 `existsSync()`，于是
// 重复点播直接命中这个半成品，media_kit 报
// `Failed to recognize file format.`；解码若被进程中断（切后台被杀、
// 强退），残文件还会永久留在缓存目录，之后每次点播都失败。
//
// 解决两件事：
// 1. 解码写 `<final>.part`，成功并校验完整性后才原子 rename 到最终路径；
// 2. `hasCachedWav` 校验 RIFF/WAVE/data 与长度一致性，发现残文件直接清理，
//    让下一次点播重新解码而不是继续播坏文件。
library;

import 'dart:io';
import 'dart:typed_data';

import 'app_logger.dart';

abstract final class WavCache {
  /// 标准 PCM WAV 头长度（三个自研解码器都输出这个布局）。
  static const int headerSize = 44;

  /// 校验时最多读取的文件头字节数（足够覆盖 fmt / data chunk）。
  static const int _probeBytes = 4096;

  /// 半成品文件后缀。
  static String partPath(String finalPath) => '$finalPath.part';

  /// 校验 WAV 字节是否完整可播。
  ///
  /// [head] 是文件开头若干字节，[length] 是整个文件长度。判据刻意兼容
  /// WAVE_FORMAT_EXTENSIBLE 等变体：只要求 RIFF/WAVE 魔数、能找到一个
  /// 非空 `data` chunk，且其声明长度与文件实际长度吻合（允许末尾 1~2 字节
  /// 对齐填充）。占位头（全 0）与未写完的 PCM 都会被拒绝。
  static bool isValidBytes(Uint8List head, {required int length}) {
    if (length <= headerSize) return false;
    if (head.length < headerSize) return false;
    if (_tag(head, 0) != 'RIFF' || _tag(head, 8) != 'WAVE') return false;
    final riffSize = _u32(head, 4);
    // 流式写入常以 0xFFFFFFFF 占位；否则至少要能容纳头 + 数据。
    if (riffSize != 0xFFFFFFFF && (riffSize < 36 || riffSize > length)) {
      return false;
    }

    // 从 fmt chunk 之后按 RIFF chunk 布局逐个跳，找 data chunk。
    var off = 12;
    while (off + 8 <= head.length) {
      final tag = _tag(head, off);
      final size = _u32(head, off + 4);
      if (tag == 'data') {
        if (size <= 0) return false;
        final dataStart = off + 8;
        final end = dataStart + size;
        if (end > length) return false; // PCM 还没写完
        if (length - end > 2) return false; // 尾部异常残留
        return true;
      }
      if (size == 0xFFFFFFFF || size > length) return false;
      off += 8 + size;
      if (off < 12) return false;
    }
    return false;
  }

  /// 同步校验磁盘上的 WAV 文件（只读文件头，开销可忽略）。
  static bool isValidFile(File f) {
    try {
      if (!f.existsSync()) return false;
      final len = f.lengthSync();
      if (len <= headerSize) return false;
      final raf = f.openSync(mode: FileMode.read);
      try {
        final n = len < _probeBytes ? len : _probeBytes;
        final bytes = raf.readSync(n);
        return isValidBytes(Uint8List.fromList(bytes), length: len);
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  /// 缓存是否可用；无效文件（半成品 / 残文件）会被删除，返回 false。
  static Future<bool> isValidCache(File f, {String tag = 'WavCache'}) async {
    try {
      if (!await f.exists()) return false;
      if (isValidFile(f)) return true;
      await f.delete();
      AppLog.w(tag, '清理不完整 WAV 缓存: ${f.path}');
    } catch (e) {
      AppLog.w(tag, 'WAV 缓存检查失败: $e');
    }
    return false;
  }

  /// 把解码产物从 `.part` 校验后原子落盘到最终路径。
  ///
  /// 返回 false 时 `.part` 会被清理，调用方应视为解码失败并走降级链。
  static Future<bool> commit(
    String part,
    String finalPath, {
    String tag = 'WavCache',
  }) async {
    final src = File(part);
    try {
      if (!await src.exists()) return false;
      if (!isValidFile(src)) {
        await src.delete();
        AppLog.w(tag, '解码产物 WAV 不完整，丢弃: $part');
        return false;
      }
      final dest = File(finalPath);
      if (await dest.exists()) await dest.delete();
      await src.rename(finalPath);
      return true;
    } catch (e) {
      AppLog.w(tag, 'WAV 原子落盘失败: $e');
      // 个别平台 rename 不允许覆盖已存在文件：退化为复制再删。
      try {
        await src.copy(finalPath);
        await src.delete();
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  static String _tag(Uint8List b, int off) {
    if (off + 4 > b.length) return '';
    return String.fromCharCodes(b.sublist(off, off + 4));
  }

  static int _u32(Uint8List b, int off) {
    if (off + 4 > b.length) return 0;
    return b[off] |
        (b[off + 1] << 8) |
        (b[off + 2] << 16) |
        (b[off + 3] << 24);
  }
}
