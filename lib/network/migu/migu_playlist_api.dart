// 咪咕音乐 —— 歌单 / 推荐（v2.6.0，移植洛雪 LX-X `musicSdk/mg/songList.js`）。
//
// 端点（均已实测，官方公开接口，无需签名 / 登录）：
//   标签       GET app.c.nf.migu.cn/pc/v1.0/template/musiclistplaza-taglist/release
//   推荐歌单   GET app.c.nf.migu.cn/pc/bmw/page-data/playlist-square-recommend/v1.0
//   标签歌单   GET app.c.nf.migu.cn/pc/v1.0/template/musiclistplaza-listbytag/release
//   歌单歌曲   GET app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0
//   歌单元信息 GET c.musicapp.migu.cn/MIGUM3.0/resource/playlist/v2.0
//
// 解析逻辑均为纯函数（parseTags / parsePlaylists / parseSongs / parseMeta），
// 离线单测喂真实 JSON 片段即可，不依赖网络。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/app_logger.dart';
import '../../network/hot_search_api.dart' show HotPlaylist;
import 'migu_api.dart' show MiguSong;
import 'migu_crypto.dart' show miguPlaylistHeaders;

/// 一个咪咕歌单标签。
class MiguTag {
  final String id;
  final String name;
  const MiguTag(this.id, this.name);
}

/// 一个咪咕歌单摘要（推荐 / 标签列表共用）。
class MiguPlaylist {
  final String id;
  final String name;
  final String cover;
  final String desc;
  final String playCount;
  const MiguPlaylist({
    required this.id,
    required this.name,
    this.cover = '',
    this.desc = '',
    this.playCount = '',
  });
}

/// 歌单元信息。
class MiguPlaylistMeta {
  final String name;
  final String cover;
  final String desc;
  final String creator;
  final String playCount;
  const MiguPlaylistMeta({
    required this.name,
    this.cover = '',
    this.desc = '',
    this.creator = '',
    this.playCount = '',
  });
}

class MiguPlaylistApi {
  MiguPlaylistApi._();

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  static const String _successCode = '000000';

  static Future<Map> _getJson(String url) async {
    final resp =
        await _dio.get<dynamic>(url, options: Options(headers: miguPlaylistHeaders()));
    final body = resp.data;
    if (body is Map) return body;
    if (body is String && body.isNotEmpty) {
      try {
        return jsonDecode(body) as Map;
      } catch (_) {
        return const {};
      }
    }
    return const {};
  }

  /// 标签列表（分组：第一组热门，其余分类）。返回摊平后的 [MiguTag]。
  static Future<List<MiguTag>> tags() async {
    const url =
        'https://app.c.nf.migu.cn/pc/v1.0/template/musiclistplaza-taglist/release';
    try {
      final data = await _getJson(url);
      if (_str(data['code']) != _successCode) return const [];
      return parseTags(data['data']);
    } catch (e) {
      AppLog.w('MiguPlaylist', '标签获取失败: $e');
      return const [];
    }
  }

  /// 解析标签（纯函数）。每个条目 `texts: [name, id]`。
  static List<MiguTag> parseTags(dynamic raw) {
    final groups = raw is List ? raw : const [];
    final out = <MiguTag>[];
    for (final g in groups) {
      if (g is! Map) continue;
      final contents = g['content'];
      if (contents is! List) continue;
      for (final c in contents) {
        if (c is! Map) continue;
        final texts = c['texts'];
        if (texts is List && texts.length >= 2) {
          out.add(MiguTag(texts[1].toString(), texts[0].toString()));
        }
      }
    }
    return out;
  }

  /// 推荐歌单（同时也用于热搜词）。
  static Future<List<MiguPlaylist>> recommend({int page = 1}) async {
    final url =
        'https://app.c.nf.migu.cn/pc/bmw/page-data/playlist-square-recommend/v1.0'
        '?templateVersion=2&pageNo=$page';
    try {
      final data = await _getJson(url);
      if (_str(data['code']) != _successCode) return const [];
      return parsePlaylists(data['data']);
    } catch (e) {
      AppLog.w('MiguPlaylist', '推荐歌单失败: $e');
      return const [];
    }
  }

  /// 按标签取歌单。
  static Future<List<MiguPlaylist>> byTag(String tagId, {int page = 1}) async {
    final url =
        'https://app.c.nf.migu.cn/pc/v1.0/template/musiclistplaza-listbytag/release'
        '?pageNumber=$page&templateVersion=2&tagId=${Uri.encodeComponent(tagId)}';
    try {
      final data = await _getJson(url);
      if (_str(data['code']) != _successCode) return const [];
      return parsePlaylists(data['data']);
    } catch (e) {
      AppLog.w('MiguPlaylist', '标签歌单失败 tagId=$tagId: $e');
      return const [];
    }
  }

  /// 解析歌单列表（纯函数）。
  ///
  /// 推荐接口返回 `data.contents`（`resType=='2021'` 的有效项：resId/txt/img/txt2），
  /// 标签接口返回 `data.contentItemList[1].itemList`（logEvent.contentId/title/imageUrl）。
  static List<MiguPlaylist> parsePlaylists(dynamic raw) {
    if (raw is! Map) return const [];
    final out = <MiguPlaylist>[];
    final contents = raw['contents'];
    if (contents is List) {
      _collectPlaylistsRecursive(contents, out);
      if (out.isNotEmpty) return out;
    }
    final groups = raw['contentItemList'];
    if (groups is List && groups.length >= 2) {
      final g = groups[1];
      if (g is Map) {
        final items = g['itemList'];
        if (items is List) {
          for (final item in items) {
            if (item is! Map) continue;
            final logEvent = item['logEvent'];
            final id = logEvent is Map ? _str(logEvent['contentId']) : '';
            if (id.isEmpty) continue;
            out.add(MiguPlaylist(
              id: id,
              name: _str(item['title']),
              cover: _https(_str(item['imageUrl'])),
              playCount: _playCountText(item['barList']),
            ));
          }
        }
      }
    }
    return out;
  }

