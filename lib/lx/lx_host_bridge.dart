import 'package:dio/dio.dart';

import 'lx_runtime.dart';

/// 默认 HTTP 桥：用 Dio 实现洛雪源脚本的 [lx.request]。
///
/// 把脚本里的 `request(url, { method, headers, body, timeout }, cb)` 映射到
/// Dio。响应体统一按**文本**返回（`ResponseType.plain`），与洛雪源脚本里
/// `resp.body` 为字符串 / 再被 `JSON.parse` 的约定一致。
class LxDioHttpClient {
  final Dio _dio;

  LxDioHttpClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              responseType: ResponseType.plain,
            ));

  Future<LxHttpResponse> call(LxHttpRequest req) async {
    final opts = req.opts;
    final method = (opts['method'] as String? ?? 'GET').toUpperCase();
    final headers = <String, dynamic>{};
    final rawHeaders = opts['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) => headers[k.toString()] = v);
    }
    final timeoutMs = opts['timeout'];
    final options = Options(
      method: method,
      headers: headers,
      responseType: ResponseType.plain,
      sendTimeout: timeoutMs is int ? Duration(milliseconds: timeoutMs) : null,
      receiveTimeout: timeoutMs is int ? Duration(milliseconds: timeoutMs) : null,
    );
    final data = opts['body'];
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
