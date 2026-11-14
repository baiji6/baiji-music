/// 日志文件持久化。
///
/// 旧版日志只活在内存环形缓冲里，**每次打开软件都会清空**——用户遇到
/// 闪退时打开日志页，看到的只是一片空白，什么都对不上。
/// 本类把日志按天写进应用支持目录（不是缓存目录，「清理缓存」不会误删），
/// 保留最近 [keepDays] 天，启动时回读当天文件，让日志页开箱就有历史。
///
/// v2.5.8-fix1 起日志目录可以由用户自定义（例如指向 SD 卡上的某个目录，
/// 方便用文件管理器直接抓日志排查问题）。自定义目录不可用（被拔掉的卡、
/// 被删掉的目录、没权限的公共目录）时**静默回落到默认目录**——
/// 日志功能不能因为一个目录设置而整体失效。
///
/// 设计约束：
/// - 写入异步且批量（队列 + 定时 flush），不在 UI 线程做同步 IO；
/// - [flushSync] 留给闪退前的最后一击——那时没有"下一次事件循环"了；
/// - 平台拿不到目录（测试环境等）时静默降级为纯内存，绝不影响主流程。
library;

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'kv_store.dart';

class LogStore {
  LogStore._();

  static final LogStore instance = LogStore._();

  /// 应用支持目录下的子目录名。
  static const String dirName = 'logs';

  /// 保留天数（含今天）。
  static const int keepDays = 7;

  /// 自定义日志目录在 KvStore 里的键名。
  ///
  /// 独立前缀是为了不和别的模块（缓存目录、下载目录……）撞键——
  /// 撞键意味着两个功能互相覆盖对方的设置，排查起来极其费劲。
  static const String customDirKey = 'log_custom_dir';

  /// 探测目录可写性用的临时文件名。
  ///
  /// 刻意不叫 `baiji_*.log`：清理旧日志时只删匹配日志名式的文件，
  /// 探针文件绝不能被卷进去（哪怕它刚好被留在了用户的目录里）。
  static const String _probeFileName = '.baiji_log_write_test';

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

  /// 最近一次「自定义目录不可用 → 回落到默认目录」的说明。
  ///
  /// 由上层（AppLog）读走并记成一条 warn，让用户和排查者知道
  /// 日志实际落在了哪里，而不是以为还在自定义目录里。
  String? _fallbackNote;

  bool get isActive => _dir != null;

  /// 当前生效的日志目录路径；未初始化（平台不支持）时为 null。
  String? get currentDirPath => _dir?.path;

  /// 最近一次回落说明；没发生过回落时为 null。
  String? get fallbackNote => _fallbackNote;

  /// 用户设置的自定义日志目录；未设置时为 null。
  ///
  /// KvStore 没初始化（测试环境、启动极早期）时返回 null——
  /// 相当于"没设置过自定义目录"，而不是抛异常打断日志初始化。
  static String? get customDir {
    try {
      final v = KvStore.instance.getString(customDirKey);
      if (v == null || v.trim().isEmpty) return null;
      return v.trim();
    } catch (_) {
      return null;
    }
  }

