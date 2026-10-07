/// 歌词解析引擎。
///
/// 支持五种来源格式，并能自动识别与自动解密：
/// - **普通 LRC**：`[mm:ss.xx]整句`
/// - **增强 LRC**：`[mm:ss.xx]<mm:ss.xx>字<mm:ss.xx>字`（逐字）
/// - **QRC**：`[起始ms,持续ms]字(偏移,持续)字...`（QQ 逐字，可加密）
/// - **YRC**：`[行起始ms,行时长ms](字起始ms,字时长ms,0)字...`（网易云逐字）
/// - **TTML**：`<p begin=".." end="..">` / 内含 `<span>` 逐音节（Apple Music）
///
/// 加密内容处理（对齐 Lyrico-Plugins 的 `qq/source.js`）：
/// - QQ QRC：hex → 3DES 解密 → zlib inflate，见 [qrcDecrypt]
/// - 其它：base64 兜底
library;

import 'dart:convert';

import '../crypto/qq_crypto.dart';
import 'lyric_model.dart';

/// LRC 解析中间态：起始时间 + 正文。
class _LrcEntry {
  final int startMs;
  final String body;
  const _LrcEntry(this.startMs, this.body);
}

/// QRC / YRC 字解析中间态。两者都用 `(起始, 持续[, 保留])` 表示一个字。
class _QrcWordRaw {
  final int start;
  final int duration;
  final String text;
  const _QrcWordRaw(this.start, this.duration, this.text);
}

/// 歌词解析器集合。
class LyricParser {
  LyricParser._();

  /// 自动识别格式并解析（含自动解密）。返回空歌词表示解析失败。
  static Lyrics parse(String raw, {String? translation, String? romanization}) {
    if (raw.trim().isEmpty) return Lyrics.empty;

    final content = _autoDecode(raw);
    if (content.isEmpty) return Lyrics.empty;

    Lyrics? parsed;
    final trimmed = content.trimLeft();

    // TTML / YRC / QRC / LRC 择优：按各自的特征标签判断。
    if (_looksLikeTtml(trimmed)) {
      parsed = _parseTtml(content);
    }
    if ((parsed == null || parsed.isEmpty) && _looksLikeYrc(content)) {
      parsed = _parseYrc(content);
    }
    if ((parsed == null || parsed.isEmpty) && _looksLikeQrc(content)) {
      parsed = _parseQrc(content);
    }
    if (parsed == null || parsed.isEmpty) {
      parsed = _parseLrc(content);
    }

    if (parsed.isEmpty) return Lyrics.empty;

    // 译文 / 罗马音按时间窗对齐到原词行上（对齐 Lyrico lyricsMerge）。
    final translatedLines = translation == null ? null : _parseLrc(translation);
    final romaLines = romanization == null ? null : _parseLrc(romanization);

    if ((translatedLines == null || translatedLines.isEmpty) &&
        (romaLines == null || romaLines.isEmpty)) {
      return parsed;
    }

    final merged = <LyricLine>[];
    for (var i = 0; i < parsed.length; i++) {
      final line = parsed[i];
      merged.add(LyricLine(
        startMs: line.startMs,
        endMs: line.endMs,
        text: line.text,
        words: line.words,
        translation: _pickAlignedText(translatedLines, parsed, i),
        romanization: _pickAlignedText(romaLines, parsed, i),
      ));
    }

    return Lyrics(
      lines: merged,
      hasWordTiming: parsed.hasWordTiming,
      hasTranslation: translatedLines != null && translatedLines.isNotEmpty,
      hasRomanization: romaLines != null && romaLines.isNotEmpty,
    );
  }

  // ==================== 自动解密 / 解码 ====================

