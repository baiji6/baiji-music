import 'package:flutter/foundation.dart';

import 'log_store.dart';

/// 应用内日志记录器。
///
/// 在桌面/移动端将日志同时输出到控制台与内存环形缓冲（供「日志查看」页读取），
/// 支持六档级别与按档位开关。v2.2.6 起额外落盘（[LogStore]）：按天写文件、
/// 保留 7 天、启动回读当天——日志不再"每次打开软件就清空"。
/// 移植自原 Android 实现的 AppLog。
class AppLog {
  static const String trace = 'TRACE';
  static const String debug = 'DEBUG';
  static const String info  = 'INFO';
  static const String warn  = 'WARN';
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

  final List<({String level, String line})> _entries = [];
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
      _entries.add((level: _levelOfLine(line), line: line));
    }
    while (_entries.length > maxLines) {
      _entries.removeAt(0);
    }
  }

  /// 从日志行文本提取级别（回读历史时用）。格式: "MM-DD HH:MM:SS.mmm LEVEL/tag ..."。
  static String _levelOfLine(String line) {
    final m = RegExp(r'\d{2}:\d{2}:\d{2}\.\d{3}\s+([A-Z]+)/').firstMatch(line);
    return m?.group(1) ?? info;
  }

  void log(String level, String tag, String message, [Object? error]) {
    if (!isEnabled(level)) return;
    final line = error == null
        ? '$message [$tag]'
        : '$message [$tag] err=${error.toString()}';
    final buf = StringBuffer()
      ..write(_ts())
      ..write(' ')
      ..write(level)
      ..write('/')
      ..write(tag)
      ..write(' ')
      ..write(line);
    final text = buf.toString();
    _entries.add((level: level, line: text));
    while (_entries.length > maxLines) {
      _entries.removeAt(0);
    }
    for (final l in _listeners) {
      l(level, text);
    }
    // 落盘（异步批量；暂停/降级时静默跳过）
    LogStore.instance.write(text);
    // 控制台输出
    if (kDebugMode) {
      debugPrint(text);
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
  List<({String level, String line})> get entries => List.unmodifiable(_entries);

  List<String> dump() => _entries.map((e) => e.line).toList();

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
