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

  // v2.5.7-pre3：LX-X preload 的 request options 超集（form/formData/binary）
  // 与响应 statusMessage。这些是标准音源常用的能力，缺失会静默取链失败。
  group('LxDioHttpClient LX-X options（v2.5.7-pre3）', () {
    test('encodeForm：Map → urlencoded；String 原样；特殊字符被编码', () {
      expect(LxDioHttpClient.encodeForm({'a': '1', 'b': '2'}), 'a=1&b=2');
      expect(LxDioHttpClient.encodeForm('raw=1&x=2'), 'raw=1&x=2');
      expect(LxDioHttpClient.encodeForm({'n': null}), 'n=');
      final enc = LxDioHttpClient.encodeForm({'q': '白 姬&x'});
      expect(enc, isNot(contains(' ')), reason: '空格必须被编码');
      expect(enc, isNot(contains('姬')), reason: '中文必须百分号编码');
      expect(enc, contains('%26'), reason: '& 不得作为参数分隔符裸露');
    });

    test('form 选项：urlencoded 编码 + 自动补 content-type', () async {
      late RequestOptions captured;
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((options) async {
        captured = options;
        return ResponseBody.fromString('ok', 200);
      });
      await LxDioHttpClient(dio: dio).call(LxHttpRequest(
        url: 'https://example/gateway',
        opts: {
          'method': 'POST',
          'form': {'source': 'tx', 'id': '001'},
        },
      ));
      expect(captured.data, 'source=tx&id=001');
      final ct = captured.headers.entries
          .firstWhere((e) => e.key.toLowerCase() == 'content-type')
          .value;
      expect(ct, 'application/x-www-form-urlencoded');
    });

    test('formData 选项：Map → FormData', () async {
      late RequestOptions captured;
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((options) async {
        captured = options;
        return ResponseBody.fromString('ok', 200);
      });
      await LxDioHttpClient(dio: dio).call(LxHttpRequest(
        url: 'https://example/upload',
        opts: {
          'method': 'POST',
          'formData': {'file': 'abc', 'k': 'v'},
        },
      ));
      expect(captured.data, isA<FormData>());
      final fd = captured.data as FormData;
      expect(fd.fields.map((e) => e.key),
          containsAll(<String>['file', 'k']));
    });

    test('binary 选项：响应按字节返回 base64，statusMessage / headers 回填',
        () async {
      final bytes = <int>[0, 1, 2, 253, 254, 255];
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((options) async {
        expect(options.responseType, ResponseType.bytes);
        return ResponseBody.fromBytes(
          bytes,
          206,
          statusMessage: 'Partial Content',
          headers: {
            'content-type': ['application/octet-stream'],
            'x-multi': ['first', 'second'],
          },
        );
      });
      final resp = await LxDioHttpClient(dio: dio).call(LxHttpRequest(
        url: 'https://example/audio',
        opts: {'method': 'GET', 'binary': true},
      ));
      expect(resp.binary, isTrue);
      expect(resp.body, base64Encode(bytes));
      expect(resp.statusCode, 206);
      expect(resp.statusMessage, 'Partial Content');
      expect(resp.headers['content-type'], 'application/octet-stream');
      expect(resp.headers['x-multi'], 'first',
          reason: '多值 header 取第一个');
    });

    test('timeout 被 clamp 到 [1, 60000] ms', () async {
      late RequestOptions captured;
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((options) async {
        captured = options;
        return ResponseBody.fromString('ok', 200);
      });
      await LxDioHttpClient(dio: dio).call(LxHttpRequest(
        url: 'https://example/t',
        opts: {'method': 'GET', 'timeout': 999999},
      ));
      expect(captured.connectTimeout, const Duration(milliseconds: 60000));
    });
  });
}