  /// 输入可能是密文，按 QRC 加密 → base64 → 原文 的顺序尝试还原。
  static String _autoDecode(String raw) {
    final s = raw.trim();

    // 1) QQ QRC：纯 hex 且不短（DES 块 8 字节对齐）
    if (s.isNotEmpty && RegExp(r'^[0-9A-Fa-f]+$').hasMatch(s) && s.length >= 16) {
      final dec = qrcDecrypt(s);
      if (dec.isNotEmpty && _looksLikeLyric(dec)) return dec;
    }

    // 2) base64 兜底（网易云等）
    if (s.isNotEmpty && RegExp(r'^[A-Za-z0-9+/=\s]+$').hasMatch(s) && s.length >= 8) {
      try {
        final bytes = base64Decode(s.replaceAll(RegExp(r'\s'), ''));
        if (bytes.isNotEmpty) {
          final text = utf8.decode(bytes, allowMalformed: true);
          if (text.isNotEmpty && _looksLikeLyric(text)) return text;
        }
      } catch (_) {
        // 非 base64，按原文继续
      }
    }

    return raw;
  }

  /// 粗判是否像歌词文本（避免把解码失败的乱码当结果）。
  static bool _looksLikeLyric(String text) =>
      RegExp(r'\[\d+:\d+').hasMatch(text) ||
      RegExp(r'\[\d+,\d+\]').hasMatch(text) ||
      text.contains('<Lyric_1') ||
      _looksLikeTtml(text);

  static bool _looksLikeQrc(String text) =>
      RegExp(r'\[\d+,\d+\]').hasMatch(text) || text.contains('<Lyric_1');

  /// YRC 与 QRC 的行首都是 `[数字,数字]`，靠**行内字标记**区分：
  /// - YRC（网易云）：`(字起始,字时长,0)` —— 3 个字段
  /// - QRC（QQ）　　：`(偏移,持续)`　　　 —— 2 个字段
  ///
  /// 必须先判 YRC，否则会被 [_looksLikeQrc] 抢先命中而按 QRC 解析。
  static bool _looksLikeYrc(String text) =>
      RegExp(r'\[\d+,\d+\]\(\d+,\d+,\d+\)').hasMatch(text);

  static bool _looksLikeTtml(String text) =>
      text.contains('<tt') ||
      RegExp(r'<p\s[^>]*begin\s*=', caseSensitive: false).hasMatch(text) ||
      (text.contains('ttml') && text.contains('<p'));

  // ==================== LRC（普通 + 增强逐字） ====================

  /// 普通/增强 LRC 行首时间戳（可重复，表示多处出现）。
  static final _lrcTag =
      RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  /// 增强 LRC 的行内逐字时间戳 `<mm:ss.xx>`。
  static final _enhancedTag =
      RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');

  static Lyrics _parseLrc(String text) {
    // 先收集 [startMs, body]
    final collected = <_LrcEntry>[];
    var lineStart = -1; // 当前尚未配正文的行首时间戳

    void flushLine(String body) {
      if (lineStart >= 0 && body.trim().isNotEmpty) {
        collected.add(_LrcEntry(lineStart, body));
      }
      lineStart = -1;
    }

    var sawAny = false;

    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        flushLine('');
        continue;
      }

      // 元信息行 [ti:xxx] / [ar:xxx] / [offset:0] 跳过
      if (RegExp(r'^\[[a-zA-Z]+:[^\]]*\]$').hasMatch(line)) continue;

      // 逐个扫描行内的时间戳标记
      var cursor = 0;
      var found = false;
      final matches = _lrcTag.allMatches(line).toList();
      for (final m in matches) {
        if (m.start != cursor) {
          // 时间戳前有正文：先把上一个收集的行尾截断
          final prev = line.substring(cursor, m.start);
          flushLine(prev);
        }
        final mm = int.tryParse(m.group(1)!) ?? 0;
        final ss = int.tryParse(m.group(2)!) ?? 0;
        final fracRaw = m.group(3) ?? '';
        final frac =
            fracRaw.isEmpty ? 0 : _fracMillis(fracRaw, fracRaw.length);
        final ms = mm * 60000 + ss * 1000 + frac;

        if (lineStart >= 0) {
          // 连续多个时间戳：都指向同一句正文，先记录前一个
          collected.add(_LrcEntry(lineStart, ''));
        }
        lineStart = ms;
        cursor = m.end;
        found = true;
        sawAny = true;
      }

      if (!found) continue;

