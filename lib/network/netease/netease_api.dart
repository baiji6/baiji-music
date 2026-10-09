import 'dart:convert';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/cover_url.dart';
import 'package:baiji_music/models/models.dart';

import 'netease_client.dart';
import 'netease_crypto.dart';

/// 网易云业务接口：搜索、歌曲详情、取流、歌词、专辑、歌单、封面。
///
/// 对应原生 `network/netease/NeteaseApi.kt`（Python 参考实现 Netease_url 逐接口移植）。
/// 取流结果。
class NeteaseUrl {
  final String url;
  final String ext;
  final String level;
  final int size;
  final int br;

  const NeteaseUrl(this.url, this.ext, this.level, this.size, this.br);

  bool isUsable() => url.isNotEmpty;
}

class NeteaseApi {
  NeteaseApi(this.client);

  final NeteaseClient client;

  // ================= 搜索 =================

  /// 关键词搜索歌曲。
  Future<List<Song>> search(String keyword,
      {int limit = 30, int offset = 0}) async {
    final form = <String, String>{
      's': keyword,
      'type': '1',
      'limit': '$limit',
      'offset': '$offset',
      'total': 'true',
      'csrf_token': '',
    };
    AppLog.i('NeteaseApi', '网易云搜索 keyword=$keyword limit=$limit offset=$offset');
    final json = await client.postApi('${NeteaseClient.apiBase}/cloudsearch/pc', form);
    final songs = (json['result'] as Map<String, dynamic>?)?['songs'] as List<dynamic>?;
    final result = <Song>[];
    if (songs != null) {
      for (final item in songs) {
        final s = toSong(item is Map<String, dynamic> ? item : {});
        if (s != null) result.add(s);
      }
    }
    AppLog.i('NeteaseApi', '网易云搜索结果 keyword=$keyword 命中=${result.length}');
    return result;
  }

  /// 搜索补全建议（歌手名与歌名）。
  Future<List<String>> suggestions(String keyword, {int limit = 8}) async {
    final form = <String, String>{
      's': keyword,
      'limit': '$limit',
      'csrf_token': '',
    };
    final json = await client.postApi('${NeteaseClient.apiBase}/search/suggest/web', form);
    final result = json['result'];
    if (result is! Map<String, dynamic>) return const [];

    final out = <String>{};
    final artists = result['artists'] as List<dynamic>?;
    if (artists != null) {
      for (final item in artists) {
        if (item is Map<String, dynamic>) {
          final n = (item['name'] as String? ?? '').trim();
          if (n.isNotEmpty) out.add(n);
        }
      }
    }
    final songs = result['songs'] as List<dynamic>?;
    if (songs != null) {
      for (final item in songs) {
        if (item is! Map<String, dynamic>) continue;
        final n = (item['name'] as String? ?? '').trim();
        if (n.isEmpty) continue;
        final singer =
            ((item['artists'] as List<dynamic>?)?[0] as Map<String, dynamic>?)?['name']
                    as String? ??
                '';
        out.add(singer.trim().isEmpty ? n : '$singer $n');
      }
    }
    AppLog.i('NeteaseApi', '网易云相关搜索 keyword=$keyword 命中=${out.length}');
    return out.take(limit).toList();
  }

  // ================= 详情 =================

  /// 批量歌曲详情，映射为 [Song]。
  Future<List<Song>> songDetailSongs(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final arr = ids.map((id) => {'id': id, 'v': 0}).toList();
    final json = await client.postApi(
      '${NeteaseClient.apiBase}/v3/song/detail',
      {'c': jsonEncode(arr)},
    );
    final songs = json['songs'] as List<dynamic>?;
    if (songs == null) return const [];
    final result = <Song>[];
    for (final item in songs) {
      final s = toSong(item is Map<String, dynamic> ? item : {});
      if (s != null) result.add(s);
    }
    return result;
  }

  // ================= 取流 =================

  /// 获取指定音质的播放直链（EAPI /eapi/song/enhance/player/url/v1）。
  Future<NeteaseUrl> songUrl(int id, NeteaseQuality quality) async {
    final header = <String, dynamic>{
      'os': 'pc',
      'appver': '',
      'osver': '',
      'deviceId': 'pyncm!',
      'requestId': '${(20000000 + DateTime.now().microsecondsSinceEpoch % 10000000)}',
    };
    final payload = <String, dynamic>{
      'ids': [id],
      'level': quality.level,
      'encodeType': quality == NeteaseQuality.dolby ? 'mp4' : 'flac',
      'header': jsonEncode(header),
    };
    if (quality == NeteaseQuality.sky) {
      payload['immerseType'] = 'c51';
    }
    AppLog.d('NeteaseApi', '网易云取流 id=$id quality=${quality.level}(${quality.label})');
    final json = await client.postEapi(
        '${NeteaseClient.eapiBase}/song/enhance/player/url/v1', payload);
    if ((json['code'] as int? ?? -1) != 200) {
      throw Exception('网易云取流失败: code=${json['code']} msg=${json['message']}');
    }
    final data = json['data'] as List<dynamic>?;
    if (data == null || data.isEmpty) {
      return NeteaseUrl('', quality.ext, quality.level, 0, 0);
    }
    final item = data[0] is Map<String, dynamic> ? data[0] as Map<String, dynamic> : const <String, dynamic>{};
    final url = item['url'] as String? ?? '';
    final type = item['type'] as String? ?? '';
    final ext = type.isNotEmpty ? '.$type' : quality.ext;
    final actualLevel = (item['level'] as String? ?? '').isNotEmpty
        ? item['level'] as String
        : quality.level;
    AppLog.d('NeteaseApi',
        '网易云取流返回 level=$actualLevel type=$type br=${item['br']} url_empty=${url.isEmpty}');
    return NeteaseUrl(
      url,
      ext,
      actualLevel,
      (item['size'] as int?) ?? 0,
      (item['br'] as int?) ?? 0,
    );
  }

