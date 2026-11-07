// 酷狗音乐 —— 歌单 / 每日推荐网络层（v2.5.4）。
//
// 端点（2026-11 沙箱实测，全部走真实响应验证过）：
//
//   1. 推荐歌单（分类标签）
//      GET http://www2.kugou.kugou.com/yueku/v9/special/getSpecial
//          ?is_smarty=1
//      → data.tagids = {主题:[{id,name}], 语种:…, 风格:…, 年代:…, 心情:…, 场景:…}
//
//   2. 推荐歌单列表
//      GET http://www2.kugou.kugou.com/yueku/v9/special/getSpecial
//          ?is_ajax=1&cdn=cdn&t={sortId}&c={categoryId}&p={page}&pagesize={n}
//      → special_db[]（specialid / specialname / nickname / img / song_count …）
//      sortId：3 热藏 / 5 推荐 / 6 最热 / 7 最新 / 8 飙升
//
//   3. 歌单歌曲
//      GET http://mobilecdn.kugou.com/api/v3/special/song
//          ?version=9108&specialid={id}&page={p}&pagesize={n}&plat=0
//          &area_code=1&with_res_tag=0
//      → data.info[]（hash / 320hash / sqhash / album_audio_id / filename …）
//
//   4. 每日推荐（每日 30 首）
//      GET https://gateway.kugou.com/everyday_song_recommend
//          ?appid=1005&clientver=20489&clienttime=…&dfid=-&mid=…&uuid=-
//          &platform=ios&signature=…
//      签名盐 = gateway 盐；x-router: everydayrec.service.kugou.com
//      → data.song_list[]（hash / hash_320 / hash_flac / mixsongid / mv_hash …）
//
//   5. 我的歌单（需登录）
//      POST https://gateway.kugou.com/v7/get_all_list
//      body = {"userid":…,"token":…,"total_ver":979,"type":2,"page":1,"pagesize":30}
//      query = appid=3116&clientver=11440&clienttime=…&dfid=-&mid=…&plat=1
//              &uuid=-&signature=…
//      签名盐 = **歌词盐**（不是 gateway 盐！逆自倾听 5.6.14 的 LeN.iliO）
//      x-router: cloudlist.service.kugou.com
//      → data.info[] / data.list[] / data.lists[]（兼容三种数组名）
//        单条字段：listid|list_id|id|list_create_listid|specialid
//                  name|list_name|specialname|title
//                  pic|sizable_cover|flexible_cover|imgurl|cover|img
//                  count|m_count|song_count|songcount|song_num|songnum
//                  global_collection_id|globalCollectionId|gid|list_create_gid
//
// 未登录时接口返回 error_code 20017（token 无效）/ 20010（参数为空），
// 调用方据此提示「登录酷狗后同步」。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../core/app_logger.dart';
import '../../models/models.dart';
import 'kugou_api.dart';
import 'kugou_auth.dart';
import 'kugou_cipher.dart';

/// 酷狗歌单 / 每日推荐接口层。
abstract final class KugouPlaylistApi {
  static const String _recommendHost = 'http://www2.kugou.kugou.com';
  static const String _mobileCdnHost = 'http://mobilecdn.kugou.com';
  static const String _gatewayHost = 'https://gateway.kugou.com';

  /// 「我的歌单」用的 clientver / appid（与常规搜索那套不同）。
  static const String _myListClientver = '11440';
  static const String _myListAppid = '3116';

  static final Dio _dio = Dio();

