import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/models/models.dart';

import 'qq_music_client.dart';

/// QQ 音乐搜索（对应原生 `network/SearchApi.kt`）。
class SearchApi {
  SearchApi(this.client);

  final QQMusicClient client;

  /// 按类型搜索歌曲（SONG）。
  /// 搜索不需要 session，直接发送请求以避免 session/QIMEI 初始化失败影响搜索。
  Future<List<Song>> searchByType(String keyword,
      {int page = 1, int num = 20}) async {
    final param = <String, dynamic>{
      'searchid': client.getSearchId(),
      'query': keyword,
      'search_type': 0, // SONG
      'num_per_page': num,
      'page_num': page,
      'highlight': 1,
      'grp': true,
    };
    AppLog.i('SearchApi', '开始搜索 keyword=$keyword page=$page num=$num');

    // 搜索接口不需要 session，直接使用 request() 绕过 ensureSession()
    // 避免因 QIMEI 注册/session 获取失败导致搜索不可用
    final comm = client.buildComm();
    final payload = <String, dynamic>{
      'comm': comm,
      'req_0': {
        'module': 'music.search.SearchCgiService',
        'method': 'DoSearchForQQMusicMobile',
        'param': _boolToInt(param),
      },
    };
    final resp = await client.request(
      method: 'POST',
      url: QQMusicClient.musicuUrl,
      jsonBody: payload,
    );
    final req0 = resp['req_0'];
    final data = req0 is Map<String, dynamic>
        ? (req0['data'] is Map<String, dynamic>
            ? req0['data'] as Map<String, dynamic>
            : <String, dynamic>{})
        : <String, dynamic>{};

    var body = data;
    if (body.containsKey('body')) {
      final inner = body['body'];
      if (inner is Map<String, dynamic>) body = inner;
    }
    var list = body['item_song'];
    if (list is! List) {
      final song = body['song'];
      list = song is Map<String, dynamic> ? song['list'] : null;
    }
    if (list is! List && body.containsKey('data')) {
      final d = body['data'];
      if (d is Map<String, dynamic>) {
        list = d['item_song'] ?? d['song']?['list'];
      }
    }

    final result = <Song>[];
    if (list is List) {
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final track = item['track_info'];
        final t = track is Map<String, dynamic> ? track : item;
        final s = Song.fromTrack(t);
        if (s.mid.isNotEmpty) result.add(s);
      }
    }
    AppLog.i('SearchApi',
        '搜索结果 keyword=$keyword 命中=${result.length} 原始条目=${list?.length ?? 0}');
    return result;
  }

  /// 递归将布尔值转 1/0。
  static dynamic _boolToInt(dynamic o) {
    if (o is bool) return o ? 1 : 0;
    if (o is Map<String, dynamic>) {
      return o.map((k, v) => MapEntry(k, _boolToInt(v)));
    }
    if (o is List) {
      return o.map(_boolToInt).toList();
    }
    return o;
  }

  /// 搜索补全建议（smartbox 接口，无需登录）。
  Future<List<String>> suggestions(String keyword, {int num = 8}) async {
    final resp = await client.request(
      method: 'GET',
      url: 'https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg',
      params: {
        'is_xml': '0',
        'format': 'json',
        'key': keyword,
        'loginUin': '0',
        'hostUin': '0',
        'inCharset': 'utf8',
        'outCharset': 'utf-8',
        'notice': '0',
        'platform': 'yqq',
        'needNewCode': '0',
      },
      headers: {'Referer': 'https://y.qq.com/portal/player.html'},
    );
    if ((resp['code'] as int? ?? -1) != 0) return const [];
    final data = resp['data'];
    if (data is! Map<String, dynamic>) return const [];

    final out = <String>{};
    final singers = (data['singer'] as Map<String, dynamic>?)?['itemlist'];
    if (singers is List) {
      for (final item in singers) {
        if (item is Map<String, dynamic>) {
          final n = (item['name'] as String? ?? '').trim();
          if (n.isNotEmpty) out.add(n);
        }
      }
    }
    final songs = (data['song'] as Map<String, dynamic>?)?['itemlist'];
    if (songs is List) {
      for (final item in songs) {
        if (item is! Map<String, dynamic>) continue;
        final n = (item['name'] as String? ?? '').trim();
        final sg = (item['singer'] as String? ?? '').trim();
        if (n.isEmpty) continue;
        out.add(sg.isEmpty ? n : '$sg $n');
      }
    }
    AppLog.i('SearchApi', '相关搜索 keyword=$keyword 命中=${out.length}');
    return out.take(num).toList();
  }

  /// 综合搜索。
  Future<List<Song>> generalSearch(String keyword,
      {int page = 1, int num = 20}) async {
    final param = <String, dynamic>{
      'searchid': client.getSearchId(),
      'search_type': 100,
      'page_num': num,
      'query': keyword,
      'page_id': page,
      'highlight': 1,
      'grp': true,
    };
    AppLog.i('SearchApi', '开始综合搜索 keyword=$keyword page=$page num=$num');
    final data = await client.execute(BizRequest(
      module: 'music.adaptor.SearchAdaptor',
      method: 'do_search_v2',
      param: param,
    ));
    final body = data['body'];
    final bodyMap = body is Map<String, dynamic> ? body : null;
    var list = (bodyMap?['item_song'] as Map<String, dynamic>?)?['items'];
    if (list is! List) {
      final song = bodyMap?['song'];
      list = song is Map<String, dynamic> ? song['list'] : null;
    }

    final result = <Song>[];
    if (list is List) {
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final track = item['track_info'];
        final t = track is Map<String, dynamic> ? track : item;
        final s = Song.fromTrack(t);
        if (s.mid.isNotEmpty) result.add(s);
      }
    }
    AppLog.i('SearchApi',
        '综合搜索结果 keyword=$keyword 命中=${result.length} 原始条目=${list?.length ?? 0}');
    return result;
  }
}