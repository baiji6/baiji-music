/// 歌词数据模型。
///
/// 统一抽象普通 LRC、增强 LRC（逐字）、QRC（逐字）与 TTML 四种格式，
/// 使 UI 只需面向 [Lyrics] 渲染，无需关心来源格式。
library;

/// 一个"字"（可以是单词、汉字或音节），带自身起止时间，用于逐字高亮。
class LyricWord {
  /// 起始时间（毫秒，相对整首歌起点）。
  final int startMs;

  /// 结束时间（毫秒）。
  final int endMs;

  /// 文本内容。可能为空——QRC 罗马音里存在只有时间片、没有文本的占位项。
  final String text;

  const LyricWord({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  /// 该字是否已唱过（用于逐字染色）。
  bool isHighlightedAt(int positionMs) => positionMs >= startMs;

  /// 该字当前所处的演唱进度 0~1（用于逐字渐变填充）。
  double progressAt(int positionMs) {
    if (positionMs <= startMs) return 0.0;
    if (positionMs >= endMs) return 1.0;
    final span = endMs - startMs;
    if (span <= 0) return 1.0;
    return (positionMs - startMs) / span;
  }

  @override
  String toString() => 'LyricWord($startMs-$endMs, "$text")';
}

/// 一行歌词。
class LyricLine {
  /// 行起始时间（毫秒）。
  final int startMs;

  /// 行结束时间（毫秒）。
  final int endMs;

  /// 逐字数据。为空表示该行只有整行时间（普通 LRC）。
  final List<LyricWord> words;

  /// 整行文本（可能已经过 HTML 实体/XML 反转义）。
  final String text;

  /// 译文（翻译），可能为空。
  final String? translation;

  /// 罗马音/拼音，可能为空。
  final String? romanization;

  const LyricLine({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.words = const [],
    this.translation,
    this.romanization,
  });

  /// 是否支持逐字（有逐字时间轴）。
  bool get isWordLevel => words.length > 1;

  /// 用于歌词指示器/搜索展示的纯文本。
  String get displayText =>
      words.isNotEmpty ? words.map((w) => w.text).join() : text;

  /// 该行是否正在演唱（用于高亮与自动滚动）。
  bool isActiveAt(int positionMs) => positionMs >= startMs && positionMs < endMs;

  @override
  String toString() =>
      'LyricLine($startMs-$endMs, "${text.length > 16 ? '${text.substring(0, 16)}…' : text}")';
}

/// 整份歌词（已按时间升序、行时间已对齐）。
class Lyrics {
  final List<LyricLine> lines;

  /// 是否存在逐字时间轴——决定 UI 是否启用卡拉 OK 式染色。
  final bool hasWordTiming;

  /// 是否有译文。
  final bool hasTranslation;

  /// 是否有罗马音。
  final bool hasRomanization;

  const Lyrics({
    required this.lines,
    this.hasWordTiming = false,
    this.hasTranslation = false,
    this.hasRomanization = false,
  });

  static const empty = Lyrics(lines: <LyricLine>[]);

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;
  int get length => lines.length;

  LyricLine operator [](int index) => lines[index];

  /// 二分查找给定播放位置所属的行下标；未命中返回 -1。
  ///
  /// 位置早于第一行时返回 0，便于 UI 首行就处于待演唱状态。
  int indexAt(Duration position) {
    final ms = position.inMilliseconds;
    if (lines.isEmpty) return -1;
    if (ms < lines.first.startMs) return 0;

    var lo = 0;
    var hi = lines.length - 1;
    var ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final line = lines[mid];
      if (ms >= line.startMs) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// 当前正在演唱的行；无则 null。
  LyricLine? lineAt(Duration position) {
    final i = indexAt(position);
    if (i < 0 || i >= lines.length) return null;
    final line = lines[i];
    return position.inMilliseconds < line.endMs ? line : null;
  }
}
