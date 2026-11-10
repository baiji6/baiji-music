import 'dart:convert';
import 'dart:io';

import 'package:baiji_music/lx/lx_engine.dart';
import 'package:baiji_music/lx/lx_engine_factory.dart';
import 'package:baiji_music/lx/lx_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// 双引擎契约（v2.5.7-pre3）。
///
/// 同一份 [contractScript] 在 QuickJS 2024 与 flutter_js/JSCore 两条路径上
/// 必须表现一致；`molan.js` 端到端加载只在 QuickJS 2024 上断言（Linux 上
/// flutter_js 走的是内置旧 QuickJS，本就无法解析现代语法；Apple 真机走系统
/// JSCore，不受此限）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LxHttpResponse> canned(LxHttpRequest req) async => LxHttpResponse(
        statusCode: 200,
        body: jsonEncode(<String, dynamic>{
          'url': 'http://cdn/contract.flac',
          'echo': req.url,
        }),
      );

  // Linux 上 flutter_js 需要 LD_LIBRARY_PATH 指向 libquickjs_c_bridge_plugin.so；
  // Apple 真机走系统 JSCore 不需要。不可用时整组跳过，保证发布 checkout 全绿。
  bool jscoreAvailable = false;
  try {
    final probe = LxRuntime(http: canned, engineOverride: LxEngineKind.jscore);
    probe.close();
    jscoreAvailable = true;
  } catch (_) {
    jscoreAvailable = false;
  }

  const String contractScript = r'''
// ==UserScript==
// @name 契约探针
// @version 1.0.0
// ==/UserScript==
(function () {
  globalThis.__probe = { ticked: false };
  setTimeout(function () { globalThis.__probe.ticked = true; }, 1);
  lx.send(lx.EVENT_NAMES.inited, {
    name: '契约探针', version: '1.0.0', author: '', homepage: '', description: '',
    sources: { kw: { type: 'music', actions: ['musicUrl'], qualitys: ['128k'] } }
  });
  lx.on(lx.EVENT_NAMES.request, function (data) {
    return new Promise(function (resolve, reject) {
      lx.request('http://probe/' + (data.action || ''), { method: 'get' },
        function (err, resp, body) {
          if (err) { reject(err); return; }
          resolve({ url: body.url, status: resp.statusCode, third: body.echo });
        });
    });
  });
})();
''';

  /// 在指定引擎上跑一遍完整宿主契约。
  void runContract(LxEngineKind kind) {
    group('引擎契约 · ${kind.name}', () {
      late LxRuntime rt;

      setUp(() {
        rt = LxRuntime(http: canned, engineOverride: kind);
        rt.loadScript(contractScript, scriptInfo: <String, dynamic>{
          'name': '契约探针',
          'version': '1.0.0',
        });
      });
      tearDown(() => rt.close());

      test('env / version / EVENT_NAMES 与 stringResult 归一化一致', () {
        expect(rt.eval('lx.env'), 'mobile');
        expect(rt.eval('lx.version'), '2.0.0');
        expect(rt.eval('lx.EVENT_NAMES.request'), 'request');
        expect(rt.eval('lx.EVENT_NAMES.inited'), 'inited');
        expect(rt.eval('lx.EVENT_NAMES.updateAlert'), 'updateAlert');
      });

      test('currentScriptInfo.rawScript 同步返回完整大字符串', () {
        expect(rt.eval('lx.currentScriptInfo.rawScript.length'),
            contractScript.length.toString());
        expect(
            rt.eval('lx.currentScriptInfo.rawScript.indexOf("契约探针") >= 0'),
            'true');
      });

      test('utils.crypto.md5 同步桥（LX-X encodeURIComponent 语义）', () {
        expect(rt.eval("lx.utils.crypto.md5('abc')"),
            '900150983cd24fb0d6963f7d28e17f72');
        expect(rt.eval("lx.utils.crypto.md5('')"),
            'd41d8cd98f00b204e9800998ecf8427e');
      });

      test('send(inited) 按宿主支持范围规范化 sources', () {
        expect(rt.inited, isNotNull);
        final sources = rt.inited!['sources'] as Map;
        expect(sources.containsKey('kw'), isTrue);
        final kw = sources['kw'] as Map;
        expect(kw['type'], 'music');
        expect((kw['actions'] as List).contains('musicUrl'), isTrue);
        expect((kw['qualitys'] as List).contains('128k'), isTrue);
      });

      test('全局 polyfill 齐备（setTimeout / setInterval / atob）', () {
        expect(rt.eval('typeof setTimeout'), 'function');
        expect(rt.eval('typeof setInterval'), 'function');
        expect(rt.eval('typeof atob'), 'function');
        expect(rt.eval('typeof globalThis.lx.request'), 'function');
      });

      test('setTimeout 由 Dart Timer 回写并冲刷 Promise', () async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(rt.eval('globalThis.__probe.ticked'), 'true');
      });

      test('lx.request 三参回调 → Dart HTTP → lx_result 闭环', () async {
        final res = await rt.dispatch('request', <String, dynamic>{
          'action': 'musicUrl',
          'source': 'kw',
          'info': <String, dynamic>{
            'musicInfo': <String, dynamic>{'songmid': 'probe-mid'},
            'type': '128k',
          },
        });
        expect(res.isError, isFalse, reason: res.error);
        expect(res.url, 'http://cdn/contract.flac');
        expect(res.field('status'), 200);
        expect(res.field('third'), 'http://probe/musicUrl');
      });

      test('引擎层 isError / stringResult 错误文本可判定', () {
        final eng = createLxEngine(override: kind);
        final ok = eng.eval('1+1');
        expect(ok.isError, isFalse);
        expect(ok.stringResult, '2');
        final bad = eng.eval('const = ;');
        expect(bad.isError, isTrue);
        expect(bad.stringResult.isNotEmpty, isTrue);
        eng.close();
      });
    },
        skip: kind == LxEngineKind.jscore && !jscoreAvailable
            ? '本机无 flutter_js 原生库（Apple 真机走系统 JSCore，不受影响）'
            : null);
  }

  runContract(LxEngineKind.quickjs2024);
  runContract(LxEngineKind.jscore);

  group('QuickJS 2024 现代语法音源（v2.5.7-pre3 核心修复）', () {
    const String molanPath = 'test/res/lx_sources/molan.js';
    const String noFixture = '未提供测试音源夹具（发布时不随工程分发）';

    test('molan.js 完整加载并声明子源与音质档位', () {
      final rt = LxRuntime(http: canned);
      try {
        rt.loadScript(File(molanPath).readAsStringSync(),
            scriptInfo: <String, dynamic>{'name': '墨澜音乐源'});
        expect(rt.inited, isNotNull);
        final sources = rt.inited!['sources'] as Map;
        expect(sources.containsKey('kw'), isTrue);
        expect(sources.containsKey('kg'), isTrue);
        expect(sources.containsKey('tx'), isTrue);
        expect(sources.containsKey('wy'), isTrue);
        // 现代语法音源会声明 hires / master 等高档位。
        final tx = sources['tx'] as Map;
        expect((tx['qualitys'] as List).contains('flac'), isTrue);
        expect((tx['actions'] as List).contains('musicUrl'), isTrue);
      } finally {
        rt.close();
      }
    }, skip: File(molanPath).existsSync() ? null : noFixture);
  });
}