  /// 浏览器 UA（www2 / mobilecdn 这些老接口会按 UA 判断来源）。
  static const Map<String, String> _webHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36',
    'Accept': '*/*',
  };

  /// 每日推荐用的移动端 UA。
  static const String _mobileUa =
      'Android810-AndroidPhone-20489-14-0-COMMENT-wifi';

  // ==================== 推荐歌单 ====================

  /// 取歌单分类标签（主题 / 语种 / 风格 / 年代 / 心情 / 场景）。
  ///
  /// 返回 `分类名 → [(id, name), …]`，id 为字符串（后续请求要原样传回）。
  ///
  /// 响应结构实测是 `data.tagids = { "主题": {id:1, data:[{id,name},…]}, … }`，
  /// 即每个分组是个对象、标签数组在它的 `data` 字段里。
  static Future<Map<String, List<KugouTag>>> categories() async {
    final url =
        '$_recommendHost/yueku/v9/special/getSpecial?is_smarty=1';
    final data = await _getJson(url);
    return parseCategories(data);
  }

  /// 取推荐歌单列表。
  ///
  /// [sortId] 排序方式：3 热藏 / 5 推荐 / 6 最热 / 7 最新 / 8 飙升；
  /// [categoryId] 分类 id（为空表示不限分类）。
  static Future<List<KugouPlaylist>> recommended({
    String sortId = '5',
    String categoryId = '',
    int page = 1,
    int pageSize = 20,
  }) async {
    final url = '$_recommendHost/yueku/v9/special/getSpecial'
        '?is_ajax=1&cdn=cdn&t=$sortId&c=$categoryId&p=$page&pagesize=$pageSize';
    final data = await _getJson(url);
    final list = data['special_db'];
    if (list is! List) return const [];
    return [
      for (final it in list)
        if (it is Map) KugouPlaylist.fromRecommend(Map<String, dynamic>.from(it)),
    ].where((p) => p.id.isNotEmpty).toList();
  }

  /// 搜索歌单（按关键字）。
  static Future<List<KugouPlaylist>> searchPlaylists(String keyword,
      {int page = 1, int pageSize = 20}) async {
    final url = '$_mobileCdnHost/api/v3/search/special'
        '?format=json&keyword=${Uri.encodeComponent(keyword)}'
        '&page=$page&pagesize=$pageSize&showtype=1';
    final data = await _getJson(url);
    final list = data['data']?['info'];
    if (list is! List) return const [];
    return [
      for (final it in list)
        if (it is Map) KugouPlaylist.fromSearch(Map<String, dynamic>.from(it)),
    ].where((p) => p.id.isNotEmpty).toList();
  }

  // ==================== 歌单歌曲 ====================

  /// 取歌单里的歌曲。
  static Future<KugouPlaylistSongs> playlistSongs(String specialId,
      {int page = 1, int pageSize = 100}) async {
    final url = '$_mobileCdnHost/api/v3/special/song'
        '?version=9108&specialid=$specialId&page=$page&pagesize=$pageSize'
        '&plat=0&area_code=1&with_res_tag=0';
    final data = await _getJson(url);
    final d = data['data'];
    if (d is! Map) return const KugouPlaylistSongs(songs: [], total: 0);
    final info = d['info'];
    final list = info is List ? info : const [];
    return KugouPlaylistSongs(
      songs: [
        for (final it in list)
          if (it is Map)
            KugouPlaylistSong.fromSpecial(Map<String, dynamic>.from(it)),
      ],
      total: (d['total'] as num?)?.toInt() ?? list.length,
    );
  }

  // ==================== 每日推荐 ====================

  /// 取每日推荐歌曲（每天一批，30 首左右）。
  static Future<List<KugouPlaylistSong>> dailyRecommend() async {
    final params = <String, String>{
      ...kugouGatewayCommon(),
      'appid': '1005',
      'clientver': '20489',
      'clienttime': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      'dfid': '-',
      'uuid': '-',
      'platform': 'ios',
    };
    final signature = kugouSign(params, kugouGatewaySalt);
    final uri = Uri.parse('$_gatewayHost/everyday_song_recommend')
        .replace(queryParameters: {...params, 'signature': signature});
    final headers = <String, String>{
      'User-Agent': _mobileUa,
      'Accept': 'application/json',
      'kg-rc': '1',
      'kg-thash': '5d816a0',
      'kg-rec': '1',
      'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
      'x-router': 'everydayrec.service.kugou.com',
    };
    final resp = await _dio.get<Map<String, dynamic>>(
      uri.toString(),
      options: Options(headers: headers, responseType: ResponseType.json),
    );
    final data = resp.data?['data'];
    if (data is! Map) return const [];
    final list = data['song_list'];
    if (list is! List) return const [];
    return [
      for (final it in list)
        if (it is Map)
          KugouPlaylistSong.fromDaily(Map<String, dynamic>.from(it)),
    ].where((s) => s.name.isNotEmpty).toList();
  }

  // ==================== 我的歌单 ====================

  /// 取当前登录账号的「我的歌单」。
  ///
  /// 未登录返回空列表（调用方按 [KugouAuth.isLoggedIn] 给提示）。
  /// 已登录但 token 失效时接口返回 error_code 20017，这里同样返回空列表
  /// 并记日志，避免把服务端错误抛到 UI。
  static Future<List<KugouPlaylist>> myPlaylists({int page = 1}) async {
    final session = KugouAuth.session;
    if (session == null || !session.isValid) return const [];
    final dev = await KugouAuth.device();
    final clientTime = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final params = <String, String>{
      'appid': _myListAppid,
      'clientver': _myListClientver,
      'clienttime': clientTime,
      'dfid': dev.dfid,
      'mid': dev.mid,
      'plat': '1',
      'uuid': '-',
    };
    // 签名盐是**歌词盐**（与 gateway 盐不同），实测错盐会返回 20006。
    final body = jsonEncode(<String, dynamic>{
      'userid': int.tryParse(session.userid) ?? 0,
      'token': session.token,
      'total_ver': 979,
      'type': 2,
      'page': page,
      'pagesize': 30,
    });
    final signature = kugouSign(params, kugouLyricSalt, body: body);
    final uri = Uri.parse('$_gatewayHost/v7/get_all_list')
        .replace(queryParameters: {...params, 'signature': signature});
    final headers = <String, String>{
      'User-Agent': 'Android15-1070-$_myListClientver-46-0-DiscoveryDRADProtocol-wifi',
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'kg-rc': '1',
      'kg-thash': '5d816a0',
      'kg-rec': '1',
      'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
      'x-router': 'cloudlist.service.kugou.com',
      'Cookie': session.token,
    };
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        uri.toString(),
        data: body,
        options: Options(headers: headers, responseType: ResponseType.json),
      );
      final data = resp.data;
      final status = (data?['status'] as num?)?.toInt() ?? 0;
      if (status != 1) {
        AppLog.w('KugouPlaylistApi',
            '我的歌单失败 status=$status err=${data?['error_code']}');
        return const [];
      }
      return parseMyPlaylists(data);
    } catch (e) {
      AppLog.w('KugouPlaylistApi', '我的歌单请求异常: $e');
      return const [];
    }
  }

  // ==================== 纯函数（供离线测试） ====================

  /// 从「我的歌单」响应里提取歌单列表。
  ///
  /// 数组名兼容三种（服务端在不同版本用过不同键）：`info` / `list` / `lists`。
  static List<KugouPlaylist> parseMyPlaylists(Map<String, dynamic>? data) {
    if (data == null) return const [];
    final d = data['data'];
    if (d is! Map) return const [];
    final list = d['info'] ?? d['list'] ?? d['lists'];
    if (list is! List) return const [];
    return [
      for (final it in list)
        if (it is Map) KugouPlaylist.fromMyList(Map<String, dynamic>.from(it)),
    ].where((p) => p.id.isNotEmpty).toList();
  }

  /// 从分类响应里提取标签（纯函数，供离线测试）。
  ///
  /// 结构：`data.tagids = { "主题": {id:1, data:[{id,name},…]}, … }`。
  static Map<String, List<KugouTag>> parseCategories(
      Map<String, dynamic> data) {
    final tagids = data['data']?['tagids'];
    if (tagids is! Map) return const {};
    final out = <String, List<KugouTag>>{};
    tagids.forEach((group, groupValue) {
      final items = groupValue is Map ? groupValue['data'] : groupValue;
      if (items is! List) return;
      out[group.toString()] = [
        for (final it in items)
          if (it is Map)
            KugouTag(
              id: (it['id'] ?? '').toString(),
              name: (it['name'] ?? it['special_name'] ?? '').toString(),
            ),
      ].where((t) => t.id.isNotEmpty && t.id != '0').toList();
    });
    return out;
  }

  /// 从推荐歌单响应里提取列表。
  static List<KugouPlaylist> parseRecommended(Map<String, dynamic> data) {
    final list = data['special_db'];
    if (list is! List) return const [];
    return [
      for (final it in list)
        if (it is Map) KugouPlaylist.fromRecommend(Map<String, dynamic>.from(it)),
    ].where((p) => p.id.isNotEmpty).toList();
  }

  /// 从搜索歌单响应里提取列表。
  static List<KugouPlaylist> parseSearchPlaylists(Map<String, dynamic> data) {
    final list = data['data']?['info'];
    if (list is! List) return const [];
    return [
      for (final it in list)
        if (it is Map) KugouPlaylist.fromSearch(Map<String, dynamic>.from(it)),
    ].where((p) => p.id.isNotEmpty).toList();
  }

  /// 从每日推荐响应里提取歌曲。
  static List<KugouPlaylistSong> parseDaily(Map<String, dynamic>? data) {
    if (data == null) return const [];
    final d = data['data'];
    if (d is! Map) return const [];
    final list = d['song_list'];
    if (list is! List) return const [];
    return [
      for (final it in list)
        if (it is Map)
          KugouPlaylistSong.fromDaily(Map<String, dynamic>.from(it)),
    ].where((s) => s.name.isNotEmpty).toList();
  }

  /// 从歌单歌曲响应里提取歌曲。
  static List<KugouPlaylistSong> parsePlaylistSongs(Map<String, dynamic> data) {
    final d = data['data'];
    if (d is! Map) return const [];
    final list = d['info'];
    if (list is! List) return const [];
    return [
      for (final it in list)
        if (it is Map)
          KugouPlaylistSong.fromSpecial(Map<String, dynamic>.from(it)),
    ].where((s) => s.name.isNotEmpty).toList();
  }

  /// 把酷狗歌单歌曲转成通用的 [Song]（供歌单详情页播放 / 下载）。
  static Song toSong(KugouPlaylistSong s) {
    return Song(
      mid: s.mixSongId,
      songId: int.tryParse(s.mixSongId) ?? 0,
      name: s.name,
      singer: s.singer,
      album: s.album,
      albumMid: '',
      duration: s.durationSeconds * 1000,
      cover: s.cover,
      source: Source.kugou,
      mvId: s.mvHash,
    );
  }

  // ==================== 内部 ====================

  static Future<Map<String, dynamic>> _getJson(String url) async {
    // 这批老接口（www2 / mobilecdn）回的是 `Content-Type: text/html`，
    // Dio 不会自动当 JSON 解析，所以按 plain 收再自己 decode。
    final resp = await _dio.get<String>(
      url,
      options: Options(
        headers: _webHeaders,
        responseType: ResponseType.plain,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final raw = resp.data ?? '';
    if (raw.isEmpty) return const <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }
}

/// 酷狗歌单分类标签。
class KugouTag {
  const KugouTag({required this.id, required this.name});

  final String id;
  final String name;

  @override
  String toString() => 'KugouTag($id, $name)';
}

/// 一个酷狗歌单（推荐 / 搜索 / 我的）。
class KugouPlaylist {
  const KugouPlaylist({
    required this.id,
    required this.name,
    required this.cover,
    required this.creator,
    this.playCount = '',
    this.trackCount,
    this.globalCollectionId = '',
  });

  /// 歌单 id（推荐/搜索是 `specialid`；我的歌单是 `listid`）。
  final String id;

  /// 歌单名。
  final String name;

  /// 封面（已归一化成 https）。
  final String cover;

  /// 创建者昵称。
  final String creator;

  /// 播放量（形如「1719.2万」）。
  final String playCount;

  /// 曲目数。
  final int? trackCount;

  /// 云歌单全局 id（`global_collection_id`）；只有「我的歌单」会有。
  final String globalCollectionId;

  /// 推荐的歌单（`special_db`）。
  factory KugouPlaylist.fromRecommend(Map<String, dynamic> j) {
    return KugouPlaylist(
      id: (j['specialid'] ?? '').toString(),
      name: (j['specialname'] ?? '').toString(),
      cover: kugouCoverUrl((j['img'] ?? j['imgurl'] ?? '').toString()),
      creator: (j['nickname'] ?? j['author'] ?? '').toString(),
      // 服务端 `total_play_count` 是「1719.2万」这种字符串，`song_count`
      // 常为 0（不准），所以优先用 `collect_count`（收藏数）兜底展示。
      playCount: (j['total_play_count'] ?? j['collect_count'] ?? '').toString(),
      trackCount: (j['song_count'] as num?)?.toInt(),
    );
  }

  /// 搜索到的歌单（`data.info`）。
  factory KugouPlaylist.fromSearch(Map<String, dynamic> j) {
    return KugouPlaylist(
      id: (j['specialid'] ?? '').toString(),
      name: (j['specialname'] ?? '').toString(),
      cover: kugouCoverUrl((j['imgurl'] ?? '').toString()),
      creator: (j['nickname'] ?? '').toString(),
      playCount: (j['playcount'] ?? '').toString(),
      trackCount: (j['songcount'] as num?)?.toInt(),
    );
  }

  /// 「我的歌单」（`v7/get_all_list`）。
  ///
  /// 服务端字段名在不同版本有差异，这里按倾听 5.6.14 的解析顺序逐个兜底。
  factory KugouPlaylist.fromMyList(Map<String, dynamic> j) {
    String pick(List<String> keys) {
      for (final k in keys) {
        final v = j[k];
        if (v == null) continue;
        final s = v.toString();
        if (s.isNotEmpty && s != '0') return s;
      }
      return '';
    }

    final id = pick(const [
      'listid',
      'list_id',
      'id',
      'list_create_listid',
      'specialid',
    ]);
    var name = pick(const ['name', 'list_name', 'specialname', 'title']);
    final cover = kugouCoverUrl(pick(const [
      'pic',
      'sizable_cover',
      'flexible_cover',
      'imgurl',
      'cover',
      'img',
    ]));
    final countRaw = pick(const [
      'count',
      'm_count',
      'song_count',
      'songcount',
      'song_num',
      'songnum',
    ]);
    final gid = pick(const [
      'global_collection_id',
      'globalCollectionId',
      'gid',
      'list_create_gid',
    ]);
    if (name.isEmpty) name = '酷狗歌单 $id';
    return KugouPlaylist(
      id: id,
      name: name,
      cover: cover,
      creator: (j['nickname'] ?? j['username'] ?? '').toString(),
      playCount: (j['play_count'] ?? j['total_play_count'] ?? '').toString(),
      trackCount: int.tryParse(countRaw),
      globalCollectionId: gid,
    );
  }
}

/// 酷狗歌单里的一首歌（推荐歌单 / 每日推荐 / 我的歌单共用）。
class KugouPlaylistSong {
  const KugouPlaylistSong({
    required this.mixSongId,
    required this.name,
    required this.singer,
    required this.album,
    required this.hash,
    required this.hqHash,
    required this.sqHash,
    required this.resHash,
    required this.cover,
    required this.durationSeconds,
    this.mvHash = '',
  });

  /// MixSongID（酷狗的主键，下载 / 评论都靠它）。
  final String mixSongId;

  final String name;
  final String singer;
  final String album;

  /// 128k 文件 hash。
  final String hash;

  /// 320k 文件 hash。
  final String hqHash;

  /// FLAC 文件 hash。
  final String sqHash;

  /// Hi-Res 文件 hash。
  final String resHash;

  final String cover;
  final int durationSeconds;

  /// MV hash（有 MV 时非空）。
  final String mvHash;

  /// 歌单歌曲（`api/v3/special/song` 的 `data.info[]`）。
  factory KugouPlaylistSong.fromSpecial(Map<String, dynamic> j) {
    final filename = (j['filename'] ?? '').toString();
    final parts = filename.split('-');
    var artist = '';
    var title = filename;
    if (parts.length >= 2) {
      artist = parts.first.trim();
      title = parts.sublist(1).join('-').trim();
    }
    title = title.replaceAll(RegExp(r'\.(mp3|flac)$', caseSensitive: false), '');
    return KugouPlaylistSong(
      mixSongId: (j['album_audio_id'] ?? '').toString(),
      name: title,
      singer: artist,
      album: (j['album_name'] ?? '').toString(),
      hash: (j['hash'] ?? '').toString(),
      hqHash: (j['320hash'] ?? j['hash_320'] ?? '').toString(),
      sqHash: (j['sqhash'] ?? j['hash_flac'] ?? '').toString(),
      resHash: (j['res_hash'] ?? j['hash_res'] ?? '').toString(),
      cover: kugouCoverUrl((j['sizable_cover'] ?? '').toString()),
      durationSeconds: (j['duration'] as num?)?.toInt() ?? 0,
      mvHash: (j['mvhash'] ?? j['mv_hash'] ?? '').toString(),
    );
  }

  /// 每日推荐（`everyday_song_recommend` 的 `data.song_list[]`）。
  factory KugouPlaylistSong.fromDaily(Map<String, dynamic> j) {
    final singerInfo = j['singerinfo'];
    var singer = (j['author_name'] ?? '').toString();
    if (singer.isEmpty && singerInfo is List && singerInfo.isNotEmpty) {
      final first = singerInfo.first;
      if (first is Map) singer = (first['name'] ?? '').toString();
    }
    return KugouPlaylistSong(
      mixSongId: (j['mixsongid'] ?? j['album_audio_id'] ?? '').toString(),
      name: (j['songname'] ?? j['ori_audio_name'] ?? '').toString(),
      singer: singer,
      album: (j['album_name'] ?? '').toString(),
      hash: (j['hash'] ?? j['hash_128'] ?? '').toString(),
      hqHash: (j['hash_320'] ?? j['320hash'] ?? '').toString(),
      sqHash: (j['hash_flac'] ?? j['sqhash'] ?? '').toString(),
      resHash: (j['hash_res'] ?? j['res_hash'] ?? '').toString(),
      cover: kugouCoverUrl((j['sizable_cover'] ?? '').toString()),
      durationSeconds: (j['time_length'] as num?)?.toInt() ?? 0,
      mvHash: (j['mv_hash'] ?? '').toString(),
    );
  }
}

/// 歌单歌曲列表（带总数）。
class KugouPlaylistSongs {
  const KugouPlaylistSongs({required this.songs, required this.total});

  final List<KugouPlaylistSong> songs;
  final int total;
}
/// 供签名自检用：暴露「我的歌单」的签名盐名，便于测试断言。
const String kugouMyListSaltName = 'lyric';

/// 便于测试：计算「我的歌单」的签名。
String kugouMyListSignature(
  Map<String, String> params,
  String body,
) =>
    md5.convert(utf8.encode('$kugouLyricSalt${_joinSorted(params)}$body'
            '$kugouLyricSalt'))
        .toString();

String _joinSorted(Map<String, String> params) {
  final keys = params.keys.toList()..sort();
  return keys.map((k) => '$k=${params[k] ?? ''}').join();
}
