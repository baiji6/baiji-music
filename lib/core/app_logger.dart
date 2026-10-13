import 'package:flutter/foundation.dart';

import 'log_store.dart';

/// 一条结构化日志条目。
///
/// v2.2.8 起日志从「纯文本行」升级为结构化条目：级别、时间、tag、
/// 消息体各自独立，UI 端不再需要每次重建都对全量日志跑正则解析。
/// [raw] 保留完整原始行，导出 / 落盘格式不变。
class LogEntry {
  const LogEntry({
    required this.level,
    required this.time,
    required this.tag,
    required this.message,
    required this.raw,
    this.noiseLines = 0,
  });

  final String level;

  /// 条目产生时间（落盘回读的历史条目按行内时间戳近似）。
  final DateTime time;

  /// 日志 tag（模块名）。
  final String tag;

  /// 消息正文（不含时间戳 / 级别 / tag 前缀）。
  final String message;

  /// 完整原始行（`MM-DD HH:MM:SS.mmm LEVEL/tag message`），导出用。
  final String raw;

  /// 消息体内被识别为「系统崩溃转储」的噪声行数
  /// （VM tombstone `***`、backtrace `#NN abs` 等）。
  final int noiseLines;

  bool get hasNoise => noiseLines > 0;
}

/// 应用内日志记录器。
///
/// 在桌面/移动端将日志同时输出到控制台与内存环形缓冲（供「日志查看」页读取），
/// 支持六档级别与按档位开关。v2.2.6 起额外落盘（[LogStore]）：按天写文件、
/// 保留 7 天、启动回读当天——日志不再"每次打开软件就清空"。
/// v2.2.8 起条目结构化（[LogEntry]），并识别崩溃转储噪声行。
/// 移植自原 Android 实现的 AppLog。
class AppLog {
  static const String trace = 'TRACE';
  static const String debug = 'DEBUG';
  static const String info = 'INFO';
  static const String warn = 'WARN';
  static const String error = 'ERROR';
  static const String fatal = 'FATAL';

  static const int maxLines = 800;

  static const List<String> levels = [trace, debug, info, warn, error, fatal];

  static const Map<String, bool> defaultEnabled = {
    trace: false,
    debug: true,
    info: true,
    warn: true,
    error: true,
    fatal: true,
  };

  final List<LogEntry> _entries = [];
  final Map<String, bool> _enabled = Map.of(defaultEnabled);
  final List<AppLogListener> _listeners = [];

  static final AppLog _instance = AppLog._();

  AppLog._();

  /// 应用可挂接的日志监听（例如持久化或转发）。
  static AppLog get instance => _instance;

  void addListener(AppLogListener l) => _listeners.add(l);

  bool isEnabled(String level) => _enabled[level] ?? false;

  void setEnabled(String level, bool on) => _enabled[level] = on;

  /// 级别优先级数字（trace=0 … fatal=5），越大越严重。
  static int levelIndex(String level) => levels.indexOf(level);

  /// 判断 [level] 的严重程度是否 >= [minLevel]。
  static bool isAtLeast(String level, String minLevel) =>
      levelIndex(level) >= levelIndex(minLevel);

  /// 挂上文件 sink，并把当天已有日志回读进内存（启动时调用一次）。
  ///
  /// 之后所有日志都会追加到当天文件；「清空」按钮会同时清掉文件。
  /// 平台拿不到目录时静默降级为纯内存日志。
  Future<void> initFileSink() async {
    await LogStore.instance.init();
    final history = await LogStore.instance.readToday();
    if (history.isEmpty) return;
    for (final line in history) {
      _entries.add(_parseLine(line));
    }
    while (_entries.length > maxLines) {
      _entries.removeAt(0);
    }
  }