      final tail = line.substring(cursor);
      if (tail.trim().isEmpty) continue; // 只有时间戳，正文可能在下一行
      flushLine(tail);
    }

    if (!sawAny) return Lyrics.empty;

    // 排序并去掉重复的占位空行
    final entries = collected.where((e) => e.body.trim().isNotEmpty).toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    if (entries.isEmpty) return Lyrics.empty;

    final lines = <LyricLine>[];
    for (var i = 0; i < entries.length; i++) {
      final startMs = entries[i].startMs;
      final body = entries[i].body;
      final endMs = i < entries.length - 1
          ? (entries[i + 1].startMs - 10).clamp(startMs + 1, startMs + 30000)
          : startMs + 2000;

      final words = _parseEnhancedWords(body);
      final plain = words.isNotEmpty
          ? words.map((w) => w.text).join()
          : _stripLeadingMarkers(body);

      if (plain.trim().isEmpty) continue;

      lines.add(LyricLine(
        startMs: startMs,
        endMs: endMs,
        text: plain,
        words: words.length > 1 ? words : const [],
      ));
    }

    if (lines.isEmpty) return Lyrics.empty;
    return Lyrics(
      lines: lines,
      hasWordTiming: lines.any((l) => l.isWordLevel),
    );
  }

  /// 解析增强 LRC 的行内逐字 `<mm:ss.xx>字<mm:ss.xx>字`。
  ///
  /// 只有出现 ≥2 个 inline 标记时才认为是逐字格式。
  static List<LyricWord> _parseEnhancedWords(String body) {
    final matches = _enhancedTag.allMatches(body).toList();
    if (matches.length < 2) return const [];

    final words = <LyricWord>[];
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      final mm = int.tryParse(m.group(1)!) ?? 0;
      final ss = int.tryParse(m.group(2)!) ?? 0;
      final fracRaw = m.group(3) ?? '';
      final frac = fracRaw.isEmpty ? 0 : _fracMillis(fracRaw, fracRaw.length);
      final startMs = mm * 60000 + ss * 1000 + frac;

      final textEnd = i < matches.length - 1 ? matches[i + 1].start : body.length;
      final text = body.substring(m.end, textEnd);
      if (text.isEmpty) continue;

      final endMs = i < matches.length - 1
          ? (() {
              final nm = matches[i + 1];
              final nmm = int.tryParse(nm.group(1)!) ?? 0;
              final nss = int.tryParse(nm.group(2)!) ?? 0;
              final nFracRaw = nm.group(3) ?? '';
              final nFrac =
                  nFracRaw.isEmpty ? 0 : _fracMillis(nFracRaw, nFracRaw.length);
              return nmm * 60000 + nss * 1000 + nFrac;
            })()
          : startMs + 800;

      words.add(LyricWord(startMs: startMs, endMs: endMs, text: text));
    }
    return words;
  }

  /// 去掉正文里残留的时间标记（普通 LRC 理论上没有，防御用）。
  static String _stripLeadingMarkers(String body) =>
      body.replaceAll(_enhancedTag, '').trim();

  /// 小数位转毫秒：`.5` → 500，`.05` → 50，`.005` → 5。
  static int _fracMillis(String digits, int len) {
    final scaled = (double.tryParse('0.$digits') ?? 0.0) * 1000;
    return scaled.round().clamp(0, 999);
  }

  // ==================== QRC（逐字） ====================

  /// QRC 行：`[起始ms,持续ms]字(偏移ms,持续ms)字...`
  static final _qrcLine = RegExp(r'^\[(\d+),(\d+)\](.*)$');

  /// QRC 行内每个字：`文本(相对偏移,持续)`。
  static final _qrcWord =
      RegExp(r'(?:^\[\d+,\d+\])?((?:(?!\(\d+,\d+\)).)*)\((\d+),(\d+)\)');

  static Lyrics _parseQrc(String text) {
    var content = text;

    // QRC 可能被包在 <Lyric_1 LyricContent="..."/> 里
    final xml = RegExp(r'<Lyric_1\s+LyricType="1"\s+LyricContent="([\s\S]*?)"\s*/>')
        .firstMatch(content);
    if (xml != null) content = _decodeEntities(xml.group(1) ?? '');

    final lines = <LyricLine>[];

    for (final rawLine in const LineSplitter().convert(content)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      // 跳过纯元信息行 [ti:xx] / [ar:xx] / [al:xx] / [by:xx]
      if (RegExp(r'^\[\w+:[^\]]*\]$').hasMatch(line)) continue;
      // 跳过 QRC 头部标记，如 [offset:0]
      final m = _qrcLine.firstMatch(line);
      if (m == null) continue;

      final lineStart = int.tryParse(m.group(1)!) ?? 0;
      final lineDur = int.tryParse(m.group(2)!) ?? 0;
      final lineEnd = lineStart + lineDur;
      final body = m.group(3) ?? '';

      final parsed = <_QrcWordRaw>[];
      for (final wm in _qrcWord.allMatches(body)) {
        final wordStart = int.tryParse(wm.group(2)!) ?? 0;
        final dur = int.tryParse(wm.group(3)!) ?? 0;
        final wordText = wm.group(1) ?? '';
        parsed.add(_QrcWordRaw(wordStart, dur, wordText));
      }

      final List<LyricWord> words;
      if (parsed.isEmpty) {
        final plain = body.trim();
        if (plain.isEmpty) continue;
        words = [
          LyricWord(
            startMs: lineStart,
            endMs: lineEnd > lineStart ? lineEnd : lineStart + 2000,
            text: plain,
          ),
        ];
      } else {
        // QRC 的字时间戳是相对行首的偏移，交给统一时间口径换算
        words = _materializeWords(parsed, lineStart, lineEnd);
      }

      final fullText = words.map((w) => w.text).join();
      if (fullText.trim().isEmpty) continue;

      lines.add(LyricLine(
        startMs: lineStart,
        endMs: lineEnd > lineStart ? lineEnd : _lastEnd(words, lineStart),
        text: fullText,
        words: words.length > 1 ? words : const [],
      ));
    }

    if (lines.isEmpty) return Lyrics.empty;
    lines.sort((a, b) => a.startMs.compareTo(b.startMs));
    return Lyrics(
      lines: lines,
      hasWordTiming: lines.any((l) => l.isWordLevel),
    );
  }

  static String _decodeEntities(String s) => s
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAllMapped(RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.tryParse(m.group(1)!) ?? 0));

  // ==================== YRC（网易云逐字） ====================

  /// YRC 行：`[行起始ms,行时长ms]` 后接正文。
  ///
  /// 正文的写法有两种，实测都会出现：
  /// - 有逐字：`(字起始,字时长,0)字(字起始,字时长,0)字...`
  /// - 无逐字：`文本`（整行一个时间片）
  ///
  /// 注意 `[12670,2790]` 之后**没有**独立的首字标记，第一个 `(...)` 就是首字。
  static final _yrcLine = RegExp(r'^\[(\d+),(\d+)\](.*)$');

  /// YRC 逐字标记：`(字起始,字时长,保留)`。
  static final _yrcWordTag = RegExp(r'\((\d+),(\d+),(\d+)\)');

  static Lyrics _parseYrc(String text) {
    final lines = <LyricLine>[];

    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final m = _yrcLine.firstMatch(line);
      if (m == null) continue;

      final lineStart = int.tryParse(m.group(1)!) ?? 0;
      final lineDur = int.tryParse(m.group(2)!) ?? 0;
      final lineEnd = lineStart + lineDur;
      final body = m.group(3) ?? '';

      // YRC 的字标记是「标记在前、文本在后」：`(12670,260,0)早(12930,180,0)上`
      // （与 QRC 的「文本在前、标记在后」恰好相反）。行首的 `[12670,2790]`
      // 之后紧跟的就是第一个字标记，其文本在其右侧。
      final tags = _yrcWordTag.allMatches(body).toList();
      final raw = <_QrcWordRaw>[];
      for (var i = 0; i < tags.length; i++) {
        final t = tags[i];
        final textEnd = i + 1 < tags.length ? tags[i + 1].start : body.length;
        raw.add(_QrcWordRaw(
          int.tryParse(t.group(1)!) ?? 0,
          int.tryParse(t.group(2)!) ?? 0,
          body.substring(t.end, textEnd),
        ));
      }

      // 元信息行（作词/作曲…）形如 `[0,1000](0,1000,0) 作词 : xxx`，
      // 文本非空，属合法歌词行，保留（与 lrc 的 `[00:00] 作词 : xxx` 一致）。
      final List<LyricWord> words;
      if (raw.isEmpty) {
        final plain = _decodeEntities(body).trim();
        if (plain.isEmpty) continue;
        words = [
          LyricWord(
            startMs: lineStart,
            endMs: lineEnd > lineStart ? lineEnd : lineStart + 2000,
            text: plain,
          ),
        ];
      } else {
        words = _materializeWords(raw, lineStart, lineEnd);
      }

      final fullText = words.map((w) => w.text).join();
      if (fullText.trim().isEmpty) continue;

      lines.add(LyricLine(
        startMs: lineStart,
        endMs: lineEnd > lineStart ? lineEnd : _lastEnd(words, lineStart),
        text: _decodeEntities(fullText),
        words: words.length > 1 ? words : const [],
      ));
    }

    if (lines.isEmpty) return Lyrics.empty;
    lines.sort((a, b) => a.startMs.compareTo(b.startMs));
    return Lyrics(
      lines: lines,
      hasWordTiming: lines.any((l) => l.isWordLevel),
    );
  }

  /// 把「原始字元组」补全为带起止时间的 [LyricWord]。
  ///
  /// 兼容两种时间口径：
  /// - 绝对值（网易云 YRC）：`start` 是整曲毫秒，首字 ≈ 行首，末字 ≈ 行尾；
  /// - 相对偏移（QQ QRC）：`start` 是相对行首的偏移，首字通常为 0。
  ///
  /// 判定看**最后一个字**而不是首字：把它按两种口径分别还原，
  /// 取"落在 [lineStart, lineEnd] 之内"的那种，比首字更不容易被
  /// "YRC 首字恰好等于行首"与"QRC 首字偏移为 0"的巧合影响。
  static List<LyricWord> _materializeWords(
      List<_QrcWordRaw> parsed, int lineStart, int lineEnd) {
    final lastRaw = parsed.last.start;
    final lastAbs = lastRaw; // 绝对值口径
    final lastRel = lineStart + lastRaw; // 相对偏移口径

    // 行时长未知时给一个宽松上界，避免误判
    final upper = lineEnd > lineStart ? lineEnd : lineStart + 60000;
    bool inRange(int v) => v >= lineStart && v <= upper;

    // 优先选锚定在行内的口径；两者都成立时，取与行尾更贴近的那个
    bool absolute;
    if (inRange(lastAbs) && !inRange(lastRel)) {
      absolute = true;
    } else if (inRange(lastRel) && !inRange(lastAbs)) {
      absolute = false;
    } else {
      absolute = (lastAbs - lineStart).abs() <= (lastRel - lineStart).abs();
    }

    final words = <LyricWord>[];
    for (var i = 0; i < parsed.length; i++) {
      final raw = parsed[i];
      final wStart = absolute ? raw.start : lineStart + raw.start;

      int wEnd;
      if (raw.duration > 0) {
        wEnd = wStart + raw.duration;
      } else if (i < parsed.length - 1) {
        final next = parsed[i + 1];
        wEnd = absolute ? next.start : lineStart + next.start;
      } else {
        wEnd = lineEnd > wStart ? lineEnd : wStart + 800;
      }

      words.add(LyricWord(
        startMs: wStart,
        endMs: wEnd > wStart ? wEnd : wStart + 1,
        text: raw.text,
      ));
    }
    return words;
  }

  static int _lastEnd(List<LyricWord> words, int fallback) =>
      words.isEmpty ? fallback + 2000 : words.last.endMs;

  // ==================== TTML ====================

  static final _pTag =
      RegExp(r'<p\b([^>]*)>([\s\S]*?)</p>', caseSensitive: false);
  static final _spanTag =
      RegExp(r'<span\b([^>]*)>([\s\S]*?)</span>', caseSensitive: false);
  static final _anyTag = RegExp(r'<[^>]+>');

  static Lyrics _parseTtml(String text) {
    final lines = <LyricLine>[];

    for (final pm in _pTag.allMatches(text)) {
      final attrs = pm.group(1) ?? '';
      final inner = pm.group(2) ?? '';

      final begin = _attr(attrs, 'begin');
      if (begin == null) continue;
      final startMs = _ttmlTime(begin);
      final endAttr = _attr(attrs, 'end');

      final words = <LyricWord>[];
      for (final sm in _spanTag.allMatches(inner)) {
        final sAttrs = sm.group(1) ?? '';
        final sBegin = _attr(sAttrs, 'begin');
        if (sBegin == null) continue;
        final sStart = _ttmlTime(sBegin);
        final sEndAttr = _attr(sAttrs, 'end');
        final sEnd = sEndAttr == null ? sStart + 500 : _ttmlTime(sEndAttr);
        final wText = _stripTags(sm.group(2) ?? '').trim();
        words.add(LyricWord(
            startMs: sStart, endMs: sEnd > sStart ? sEnd : sStart + 1, text: wText));
      }

      final fullText = _decodeEntities(_stripTags(inner)).trim();
      if (fullText.isEmpty) continue;

      var endMs = endAttr == null ? 0 : _ttmlTime(endAttr);
      if (endMs <= startMs) {
        endMs = words.isNotEmpty
            ? words.last.endMs
            : startMs + 2000;
      }

      lines.add(LyricLine(
        startMs: startMs,
        endMs: endMs,
        text: fullText,
        words: words.length > 1 ? words : const [],
      ));
    }

    if (lines.isEmpty) return Lyrics.empty;
    lines.sort((a, b) => a.startMs.compareTo(b.startMs));
    return Lyrics(
      lines: lines,
      hasWordTiming: lines.any((l) => l.isWordLevel),
    );
  }

  /// 取 XML 属性值（单/双引号均可，属性名大小写不敏感）。
  static String? _attr(String attrs, String name) {
    final re = RegExp('$name\\s*=\\s*(["\\\'])([^\\1]*?)\\1', caseSensitive: false);
    final m = re.firstMatch(attrs);
    return m?.group(2);
  }

  /// TTML 时钟值 → 毫秒。支持 `hh:mm:ss.mmm` / `mm:ss.mmm` / `ss.mmm` / 纯秒。
  static int _ttmlTime(String value) {
    final v = value.trim();
    if (v.isEmpty) return 0;

    final clock = RegExp(r'^(\d+(?:\.\d+)?)$').firstMatch(v);
    if (clock != null) {
      return (double.tryParse(clock.group(1)!) ?? 0.0) * 1000 ~/ 1;
    }

    final parts = v.split(':');
    if (parts.length == 2) {
      final mm = int.tryParse(parts[0]) ?? 0;
      final ss = double.tryParse(parts[1]) ?? 0.0;
      return (mm * 60000 + ss * 1000).round();
    }
    if (parts.length == 3) {
      final hh = int.tryParse(parts[0]) ?? 0;
      final mm = int.tryParse(parts[1]) ?? 0;
      final ss = double.tryParse(parts[2]) ?? 0.0;
      return (hh * 3600000 + mm * 60000 + ss * 1000).round();
    }
    return 0;
  }

  static String _stripTags(String s) => s.replaceAll(_anyTag, '');

  // ==================== 译文 / 罗马音对齐 ====================

  /// 对齐 Lyrico `lyricsMerge`：把译文按时间窗挂到原词行上，返回整行文本。
  static String? _pickAlignedText(Lyrics? other, Lyrics original, int index) {
    if (other == null || other.isEmpty) return null;
    final orig = original[index];
    final winStart = orig.startMs;
    final winEnd =
        index < original.length - 1 ? original[index + 1].startMs : 1 << 31;

    for (final cand in other.lines) {
      if (cand.startMs < winStart - 500) continue;
      if (cand.startMs >= winEnd) break;
      return cand.displayText.isEmpty ? null : cand.displayText;
    }
    return null;
  }
}
