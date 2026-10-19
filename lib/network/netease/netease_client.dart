import 'dart:convert';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/string_clip.dart';
import 'package:dio/dio.dart';

import 'netease_crypto.dart';
import 'netease_api.dart';
import 'netease_weapi.dart';

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

  /// 登录后补齐浏览器会话 Cookie。
  ///
  /// 扫码登录只从轮询响应的 Set-Cookie 拿到登录态字段（MUSIC_U/
  /// __csrf 等），真实浏览器会话还有 NMTID/_ntes_nuid/JSESSIONID-WYYY 等。
  /// `/discover` 页面会下发 NMTID（设备追踪 Cookie，网易云每次页面访问
  /// 都带），把它 harvest 进来让会话更接近真实浏览器。
  /// 只增不覆盖，不动已有登录态字段。
  ///
  /// 注意：music.163.com 首页被 CDN 缓存不吐 Set-Cookie，必须打
  /// /discover 或任一 api 路径（实测两者都会下发 NMTID）。
  ///
  /// v2.3.0-fix5 起写接口已全部改走 weapi 加密通道（见 [postWeapi]），
  /// 「明文接口 400」的根因与 Cookie 完整性无关；本方法保留是为让会话
  /// 更贴近真实浏览器，降低真风控（code=250）的概率。
  Future<void> enrichCookie() async {
    try {
      final resp = await getRaw('https://music.163.com/discover');
      final harvested = <String, String>{};
      for (final entry in resp.headers.map['set-cookie'] ?? const []) {
        final first = entry.split(';').first.trim();
        final idx = first.indexOf('=');
        if (idx <= 0) continue;
        final name = first.substring(0, idx).trim();
        final value = first.substring(idx + 1).trim();
        if (name.isNotEmpty && value.isNotEmpty) harvested[name] = value;
      }
      if (harvested.isEmpty) return;
      final merged = mergeHarvestedCookie(cookie, harvested);
      if (merged == cookie) return;
      cookie = merged;
      AppLog.i('NeteaseClient', 'Cookie 补齐完成');
    } catch (e) {
      // 补齐失败不影响登录态本身
      AppLog.w('NeteaseClient', 'Cookie 补齐失败: $e');
    }
  }

  /// 合并 harvest 到的 Cookie：**只增不覆盖**——已有字段（登录态）
  /// 优先保留，仅追加缺失的浏览器会话字段。纯函数，可单测。
  static String mergeHarvestedCookie(
      String existing, Map<String, String> harvested) {
    if (harvested.isEmpty) return existing;
    final map = <String, String>{};
    parseCookie(existing, map);
    var added = 0;
    harvested.forEach((k, v) {
      if (!map.containsKey(k)) {
        map[k] = v;
        added++;
      }
    });
    if (added == 0) return existing;
    return map.entries.map((e) => '${e.key}=${e.value}').join('; ');
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

  /// 网页版 weapi 请求（写接口必须走这条，v2.3.0-fix5）。
  ///
  /// 网易云**写接口**（发评/回复/点赞/删除）的明文 `/api` 形态已废弃：
  /// 带完整 Cookie POST 表单恒定返回 `{"code":400,"参数错误"}`，与账号和
  /// 频率无关——App 在 v2.3.0-fix3 及以前把它误判成「250 风控」。网页版
  /// 同款做法是打 `/weapi/...?csrf_token=X`，请求体为 AES 双层加密的
  /// `params` + RSA 的 `encSecKey`（见 [NeteaseWeapi]），实测同一账号
  /// 同一 Cookie 立即 code=200。
  Future<Map<String, dynamic>> postWeapi(
    String weapiUrl,
    Map<String, dynamic> payload, {
    required String csrf,
  }) {
    final encrypted = NeteaseWeapi.encrypt(payload);
    final body =
        'params=${Uri.encodeQueryComponent(encrypted.params)}'
        '&encSecKey=${Uri.encodeQueryComponent(encrypted.encSecKey)}';
    final url = '$weapiUrl?csrf_token=${Uri.encodeQueryComponent(csrf)}';
    return _postForm(body, url, isJson: false);
  }

  /// 网页版接口 GET。
  Future<Map<String, dynamic>> getApi(String apiUrl) async {
    final resp = await _retry(() => _dio.get(apiUrl,
        options: Options(headers: _baseHeaders(), validateStatus: (_) => true)));
    return _decode(resp, apiUrl);
  }

  /// 网页版接口 GET，保留原始响应（扫码登录轮询要读 Set-Cookie 里的
  /// MUSIC_U；[getApi] 只解 JSON 会把响应头丢掉）。
  Future<Response<dynamic>> getRaw(String apiUrl) async {
    return _retry(() => _dio.get(apiUrl,
        options: Options(headers: _baseHeaders(), validateStatus: (_) => true)));
  }

  Map<String, String> _baseHeaders() => {
        'User-Agent': userAgent,
        'Referer': referer,
        'Cookie': buildCookieHeader(),
        'Content-Type': 'application/x-www-form-urlencoded',
      };

  /// 连接类失败的轻量重试（最多 2 次尝试，间隔 600ms）。
  ///
  /// 线上日志里网易云歌词接口出现过 `connection timeout`（10-16 00:22:03），
  /// 一次失败用户就彻底拿不到歌词。超时/连接错误多是瞬时抖动，
  /// 重试一次大概率成功；4xx/5xx 与解析错误不重试（重试无意义）。
  Future<T> _retry<T>(Future<T> Function() op) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await op();
      } on DioException catch (e) {
        final transient = e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.connectionError;
        if (!transient || attempt >= 1) rethrow;
        AppLog.d('NeteaseClient', '请求失败，600ms 后重试: ${e.type}');
        await Future.delayed(const Duration(milliseconds: 600));
      }
    }
  }

  Future<Map<String, dynamic>> _postForm(
      String body, String url, {bool isJson = false}) async {
    final resp = await _retry(() => _dio.post(url,
        data: body,
        options: Options(headers: _baseHeaders(), validateStatus: (_) => true)));
    return _decode(resp, url);
  }

  Map<String, dynamic> _decode(Response resp, String url) {
    // Dio 的默认 responseType 是 json：响应 content-type 为 JSON 时它已经
    // 把 body 解成 Map 了（interface3 的 eapi 接口就是这样），此时不能再
    // 对 Map.toString() 做一次 jsonDecode（必然失败）。
    final data = resp.data;
    if (data is Map<String, dynamic>) {
      AppLog.d('NeteaseClient',
          '<<< HTTP ${resp.statusCode} $url resp=${jsonEncode(data).clip(500)}');
      return data;
    }
    final text = data?.toString() ?? '';
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