  // ================= 歌词 =================

  /// 获取歌词（原文，无则返回翻译）。
  Future<String> lyric(int id) async {
    final form = <String, String>{
      'id': '$id',
      'cp': 'false',
      'tv': '0',
      'lv': '-1',
      'rv': '0',
      'kv': '-1',
      'yv': '0',
      'ytv': '0',
      'yrv': '0',
    };
    final json = await client.postApi('${NeteaseClient.apiBase}/song/lyric', form);
    final lrc = (json['lrc'] as Map<String, dynamic>?)?['lyric'] as String? ?? '';
    if (lrc.isNotEmpty) return lrc;
    return (json['tlyric'] as Map<String, dynamic>?)?['lyric'] as String? ?? '';
  }

  // ================= 歌单 / 专辑 =================

  /// 歌单详情中的歌曲列表。
  Future<List<Song>> playlistDetail(int playlistId) async {
    final json = await client.postApi(
      '${NeteaseClient.apiBase}/v6/playlist/detail',
      {'id': '$playlistId', 'n': '100000', 's': '0'},
    );
    final playlist = json['playlist'];
    if (playlist is! Map<String, dynamic>) return const [];
    final tracks = playlist['tracks'] as List<dynamic>?;
    if (tracks == null) return const [];
    final result = <Song>[];
    for (final item in tracks) {
      final s = toSong(item is Map<String, dynamic> ? item : {});
      if (s != null) result.add(s);
    }
    return result;
  }

  /// 专辑详情中的歌曲列表。
  Future<List<Song>> albumDetail(int albumId) async {
    final json = await client.getApi('${NeteaseClient.apiBase}/v1/album/$albumId');
    final album = json['album'];
    final albumName = (album is Map<String, dynamic>)
        ? (album['name'] as String? ?? '')
        : '';
    final picId = (album is Map<String, dynamic>)
        ? ((album['pic'] as num?)?.toInt() ?? 0)
        : 0;
    final albumCover = NeteaseCrypto.picUrl(picId);
    final songs = json['songs'] as List<dynamic>?;
    if (songs == null) return const [];
    final result = <Song>[];
    for (final item in songs) {
      if (item is! Map<String, dynamic>) continue;
      final song = toSong(item);
      if (song == null) continue;
      // 专辑接口的歌曲可能缺少专辑信息，补齐
      if (song.album.isEmpty) {
        result.add(Song(
          mid: song.mid,
          songId: song.songId,
          name: song.name,
          singer: song.singer,
          album: albumName,
          albumMid: song.albumMid,
          duration: song.duration,
          cover: song.cover.isEmpty ? albumCover : song.cover,
          source: song.source,
        ));
      } else {
        result.add(song);
      }
    }
    return result;
  }

  // ================= 映射 =================

  /// 网易云接口 JSON → 通用 [Song]（mid 前缀 ne 区分来源）。
  Song? toSong(Map<String, dynamic> o) {
    final id = (o['id'] as num?)?.toInt() ?? 0;
    if (id == 0) return null;

    final name = o['name'] as String? ?? '';
    final ar = o['ar'] as List<dynamic>? ?? o['artists'] as List<dynamic>?;
    final singer = _buildSinger(ar);

    final al = o['al'];
    final alMap = al is Map<String, dynamic> ? al : (o['album'] is Map<String, dynamic> ? o['album'] as Map<String, dynamic> : null);
    final album = alMap?['name'] as String? ?? '';
    final picId = (alMap?['pic'] as num?)?.toInt() ?? 0;
    final picUrl = alMap?['picUrl'] as String? ?? '';
    // 封面取最大档：picUrl 不带 param 时补上 3000（CDN 会截断到原图上限）
    final cover = picUrl.isNotEmpty
        ? CoverUrl.maximize(picUrl)
        : NeteaseCrypto.picUrl(picId);

    var duration = (o['dt'] as num?)?.toInt() ?? 0;
    if (duration <= 0) duration = (o['duration'] as num?)?.toInt() ?? 0;

    return Song(
      mid: 'ne$id',
      songId: id,
      name: name,
      singer: singer,
      album: album,
      albumMid: '',
      duration: duration,
      cover: cover,
      source: Source.netease,
    );
  }

  String _buildSinger(List<dynamic>? arr) {
    if (arr == null || arr.isEmpty) return '';
    final names = <String>[];
    for (final item in arr) {
      if (item is Map<String, dynamic>) {
        final n = item['name'] as String? ?? '';
        if (n.isNotEmpty) names.add(n);
      }
    }
    return names.join(' / ');
  }
}