  /// 测试专用：重置内部状态（LogStore 是进程级单例，用例之间需要干净环境）。
  void debugResetForTest() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _queue.clear();
    _dir = null;
    _today = null;
    _broken = false;
    _fallbackNote = null;
  }

  /// 初始化：定位目录、清理过期文件、打开当天文件。
  ///
  /// 目录选择顺序：用户自定义目录（存在且可写）→ 默认目录（应用支持目录下的
  /// logs 子目录）。自定义目录不可用时**静默回落**并在 [_fallbackNote] 里
  /// 留一句原因——用户拔了 SD 卡不该导致整个日志功能停摆。
  Future<void> init() async {
    if (_dir != null || _broken) return;
    try {
      final custom = customDir;
      if (custom != null && custom.isNotEmpty) {
        final dir = Directory(custom);
        // 启动时不主动创建自定义目录：路径不存在多半是卡被拔了 / 目录被删了，
        // 这时凭空建一个反而会掩盖问题，直接回落到默认目录更诚实。
        if (await _isWritable(dir)) {
          _dir = dir;
          if (await _openAt(dir)) return;
        }
        _fallbackNote =
            '自定义日志目录不可用（不存在或不可写），已回落到默认目录: $custom';
      }
      final base = await getApplicationSupportDirectory();
      final fallback =
          Directory('${base.path}${Platform.pathSeparator}$dirName');
      _dir = fallback;
      if (await _openAt(fallback)) return;
      // 默认目录也用不了（平台不支持 / 权限异常）→ 静默降级为纯内存日志，
      // 绝不影响主流程。
      _broken = true;
      _dir = null;
      _today = null;
    } catch (_) {
      _broken = true;
      _dir = null;
      _today = null;
    }
  }

  /// 在指定目录上建立写入目标：打开当天文件 + 清理过期日志。
  ///
  /// 返回 false 表示这个目录用不了（只读、权限被收回等），调用方据此回落。
  Future<bool> _openAt(Directory dir) async {
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _today = _fileFor(DateTime.now());
      if (!_today!.existsSync()) _today!.createSync(recursive: true);
      await _pruneOld();
      return true;
    } catch (_) {
      _today = null;
      return false;
    }
  }

  /// 默认日志目录：应用支持目录下的 [dirName] 子目录。
  static Future<Directory> _defaultDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}$dirName');
  }

  /// 默认日志目录路径（设置页展示"恢复默认"的目标用）。
  ///
  /// 平台拿不到目录时返回 null，调用方自己决定怎么兜底。
  static Future<String?> defaultDirPath() async {
    try {
      return (await _defaultDir()).path;
    } catch (_) {
      return null;
    }
  }

  /// 目录是否可用：存在，且能写文件。
  ///
  /// 用一个独立命名的探针文件来试写（而不是直接创建当天的日志文件）——
  /// 万一这个目录最终不被采用，也不该在用户目录里留下一堆空日志文件。
  static Future<bool> _isWritable(Directory dir, {bool create = false}) async {
    try {
      if (!dir.existsSync()) {
        if (!create) return false;
        dir.createSync(recursive: true);
      }
      final probe =
          File('${dir.path}${Platform.pathSeparator}$_probeFileName');
      await probe.writeAsString('probe', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 设置自定义日志目录并立即生效。
  ///
  /// 传 null 或空串表示恢复默认目录。返回**实际生效**的目录路径——
  /// 自定义目录不可用时返回的是回落到默认目录之后的路径。
  ///
  /// 只影响切换之后的写入：切换前已经写进旧目录的日志留在原处，
  /// **不做迁移**。搬迁会在用户目录里凭空多出一份文件，用户回头翻
  /// 旧目录时反而对不上号；留着旧文件也方便对比切换前后的现场。
  Future<String?> setCustomDir(String? path) async {
    final target = path?.trim();
    if (target != null && target.isNotEmpty) {
      // 先验证再落盘：目录写不进去就别记下来，否则用户会看到一个
      // "设置成功"却根本没生效的假象。
      final dir = Directory(target);
      if (!await _isWritable(dir, create: true)) {
        return currentDirPath;
      }
    }
    if (target == null || target.isEmpty) {
      await KvStore.instance.remove(customDirKey);
    } else {
      await KvStore.instance.setString(customDirKey, target);
    }
    // 切换的瞬间不能丢日志：先把队列里的内容落到旧目录。
    await _flush();
    await _reopen();
    return currentDirPath;
  }

  /// 重新解析目录并指向新的当天文件（切换自定义目录后调用）。
  ///
  /// 解析失败时**保留原来的目录**继续写日志——切换目录是用户主动的操作，
  /// 失败了就该原地不动，而不是把日志功能整个弄瘫。
  Future<void> _reopen() async {
    final prevDir = _dir;
    final prevToday = _today;
    _dir = null;
    _today = null;
    _broken = false;
    _fallbackNote = null;
    await init();
    if (_dir == null) {
      _dir = prevDir;
      _today = prevToday;
      _broken = false;
    }
  }

  /// 日志文件名：`baiji_20261013.log`。
  static String _fileName(DateTime d) {
    final stamp = '${d.year.toString().padLeft(4, '0')}'
        '${d.month.toString().padLeft(2, '0')}'
        '${d.day.toString().padLeft(2, '0')}';
    return 'baiji_$stamp.log';
  }

  File _fileFor(DateTime d) {
    return File('${_dir!.path}${Platform.pathSeparator}${_fileName(d)}');
  }

  /// 删除 [keepDays] 天之前的日志文件。
  ///
  /// **只删匹配 [baiji_YYYYMMDD.log] 的文件**，绝不整目录清空——用户可能把
  /// 日志目录指向 SD 卡根目录或某个装了一堆文件的文件夹，整目录删会误伤
  /// 别人的东西。正则只认本 App 的日志文件名，其它文件一律跳过。
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
