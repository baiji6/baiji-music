import 'dart:convert';
import 'dart:typed_data';

import 'package:baiji_music/core/string_clip.dart';
import 'package:dio/dio.dart';

/// QQ 音乐 HTTP 封装（对应原生 `QQMusicClient.request/rawRequest/...`）。
///
/// 与 Kotlin 版行为保持一致：
/// - 内存态 Cookie Jar（按 host 存储）
/// - 支持自定义 UA、Cookie 头合并、Set-Cookie 解析
/// - `noRedirect` 用于登录流程取 302 Location 中的 code
class QqHttp {
  QqHttp({String? userAgent})
      : defaultUserAgent = userAgent ?? 'QQMusic 14090008(android 10)' {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
      followRedirects: false,
      validateStatus: (_) => true,
    ));
  }

  final String defaultUserAgent;
  late final Dio _dio;

  final Map<String, List<Map<String, String>>> _cookieStore = {};

  /// 显式设置整段 Cookie（供登录成功后注入），按解析后的键值存入 host。
  void setCookies(String host, String cookieHeader) {
    final parts = parseCookieHeader(cookieHeader);
    _cookieStore[host] = parts.entries.map((e) => {e.key: e.value}).toList();
  }

  Map<String, String> cookiesFor(String host) {
    final list = _cookieStore[host] ?? const [];
    final map = <String, String>{};
    for (final e in list) {
      map.addAll(e);
    }
    return map;
  }

  /// 解析 "k=v; k=v" 形式的 Cookie 头。
  static Map<String, String> parseCookieHeader(String header) {
    final out = <String, String>{};
    for (final part in header.split(';')) {
      final seg = part.trim();
      if (seg.isEmpty) continue;
      final idx = seg.indexOf('=');
      if (idx <= 0) continue;
      final k = seg.substring(0, idx).trim();
      final v = seg.substring(idx + 1).trim();
      if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
    }
    return out;
  }

  /// 从 Set-Cookie 响应头提取 cookies（保留首个值）。
  static Map<String, String> parseSetCookies(List<String> setCookie) {
    final out = <String, String>{};
    for (final c in setCookie) {
      final first = c.split(';').first.trim();
      final idx = first.indexOf('=');
      if (idx <= 0) continue;
      final name = first.substring(0, idx).trim();
      final value = first.substring(idx + 1).trim();
      if (value.isNotEmpty) out[name] = value;
    }
    return out;
  }

  static List<String> _setCookieHeaders(Response resp) {
    final raw = resp.headers.map;
    final out = <String>[];
    raw.forEach((k, v) {
      if (k.toLowerCase() == 'set-cookie') out.addAll(v);
    });
    return out;
  }

  /// JSON 请求（自动带 UA，合并 Cookie）。
  Future<Map<String, dynamic>> jsonRequest({
    required String method,
    required String url,
    Map<String, String>? params,
    Map<String, dynamic>? jsonBody,
    String? bodyString,
    Map<String, String>? headers,
    Map<String, String>? cookies,
  }) async {
    final uri = Uri.parse(url).replace(queryParameters: params);
    final host = uri.host;

    final cookieParts = <String, String>{};
    headers?.forEach((k, v) {
      if (k.toLowerCase() == 'cookie') {
        cookieParts.addAll(parseCookieHeader(v));
      }
    });
    if (cookies != null) cookieParts.addAll(cookies);

    final finalHeaders = <String, String>{
      'User-Agent': defaultUserAgent,
      if (cookieParts.isNotEmpty)
        'Cookie': cookieParts.entries.map((e) => '${e.key}=${e.value}').join('; '),
      ...?headers,
    };

    final resp = await _dio.request(
      uri.toString(),
      data: jsonBody != null
          ? jsonEncode(jsonBody)
          : bodyString,
      options: Options(
        method: method,
        headers: finalHeaders,
        contentType: jsonBody != null ? 'application/json' : null,
      ),
    );

    // 保存 Set-Cookie
    final setCookies = parseSetCookies(_setCookieHeaders(resp));
    if (setCookies.isNotEmpty) {
      final cur = cookiesFor(host);
      cur.addAll(setCookies);
      _cookieStore[host] = cur.entries.map((e) => {e.key: e.value}).toList();
    }

    final text = _respText(resp);
    if (text.isEmpty) return {};
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      throw DioException.connectionError(
        requestOptions: resp.requestOptions,
        reason: '非法 JSON: ${text.clip(200)}',
      );
    }
  }

  /// 原始文本请求（不解析 JSON），返回响应文本 + Set-Cookie。
  Future<({String text, Map<String, String> cookies})> rawRequest({
    required String method,
    required String url,
    Map<String, String>? params,
    String? body,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse(url).replace(queryParameters: params);
    final resp = await _dio.request(
      uri.toString(),
      data: body,
      options: Options(
        method: method,
        headers: {'User-Agent': defaultUserAgent, ...?headers},
      ),
    );
    final cookies = parseSetCookies(_setCookieHeaders(resp));
    return (text: _respText(resp), cookies: cookies);
  }

  /// 禁止重定向的原始请求，返回状态码、Location、头、Cookie（登录用）。
  Future<({String text, Map<String, String> cookies, int status, Map<String, String> headers, String location})>
      rawNoRedirect({
    required String method,
    required String url,
    Map<String, String>? params,
    String? body,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse(url).replace(queryParameters: params);
    final resp = await _dio.request(
      uri.toString(),
      data: body,
      options: Options(
        method: method,
        headers: {'User-Agent': defaultUserAgent, ...?headers},
        followRedirects: false,
      ),
    );
    final cookies = parseSetCookies(_setCookieHeaders(resp));
    final headerMap = <String, String>{};
    resp.headers.forEach((k, v) {
      if (!headerMap.containsKey(k.toLowerCase())) {
        headerMap[k.toLowerCase()] = v.firstOrNull ?? '';
      }
    });
    final location = headerMap['location'] ?? '';
    return (
      text: _respText(resp),
      cookies: cookies,
      status: resp.statusCode ?? -1,
      headers: headerMap,
      location: location,
    );
  }

  /// 原始字节请求（二维码图片）。
  Future<({Uint8List bytes, Map<String, String> cookies})> rawBytes(
      {required String url, Map<String, String>? headers}) async {
    final resp = await _dio.request(
      url,
      options: Options(
        method: 'GET',
        headers: {'User-Agent': defaultUserAgent, ...?headers},
        responseType: ResponseType.bytes,
      ),
    );
    final data = resp.data;
    final bytes = data is Uint8List
        ? data
        : data is List<int>
            ? Uint8List.fromList(data)
            : _respText(resp).codeUnits;
    final cookies = parseSetCookies(_setCookieHeaders(resp));
    return (bytes: Uint8List.fromList(bytes), cookies: cookies);
  }

  String _respText(Response resp) {
    final d = resp.data;
    if (d is String) return d;
    if (d is List<int>) return utf8.decode(d, allowMalformed: true);
    if (d != null && (d is Map || d is List)) return jsonEncode(d);
    return '';
  }
}