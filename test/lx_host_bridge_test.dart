import 'dart:convert';
import 'dart:typed_data';

import 'package:baiji_music/lx/lx_host_bridge.dart';
import 'package:baiji_music/lx/lx_runtime.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 拦截全部请求，断言 Dart 侧给 Dio 的参数并返回可控响应。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.onFetch);

  final Future<ResponseBody> Function(RequestOptions options) onFetch;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      onFetch(options);

  @override
  void close({bool force = false}) {}
}

void main() {
  group('LxDioHttpClient.prepareBody（纯函数）', () {
    test('Map body + JSON content-type → JSON 字符串', () {
      final r = LxDioHttpClient.prepareBody(
          {'a': 1, 'b': 'x'}, {'Content-Type': 'application/json'});
      expect(r, isA<String>());
      expect(jsonDecode(r as String), {'a': 1, 'b': 'x'});
    });

    test('Map body 未声明 content-type 也按 JSON 编码', () {
      expect(LxDioHttpClient.prepareBody({'a': 1}, {}), jsonEncode({'a': 1}));
    });

    test('String body + octet-stream 原样透传', () {
      const raw = 'binary-ish';
      expect(
          LxDioHttpClient.prepareBody(
              raw, {'content-type': 'application/octet-stream'}),
          raw);
    });

    test('List body 按 JSON 编码；null 原样；content-type 大小写不敏感', () {
      expect(LxDioHttpClient.prepareBody([1, 2], {}), '[1,2]');
      expect(LxDioHttpClient.prepareBody(null, {}), isNull);
      expect(
          LxDioHttpClient.prepareBody(
              {'a': 1}, {'CONTENT-TYPE': 'APPLICATION/JSON'}),
          jsonEncode({'a': 1}));
    });

    test('非 JSON content-type 时 Map 交 Dio form 编码', () {
      final r = LxDioHttpClient.prepareBody(
          {'a': '1'}, {'Content-Type': 'application/x-www-form-urlencoded'});
      expect(r, isA<Map>());
    });
  });

  group('LxDioHttpClient.call（注入 adapter）', () {
    test('POST 请求体显式编码 / headers 回填 / 非 2xx 响应体保留', () async {
      late RequestOptions captured;
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((options) async {
        captured = options;
        return ResponseBody.fromString(
          jsonEncode({'code': 429, 'message': '请求过速'}),
          429,
          headers: {
            'content-type': ['application/json'],
            'x-test': ['yes'],
          },
        );
      });
      final client = LxDioHttpClient(dio: dio);
      final resp = await client.call(LxHttpRequest(
        url: 'https://example/music/url',
        opts: {
          'method': 'POST',
          'headers': {'Content-Type': 'application/json'},
          'body': {'source': 'tx', 'quality': '128k'},
          'timeout': 5000,
          'follow_max': 5,
        },
      ));
      expect(resp.statusCode, 429);
      expect(resp.body, contains('请求过速'));
      expect(resp.headers['x-test'], 'yes');
      expect(captured.method, 'POST');
      expect(captured.data, isA<String>());
      expect(jsonDecode(captured.data as String),
          {'source': 'tx', 'quality': '128k'});
      expect(captured.connectTimeout, const Duration(milliseconds: 5000));
      expect(captured.maxRedirects, 5);
      expect(captured.validateStatus(429), isTrue);
    });

    test('GET 200 正常回传 body 与 headers', () async {
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((options) async {
        expect(options.method, 'GET');
        return ResponseBody.fromString(
          'hello-plain',
          200,
          headers: {
            'x-env': ['test'],
          },
        );
      });
      final resp = await LxDioHttpClient(dio: dio).call(LxHttpRequest(
        url: 'https://example/ping',
        opts: {'method': 'GET'},
      ));
      expect(resp.statusCode, 200);
      expect(resp.body, 'hello-plain');
      expect(resp.headers['x-env'], 'test');
    });
  });
}
