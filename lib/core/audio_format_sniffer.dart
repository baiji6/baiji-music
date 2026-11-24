/// 音频容器魔数嗅探：从文件头字节判断真实格式。
///
/// 加密音源（QQ 音乐 2 / 酷我 QMC）经本地中继解密后，落盘扩展名若沿用
/// 「加密直链文件名前缀反查」的结果，会在服务端降级时错位——例如请求
/// 杜比档却返回 `Q0M0.mflac`，被命名成 `.ogg` 而内容其实是 FLAC，播放器
/// 按错误后缀解析即失败。下载落盘后用本工具按真实魔数校正扩展名即可根治。
library;

import 'dart:io';
import 'dart:typed_data';

class AudioFormatSniffer {
  AudioFormatSniffer._();

  /// 需要嗅探的前 N 字节（ftyp 在偏移 4，12 字节足够；MP3 裸帧 2 字节）。
  static const int probeBytes = 16;

  static bool _eq(Uint8List d, int off, String s) {
    for (var i = 0; i < s.length; i++) {
      if (off + i >= d.length || d[off + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// 按文件头返回**带点的扩展名**（如 `.flac` / `.ogg` / `.m4a`）。
  /// 识别不出返回空串（调用方保留原扩展名）。
  static String detectExt(Uint8List head) {
    if (head.length >= 4) {
      if (_eq(head, 0, 'ID3')) return '.mp3';
      if (_eq(head, 0, 'fLaC')) return '.flac';
      if (_eq(head, 0, 'OggS')) return '.ogg';
      if (_eq(head, 0, 'RIFF') && head.length >= 12 && _eq(head, 8, 'WAVE')) {
        return '.wav';
      }
      // ftyp 盒（偏移 4）：M4A / MP4 / M4B 都是 MP4 容器。这里返回 .mp4，
      // 与杜比全景声等用户的预期一致，且所有播放器都能识别。
      if (head.length >= 12 && _eq(head, 4, 'ftyp')) return '.mp4';
    }
    if (head.length >= 2 && head[0] == 0xFF) {
      // ADTS AAC 裸流必须先判：其第 2 字节同样满足 MPEG 裸帧的 111xxxxx，
      // 放后面会被误判成 .mp3。ADTS syncword 为 0xFFF，layer 位恒 00。
      if ((head[1] & 0xF6) == 0xF0) return '.aac';
      // MPEG 裸帧（无 ID3 的 MP3）：0xFF + 111xxxxx
      if ((head[1] & 0xE0) == 0xE0) return '.mp3';
    }
    return '';
  }

  /// 两个扩展名是否表示同一音频容器（无需改名）。
  ///
  /// MP4 家族的 `.mp4` / `.m4a` / `.m4b` 是同一个容器，只是约定后缀不同，
  /// 不该来回改；其余按字面大小写不敏感比较。
  static bool sameContainer(String? a, String? b) {
    final x = (a ?? '').toLowerCase();
    final y = (b ?? '').toLowerCase();
    if (x == y) return true;
    const mp4Family = <String>{'.mp4', '.m4a', '.m4b', '.aac'};
    return mp4Family.contains(x) && mp4Family.contains(y);
  }

  /// 读取文件头 [probeBytes] 字节并返回检测到的扩展名；识别不出返回空串。
  static String detectExtOfFile(String path) {
    final f = File(path);
    if (!f.existsSync()) return '';
    final raf = f.openSync();
    try {
      final head = raf.readSync(probeBytes);
      return detectExt(head);
    } catch (_) {
      return '';
    } finally {
      raf.closeSync();
    }
  }

  /// 按真实魔数校正文件扩展名，返回最终路径。
  ///
  /// 检测不出、或与当前后缀属于同一容器时保持原样；需要改名时做 ` (1)`
  /// 去重，绝不覆盖已有文件。用于加密流下载后修正「内容与后缀不符」。
  static String correctExtOfFile(String path) {
    final detected = detectExtOfFile(path);
    if (detected.isEmpty) return path;
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf(Platform.pathSeparator);
    final oldExt = (dot > slash) ? path.substring(dot) : '';
    if (sameContainer(oldExt, detected)) return path;
    final stem = dot > slash ? path.substring(0, dot) : path;
    var target = '$stem$detected';
    var n = 1;
    while (File(target).existsSync()) {
      target = '$stem ($n)$detected';
      n++;
    }
    try {
      File(path).renameSync(target);
      return target;
    } catch (_) {
      return path;
    }
  }
}
