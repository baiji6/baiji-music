import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/string_clip.dart';
import 'package:baiji_music/crypto/qq_crypto.dart' as qqce;
import 'package:baiji_music/data/device_manager.dart';
import 'package:baiji_music/models/models.dart';

import 'login_api.dart';
import 'qq_http.dart';
import 'search_api.dart';
import 'song_api.dart';

/// QQ 音乐 API 客户端核心。
///
/// 对应原生 `network/QQMusicClient.kt`。原先的 JNI 原生 .so 调用
/// （buildComm / qimeiBuild / getSearchId / hash33 / qrcDecrypt）
/// 已全部替换为本工程纯 Dart 的 `qq_crypto.dart` 实现，六端完全一致。
class QQMusicClient {
  // ============ 平台档案常量（对应 Kotlin companion object） ============

  static const String musicuUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
  static const String qimeiHost =
      'https://api.tencentmusic.com/tme/trpc/proxy';
  static const int ct = 11;
  static const int cv = 14090008;
  static const int uaVersion = 14090008;
  static const String qimeiAppVersion = '14.9.0.8';
  static const String qimeiSdkVersion = '1.2.13.6';
  static const String chid = '10003505';

  static const String _loginPrefs = 'login_info';
  static const String _keyCred = 'credential_json';

  QQMusicClient({QqHttp? http}) {
    _http = http ?? QqHttp(userAgent: getUserAgent());
  }

  final DeviceManager device = DeviceManager();
  late final QqHttp _http;

  final math.Random _secure = math.Random.secure();

  // 业务模块
  late final SearchApi search = SearchApi(this);
  late final SongApi song = SongApi(this);
  late final LoginApi login = LoginApi(this);

  // ============ 凭证 ============

