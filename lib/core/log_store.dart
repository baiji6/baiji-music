/// 日志文件持久化。
///
/// 旧版日志只活在内存环形缓冲里，**每次打开软件都会清空**——用户遇到
/// 闪退时打开日志页，看到的只是一片空白，什么都对不上。
/// 本类把日志按天写进应用支持目录（不是缓存目录，「清理缓存」不会误删），
/// 保留最近 [keepDays] 天，启动时回读当天文件，让日志页开箱就有历史。
///
/// 设计约束：
/// - 写入异步且批量（队列 + 定时 flush），不在 UI 线程做同步 IO；
/// - [flushSync] 留给闪退前的最后一击——那时没有"下一次事件循环"了；
/// - 平台拿不到目录（测试环境等）时静默降级为纯内存，绝不影响主流程。
library;

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class LogStore {
  LogStore._();

  static final LogStore instance = LogStore._();

  /// 应用支持目录下的子目录名。
  static const String dirName = 'logs';

  /// 保留天数（含今天）。
  static const int keepDays = 7;

  /// 文件名单日期格式：`baiji_20261013.log`。
  static final _fileRe = RegExp(r'^baiji_(\d{8})\.log$');

  Directory? _dir;
  File? _today;

  /// 待写缓冲。
  final List<String> _queue = [];

  /// flush 定时器（第一条日志入队时启动，1s 批量落盘）。
  Timer? _flushTimer;

  /// 平台不支持（无目录实现）时静默降级。
  bool _broken = false;

  bool get isActive => _dir != null;

  /// 测试专用：重置内部状态（LogStore 是进程级单例，用例之间需要干净环境）。
  void debugResetForTest() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _queue.clear();
    _dir = null;
    _today = null;
    _broken = false;
  }

  /// 初始化：定位目录、清理过期文件、打开当天文件。
  Future<void> init() async {
    if (_dir != null || _broken) return;
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}$dirName');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _dir = dir;
      await _pruneOld();
      _today = _fileFor(DateTime.now());
      if (!_today!.existsSync()) _today!.createSync(recursive: true);
    } catch (_) {
      _broken = true;
      _dir = null;
      _today = null;
    }
  }

  File _fileFor(DateTime d) {
    final stamp = '${d.year.toString().padLeft(4, '0')}'
        '${d.month.toString().padLeft(2, '0')}'
        '${d.day.toString().padLeft(2, '0')}';
    return File('${_dir!.path}${Platform.pathSeparator}baiji_$stamp.log');
  }

  /// 删除 [keepDays] 天之前的日志文件。
  Future<void> _pruneOld() async {
    final now = DateTime.now();
    final deadline = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: keepDays));
    await for (final entity in _dir!.list()) {
      if (entity is! File) continue;
      final m = _fileRe.firstMatch(entity.uri.pathSegments.last);
      if (m == null) continue;
      final stamp = m.group(1)!;
      final y = int.parse(stamp.substring(0, 4));
      final mo = int.parse(stamp.substring(4, 6));
      final d = int.parse(stamp.substring(6, 8));
      if (DateTime(y, mo, d).isBefore(deadline)) {
        try {
          await entity.delete();
        } catch (_) {
          // 占用中/权限问题：跳过，下次启动再试
        }
      }
    }
  }

  /// 回读当天日志全文（供启动时灌进内存缓冲）。
  Future<List<String>> readToday() async {
    final file = _today;
    if (file == null || !file.existsSync()) return const [];
    try {
      final text = await file.readAsString();
      if (text.isEmpty) return const [];
      return text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 追加一条日志（异步批量落盘）。
  void write(String line) {
    if (_broken || _today == null) return;
    _queue.add(line);
    _flushTimer ??= Timer(const Duration(seconds: 1), _flush);
  }

  Future<void> _flush() async {
    _flushTimer = null;
    if (_queue.isEmpty || _today == null) return;
    final batch = List<String>.of(_queue);
    _queue.clear();
    try {
      final sink = _today!.openWrite(mode: FileMode.append);
      sink.write('${batch.join('\n')}\n');
      await sink.flush();
      await sink.close();
    } catch (_) {
      // 磁盘满 / 文件被删：放弃这一批，不影响后续日志
    }
  }

  /// 同步刷盘——闪退路径专用，没有事件循环可等。
  void flushSync() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_queue.isEmpty || _today == null) return;
    final batch = List<String>.of(_queue);
    _queue.clear();
    try {
      _today!.writeAsStringSync('${batch.join('\n')}\n',
          mode: FileMode.append, flush: true);
    } catch (_) {
      // 忽略
    }
  }

  /// 清空当天文件（日志页「清空」按钮）。
  Future<void> clearToday() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _queue.clear();
    final file = _today;
    if (file == null) return;
    try {
      await file.writeAsString('');
    } catch (_) {
      // 忽略
    }
  }

  /// 所有历史日志文件（新→旧），供开发者模式导出。
  Future<List<File>> historyFiles() async {
    final dir = _dir;
    if (dir == null || !dir.existsSync()) return const [];
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File && _fileRe.hasMatch(entity.uri.pathSegments.last)) {
        files.add(entity);
      }
    }
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }
}
