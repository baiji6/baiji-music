import '../lyrics/lyric_model.dart';

/// 歌词序列化：把内存中的 [Lyrics] 还原成可落盘 / 可嵌入标签的 LRC 文本。
///
/// 两种输出模式，对应设置里的「逐行歌词 / 逐字歌词」：
///
/// **逐行**（标准 LRC）
/// ```
/// [00:12.34]窗外的麻雀 在电线杆上多嘴
/// ```
///
/// **逐字**（增强 LRC，行首时间 + 行内每字起始时间）
/// ```
/// [00:12.34]<00:12.34>窗<00:12.56>外<00:12.80>的
/// ```
///
/// 选用增强 LRC 而不是 QRC / YRC：后两者是各家私有格式，
/// 而增强 LRC 是纯文本，既方便嵌入任意容器的歌词标签，
/// 又能被本工程的 [LyricParser] 原样解析回逐字数据。
class LyricSerializer {
  LyricSerializer._();

  /// 写出逐行 LRC。
  static String toLineLrc(Lyrics lyrics) {
    final sb = StringBuffer();
    for (final line in lyrics.lines) {
      final text = line.displayText.trim();
      if (text.isEmpty) continue;
      sb.writeln('${_tag(line.startMs)}$text');
    }
    return sb.toString();
  }

  /// 写出逐字 LRC；没有逐字数据的行自动退化为整行输出。
  static String toWordLrc(Lyrics lyrics) {
    final sb = StringBuffer();
    for (final line in lyrics.lines) {
      if (line.isWordLevel) {
        final body = StringBuffer();
        for (final w in line.words) {
          if (w.text.isEmpty) continue;
          body.write('<${_clock(w.startMs)}>${w.text}');
        }
        if (body.isNotEmpty) {
          sb.writeln('${_tag(line.startMs)}$body');
          continue;
        }
      }
      final text = line.displayText.trim();
      if (text.isEmpty) continue;
      sb.writeln('${_tag(line.startMs)}$text');
    }
    return sb.toString();
  }

  /// 按模式写出。
  static String toLrc(Lyrics lyrics, {required bool wordLevel}) =>
      wordLevel ? toWordLrc(lyrics) : toLineLrc(lyrics);

  /// `[mm:ss.xx]`，xx 为百分秒（与 [LyricParser] 的输入格式一致）。
  static String _tag(int ms) {
    final clamped = ms < 0 ? 0 : ms;
    final m = clamped ~/ 60000;
    final s = (clamped % 60000) ~/ 1000;
    final cs = (clamped % 1000) ~/ 10;
    return '[${_pad2(m)}:${_pad2(s)}.${_pad2(cs)}]';
  }

  /// `<mm:ss.xx>`：行内逐字时间戳。
  static String _clock(int ms) {
    final clamped = ms < 0 ? 0 : ms;
    final m = clamped ~/ 60000;
    final s = (clamped % 60000) ~/ 1000;
    final cs = (clamped % 1000) ~/ 10;
    return '${_pad2(m)}:${_pad2(s)}.${_pad2(cs)}';
  }

  static String _pad2(int v) => v.toString().padLeft(2, '0');
}