  Credential get credential {
    final raw = KvStore.instance.getString(
        '$_loginPrefs:$_keyCred');
    if (raw == null || raw.isEmpty) return Credential();
    try {
      return Credential.fromDict(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return Credential();
    }
  }

  set credential(Credential value) {
    KvStore.instance.setString(
      '$_loginPrefs:$_keyCred',
      jsonEncode({
        'musicid': value.musicid,
        'musickey': value.musickey,
        'loginType': value.loginType,
        'openid': value.openid,
        'refreshToken': value.refreshToken,
        'accessToken': value.accessToken,
        'unionid': value.unionid,
        'strMusicid': value.strMusicid,
        'refreshKey': value.refreshKey,
        'musickeyCreateTime': value.musickeyCreateTime,
        'keyExpiresIn': value.keyExpiresIn,
        'expiredAt': value.expiredAt,
      }),
    );
  }

  void logout() {
    KvStore.instance.remove('$_loginPrefs:$_keyCred');
  }

  bool isLoggedIn() => credential.isLoggedIn();

  /// 与 Kotlin getUserAgent() 一致：从设备 version.release 取系统版本。
  String getUserAgent() {
    final d = device.getDevice();
    final version = d['version'];
    final release = (version is Map && version['release'] != null)
        ? version['release'].toString()
        : '10';
    return 'QQMusic $uaVersion(android $release)';
  }

  // ============ HTTP ============

  /// JSON 请求（对应 Kotlin request()）。
  /// 自动携带登录 Cookie（uin / qm_keyst 等）与 User-Agent。
  Future<Map<String, dynamic>> request({
    required String method,
    required String url,
    Map<String, String>? params,
    Map<String, String>? headers,
    Map<String, dynamic>? jsonBody,
    String? bodyString,
    Map<String, String>? cookies,
  }) async {
    // 收集所有 Cookie 段，合并为单个 Cookie 头，避免重复头导致服务端取错
    final cookieParts = <String, String>{};
    headers?.forEach((k, v) {
      if (k.toLowerCase() == 'cookie') {
        cookieParts.addAll(QqHttp.parseCookieHeader(v));
      }
    });
    if (cookies != null) cookieParts.addAll(cookies);

    final cred = credential;
    if (cred.musicid != 0) {
      final id = cred.strMusicid.isNotEmpty
          ? cred.strMusicid
          : cred.musicid.toString();
      cookieParts['uin'] = id;
      cookieParts['qqmusic_uin'] = id;
      cookieParts['qm_keyst'] = cred.musickey;
      cookieParts['qqmusic_key'] = cred.musickey;
    }

    final finalHeaders = <String, String>{};
    // 业务层指定 UA 时优先保留，避免大小写变体导致重复头
    headers?.forEach((k, v) {
      if (k.toLowerCase() == 'user-agent') {
        finalHeaders['User-Agent'] = v;
      } else {
        finalHeaders[k] = v;
      }
    });
    if (!finalHeaders.containsKey('User-Agent')) {
      finalHeaders['User-Agent'] = getUserAgent();
    }
    if (cookieParts.isNotEmpty) {
      finalHeaders['Cookie'] = cookieParts.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');
    }

    return _http.jsonRequest(
      method: method,
      url: url,
      params: params,
      jsonBody: jsonBody,
      bodyString: bodyString,
      headers: finalHeaders,
    );
  }

  /// 原始文本请求（二维码登录用）。
  Future<({String text, Map<String, String> cookies})> rawRequest({
    required String method,
    required String url,
    Map<String, String>? headers,
    String? body,
  }) {
    return _http.rawRequest(
      method: method,
      url: url,
      body: body,
      headers: {'User-Agent': getUserAgent(), ...?headers},
    );
  }

  /// 禁止重定向的原始请求（登录流程取 302 Location 中的 code）。
  Future<
      ({
        String text,
        Map<String, String> cookies,
        int status,
        Map<String, String> headers,
        String location,
      })> rawRequestNoRedirect({
    required String method,
    required String url,
    Map<String, String>? headers,
    String? body,
  }) {
    return _http.rawNoRedirect(
      method: method,
      url: url,
      body: body,
      headers: {'User-Agent': getUserAgent(), ...?headers},
    );
  }

  /// 原始字节请求。
  Future<Uint8List> rawBytes(String url,
      {Map<String, String>? headers}) async {
    final r =
        await _http.rawBytes(url: url, headers: {'User-Agent': getUserAgent(), ...?headers});
    return r.bytes;
  }

  /// 单次请求同时返回响应体字节和 Set-Cookie（二维码图片 + qrsig 必须同一次请求）。
  Future<({Uint8List bytes, Map<String, String> cookies})> rawQrcode(
      String url,
      {Map<String, String>? headers}) {
    return _http.rawBytes(url: url, headers: {'User-Agent': getUserAgent(), ...?headers});
  }

  // ============ Session ============

  bool _sessionEnsured = false;

  /// 登录成功后调用，强制重新建立 session。
  void resetSession() {
    _sessionEnsured = false;
    device.sessionSaveTime = 0;
  }

  Future<void> ensureSession() async {
    if (_sessionEnsured && device.isSessionValid()) return;
    await ensureQimei();
    final comm = buildComm();
    final payload = <String, dynamic>{
      'comm': comm,
      'req_0': {
        'module': 'music.getSession.session',
        'method': 'GetSession',
        'param': {
          'uid': device.sessionUid.toString(),
          'vkey': 0,
          'caller': 0,
        },
      },
    };
    final resp = await request(
      method: 'POST',
      url: musicuUrl,
      jsonBody: payload,
    );
    final req0 = resp['req_0'];
    final session = (req0 is Map<String, dynamic>)
        ? ((req0['data'] is Map<String, dynamic>)
            ? (req0['data'] as Map<String, dynamic>)['session']
            : null)
        : null;
    if (session is Map<String, dynamic>) {
      device.sessionUid =
          int.tryParse(session['uid']?.toString() ?? '') ?? 0;
      device.sessionSid = session['sid'] as String? ?? '';
      device.sessionSaveTime =
          DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _sessionEnsured = true;
      AppLog.i('QQMusicClient',
          'getSession 成功 uid=${device.sessionUid} sid=${device.sessionSid.clip(8)}');
    } else {
      AppLog.e('QQMusicClient', 'getSession 失败: ${jsonEncode(resp).clip(500)}');
      throw Exception('获取 session 失败');
    }
  }

  // ============ QIMEI ============

  Future<void> ensureQimei() async {
    if (device.hasQimei()) return;
    final d = device.getDevice();
    final q = qqce.qimeiBuild(d);
    final body = <String, dynamic>{
      'app': 0,
      'os': 1,
      'qimeiParams': {
        'key': q['key'],
        'params': q['params'],
        'time': q['time'],
        'nonce': q['nonce'],
        'sign': q['sign'],
        'extra': q['extra'],
      },
    };
    final headers = <String, String>{
      'Host': 'api.tencentmusic.com',
      'method': 'GetQimei',
      'service': 'trpc.tme_datasvr.qimeiproxy.QimeiProxy',
      'appid': 'qimei_qq_android',
      'sign': q['header_sign'] ?? '',
      'user-agent': 'QQMusic',
      'timestamp': q['time'] ?? '',
      'Content-Type': 'application/json',
    };
    final resp = await request(
      method: 'POST',
      url: qimeiHost,
      headers: headers,
      jsonBody: body,
    );
    // data 可能是内嵌 JSON 字符串，也可能是对象
    final data = resp['data'];
    final inner = data is String
        ? (() {
            try {
              return (jsonDecode(data) as Map<String, dynamic>)['data'];
            } catch (_) {
              return null;
            }
          })()
        : (data is Map<String, dynamic> ? data['data'] : null);
    final innerMap = inner is Map<String, dynamic> ? inner : null;
    final q16 = innerMap?['q16'] as String? ?? '';
    final q36 = innerMap?['q36'] as String? ?? '';
    if (q16.isEmpty || q36.isEmpty) {
      AppLog.e('QQMusicClient',
          'QIMEI 注册失败: resp=${jsonEncode(resp).clip(500)}');
      throw Exception('QIMEI 注册失败');
    }
    device.applyQimei(q16, q36);
    AppLog.i('QQMusicClient',
        'QIMEI 注册成功 q16=${q16.clip(8)} q36=${q36.clip(8)}');
  }

  // ============ Comm ============

  /// 构建 comm 参数（对应 SecurityApi.buildComm -> qq_build_comm）。
  Map<String, dynamic> buildComm() {
    final opened = credential;
    final loggedIn = opened.isLoggedIn();
    final d = device.getDevice();
    final commStr = qqce.buildComm(
      credential: jsonDecode(opened.toJsonString()) as Map<String, dynamic>,
      device: d,
      loggedIn: loggedIn,
      q16: device.hasQimei() ? device.q16() : '',
      q36: device.hasQimei() ? device.q36() : '',
      sessionUid: device.sessionUid,
      sessionSid: device.sessionSid,
    );
    return jsonDecode(commStr) as Map<String, dynamic>;
  }

  // ============ 业务请求 ============

  /// 业务请求（返回 req_0.data）。
  Future<Map<String, dynamic>> execute(
    BizRequest req, {
    Map<String, dynamic>? extraComm,
  }) async {
    final req0 = await executeFull(req, extraComm);
    final data = req0['data'];
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  /// 返回完整 req_0（含 code 与 data），供登录流程校验错误码。
  Future<Map<String, dynamic>> executeRaw(
    BizRequest req, {
    Map<String, dynamic>? extraComm,
  }) async {
    return executeFull(req, extraComm);
  }

  Future<Map<String, dynamic>> executeFull(
    BizRequest req,
    Map<String, dynamic>? extraComm,
  ) async {
    await ensureSession();
    final comm = buildComm();
    if (extraComm != null) {
      extraComm.forEach((k, v) {
        comm[k] = v;
      });
    }
    final payload = <String, dynamic>{
      'comm': comm,
      'req_0': {
        'module': req.module,
        'method': req.method,
        'param': boolToInt(req.param),
      },
    };
    AppLog.d('QQMusicClient',
        '业务请求 module=${req.module} method=${req.method} 已登录=${credential.isLoggedIn()}');
    final resp = await request(
      method: 'POST',
      url: musicuUrl,
      jsonBody: payload,
    );
    final req0 = resp['req_0'];
    if (req0 is! Map<String, dynamic>) {
      throw CgiException(-1, '响应缺少 req_0');
    }
    final code = req0['code'] as int? ?? -1;
    AppLog.d('QQMusicClient',
        '业务响应 ${req.module}.${req.method} code=$code msg=${req0['msg']}');
    if (code != 0 && !req.allowErrorCodes) {
      throw CgiException(code, req0['msg']?.toString() ?? '');
    }
    return req0;
  }

  /// 递归将布尔值转 1/0（对应 Kotlin boolToInt）。
  static dynamic boolToInt(dynamic o) {
    if (o is bool) return o ? 1 : 0;
    if (o is Map<String, dynamic>) {
      return o.map((k, v) => MapEntry(k, boolToInt(v)));
    }
    if (o is List) {
      return o.map(boolToInt).toList();
    }
    return o;
  }

  /// 搜索 ID（对应 SecurityApi.getSearchId -> jni_bridge nativeGetSearchId）。
  String getSearchId() {
    final e = _secure.nextInt(20) + 1; // [1, 20]
    final t = e * 18014398509481984;
    final n = _secure.nextInt(4194304) * 4294967296; // [0, 4194303]
    final now = DateTime.now().millisecondsSinceEpoch;
    final r = now % 86400000;
    return (t + n + r).toString();
  }

  /// 随机 UUID v4（对应 Kotlin randomUuid()）。
  String randomUuid() {
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _secure.nextInt(256);
    }
    bytes[6] = ((bytes[6] & 0x0f) | 0x40);
    bytes[8] = ((bytes[8] & 0x3f) | 0x80);
    final sb = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
      if (i == 3 || i == 5 || i == 7 || i == 9) sb.write('-');
    }
    return sb.toString();
  }
}

/// 业务请求参数（对应 Kotlin BizRequest data class）。
class BizRequest {
  final String module;
  final String method;
  final Map<String, dynamic> param;
  final bool allowErrorCodes;

  const BizRequest({
    required this.module,
    required this.method,
    required this.param,
    this.allowErrorCodes = false,
  });
}

/// CG 业务错误（对应 Kotlin CgiException）。
class CgiException implements Exception {
  final int code;
  final String msg;

  const CgiException(this.code, this.msg);

  @override
  String toString() => '业务错误 $code: $msg';
}