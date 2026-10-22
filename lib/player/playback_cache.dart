// 歌曲播放缓存（磁盘）—— v2.4.0-fix2 新增。
//
// ## 为什么需要它
//
// libmpv 自带 `--cache` / `--cache-on-disk`（media_kit 两者都默认打开），
// 但**在本项目的用法下它不落盘**：实测 mpv 0.37 + 可 Seek 的 HTTP 流，
// `~/.cache/mpv` 目录会被创建却始终是空的，已下载的数据全留在内存里
// （`Cache: 3.2s/31KB` 一路到播完）。于是「清理缓存」对播放缓存
// 完全无能为力——用户点了没反应。
//
// 另外 media_kit 的 `PlayerConfiguration` 不暴露 `cache-dir`，
// `NativePlayer._create()` 的 options 表是硬编码的，外部无法在
// `mpv_initialize()` 之前改缓存目录；所以「让 libmpv 把缓存写到我们
// 托管的位置」这条路走不通，只能自己做一份。
//
// ## 设计
//
// - **块对齐**：粒度 256 KiB，按 `offset ~/ blockSize` 分块。播放器的
//   Range 请求边界和 CDN 的分块边界都不固定，只有按固定粒度对齐，
//   任意区间请求才可能命中。
// - **原子写**：先写 `.tmp` 再 rename，并发请求不会读到半块。
// - **总量上限**：默认 512 MB，超限按 mtime 从旧到新淘汰（LRU 近似）。
// - **永不抛异常**：缓存是纯优化，任何 IO 失败都静默降级为「未命中」，
//   不能反过来变成播放失败的根因。
//
// ## 目录
//
// `<缓存根目录>/playback/<trackKey>/<块号>.blk`，由 [CacheManager]
// 统一托管（`playback` 已进 `managedDirNames`），「清理缓存」会连它
// 一起清空，占用也会出现在明细里。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core/app_logger.dart';
import '../core/cache_manager.dart';

/// 歌曲播放缓存（进程内单例）。
class PlaybackCache {
  PlaybackCache._();

  static final PlaybackCache instance = PlaybackCache._();

  /// 块大小（字节）。
  ///
  /// 256 KiB：mpv 一次 Range 请求通常正好 1~2 块；太小块数爆炸、
  /// 目录项太多，太大命中率低。
  static const int blockSize = 256 * 1024;

  /// 缓存总量上限（字节）。超限按 mtime 从旧到新淘汰。
  static const int limitBytes = 512 * 1024 * 1024;

  static const String _tag = 'PlaybackCache';

  Directory? _dir;

  /// 缓存目录（不存在则创建）。失败时返回 null，调用方按「未命中」处理。
  Future<Directory?> _ensureDir() async {
    if (_dir != null) return _dir;
    try {
      _dir = await CacheManager.subDir(CacheManager.playbackDirName);
      return _dir;
    } catch (e) {
      AppLog.w(_tag, '缓存目录不可用: $e');
      return null;
    }
  }

  /// 由远端地址（或 ekey）派生稳定的目录名。
  ///
  /// 只取内容寻址用的摘要，不把可能很长的 URL 直接当目录名。
  static String keyOf(String seed) {
    final s = seed.trim();
    if (s.isEmpty) return '';
    return sha1.convert(utf8.encode(s)).toString();
  }

  static int blockIndexOf(int offset) => offset ~/ blockSize;

  static int blockStart(int index) => index * blockSize;

  String _blockPath(Directory dir, String key, int index) =>
      '${dir.path}${Platform.pathSeparator}$key${Platform.pathSeparator}$index.blk';

  /// 读一个块的明文。未命中 / 读失败返回 null。
  Future<Uint8List?> read(String key, int index) async {
    if (key.isEmpty || index < 0) return null;
    final dir = await _ensureDir();
    if (dir == null) return null;
    try {
      final f = File(_blockPath(dir, key, index));
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return null;
      // 命中后顺手刷新 mtime，让淘汰顺序接近真正的 LRU
      try {
        await f.setLastModified(DateTime.now());
      } catch (_) {}
      return bytes;
    } catch (e) {
      AppLog.w(_tag, '读取块失败 key=$key idx=$index: $e');
      return null;
    }
  }

  /// 写一个块的明文。原子写（tmp + rename），失败静默。
  Future<void> write(String key, int index, Uint8List data) async {
    if (key.isEmpty || index < 0 || data.isEmpty) return;
    final dir = await _ensureDir();
    if (dir == null) return;
    final target = File(_blockPath(dir, key, index));
    final tmp = File('${target.path}.tmp');
    try {
      await target.parent.create(recursive: true);
      await tmp.writeAsBytes(data, flush: true);
      await tmp.rename(target.path);
    } catch (e) {
      AppLog.w(_tag, '写入块失败 key=$key idx=$index: $e');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return;
    }
    unawaited(_evictIfNeeded());
  }

  /// 当前占用（字节）。
  Future<int> sizeBytes() async {
    final dir = await _ensureDir();
    if (dir == null) return 0;
    return CacheManager.dirSize(dir);
  }

  /// 清空整个播放缓存。
  Future<int> clear() async {
    final dir = await _ensureDir();
    if (dir == null) return 0;
    return CacheManager.emptyDir(dir);
  }

  /// 超限时按 mtime 从旧到新删块文件，直到低于上限或没有可删的。
  Future<void> _evictIfNeeded() async {
    try {
      final dir = await _ensureDir();
      if (dir == null) return;
      final files = <File>[];
      var total = 0;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          final len = await e.length();
          total += len;
          files.add(e);
        }
      }
      if (total <= limitBytes) return;
      // mtime 旧的先删
      files.sort((a, b) {
        final ta = a.lastModifiedSync();
        final tb = b.lastModifiedSync();
        return ta.compareTo(tb);
      });
      var freed = 0;
      for (final f in files) {
        if (total - freed <= limitBytes * 0.9) break;
        final len = await f.length();
        try {
          await f.delete();
        } catch (_) {}
        freed += len;
      }
      if (freed > 0) {
        AppLog.i(_tag, '淘汰旧缓存 ${CacheManager.formatBytes(freed)}');
      }
    } catch (e) {
      AppLog.w(_tag, '淘汰失败: $e');
    }
  }
}
