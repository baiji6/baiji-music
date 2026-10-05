import 'dart:convert';

import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/models/models.dart';

/// 本地历史存储：播放历史 与 搜索历史。
///
/// 对应原生 `data/HistoryStore.kt`，使用 SharedPreferences 持久化，重启不清空。
class HistoryStore {
  static const _keySearch = 'search_history';
  static const _keyPlay = 'play_history';
  static const _max = 30;

  // ---------- 搜索历史 ----------

  static List<String> searchHistory() {
    final raw = KvStore.instance.getString(_keySearch);
    if (raw == null || raw.isEmpty) return [];
    try {
      final arr = jsonDecode(raw) as List<dynamic>;
      return arr.whereType<String>().where((s) => s.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  static void writeSearch(List<String> list) {
    KvStore.instance
        .setString(_keySearch, jsonEncode(list.take(_max).toList()));
  }

  /// 记录一次搜索，最新在前，去重。
  static void addSearch(String keyword) {
    final k = keyword.trim();
    if (k.isEmpty) return;
    final list = searchHistory().where((it) => it != k).toList();
    list.insert(0, k);
    writeSearch(list);
  }

  /// 记录一次搜索，但专用于开头搜索（避免重复记录）。返回是否新增。
  static bool addSearchIfNew(String keyword) {
    final k = keyword.trim();
    if (k.isEmpty) return false;
    if (searchHistory().any((it) => it == k)) return false;
    addSearch(k);
    return true;
  }

  static void clearSearch() => KvStore.instance.remove(_keySearch);

  // ---------- 播放历史 ----------

  static List<Song> playHistory() {
    final raw = KvStore.instance.getString(_keyPlay);
    if (raw == null || raw.isEmpty) return [];
    try {
      final arr = jsonDecode(raw) as List<dynamic>;
      final out = <Song>[];
      for (final e in arr) {
        if (e is! Map<String, dynamic>) continue;
        final s = Song.fromJson(e);
        if (s.mid.isNotEmpty) out.add(s);
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static void writePlay(List<Song> list) {
    KvStore.instance
        .setString(_keyPlay, jsonEncode(list.take(_max).map((s) => s.toJson()).toList()));
  }

  /// 记录一次播放，最新在前，同 mid 去重。
  static void addPlay(Song song) {
    if (song.mid.isEmpty) return;
    final list = playHistory().where((it) => it.mid != song.mid).toList();
    list.insert(0, song);
    writePlay(list);
  }

  static void clearPlay() => KvStore.instance.remove(_keyPlay);
}