  /// 把落盘回读的原始行还原成结构化条目。
  /// 格式: "MM-DD HH:MM:SS.mmm LEVEL/tag message"。
  static LogEntry _parseLine(String line) {
    final m = RegExp(
      r'^(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.\d{3} ([A-Z]+)/(\S+)\s*(.*)$',
      dotAll: true,
    ).firstMatch(line);
    if (m == null) {
      return LogEntry(
        level: info,
        time: DateTime.now(),
        tag: '',
        message: line,
        raw: line,
        noiseLines: countNoiseLines(line),
      );
    }
    final message = m.group(8) ?? '';
    final now = DateTime.now();
    return LogEntry(
      level: m.group(6) ?? info,
      // 行内没有年份，回读时按当前年补一个近似时间（仅用于 UI 展示）。
      time: DateTime(
        now.year,
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!),
        int.parse(m.group(5)!),
      ),
      tag: m.group(7) ?? '',
      message: message,
      raw: line,
      noiseLines: countNoiseLines(message),
    );
  }

  // ==================== 崩溃转储噪声识别 ====================

  /// 识别 VM / 系统崩溃转储的噪声行：
  /// - tombstone 分隔与段头（`*** *** ***` / `Build fingerprint:` / `pid: N, tid: N`）
  /// - native backtrace 帧（`#01 abs 0000…` / `#02 pc 0000…`）
  ///
  /// 这类行动辄几百行十六进制地址，对排障没有可读性；日志页默认折叠，
  /// 用户显式展开才看全文（崩前证据仍完整保留在 raw 里）。
  static final RegExp _noiseRe = RegExp(
    r'^(?:\*[\*\s]*$'
    r'|#{1,2}\d{1,3}\s+(?:abs|pc|ip|sp)\s'
    r'|Build fingerprint:'
    r'|pid:\s*\d+,\s*tid:'
    r'|>>>\s)',
  );

  /// 单行是否崩溃转储噪声（日志页折叠视图复用同一判定）。
  static bool isNoiseLine(String line) => _noiseRe.hasMatch(line.trimLeft());

  /// 统计 [text] 里的崩溃转储噪声行数。
  static int countNoiseLines(String text) {
    if (!text.contains('\n')) return 0;
    var n = 0;
    for (final line in text.split('\n')) {
      if (isNoiseLine(line)) n++;
    }
    return n;
  }

  void log(String level, String tag, String message, [Object? error]) {
    if (!isEnabled(level)) return;
    final msg = error == null ? message : '$message err=${error.toString()}';
    final buf = StringBuffer()
      ..write(_ts())
      ..write(' ')
      ..write(level)
      ..write('/')
      ..write(tag)
      ..write(' ')
      ..write(msg);
    final raw = buf.toString();
    _entries.add(
      LogEntry(
        level: level,
        time: DateTime.now(),
        tag: tag,
        message: msg,
        raw: raw,
        noiseLines: countNoiseLines(msg),
      ),
    );
    while (_entries.length > maxLines) {
      _entries.removeAt(0);
    }
    for (final l in _listeners) {
      l(level, raw);
    }
    // 落盘（异步批量；暂停/降级时静默跳过）
    LogStore.instance.write(raw);
    // 控制台输出
    if (kDebugMode) {
      debugPrint(raw);
    }
  }

  static void t(String tag, String msg, [Object? e]) =>
      _instance.log(trace, tag, msg, e);
  static void d(String tag, String msg, [Object? e]) =>
      _instance.log(debug, tag, msg, e);
  static void i(String tag, String msg, [Object? e]) =>
      _instance.log(info, tag, msg, e);
  static void w(String tag, String msg, [Object? e]) =>
      _instance.log(warn, tag, msg, e);
  static void e(String tag, String msg, [Object? e]) =>
      _instance.log(error, tag, msg, e);
  static void f(String tag, String msg, [Object? e]) =>
      _instance.log(fatal, tag, msg, e);

  /// 所有日志条目（含级别信息）。
  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// 按级别下限 + 关键词过滤的快照（日志页专用）。
  ///
  /// [minLevel] 级别下限（含本身）；[keyword] 对 tag / 消息做不区分大小写
  /// 的子串匹配；[hideNoise] 为 true 时隐藏**整条都是崩溃转储**的条目
  /// （有正文的条目仍保留，转储部分由 UI 折叠）。
  List<LogEntry> snapshot({
    String minLevel = trace,
    String keyword = '',
    bool hideNoise = false,
  }) {
    final minIdx = levelIndex(minLevel);
    final kw = keyword.trim().toLowerCase();
    return _entries.where((e) {
      if (levelIndex(e.level) < minIdx) return false;
      if (kw.isNotEmpty &&
          !e.tag.toLowerCase().contains(kw) &&
          !e.message.toLowerCase().contains(kw)) {
        return false;
      }
      if (hideNoise &&
          e.hasNoise &&
          e.message.trim().split('\n').length == e.noiseLines) {
        return false;
      }
      return true;
    }).toList();
  }

  List<String> dump() => _entries.map((e) => e.raw).toList();

  /// 清空内存日志，同时清掉当天落盘文件（否则重启又回读回来了）。
  void clear() {
    _entries.clear();
    LogStore.instance.clearToday();
  }

  /// 同步刷盘——闪退路径专用（没有事件循环可等）。
  void flushSync() => LogStore.instance.flushSync();

  String _ts() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.'
        '${three(now.millisecond)}';
  }
}

/// 日志监听回调。
typedef AppLogListener = void Function(String level, String line);
