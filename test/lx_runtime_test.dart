import 'dart:convert';
import 'dart:io';

import 'package:baiji_music/lx/lx_runtime.dart';
import 'package:crypto/crypto.dart' as crypto;
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

    String evalCrypto(String expr) => rt.eval(expr);

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

  // v2.5.7-pre2：宿主契约加固。pre1 的 resp.body 恒为字符串，ikun 直接读
  // body.code 必抛 "unknow error"；console.groupEnd / EVENT_NAMES.updateAlert
  // 缺失也会打断脚本。下面用内联脚本 + 真实夹具同时锁住这几条修复。
  group('洛雪宿主契约加固（v2.5.7-pre2）', () {
    /// 按 URL 区分 JSON / 纯文本响应，并带上自定义响应头。
    Future<LxHttpResponse> probeHandler(LxHttpRequest req) async {
      if (req.url.contains('/text')) {
        return LxHttpResponse(
            statusCode: 200,
            body: 'plain-not-json',
            headers: const {'x-test': 'yes'});
      }
      return LxHttpResponse(
        statusCode: 200,
        body: jsonEncode({'code': 200, 'url': 'http://cdn/ikun.flac'}),
        headers: const {'x-test': 'yes'},
      );
    }

    test('console 补齐 groupEnd / group / table / timeEnd', () {
      final rt = LxRuntime(http: probeHandler);
      expect(
          rt.eval("typeof console.groupEnd === 'function' && "
              "typeof console.group === 'function' && "
              "typeof console.table === 'function' && "
              "typeof console.timeEnd === 'function'"),
          'true');
      rt.close();
    });

    test('EVENT_NAMES 补齐 updateAlert / updateLog / log / error', () {
      final rt = LxRuntime(http: probeHandler);
      expect(
          rt.eval("lx.EVENT_NAMES.updateAlert + '|' + "
              "lx.EVENT_NAMES.updateLog + '|' + "
              "lx.EVENT_NAMES.log + '|' + lx.EVENT_NAMES.error"),
          'updateAlert|updateLog|log|error');
      rt.close();
    });

    test('lx.request：JSON 体→对象、非 JSON 体→字符串、headers 透传',
        () async {
      final rt = LxRuntime(http: probeHandler);
      const script = r'''
const { EVENT_NAMES, on, send, request } = globalThis.lx
send(EVENT_NAMES.inited, { status: true, sources: {} })
on(EVENT_NAMES.request, () => new Promise((resolve) => {
  request('https://example/json', {}, (err, resp) => {
    if (err) return resolve({ fatal: String(err) })
    request('https://example/text', {}, (err2, resp2) => {
      if (err2) return resolve({ fatal: String(err2) })
      resolve({
        jsonType: typeof resp.body,
        jsonCode: resp.body.code,
        textType: typeof resp2.body,
        text: resp2.body,
        header: resp.headers['x-test'],
      })
    })
  })
}))
''';
      rt.loadScript(script);
      final res = await rt.dispatch('request', {'action': 'probe'});
      expect(res.isError, isFalse, reason: '${res.error}');
      expect(res.field('jsonType'), 'object');
      expect(res.field('jsonCode'), 200);
      expect(res.field('textType'), 'string');
      expect(res.field('text'), 'plain-not-json');
      expect(res.field('header'), 'yes');
      rt.close();
    });

    // 现有「baimusic musicUrl 拿到直链」用例即不回归保证：cannedHandler
    // 返回 JSON 字符串，修复后 __lxBody 解析成对象，baimusic.parseBody
    // 对非字符串直接 return，body.url 仍可用。
    test('ikun 真实音源取链成功（锁 resp.body 对象化 + console/EVENT_NAMES）',
        () async {
      final rt = LxRuntime(http: probeHandler);
      rt.loadScript(await readSource(ikunPath));
      final res = await rt.dispatch('request', {
        'action': 'musicUrl',
        'source': 'tx',
        'info': {
          'musicInfo': {'hash': 'HASH1', 'songmid': 'MID1'},
          'type': '128k',
        },
      });
      expect(res.isError, isFalse, reason: '${res.error}');
      expect(res.url, 'http://cdn/ikun.flac');
      rt.close();
    }, skip: hasIkun ? null : noFixture);
  });

  // v2.5.7-pre3：按 LX-X `user-api-preload.js` 重建的宿主契约。之前只围绕
  // 用户导入的 4 个音源打补丁，换一个音源就取不了流。这里锁住 env/version、
  // currentScriptInfo、三参 request 回调、abort、定时器、全局 polyfill、
  // 以及 crypto 的 LX-X 语义，确保任意符合 LX-X 环境的音源都能加载取流。
  group('LX-X 宿主契约（v2.5.7-pre3）', () {
    LxRuntime makeRuntime([LxHttpRequestHandler? http]) =>
        LxRuntime(http: http ?? cannedHandler);

    // 布尔/对象一律用 String(...) 包裹，避免依赖 stringResult 对 JS 类型的
    // 转换差异，断言稳定落在字符串上；eval 已是引擎无关的归一化文本。
    String ev(LxRuntime rt, String expr) => rt.eval(expr);

    test('lx 契约：env=mobile / version=2.0.0 / EVENT_NAMES / currentScriptInfo',
        () {
      final rt = makeRuntime();
      expect(ev(rt, 'lx.env'), 'mobile');
      expect(ev(rt, 'lx.version'), '2.0.0');
      expect(ev(rt, 'lx.EVENT_NAMES.request'), 'request');
      expect(ev(rt, 'lx.EVENT_NAMES.inited'), 'inited');
      expect(ev(rt, 'lx.EVENT_NAMES.updateAlert'), 'updateAlert');
      expect(ev(rt, 'typeof lx.currentScriptInfo'), 'object');
      expect(ev(rt, "Object.keys(lx.currentScriptInfo).sort().join(',')"),
          'author,description,homepage,name,rawScript,version');
      expect(
          ev(rt, "String(lx.on('request', function () {}) instanceof Promise)"),
          'true');
      expect(ev(rt, "String(lx.send('log', { a: 1 }) instanceof Promise)"),
          'true');
      rt.close();
    });

    test('loadScript 注入 currentScriptInfo，rawScript getter 取回原文', () {
      final rt = makeRuntime();
      const src = 'const __lx_probe = 42;';
      rt.loadScript(src, scriptInfo: <String, dynamic>{
        'name': '我的音源',
        'version': '9.9.9',
        'author': 'tester',
        'homepage': 'https://example/home',
        'description': '契约测试',
      });
      expect(ev(rt, 'lx.currentScriptInfo.name'), '我的音源');
      expect(ev(rt, 'lx.currentScriptInfo.version'), '9.9.9');
      expect(ev(rt, 'lx.currentScriptInfo.author'), 'tester');
      expect(ev(rt, 'lx.currentScriptInfo.homepage'), 'https://example/home');
      expect(ev(rt, 'lx.currentScriptInfo.description'), '契约测试');
      expect(ev(rt, 'lx.currentScriptInfo.rawScript'), src);
      rt.close();
    });

    test('send(inited) 按 LX-X 支持范围规范化 sources', () {
      final rt = makeRuntime();
      rt.loadScript(r'''
const { EVENT_NAMES, send } = globalThis.lx
send(EVENT_NAMES.inited, { status: true, sources: {
  kw: { type: 'music', actions: ['musicUrl', 'lyric'], qualitys: ['128k', 'bad_q', 'flac'] },
  tx: { actions: ['musicUrl'], qualitys: ['320k'] },
  mg: { type: 'other', actions: ['musicUrl'], qualitys: ['128k'] },
  zz: { actions: ['musicUrl'], qualitys: ['128k'] }
} })
''');
      final init = rt.inited;
      expect(init, isNotNull);
      expect(init!['status'], isTrue);
      final sources = init['sources'] as Map;
      expect(sources.containsKey('zz'), isFalse,
          reason: '非 allSources 子源被剔除');
      expect(sources.containsKey('mg'), isFalse,
          reason: 'type != music 被剔除');
      final kw = sources['kw'] as Map;
      expect(kw['type'], 'music');
      expect(kw['actions'], ['musicUrl'], reason: '非法 action 被裁剪');
      expect(kw['qualitys'], ['128k', 'flac'], reason: '非法音质被裁剪');
      final tx = sources['tx'] as Map;
      expect(tx['name'], 'tx', reason: '省略 name 回退到子源 id');
      expect(tx['qualitys'], ['320k']);
      rt.close();
    });

    test('lx.request 三参回调 (err, resp, body)；resp 含 statusMessage/headers；返回 abort',
        () async {
      Future<LxHttpResponse> handler(LxHttpRequest req) async => LxHttpResponse(
            statusCode: 200,
            body: jsonEncode({'code': 0, 'url': 'http://cdn/x.flac'}),
            headers: const {'x-echo': 'ok'},
            statusMessage: 'OK',
          );
      final rt = makeRuntime(handler);
      const script = r'''
const { EVENT_NAMES, on, send, request } = globalThis.lx
send(EVENT_NAMES.inited, { status: true, sources: {} })
on(EVENT_NAMES.request, () => new Promise((resolve) => {
  const abort = request('https://example/json', {}, (err, resp, body) => {
    if (err) return resolve({ fatal: String(err) })
    resolve({
      hasResp: String(resp !== null),
      statusCode: resp.statusCode,
      statusMessage: resp.statusMessage,
      header: resp.headers['x-echo'],
      bodyType: typeof body,
      bodyCode: body.code,
      respBodyCode: resp.body.code,
      sameRef: String(body === resp.body),
      abortType: typeof abort,
      abortOk: String((function () { try { abort(); return true } catch (e) { return false } })())
    })
  })
}))
''';
      rt.loadScript(script);
      final res = await rt.dispatch('request', {'action': 'probe'});
      expect(res.isError, isFalse, reason: '${res.error}');
      expect(res.field('hasResp'), 'true');
      expect(res.field('statusCode'), 200);
      expect(res.field('statusMessage'), 'OK');
      expect(res.field('header'), 'ok');
      expect(res.field('bodyType'), 'object');
      expect(res.field('bodyCode'), 0);
      expect(res.field('respBodyCode'), 0);
      expect(res.field('sameRef'), 'true');
      expect(res.field('abortType'), 'function');
      expect(res.field('abortOk'), 'true');
      rt.close();
    });

    test('lx.request abort() 后迟到响应不再回调（Dart 丢弃已废弃请求）',
        () async {
      // HTTP 固定延迟 60ms；脚本 10ms 就 abort 并 resolve，用于验证迟到的
      // 响应不会再触发已废弃的回调。
      Future<LxHttpResponse> handler(LxHttpRequest req) async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return LxHttpResponse(statusCode: 200, body: '{"x":1}');
      }

      final rt = makeRuntime(handler);
      const script = r'''
globalThis.__fired = false
const { EVENT_NAMES, on, send, request } = globalThis.lx
send(EVENT_NAMES.inited, { status: true, sources: {} })
on(EVENT_NAMES.request, () => new Promise((resolve) => {
  const abort = request('https://example/slow', {}, () => { globalThis.__fired = true })
  abort()
  setTimeout(() => resolve({ firedBefore: String(globalThis.__fired) }), 10)
}))
''';
      rt.loadScript(script);
      final res = await rt.dispatch('request', {'action': 'probe'});
      expect(res.field('firedBefore'), 'false');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(ev(rt, 'String(globalThis.__fired)'), 'false',
          reason: 'abort 后迟到响应不得再触发回调');
      rt.close();
    });

    test('setTimeout 回调由 Dart Timer 驱动（LX-X 定时器桥闭环）', () async {
      final rt = makeRuntime();
      const script = r'''
globalThis.__timerFired = false
const { EVENT_NAMES, on, send } = globalThis.lx
send(EVENT_NAMES.inited, { status: true, sources: {} })
on(EVENT_NAMES.request, () => new Promise((resolve) => {
  setTimeout(() => {
    globalThis.__timerFired = true
    resolve({ timerFired: true })
  }, 5)
}))
''';
      rt.loadScript(script);
      final res = await rt.dispatch('request', {'action': 'probe'});
      expect(res.isError, isFalse, reason: '${res.error}');
      expect(res.field('timerFired'), isTrue);
      expect(ev(rt, 'String(globalThis.__timerFired)'), 'true');
      rt.close();
    });

    test('全局定时器 / 环境 polyfill 齐备', () {
      final rt = makeRuntime();
      expect(
          ev(rt,
              "[typeof setTimeout, typeof clearTimeout, typeof setInterval, typeof clearInterval, typeof setImmediate, typeof queueMicrotask].join(',')"),
          'function,function,function,function,function,function');
      expect(
          ev(rt,
              "[typeof global, typeof process, typeof require, typeof atob, typeof btoa, typeof crypto, typeof performance, typeof fetch, typeof Buffer, typeof TextEncoder].join(',')"),
          'object,object,function,function,function,object,object,function,function,function');
      expect(ev(rt, "atob(btoa('hello'))"), 'hello');
      expect(ev(rt, 'process.platform'), 'android');
      rt.close();
    });

    test('md5 对字符串按 LX-X 语义 md5(encodeURIComponent(str))', () {
      final rt = makeRuntime();
      // 取 JS 侧 encodeURIComponent 结果，Dart 侧独立算 md5，不假设
      // Dart Uri.encodeComponent 与 JS 完全一致。
      final enc = ev(rt, "encodeURIComponent('白 姬&x=1')");
      final expected = crypto.md5.convert(utf8.encode(enc)).toString();
      expect(ev(rt, "lx.utils.crypto.md5('白 姬&x=1')"), expected);
      final raw = crypto.md5.convert(utf8.encode('白 姬&x=1')).toString();
      expect(expected, isNot(raw), reason: '证明确实先做了 encodeURIComponent');
      expect(ev(rt, "lx.utils.crypto.md5('abc')"),
          crypto.md5.convert(utf8.encode('abc')).toString());
      rt.close();
    });

    test('aesEncrypt 支持 LX-X (buffer, mode, key, iv) 签名并可解密往返', () {
      final rt = makeRuntime();
      final lxSig = ev(rt,
          "lx.utils.crypto.aesEncrypt('hello', 'aes-128-ecb', '0123456789abcdef').toString('hex')");
      final desktopSig = ev(rt,
          "lx.utils.crypto.aesEncrypt('hello', '0123456789abcdef').toString('hex')");
      expect(lxSig, isNotEmpty);
      expect(lxSig, desktopSig, reason: '两种签名在 ECB 下应等价');
      final back = ev(rt,
          "lx.utils.crypto.aesDecrypt(lx.utils.crypto.aesEncrypt('白姬hello', 'aes-128-ecb', '0123456789abcdef'), '0123456789abcdef').toString()");
      expect(back, '白姬hello');
      rt.close();
    });

    test('rsaEncrypt 对齐 LX-X RSA/ECB/NoPadding（openssl 已知向量）', () {
      final rt = makeRuntime();
      // 1024-bit X.509 SPKI 公钥；明文 128 字节（120 个 0 + "ABCDEFGH"），
      // 密文由 openssl `pkeyutl -encrypt -pkeyopt rsa_padding_mode:none` 生成。
      const pub =
          'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCXxyQNfB3a86Xu6ev0ASIUmFtnlMINELay4p9yIvDIC8mm5WU/tF02lCg7Reuloe1is9RGKxvoNuRvneLoqTbgqR09A1lgOr/nNPgYFYTZ4DKQ27oV3SIw62o1FtN3OAYwjddb3Oaab98Tdg05QUAppNANDvOpwMDRYj1DqUFDEwIDAQAB';
      const cipherHex =
          '77ba8c333a6c885ea5447dd00f3cc5fb16410561b27797aa843bd36e5ad61a01f37ca1ad20f71aba92f24482b7bef50d5faabadcbbb37a4eed90002fc43789c7498f83f6610a172114d20ac117c90e404382a357d9ce6532ea7d11433ec0a88bb2e9c2f6c6cbc0a6c12803ae88f9cdda1907eee298907a328f4211920666bff1';
      final script = r'''
(function () {
  var buf = new Uint8Array(128)
  var tail = [65, 66, 67, 68, 69, 70, 71, 72]
  for (var i = 0; i < tail.length; i++) buf[120 + i] = tail[i]
  return lx.utils.crypto.rsaEncrypt(buf,
    '-----BEGIN PUBLIC KEY-----' + '__PUB__' + '-----END PUBLIC KEY-----').toString('hex')
})()
'''
          .replaceAll('__PUB__', pub);
      expect(ev(rt, script), cipherHex);
      rt.close();
    });
  });
}
