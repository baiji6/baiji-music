import 'package:flutter/foundation.dart';

/// 应用内日志记录器。
///
/// 在桌面/移动端将日志同时输出到控制台与内存环形缓冲（供「日志查看」页读取），
/// 支持六档级别与按档位开关。移植自原 Android 实现的 AppLog。
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
    // 控制台输出
    if (kDebugMode) {
      debugPrint(text);
    }
  }

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

  List<String> dump() => _entries.map((e) => e.line).toList();

  void clear() => _entries.clear();

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