import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';
import 'kv_store.dart';

/// 一项缓存的占用明细。
class CacheEntry {
  const CacheEntry(this.label, this.bytes, {this.detail = ''});

  final String label;
  final int bytes;
  final String detail;

  String get readable => CacheManager.formatBytes(bytes);
}

/// 缓存管理：统一缓存目录 + 占用统计 + 清理。
///
/// ## 现状说明（别被「清理图片缓存」误导）
///
/// App 里封面用的是 `Image.network`，走的是 Flutter 内置的内存 [ImageCache]，
/// **并不落盘**（工程里虽然有 `cached_network_image` 依赖，但没有任何地方在用）。
/// 所以真正能被"清理"的是这三样：
/// - 内存图片缓存（`PaintingBinding.imageCache`，默认上限 100 MB）；
/// - 缓存目录下的临时文件（日志导出、图片落盘缓存等）；
/// - 本地歌曲封面的内存缓存。
///
/// 把内存缓存做成「可清理 + 可自定义上限」比伪造一个磁盘缓存目录更有意义。
class CacheManager {
  CacheManager._();

  static const String _prefs = 'cache';
  static const String _kRoot = 'root_dir';
  static const String _kMemoryLimitMb = 'memory_limit_mb';

  /// 应用在缓存目录下的子目录名。
  static const String imagesDirName = 'images';
  static const String miscDirName = 'misc';

  static String? _runtimeRoot;

  /// 用户自定义的缓存目录；为空表示用系统默认。
  static String get customRoot =>
      KvStore.instance.getString('$_prefs:$_kRoot') ?? '';

  /// 自定义目录的标记文件。目录里没有它就说明不是我们建的缓存目录，
  /// 拒绝使用——否则用户误选了「文档」这类目录，一次「清理缓存」就把
  /// 整个目录连根拔起了。
  static const String _kMarker = '.baiji_cache';

  static Future<void> setCustomRoot(String? path) async {
    if (path == null || path.trim().isEmpty) {
      await KvStore.instance.remove('$_prefs:$_kRoot');
      _runtimeRoot = null;
    } else {
      final dir = Directory(path.trim());
      await dir.create(recursive: true);
      final marker = File(
          '${dir.path}${Platform.pathSeparator}$_kMarker');
      if (!await marker.exists()) {
        // 只在空目录里写标记；目录里已有其它文件说明用户选错了地方
        var entries = 0;
        try {
          await for (final _ in dir.list(followLinks: false)) {
            if (++entries >= 1) break;
          }
        } catch (_) {}
        if (entries > 0) {
          throw StateError(
              '所选目录里已有其它文件，为避免误删请改选一个空目录或新建目录');
        }
        await marker.writeAsString('baiji music cache');
      }
      await KvStore.instance.setString('$_prefs:$_kRoot', dir.path);
      _runtimeRoot = dir.path;
    }
    AppLog.i('CacheManager', '缓存目录已设为 ${await cacheRoot()}');
  }

  /// 当前生效的缓存根目录。自定义目录不存在时自动退回默认目录，
  /// 免得用户把目录删了之后整个 App 的缓存读写全崩。
  static Future<Directory> cacheRoot() async {
    final custom = _runtimeRoot ?? customRoot;
    if (custom.isNotEmpty) {
      final dir = Directory(custom);
      if (await dir.exists()) return dir;
      AppLog.w('CacheManager', '自定义缓存目录不存在，改用默认目录: $custom');
    }
    final dir = await getApplicationCacheDirectory();
    return Directory('${dir.path}${Platform.pathSeparator}$_prefs');
  }

