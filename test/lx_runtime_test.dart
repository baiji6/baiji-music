import 'dart:convert';
import 'dart:io';

import 'package:baiji_music/lx/lx_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String baimusicPath = 'test/res/lx_sources/baimusic.js';
  const String ikunPath = 'test/res/lx_sources/ikun.js';
  // 用户提供的测试源按需求「发布时不上传到项目」，已加入 .gitignore。
  // 夹具缺失（CI / 发布 checkout）时相关测试自动跳过，全量测试仍全绿；
  // 本地把 4 个源放进 test/res/lx_sources/ 即可完整验证真实插件契约。
  final bool hasBaimusic = File(baimusicPath).existsSync();
  final bool hasIkun = File(ikunPath).existsSync();
  const String noFixture = '未提供测试音源夹具（发布时不随工程分发）';

  Future<String> readSource(String p) => File(p).readAsString();

  /// 返回固定响应的桩 HTTP 桥（网关源会忽略 URL，只关心 body）。
  Future<LxHttpResponse> cannedHandler(LxHttpRequest req) async =>
      LxHttpResponse(
          statusCode: 200, body: jsonEncode({'url': 'http://cdn/test.flac'}));

  group('LxRuntime 宿主桥（PoC）', () {
    test('baimusic 脚本加载并捕获 inited 声明', () async {
      final rt = LxRuntime(http: cannedHandler);
      final script = await readSource(baimusicPath);
      rt.loadScript(script);
      expect(rt.inited, isNotNull);
      final sources = rt.inited!['sources'] as Map;
      expect(sources.containsKey('kw'), isTrue);
      expect(sources.containsKey('tx'), isTrue);
      rt.close();
    }, skip: hasBaimusic ? null : noFixture);

    test('baimusic musicUrl 经 lx.request→Dart→resolve 拿到直链（异步桥闭环）',
        () async {
      final rt = LxRuntime(http: cannedHandler);
      rt.loadScript(await readSource(baimusicPath));
      final res = await rt.dispatch('request', {
        'action': 'musicUrl',
        'source': 'kw',
        'info': {
          'musicInfo': {'songmid': '123456'},
          'type': 'flac',
        },
      });
      expect(res.isError, isFalse);
      expect(res.url, equals('http://cdn/test.flac'));
      rt.close();
    }, skip: hasBaimusic ? null : noFixture);

    test('ikun 脚本加载并捕获 inited（含多子源）', () async {
      final rt = LxRuntime(http: cannedHandler);
      rt.loadScript(await readSource(ikunPath));
      expect(rt.inited, isNotNull);
      final sources = rt.inited!['sources'] as Map;
      // ikun 支持 git/kg/kw/tx/wy 等
      expect(sources.isNotEmpty, isTrue);
      rt.close();
    }, skip: hasIkun ? null : noFixture);
  });

  group('LxRuntime utils.crypto 正确性（同步加密桥）', () {
    late LxRuntime rt;
    setUp(() {
      rt = LxRuntime(http: cannedHandler);
    });
    tearDown(() => rt.close());

    String evalCrypto(String expr) {
      final r = rt.rawRuntime.evaluate(expr);
      return r.stringResult;
    }

    test('md5 / sha1 / sha256 已知向量', () {
      expect(evalCrypto("lx.utils.crypto.md5('abc')"),
          equals('900150983cd24fb0d6963f7d28e17f72'));
      expect(evalCrypto("lx.utils.crypto.md5('')"),
          equals('d41d8cd98f00b204e9800998ecf8427e'));
      expect(evalCrypto("lx.utils.crypto.sha1('abc')"),
          equals('a9993e364706816aba3e25717850c26c9cd0d89d'));
      expect(evalCrypto("lx.utils.crypto.sha256('abc')"),
          equals('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'));
    });

    test('hmacSha1 / hmacSha256 已知向量', () {
      // HMAC("key", "The quick brown fox jumps over the lazy dog")
      const msg = 'The quick brown fox jumps over the lazy dog';
      expect(evalCrypto("lx.utils.crypto.hmacSha1('$msg', 'key')"),
          equals('de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9'));
      expect(evalCrypto("lx.utils.crypto.hmacSha256('$msg', 'key')"),
          equals('f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8'));
    });

    test('randomBytes 返回 BufferLike（可 toString / toJSON）', () {
      expect(evalCrypto('lx.utils.crypto.randomBytes(16).toJSON().length'),
          equals('16'));
      expect(evalCrypto('lx.utils.crypto.randomBytes(24).toString("hex").length'),
          equals('48'));
    });

    test('aesEncrypt / aesDecrypt ECB 往返（PKCS7）', () {
      expect(
          evalCrypto(
              "lx.utils.crypto.aesDecrypt(lx.utils.crypto.aesEncrypt('hello白姬', '0123456789abcdef'), '0123456789abcdef').toString()"),
          equals('hello白姬'));
    });

    test('TextEncoder / Buffer polyfill', () {
      expect(evalCrypto("new TextEncoder().encode('ab').length"), equals('2'));
      expect(evalCrypto("Buffer.from('48656c6c6f','hex').toString()"),
          equals('Hello'));
    });
  });
}
