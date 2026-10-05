import 'dart:convert';

import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/models/models.dart';

/// 本地歌单存储（对应原生 `data/PlaylistStore.kt`，SharedPreferences 持久化）。
///
/// 支持：创建歌单、收藏歌曲、移除歌曲、删除歌单。
class PlaylistStore {
  static const _keyPlaylists = 'playlist_list';

  static List<Playlist> _readAll() {
    final raw = KvStore.instance.getString(_keyPlaylists);
    if (raw == null || raw.isEmpty) return [];
    try {
      final arr = jsonDecode(raw) as List<dynamic>;
      final out = <Playlist>[];
      for (final e in arr) {
        if (e is! Map<String, dynamic>) continue;
        final name = e['name'] as String?;
        if (name == null || name.isEmpty) continue;
        final pl = Playlist(name);
        final songs = e['songs'] as List<dynamic>? ?? [];
        for (final s in songs) {
          if (s is! Map<String, dynamic>) continue;
          final song = Song.fromJson(s);
          if (song.mid.isNotEmpty) pl.songs.add(song);
        }
        out.add(pl);
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static void _writeAll(List<Playlist> list) {
    final arr = list.map((pl) => {
          'name': pl.name,
          'songs': pl.songs.map((s) => s.toJson()).toList(),
        }).toList();
    KvStore.instance.setString(_keyPlaylists, jsonEncode(arr));
  }

  /// 歌单名称列表。
  static List<String> playlistNames() =>
      _readAll().map((pl) => pl.name).toList();

  /// 获取某歌单的歌曲。
  static List<Song> songsOf(String name) {
    for (final pl in _readAll()) {
      if (pl.name == name) return pl.songs;
    }
    return [];
  }

  /// 创建歌单，返回是否成功（已存在则失败）。
  static bool createPlaylist(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final list = _readAll();
    if (list.any((pl) => pl.name == trimmed)) return false;
    list.add(Playlist(trimmed));
    _writeAll(list);
    return true;
  }

  /// 删除歌单。
  static void deletePlaylist(String name) {
    final list = _readAll().where((pl) => pl.name != name).toList();
    _writeAll(list);
  }

  /// 收藏歌曲到歌单，返回是否成功（已存在则失败）。
  static bool addSong(String playlist, Song song) {
    final list = _readAll();
    Playlist? target;
    for (final pl in list) {
      if (pl.name == playlist) {
        target = pl;
        break;
      }
    }
    if (target == null) return false;
    if (target.songs.any((s) => s.mid == song.mid)) return false;
    target.songs.add(song);
    _writeAll(list);
    return true;
  }

  /// 从歌单移除歌曲。
  static void removeSong(String playlist, String songMid) {
    final list = _readAll();
    for (final pl in list) {
      if (pl.name == playlist) {
        pl.songs.removeWhere((s) => s.mid == songMid);
        break;
      }
    }
    _writeAll(list);
  }
}

/// 歌单对象。
class Playlist {
  final String name;
  final List<Song> songs;

  Playlist(this.name, {List<Song>? songs}) : songs = songs ?? [];
}