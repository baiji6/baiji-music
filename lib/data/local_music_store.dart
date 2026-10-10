import 'dart:convert';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/local/local_scanner.dart';
import 'package:baiji_music/models/models.dart';

/// 本地音乐库：歌曲清单、指纹索引、用户指定的扫描目录。
///
/// 三个键分工：
/// - `_keySongs`  完整歌曲列表（含元数据，供 UI 直接渲染）
/// - `_keyFp`     「路径 → 指纹」，增量扫描的依据
/// - `_keyDirs`   用户手动添加的目录（系统目录每次动态算，不落盘）
///
/// 之所以把指纹和歌曲分开存：扫描时要频繁比对指纹，而从完整歌曲里
/// 反序列化全部字段太浪费；指纹结构极简，读写都便宜。
class LocalMusicStore {
  static const _keySongs = 'local_songs';
  static const _keyFp = 'local_fingerprints';
  static const _keyDirs = 'local_scan_dirs';
  static const _keyScanned = 'local_has_scanned';

  // ---------- 歌曲清单 ----------

  static List<Song> songs() {
    final raw = KvStore.instance.getString(_keySongs);
    if (raw == null || raw.isEmpty) return [];
    try {
      final arr = jsonDecode(raw) as List<dynamic>;
      final out = <Song>[];
      for (final e in arr) {
        if (e is! Map<String, dynamic>) continue;
        final s = Song.fromJson(e);
        // 本地歌曲以文件路径为命脉，没有路径的一律丢弃
        if (s.localPath.isNotEmpty) out.add(s);
      }
      return out;
    } catch (e) {
      AppLog.w('LocalMusicStore', '歌曲清单解析失败: $e');
      return [];
    }
  }

  static Future<void> writeSongs(List<Song> list) =>
      KvStore.instance.setString(
        _keySongs,
        jsonEncode(list.map((s) => s.toJson()).toList()),
      );

  // ---------- 指纹索引 ----------

  static Map<String, LocalFingerprint> fingerprints() {
    final raw = KvStore.instance.getString(_keyFp);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, LocalFingerprint>{};
      map.forEach((k, v) {
        final fp = LocalFingerprint.fromJson(v);
        if (fp != null) out[k] = fp;
      });
      return out;
    } catch (e) {
      AppLog.w('LocalMusicStore', '指纹解析失败: $e');
      return {};
    }
  }

  static Future<void> writeFingerprints(Map<String, LocalFingerprint> map) =>
      KvStore.instance.setString(
        _keyFp,
        jsonEncode(map.map((k, v) => MapEntry(k, v.toJson()))),
      );

  /// 「路径 → 已有歌曲」，供扫描时复用未变动的条目。
  static Map<String, Song> songsByPath() {
    final out = <String, Song>{};
    for (final s in songs()) {
      out[s.localPath] = s;
    }
    return out;
  }

  /// 把任意歌曲列表转成「路径 → 歌曲」。
  ///
  /// 扫描结果还没落盘时（比如同一次会话里连续扫两次），用这个构造入参。
  static Map<String, Song> songsByPathFor(List<Song> list) => {
        for (final s in list) s.localPath: s,
      };

  /// 把任意歌曲列表转成「路径 → 指纹」。
  static Map<String, LocalFingerprint> fingerprintsFor(List<Song> list) => {
        for (final s in list)
          s.localPath: LocalFingerprint(s.localSize, s.localMtime),
      };

  // ---------- 扫描目录 ----------

  static List<String> customDirs() {
    final raw = KvStore.instance.getString(_keyDirs);
    if (raw == null || raw.isEmpty) return [];
    try {
      final arr = jsonDecode(raw) as List<dynamic>;
      return arr.whereType<String>().where((s) => s.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> writeCustomDirs(List<String> list) =>
      KvStore.instance.setString(_keyDirs, jsonEncode(list));

  /// 添加一个用户目录（去重）。
  static Future<void> addCustomDir(String path) async {
    if (path.isEmpty) return;
    final list = customDirs();
    if (list.contains(path)) return;
    list.add(path);
    await writeCustomDirs(list);
  }

  static Future<void> removeCustomDir(String path) async {
    final list = customDirs().where((p) => p != path).toList();
    await writeCustomDirs(list);
  }

  // ---------- 首次扫描标记 ----------

  /// 是否已经扫过一次（用于「首次自动扫」）。
  static bool hasScanned() => KvStore.instance.getBool(_keyScanned);

  static Future<void> markScanned() =>
      KvStore.instance.setBool(_keyScanned, true);

  // ---------- 组合操作 ----------

  /// 把扫描结果落盘。
  ///
  /// 这里**整体覆盖**而非合并：[LocalScanResult.songs] 已经是当前全部有效
  /// 歌曲（含指纹未变直接复用的），因此删除项天然不在其中，无需额外处理
  /// `missing`。合并反而会让上一次的残留数据在多次扫描后越积越多。
  ///
  /// 返回最终的歌曲列表。
  static Future<List<Song>> save(LocalScanResult result) async {
    final fp = <String, LocalFingerprint>{
      for (final s in result.songs)
        s.localPath: LocalFingerprint(s.localSize, s.localMtime),
    };

    await writeFingerprints(fp);
    await writeSongs(result.songs);
    await markScanned();
    return result.songs;
  }

  /// 清掉整个本地音乐库（含指纹与首次扫描标记）。
  static Future<void> clear() async {
    await KvStore.instance.remove(_keySongs);
    await KvStore.instance.remove(_keyFp);
    await KvStore.instance.remove(_keyScanned);
  }
}