  /// 在缓存目录下取一个子目录，不存在则创建。
  static Future<Directory> subDir(String name) async {
    final root = await cacheRoot();
    final dir = Directory(
        '${root.path}${Platform.pathSeparator}$name');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 缓存目录下的一个文件路径（不保证存在）。
  static Future<File> cacheFile(String name) async =>
      File('${(await subDir(miscDirName)).path}${Platform.pathSeparator}$name');

  /// 内存图片缓存上限（MB）。
  static int get memoryLimitMb {
    final v = KvStore.instance.getInt('$_prefs:$_kMemoryLimitMb', def: 100);
    return v.clamp(16, 1024);
  }

  static Future<void> setMemoryLimitMb(int mb) =>
      KvStore.instance.setInt('$_prefs:$_kMemoryLimitMb', mb.clamp(16, 1024));

  /// 把内存图片缓存上限应用到当前进程（重启后失效，所以每次启动都要设一次）。
  static void applyMemoryLimit() {
    PaintingBinding.instance.imageCache.maximumSize = memoryLimitMb * 1024 * 1024;
  }

  /// 递归统计目录占用；目录不存在返回 0。
  static Future<int> dirSize(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {
            // 文件正被占用 / 已删除，跳过
          }
        }
      }
    } catch (_) {
      // 权限不足等
    }
    return total;
  }

  /// 各类缓存占用明细。
  static Future<List<CacheEntry>> breakdown() async {
    final out = <CacheEntry>[];

    final cache = PaintingBinding.instance.imageCache;
    final live = cache.liveImageCount;
    out.add(CacheEntry(
      '内存图片缓存',
      cache.currentSizeBytes,
      detail: '$live 张在用 / 上限 $memoryLimitMb MB',
    ));

    final root = await cacheRoot();
    var cacheBytes = 0;
    for (final name in [imagesDirName, miscDirName]) {
      cacheBytes += await dirSize(
          Directory('${root.path}${Platform.pathSeparator}$name'));
    }
    out.add(CacheEntry('缓存目录（临时文件）', cacheBytes,
        detail: '${root.path}（只统计 images/与 misc/）'));

    try {
      final tmp = await getTemporaryDirectory();
      out.add(CacheEntry('系统临时目录', await dirSize(tmp), detail: tmp.path));
    } catch (e) {
      AppLog.w('CacheManager', '读取临时目录失败: $e');
    }

    return out;
  }

  static Future<int> totalBytes() async {
    var sum = 0;
    for (final e in await breakdown()) {
      sum += e.bytes;
    }
    return sum;
  }

  /// 清理缓存。
  ///
  /// **不碰**下载目录、历史记录、歌单与本地音乐库——那些是用户数据不是缓存。
  /// 内存图片缓存会被整个清空，当前正在显示的封面会重新加载一次。
  ///
  /// 注意本地歌曲封面另有一份独立的字节缓存（`LocalCoverCache`，在 ui 层，
  /// 200 条上限），由设置页在调用本方法后一并清掉——core 不反向依赖 ui。
  static Future<int> clear() async {
    var freed = 0;

    // 整个内存缓存清空：正在显示的封面会闪一下并重新请求一次
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();

    final root = await cacheRoot();
    // 只删App 自己建的这两个子目录，不碰根目录下用户可能自己放的东西
    for (final name in [imagesDirName, miscDirName]) {
      final dir = Directory('${root.path}${Platform.pathSeparator}$name');
      freed += await _emptyDir(dir);
    }
    //系统临时目录只统计、绝不删除：桌面端 getTemporaryDirectory() 返回的是
    // 系统共享目录（Linux /tmp、macOS /var/folders/...、Windows %TEMP%），
    // 递归删它会波及同机其它应用正在用的文件，Linux 上还会影响其他用户。

    AppLog.i('CacheManager', '缓存已清理，释放约 ${formatBytes(freed)}');
    return freed;
  }

  /// 清空目录内容但保留目录本身。返回释放的字节数。
  static Future<int> _emptyDir(Directory dir) async {
    if (!await dir.exists()) return 0;
    var freed = 0;
    try {
      await for (final e in dir.list(followLinks: false)) {
        try {
          if (e is File) {
            freed += await e.length();
            await e.delete();
          } else if (e is Directory) {
            freed += await dirSize(e);
            await e.delete(recursive: true);
          }
        } catch (_) {
          // 单个文件删不掉（占用中）不影响其它
        }
      }
    } catch (_) {}
    return freed;
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    final s = v >= 100 || i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '$s ${units[i]}';
  }
}