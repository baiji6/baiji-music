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
  ///
  /// v2.3.0-fix6：weapi 请求指纹对齐真浏览器（风控 250 缓解，见
  /// [_weapiHeaders]）。
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
    return _postForm(body, url, headers: _weapiHeaders());
  }

  /// [postWeapi] 的全量形态：附返 Set-Cookie。
  ///
  /// 手机验证码登录（[loginByCellphone]）的登录态不在 body 里，而在
  /// 响应的 Set-Cookie（MUSIC_U/__csrf）——[postWeapi] 只解 body 会丢。
  Future<({Map<String, dynamic> body, List<String> setCookies})>
      postWeapiFull(
    String weapiUrl,
    Map<String, dynamic> payload, {
    required String csrf,
  }) async {
    final encrypted = NeteaseWeapi.encrypt(payload);
    final body =
        'params=${Uri.encodeQueryComponent(encrypted.params)}'
        '&encSecKey=${Uri.encodeQueryComponent(encrypted.encSecKey)}';
    final url = '$weapiUrl?csrf_token=${Uri.encodeQueryComponent(csrf)}';
    final resp = await _retry(() => _dio.post(url,
        data: body,
        options: Options(
            headers: _weapiHeaders(), validateStatus: (_) => true)));
    return (
      body: _decode(resp, url),
      setCookies: resp.headers.map['set-cookie'] ?? const <String>[],
    );
  }

  /// 从 Set-Cookie 列表拼 Cookie 串（登录接口响应用）。
  ///
  /// 与 `NeteaseQrLogin.buildCookieFromSetCookie` 同逻辑——那边在
  /// netease_qr_login.dart（反向依赖本文件），为避免循环 import 在此
  /// 保留一份纯函数实现。
  static String buildCookieFromSetCookie(List<String> setCookies) {
    final map = <String, String>{};
    for (final entry in setCookies) {
      final first = entry.split(';').first.trim();
      final idx = first.indexOf('=');
      if (idx <= 0) continue;
      final name = first.substring(0, idx).trim();
      final value = first.substring(idx + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      map[name] = value;
    }
    return map.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 当前 Cookie 里的 `__csrf`（weapi 请求必带，登录后由网易云下发）。
  String get csrfToken {
    final map = <String, String>{};
    parseCookie(cookie, map);
    return map['__csrf'] ?? '';
  }

  // ================= 手机验证码登录（v2.4.2，仿倾听） =================
  //
  // 网页版通道（weapi）：发码 POST /weapi/captcha/sent，登录 POST
  // /weapi/login/cellphone。登录态在响应 Set-Cookie（MUSIC_U），账号
  // 信息在 body 的 account/profile——与扫码登录同型。

  /// 发送登录短信验证码。
  ///
  /// 成功 code=200；失败（限频/手机号问题等）code!=200 且带 message，
  /// 直接抛给 UI 展示。
  Future<void> sendCaptcha(String phone, {String countrycode = '86'}) async {
    final resp = await postWeapi(
      'https://music.163.com/weapi/captcha/sent',
      {'phone': phone, 'ctcode': int.tryParse(countrycode) ?? 86},
      csrf: csrfToken,
    );
    final code = resp['code'];
    if (code != 200) {
      final msg = (resp['message'] ?? resp['msg'] ?? '').toString();
      throw Exception('验证码发送失败（$code）${msg.isEmpty ? '' : '：$msg'}');
    }
  }

  /// 手机号 + 短信验证码登录。
  ///
  /// 成功返回拼好的 Cookie（调用方整体替换 [cookie]）与账号信息；
  /// 业务失败（验证码错误等）抛 [NeteaseLoginException]。
  Future<NeteasePhoneLogin> loginByCellphone(
    String phone,
    String captcha, {
    String countrycode = '86',
  }) async {
    final r = await postWeapiFull(
      'https://music.163.com/weapi/login/cellphone',
      {
        'phone': phone,
        'countrycode': int.tryParse(countrycode) ?? 86,
        'captcha': captcha,
        'rememberLogin': 'true',
      },
      csrf: csrfToken,
    );
    final code = r.body['code'];
    if (code != 200) {
      final msg = (r.body['message'] ?? r.body['msg'] ?? '').toString();
      throw NeteaseLoginException(
        code is int ? code : -1,
        msg.isEmpty ? '登录失败（$code）' : msg,
      );
    }
    final setCookie =
        NeteaseClient.buildCookieFromSetCookie(r.setCookies);
    if (!setCookie.contains('MUSIC_U=')) {
      throw const NeteaseLoginException(-1, '登录成功但未取到登录态 Cookie');
    }
    final account = r.body['account'];
    final profile = r.body['profile'];
    final uid = profile is Map<String, dynamic>
        ? ((profile['userId'] ?? account is Map<String, dynamic>
                ? (account as Map<String, dynamic>)['id']
                : null) as num?)
            ?.toInt()
        : null;
    return NeteasePhoneLogin(
      cookie: setCookie,
      userId: uid ?? 0,
      nickname: profile is Map<String, dynamic>
          ? (profile['nickname'] ?? '').toString()
          : '',
    );
  }

  /// weapi（网页端通道）专用请求头：**对齐真浏览器指纹**。
  ///
  /// weapi 是网页端通道，之前通用头里的三样东西都是「非浏览器」标记，
  /// 叠在浏览器 Cookie 上会抬高风控评分（实测表现即写接口 code=250）：
  /// - UA 带 `NeteaseMusicDesktop/2.10.2`（桌面客户端标识）；
  /// - Cookie 被追加了 `os=pc; appver=…; osver=…; deviceId=pyncm!`
  ///   （桌面客户端 + 第三方库标记）；
  /// - 浏览器对同源 POST 必带的 `Origin` 头缺失。
  /// 因此 weapi 请求改用纯浏览器 UA + Origin，Cookie 原样直传不加工
  /// （eapi / 明文 api 通道维持原头不变，那些通道吃桌面客户端指纹）。
  Map<String, String> _weapiHeaders() => {
        'User-Agent': webUserAgent,
        'Referer': referer,
        'Origin': 'https://music.163.com',
        'Cookie': cookie,
        'Content-Type': 'application/x-www-form-urlencoded',
      };

  /// 纯浏览器 UA（weapi 通道专用，见 [_weapiHeaders]）。
  static const String webUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

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

  Future<Map<String, dynamic>> _postForm(String body, String url,
      {bool isJson = false, Map<String, String>? headers}) async {
    final resp = await _retry(() => _dio.post(url,
        data: body,
        options: Options(
            headers: headers ?? _baseHeaders(),
            validateStatus: (_) => true)));
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

/// 手机验证码登录结果（v2.4.2）。
class NeteasePhoneLogin {
  const NeteasePhoneLogin({
    required this.cookie,
    required this.userId,
    required this.nickname,
  });

  /// 从登录响应 Set-Cookie 拼出的登录态 Cookie（整体替换用，含 MUSIC_U）。
  final String cookie;

  /// 账号 uid（写 KvStore 的 `netease_user_id`，「我的歌单」依赖它）。
  final int userId;

  final String nickname;
}

/// 验证码登录业务失败（验证码错误 / 限频等）。
class NeteaseLoginException implements Exception {
  const NeteaseLoginException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => message;
}
