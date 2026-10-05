import 'dart:convert';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/string_clip.dart';
import 'package:dio/dio.dart';

import 'netease_crypto.dart';
import 'netease_api.dart';

/// 网易云 API 客户端。
///
/// 对应原生 `network/netease/NeteaseClient.kt`：HTTP 编排，
/// EAPI 参数加密见 [NeteaseCrypto]；登录态以网页版 Cookie（需含 MUSIC_U）保存。
class NeteaseClient {
  static const String _prefsCookie = 'netease_cookie';
  static const String _prefsUserId = 'netease_user_id';

  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/2.10.2.200154';
  static const String referer = 'https://music.163.com/';

  /// 网页版接口根地址（搜索/详情/歌词/歌单/专辑）
  static const String apiBase = 'https://music.163.com/api';

  /// EAPI 接口根地址（取流/登录）
  static const String eapiBase = 'https://interface3.music.163.com/eapi';

  NeteaseClient() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
      validateStatus: (_) => true,
    ));
  }

  late final Dio _dio;

  late final NeteaseApi api = NeteaseApi(this);

  String get cookie => KvStore.instance.getString(_prefsCookie, def: '') ?? '';

  set cookie(String v) {
    KvStore.instance.setString(_prefsCookie, v.trim());
  }

  int get userId => KvStore.instance.getInt(_prefsUserId, def: 0);

  set userId(int v) => KvStore.instance.setInt(_prefsUserId, v);

  bool isLoggedIn() => cookie.contains('MUSIC_U=');

  void logout() {
    KvStore.instance.remove(_prefsCookie);
    KvStore.instance.remove(_prefsUserId);
  }

  /// 组装请求 Cookie：用户 Cookie 优先，并补齐 os/appver 等字段。
  String buildCookieHeader() {
    final map = <String, String>{};
    parseCookie(cookie, map);
    map.putIfAbsent('os', () => 'pc');
    map.putIfAbsent('appver', () => '8.9.70');
    map.putIfAbsent('osver', () => '10');
    map.putIfAbsent('deviceId', () => 'pyncm!');
    return map.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 解析一段 Cookie 字符串到 map（兼容 "k=v; k=v" 与换行分隔）。
  static void parseCookie(String raw, Map<String, String> out) {
    if (raw.trim().isEmpty) return;
    for (final part in raw.replaceAll('\n', ';').split(';')) {
      final seg = part.trim();
      if (seg.isEmpty) continue;
      final idx = seg.indexOf('=');
      if (idx <= 0) continue;
      var v = seg.substring(idx + 1).trim();
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
        v = v.substring(1, v.length - 1);
      }
      if (v.isNotEmpty) out[seg.substring(0, idx).trim()] = v;
    }
  }

  // ================= HTTP =================

  /// EAPI 请求：payload 加密后以 params 表单字段提交。
  Future<Map<String, dynamic>> postEapi(
      String eapiUrl, Map<String, dynamic> payload) async {
    final path = Uri.parse(eapiUrl).path;
    final params = NeteaseCrypto.encryptParams(path, jsonEncode(payload));
    return _postForm('params=${Uri.encodeQueryComponent(params)}', eapiUrl,
        isJson: false);
  }

  /// 网页版接口 POST（表单参数）。
  Future<Map<String, dynamic>> postApi(
      String apiUrl, Map<String, String> form) async {
    final body = form.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return _postForm(body, apiUrl, isJson: false);
  }

  /// 网页版接口 GET。
  Future<Map<String, dynamic>> getApi(String apiUrl) async {
    final resp = await _dio.get(apiUrl,
        options: Options(headers: _baseHeaders(), validateStatus: (_) => true));
    return _decode(resp, apiUrl);
  }

  Map<String, String> _baseHeaders() => {
        'User-Agent': userAgent,
        'Referer': referer,
        'Cookie': buildCookieHeader(),
        'Content-Type': 'application/x-www-form-urlencoded',
      };

  Future<Map<String, dynamic>> _postForm(
      String body, String url, {bool isJson = false}) async {
    final resp = await _dio.post(url,
        data: body,
        options: Options(headers: _baseHeaders(), validateStatus: (_) => true));
    return _decode(resp, url);
  }

  Map<String, dynamic> _decode(Response resp, String url) {
    final text = resp.data?.toString() ?? '';
    AppLog.d('NeteaseClient', '<<< HTTP ${resp.statusCode} $url resp=${text.clip(500)}');
    if (text.trim().isEmpty) {
      throw Exception('网易云返回空响应');
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'code': -1, 'message': '非 JSON 对象'};
    } catch (e) {
      throw Exception('网易云响应解析失败: ${text.clip(200)}');
    }
  }
}