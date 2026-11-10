import 'dart:convert';

import 'package:dio/dio.dart';

import 'lx_runtime.dart';

/// 默认 HTTP 桥：用 Dio 实现洛雪源脚本的 [lx.request]。
///
/// 把脚本里的 `request(url, { method, headers, body, timeout }, cb)` 映射到
/// Dio。响应体统一按**文本**返回（`ResponseType.plain`），由 bootstrap 的
/// `__lxBody` 决定以字符串还是已解析对象交给脚本（见 lx_bootstrap.dart）。
class LxDioHttpClient {
  final Dio _dio;

  LxDioHttpClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              responseType: ResponseType.plain,
            ));

  /// 把脚本传来的 `body` 归一成 Dio 可发送的 data（v2.5.7-pre2）。
  ///
  /// dio 5.11.1 在 JSON content-type 下本就会自动 jsonEncode Map，这里显式
  /// 化以消除对隐式行为/版本的依赖，并覆盖「Map body 但未声明 content-type」
  /// 的音源。字符串（如 baimusic 的二进制密文 + octet-stream）原样透传。
  static Object? prepareBody(dynamic body, Map<String, dynamic> headers) {
    if (body == null || body is String) return body;
    if (body is! Map && body is! List) return body.toString();
    String? contentType;
    headers.forEach((k, v) {
      if (k.toString().toLowerCase() == 'content-type') {
        contentType = v?.toString();
      }
    });
    final jsonLike =
        contentType == null || contentType!.toLowerCase().contains('json');
    return jsonLike ? jsonEncode(body) : body;
  }

  Future<LxHttpResponse> call(LxHttpRequest req) async {
    final opts = req.opts;
    final method = (opts['method'] as String? ?? 'GET').toUpperCase();
    final headers = <String, dynamic>{};
    final rawHeaders = opts['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) => headers[k.toString()] = v);
    }
    final timeoutMs = opts['timeout'];
    final timeout =
        timeoutMs is int ? Duration(milliseconds: timeoutMs) : null;
    final followMax = opts['follow_max'];
    final options = Options(
      method: method,
      headers: headers,
      responseType: ResponseType.plain,
      connectTimeout: timeout,
      sendTimeout: timeout,
      receiveTimeout: timeout,
      // 非 2xx 也把响应体交还脚本：ikun 会读 403/429/500 的 body.message
      // 再抛可读错误，Dio 默认的 validateStatus 会直接吞掉这些 body。
      validateStatus: (_) => true,
      maxRedirects: followMax is int ? followMax : null,
    );
    final data = prepareBody(opts['body'], headers);
    late final Response resp;
    switch (method) {
      case 'GET':
        resp = await _dio.get(req.url, options: options);
      case 'HEAD':
        resp = await _dio.head(req.url, options: options);
      case 'POST':
        resp = await _dio.post(req.url, data: data, options: options);
      default:
        resp = await _dio.request(req.url, data: data, options: options);
    }
    final body = resp.data is String ? resp.data as String : '';
    return LxHttpResponse(
      statusCode: resp.statusCode ?? 200,
      body: body,
      headers: resp.headers.map
          .map((k, v) => MapEntry(k, v.isNotEmpty ? v.first : '')),
    );
  }
}
