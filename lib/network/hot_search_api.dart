// 三平台 —— 热搜词 + 热门歌单
//   QQ音乐   : 热搜 gethotkey.fcg         热门歌单 fcg_get_diss_by_tag.fcg
//   网易云   : 热搜 api/search/hot         热门歌单 api/playlist/highquality/list
//   酷我音乐 : 热门 hotpage(XML 推荐热页)   热门歌单 getRcmPlayList(order=hot)
// 全部为官方公开接口, 无需签名/登录。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fast_gbk/fast_gbk.dart';

/// gzip 安全解码: 命中 gzip 魔数(1f 8b)则先解压
List<int> maybeGunzip(List<int> bytes) =>
    (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b)
        ? gzip.decode(bytes)
        : bytes;

/// 容错解码: 先 UTF-8, 失败再 GBK (QQ 接口编码在 utf-8 / gb2312 间浮动)
String decodeMaybeGbkBody(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return gbk.decode(bytes, allowMalformed: true);
  }
}

final Dio _hotDio = Dio(BaseOptions(
  connectTimeout: const Duration(seconds: 15),
  receiveTimeout: const Duration(seconds: 20),
  responseType: ResponseType.bytes,
));

/// 统一 GET (JSON), 带超时 + gzip 兼容 + 编码容错
Future<Map<String, dynamic>> getJsonWithRetry(
  String url, {
  Map<String, String>? headers,
  int retries = 3,
}) async {
  Exception? lastErr;
  for (int i = 0; i < retries; i++) {
    try {
      final resp = await _hotDio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: headers,
        ),
      );
      final body = decodeMaybeGbkBody(maybeGunzip(resp.data ?? const []));
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      lastErr = e is Exception ? e : Exception(e.toString());
      if (i < retries - 1) {
        await Future.delayed(const Duration(milliseconds: 400));
      }
    }
  }
  throw lastErr ?? Exception('unknown');
}

/// 一条热搜词。
class HotKeyword {
  final String word;
  final String? count;

  const HotKeyword(this.word, this.count);

  factory HotKeyword.fromJson(Map<String, dynamic> j) => HotKeyword(
        (j['word'] ?? '').toString(),
        j['count']?.toString(),
      );
}

/// 一个热门歌单摘要。
class HotPlaylist {
  final String id;
  final String name;
  final String cover;
  final String creator;
  final String? playCount;
  final int? trackCount;

  const HotPlaylist({
    required this.id,
    required this.name,
    required this.cover,
    required this.creator,
    this.playCount,
    this.trackCount,
  });

  factory HotPlaylist.fromJson(Map<String, dynamic> j) => HotPlaylist(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        cover: (j['cover'] ?? '').toString(),
        creator: (j['creator'] ?? '').toString(),
        playCount: j['playCount']?.toString(),
        trackCount: (j['trackCount'] as num?)?.toInt(),
      );
}

// ───────────────────────────── QQ音乐 ─────────────────────────────
class QqHot {
  static const Map<String, String> headers = {
    'Referer': 'https://y.qq.com/',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
  };

