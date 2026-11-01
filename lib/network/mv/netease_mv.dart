// 网易云 MV 播放源 —— /weapi/song/enhance/play/mv/url。
//
// 逆向自聆澜网易脚本的 getMvSource（v2.4.3），weapi 加密（复用项目
// NeteaseClient.postWeapi，登录后带 MUSIC_U 可看部分 VIP MV，未登录可看
// 免费 MV）：
//
//   POST https://music.163.com/weapi/song/enhance/play/mv/url?csrf_token=
//   payload: {"id":"5404646","r":1080,"csrf_token":""}
//
// 响应（实测 2026-11，mvid=5404646 光年之外 MV）：
//   {"code":200,"data":{"url":"http://vodkgeyttp8.vod.126.net/...",
//    "r":1080,"size":82829918,"expi":3600,"fee":0,"mvFee":0,...}}
//
// 注意 data 可能是对象也可能是数组（历史接口两种形态），统一兼容；
// url 是 http://（实测 CDN 直接可用），交给本地代理注入 Referer。
library;

import 'dart:convert';
import 'dart:async';

import 'package:http/http.dart' as http;

import '../../core/app_logger.dart';
import '../netease/netease_client.dart';
import 'mv_source.dart';

class NeteaseMvApi {
  NeteaseMvApi._();

  static const String _weapiUrl =
      'https://music.163.com/weapi/song/enhance/play/mv/url';

  /// MV CDN 防盗链头（脚本同款）。
  static const Map<String, String> cdnHeaders = {
    'Referer': 'https://music.163.com/',
    'Origin': 'https://music.163.com',
  };

  /// 拉取 MV 播放源。[mvId] 为数字 id 字符串。
  static Future<MvSource?> getSource(
      NeteaseClient client, String mvId, MvQuality quality) async {
    final id = int.tryParse(mvId.trim());
    if (id == null || id <= 0) return null;

    final json = await client.postWeapi(_weapiUrl, {
      'id': '$id',
      'r': quality.height,
      'csrf_token': '',
    }, csrf: client.csrfToken);

    final code = json['code'];
    if (code != 200) {
      throw MvUnavailable('网易 MV 接口 code=$code');
    }
    final item = _pickDataItem(json['data']);
    if (item == null) return null;

    final url = item['url']?.toString() ?? '';
    if (url.isEmpty) {
      final inner = item['code'];
      throw MvUnavailable(inner == 404
          ? '该 MV 不存在或已下架'
          : '该 MV 需要登录或 VIP（code=$inner）');
    }
    final expi = _num(item['expi'] ?? item['expiresIn']);
    final r = _num(item['r']);
    return MvSource(
      url: url,
      headers: cdnHeaders,
      videoQuality: '${r > 0 ? r : quality.height}p',
      size: _num(item['size'] ?? item['filesize'] ?? item['fileSize']),
      bitrate: _num(item['bitrate']),
      expiresInSeconds: expi > 0 ? expi : 0,
    );
  }

  /// data 兼容：对象直接用；数组取第一个 url 非空的。
  static Map<String, dynamic>? _pickDataItem(dynamic data) =>
      pickDataItemForTest(data);

  /// 测试钩子：网易 `data` 字段的对象/数组双形态解析。
  static Map<String, dynamic>? pickDataItemForTest(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is List) {
      for (final e in data) {
        if (e is Map<String, dynamic> &&
            (e['url']?.toString() ?? '').isNotEmpty) {
          return e;
        }
      }
      return data.isEmpty ? null : _asMap(data.first);
    }
    return null;
  }

  static Map<String, dynamic>? _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : null;

  static int _num(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

/// 网易歌曲详情的 MV id 兜底查询（搜索接口不带 mvid）。
///
/// GET /api/v3/song/detail?id=[<id>]&c=[{"id":<id>}]（**GET query 形态**，
/// POST 表单会回 400「参数错误」，实测 2026-11）
/// 响应 songs[0].mv —— 0 表示无 MV（实测晴天 id=186016 mv=0）。
Future<String> fetchNeteaseMvId(int songId) async {
  if (songId <= 0) return '';
  // 该接口只认 GET query：c 参数原样放 query（服务端自行解析 JSON）
  final uri = Uri.parse('${NeteaseClient.apiBase}/v3/song/detail')
      .replace(queryParameters: {
    'id': '[$songId]',
    'c': '[{"id":$songId}]',
  });
  final resp = await http.get(uri, headers: {
    'User-Agent': NeteaseClient.userAgent,
    'Referer': NeteaseClient.referer,
  }).timeout(const Duration(seconds: 15));
  if (resp.statusCode != 200) {
    throw MvUnavailable('网易歌曲详情 HTTP ${resp.statusCode}');
  }
  final json = jsonDecode(utf8.decode(resp.bodyBytes));
  if (json is! Map) return '';
  final songs = json['songs'];
  if (songs is List && songs.isNotEmpty) {
    final s = songs.first;
    final mv = s is Map ? s['mv'] : null;
    final n = mv is num ? mv.toInt() : int.tryParse('${mv ?? ''}') ?? 0;
    if (n > 0) return '$n';
  }
  AppLog.i('NeteaseMvApi', 'song $songId 无 MV');
  return '';
}