  static void _collectPlaylistsRecursive(List list, List<MiguPlaylist> out) {
    final seen = <String>{};
    void walk(List nodes) {
      for (final n in nodes) {
        if (n is! Map) continue;
        final nested = n['contents'];
        if (nested is List) {
          walk(nested);
          continue;
        }
        if (_str(n['resType']) != '2021') continue;
        final id = _str(n['resId']);
        if (id.isEmpty || seen.contains(id)) continue;
        seen.add(id);
        out.add(MiguPlaylist(
          id: id,
          name: _str(n['txt']),
          cover: _https(_str(n['img'])),
          desc: _str(n['txt2']),
        ));
      }
    }
    walk(list);
  }

  static String _playCountText(dynamic barList) {
    if (barList is! List || barList.isEmpty) return '';
    final first = barList.first;
    return first is Map ? _str(first['title']) : '';
  }

  /// 歌单歌曲列表（分页）。
  static Future<List<MiguSong>> playlistSongs(String id, {int page = 1}) async {
    final url =
        'https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0'
        '?pageNo=$page&pageSize=50&playlistId=${Uri.encodeComponent(id)}';
    try {
      final data = await _getJson(url);
      if (_str(data['code']) != _successCode) return const [];
      return parseSongs(data['data']);
    } catch (e) {
      AppLog.w('MiguPlaylist', '歌单歌曲失败 id=$id: $e');
      return const [];
    }
  }

  /// 解析歌单歌曲（纯函数）。字段与搜索的 filterMusicInfoListV5 同型
  /// （songId / singerList / album / albumId / duration / img1~3 / lrcUrl…）。
  static List<MiguSong> parseSongs(dynamic raw) {
    if (raw is! Map) return const [];
    final list = raw['songList'];
    if (list is! List) return const [];
    final out = <MiguSong>[];
    final seen = <String>{};
    for (final item in list) {
      if (item is! Map) continue;
      final songId = _str(item['songId']);
      if (songId.isEmpty || seen.contains(songId)) continue;
      seen.add(songId);
      final singers = item['singerList'];
      final singer = singers is List
          ? singers.whereType<Map>().map((m) => _str(m['name']))
              .where((s) => s.isNotEmpty).join('、')
          : '';
      String? cover;
      for (final k in ['img3', 'img2', 'img1']) {
        final v = item[k];
        if (v is String && v.isNotEmpty) {
          cover = v;
          break;
        }
      }
      out.add(MiguSong(
        songId: songId,
        copyrightId: _str(item['copyrightId']),
        albumId: _str(item['albumId']),
        name: _str(item['songName']).isNotEmpty
            ? _str(item['songName'])
            : _str(item['name']),
        singer: singer,
        album: _str(item['album']),
        durationSeconds: int.tryParse(_str(item['duration'])) ?? 0,
        mvId: _str(item['mvId']),
        cover: cover != null ? _https(cover) : '',
        lrcUrl: _str(item['lrcUrl']),
        mrcUrl: _str(item['mrcUrl']),
        trcUrl: _str(item['trcUrl']),
      ));
    }
    return out;
  }

  /// 歌单元信息。
  static Future<MiguPlaylistMeta?> playlistMeta(String id) async {
    final url =
        'https://c.musicapp.migu.cn/MIGUM3.0/resource/playlist/v2.0'
        '?playlistId=${Uri.encodeComponent(id)}';
    try {
      final data = await _getJson(url);
      if (_str(data['code']) != _successCode) return null;
      return parseMeta(data['data']);
    } catch (e) {
      AppLog.w('MiguPlaylist', '歌单元信息失败 id=$id: $e');
      return null;
    }
  }

  /// 解析元信息（纯函数）。
  static MiguPlaylistMeta? parseMeta(dynamic raw) {
    if (raw is! Map) return null;
    final img = raw['imgItem'];
    final op = raw['opNumItem'];
    return MiguPlaylistMeta(
      name: _str(raw['title']),
      cover: img is Map ? _https(_str(img['img'])) : '',
      desc: _str(raw['summary']),
      creator: _str(raw['ownerName']),
      playCount: op is Map ? _str(op['playNum']) : '',
    );
  }

  /// 推荐歌单 → 热门歌单摘要（供发现页 / 热搜复用）。
  static List<HotPlaylist> toHotPlaylists(List<MiguPlaylist> lists) => [
        for (final p in lists)
          HotPlaylist(
            id: p.id,
            name: p.name,
            cover: p.cover,
            creator: '',
            playCount: p.playCount.isEmpty ? null : p.playCount,
          ),
      ];

  static String _https(String url) {
    if (url.isEmpty) return '';
    if (url.startsWith('http://')) return 'https://${url.substring(7)}';
    if (url.startsWith('https://')) return url;
    return 'https://d.musicapp.migu.cn$url';
  }

  static String _str(dynamic v) => v == null ? '' : v.toString();
}