  /// 热搜词
  static Future<List<HotKeyword>> hotSearch({int limit = 20}) async {
    final url = Uri.parse('https://c.y.qq.com/splcloud/fcgi-bin/gethotkey.fcg')
        .replace(queryParameters: {
      'g_tk': '5381',
      'uin': '0',
      'format': 'json',
      'notice': '0',
      'platform': 'yqq.json',
      'needNewCode': '1',
    }).toString();
    final data = await getJsonWithRetry(url, headers: headers);
    final list = (data['data']?['hotkey'] ?? const []) as List<dynamic>;
    return list
        .take(limit)
        .map((e) => HotKeyword.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((e) => e.word.isNotEmpty)
        .toList();
  }

  /// 热门歌单
  static Future<List<HotPlaylist>> hotPlaylists({int limit = 30}) async {
    final url = Uri.parse(
            'https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg')
        .replace(queryParameters: {
      'picmid': '1',
      'g_tk': '5381',
      'loginUin': '0',
      'hostUin': '0',
      'format': 'json',
      'inCharset': 'utf8',
      'outCharset': 'utf8',
      'notice': '0',
      'platform': 'yqq.json',
      'needNewCode': '1',
      'categoryId': '10000000',
      'sortId': '5', // 5=最热
      'sin': '0',
      'ein': limit.toString(),
    }).toString();
    final data = await getJsonWithRetry(url, headers: headers);
    final list = (data['data']?['list'] ?? const []) as List<dynamic>;
    return list
        .map((e) => HotPlaylist.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((e) => e.id.isNotEmpty)
        .toList();
  }
}

// ───────────────────────────── 网易云音乐 ─────────────────────────────
class NeteaseHot {
  static const Map<String, String> headers = {
    'Referer': 'https://music.163.com/',
    'User-Agent': 'Mozilla/5.0',
  };

  /// 热搜词
  static Future<List<HotKeyword>> hotSearch({int limit = 20}) async {
    final url = Uri.parse('https://music.163.com/api/search/hot')
        .replace(queryParameters: {'type': '111', 'limit': limit.toString()})
        .toString();
    final data = await getJsonWithRetry(url, headers: headers);
    final list = (data['result']?['hots'] ?? const []) as List<dynamic>;
    return list
        .take(limit)
        .map((e) => HotKeyword.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((e) => e.word.isNotEmpty)
        .toList();
  }

  /// 热门歌单(精品歌单)
  static Future<List<HotPlaylist>> hotPlaylists({int limit = 30}) async {
    final url = Uri.parse(
            'https://music.163.com/api/playlist/highquality/list')
        .replace(queryParameters: {
      'limit': limit.toString(),
      'before': '0',
    }).toString();
    final data = await getJsonWithRetry(url, headers: headers);
    final list = (data['playlists'] ?? const []) as List<dynamic>;
    return list
        .map((e) => HotPlaylist.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((e) => e.id.isNotEmpty)
        .toList();
  }
}

// ───────────────────────────── 酷我音乐 ─────────────────────────────
class KuwoHot {
  static const Map<String, String> headers = {'User-Agent': 'Mozilla/5.0'};

  /// 热门推荐（热搜/热歌）：解析 hotpage 推荐热页 XML 的 `<music>` 节点
  static Future<List<HotKeyword>> hotSearch({int limit = 30}) async {
    final url = Uri.parse('http://mgxhtj.kuwo.cn/mgxh.s').replace(
        queryParameters: {
      'source': 'kwplayer_ar_10.8.3.1_704.apk',
      'type': 'hotpage',
    }).toString();
    final resp = await _hotDio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes, headers: headers),
    );
    final xml = utf8.decode(maybeGunzip(resp.data ?? const []));
    final out = <HotKeyword>[];
    final musicRe = RegExp(r'<music\b([^>]*)>');
    for (final m in musicRe.allMatches(xml)) {
      final attrs = _attrs(m.group(1) ?? '');
      final name = attrs['name'] ?? '';
      final artist = attrs['artist'] ?? '';
      if (name.isEmpty) continue;
      out.add(HotKeyword(
        artist.isEmpty ? name : '$name - $artist',
        attrs['rid'],
      ));
      if (out.length >= limit) break;
    }
    return out;
  }

  /// 热门歌单(推荐歌单, order=hot)
  static Future<List<HotPlaylist>> hotPlaylists({int limit = 30}) async {
    final url = Uri.parse(
            'http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList')
        .replace(queryParameters: {
      'loginUid': '0',
      'loginSid': '0',
      'appUid': '76039576',
      'pn': '0',
      'rn': limit.toString(),
      'order': 'hot',
    }).toString();
    final data = await getJsonWithRetry(url, headers: headers);
    final list = (data['data']?['data'] ?? const []) as List<dynamic>;
    return list
        .map((e) => HotPlaylist.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((e) => e.id.isNotEmpty)
        .toList();
  }

  /// 解析 XML 标签内的 key="value" 属性
  static Map<String, String> _attrs(String tag) {
    final map = <String, String>{};
    final re = RegExp(r'(\w+)\s*=\s*"([^"]*)"');
    for (final m in re.allMatches(tag)) {
      map[m.group(1)!] = m.group(2)!;
    }
    return map;
  }
}

/// 统一入口：按音源标识取热搜词。
///
/// [source] 为 `qq` / `netease` / `kuwo`。
Future<List<HotKeyword>> hotKeywordsOf(String source, {int limit = 20}) async {
  switch (source) {
    case 'netease':
      return NeteaseHot.hotSearch(limit: limit);
    case 'kuwo':
      return KuwoHot.hotSearch(limit: limit);
    default:
      return QqHot.hotSearch(limit: limit);
  }
}

/// 统一入口：按音源标识取热门歌单。
Future<List<HotPlaylist>> hotPlaylistsOf(String source, {int limit = 30}) async {
  switch (source) {
    case 'netease':
      return NeteaseHot.hotPlaylists(limit: limit);
    case 'kuwo':
      return KuwoHot.hotPlaylists(limit: limit);
    default:
      return QqHot.hotPlaylists(limit: limit);
  }
}
