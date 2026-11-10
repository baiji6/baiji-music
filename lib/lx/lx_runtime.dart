import 'dart:async';
import 'dart:convert';

import 'package:baiji_music/core/app_logger.dart';
import 'package:flutter_js/flutter_js.dart';

import 'lx_bootstrap.dart';
import 'lx_crypto.dart';

/// 一次 [lx.request] 的 Dart 侧请求描述。
///
/// [opts] 对应洛雪源脚本里 `request(url, opts, cb)` 的 `opts`
/// （`method` / `headers` / `body` / `timeout`）。
class LxHttpRequest {
  final String url;
  final Map<String, dynamic> opts;

  LxHttpRequest({required this.url, required this.opts});
}

/// 一次 [lx.request] 的 Dart 侧响应。
///
/// `body` 始终是**文本**（洛雪源的 `resp.body` 在脚本里要么就是字符串，
/// 要么被源自己 JSON.parse；二进制极少，后续按需补 base64）。
class LxHttpResponse {
  final int statusCode;
  final String body;
  final Map<String, String> headers;

  LxHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });
}

/// HTTP 桥实现：Dart 侧用 Dio（或测试桩）完成 [lx.request]。
typedef LxHttpRequestHandler = Future<LxHttpResponse> Function(
    LxHttpRequest request);

/// [dispatch] 的结果。
///
/// 洛雪取流处理器返回 URL 字符串或 `{ url, quality, ekey, format, ... }`，
/// 这里统一归一成 [url]。
class LxDispatchResult {
  final dynamic result;
  final String? error;

  LxDispatchResult({this.result, this.error});

  bool get isError => error != null;

  /// 取流链接：本身是字符串则直接取，否则取 `{url}` 字段。
  String? get url {
    if (isError) return null;
    if (result is String) return result as String;
    if (result is Map) {
      final u = (result as Map)['url'];
      return u is String ? u : null;
    }
    return null;
  }

  /// 任意附加字段（如 `ekey` / `format` / `quality`），供调用方按需取用。
  dynamic field(String name) {
    if (result is Map) return (result as Map)[name];
    return null;
  }
}

class LxScriptException implements Exception {
  final String message;

  LxScriptException(this.message);

  @override
  String toString() => 'LxScriptException: $message';
}

/// 洛雪音源 JS 运行时宿主。
///
/// 封装 flutter_js 的 `JavascriptRuntime`，注入 [lxBootstrapJs] 引导脚本，
/// 并实现 LX 契约的事件桥（`request` / `send` / `on` / `EVENT_NAMES` /
/// `utils.crypto` / `utils.buffer`）。
///
/// **异步桥不依赖 `evaluate` 重入**：JS 的 `lx.request` 通过 `sendMessage`
/// 把请求交给 Dart，`onMessage` 处理器同步登记后立即返回（绝不在此 await），
/// 异步 HTTP 完成后由 `_handleRequest` 调 `evaluate('__lxResolveRequest(...)')`
/// 回写，并 `executePendingJob()` 让 QuickJS 跑完 Promise 的 `.then`（回传
/// `lx_result`）——该模式与 flutter_js 自带的 `setTimeout` 实现同构，已验证。
class LxRuntime {
  final JavascriptRuntime _rt;
  final LxHttpRequestHandler _http;
  final Map<int, Completer<LxDispatchResult>> _dispatchCompleters = {};
  Map<String, dynamic>? _inited;
  int _dispatchId = 0;
  bool _closed = false;
  Timer? _eventLoop;

  LxRuntime({required LxHttpRequestHandler http})
      // 保留 `http` 命名参数（对外 API），故私有字段用初始化列表赋值。
      // ignore: prefer_initializing_formals
      : _http = http,
        _rt = getJavascriptRuntime(xhr: false) {
    _setupBridge();
    final res = _rt.evaluate(lxBootstrapJs);
    if (res.isError) {
      throw LxScriptException('宿主引导脚本加载失败: ${res.stringResult}');
    }
    // 驱动 QuickJS 事件循环：保证 Promise 的 .then（如回传 lx_result）被执行。
    // Apple 端走 JSCore，executePendingJob 是空操作，无害。
    _eventLoop = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_closed) return;
      try {
        _rt.executePendingJob();
      } catch (_) {
        /* 运行时已不可用 */
      }
    });
  }

  void _setupBridge() {
    // 同步加密桥：bootstrap 里 `utils.crypto.*` 经 sendMessage('lx_crypto', …)
    // 同步取回结果（hash 返回 hex，random/AES 返回 base64）。此回调必须同步
    // 返回值，不得 await——flutter_js 会把返回值转成 JS 值回传给源脚本。
    _rt.onMessage('lx_crypto', handleLxCrypto);
    // v2.5.7-pre2：把音源脚本的 console 输出转发到 App 日志。用户反馈
    // 「洛雪取流好像有问题」时，脚本内部的 throw / 鉴权失败终于可见。
    _rt.onMessage('lx_console', (dynamic args) {
      try {
        final map = Map<String, dynamic>.from(args as Map);
        final level = map['level']?.toString() ?? 'log';
        final text = (map['args'] as List? ?? const <dynamic>[]).join(' ');
        AppLog.d('LxScript', '[$level] $text');
      } catch (_) {
        /* 日志通道不能反过来打断脚本 */
      }
    });
    _rt.onMessage('lx_inited', (dynamic args) {
      // args 已是 jsonDecode 后的对象：{ data: {...} }
      final map = Map<String, dynamic>.from(args as Map);
      _inited = map['data'] as Map<String, dynamic>?;
      AppLog.d('LxRuntime', '音源 inited: ${_inited?['sources']}');
    });
    _rt.onMessage('lx_send', (dynamic args) {
      AppLog.d('LxRuntime', 'lx.send: $args');
    });
    _rt.onMessage('lx_request', (dynamic args) {
      // QuickJsRuntime2 的 sendMessage 是**同步**调用，此处不得 await；
      // 用 IIFE 派发异步工作，完成后经 evaluate 回写。
      final map = Map<String, dynamic>.from(args as Map);
      final reqId = map['reqId'] as int;
      final url = map['url'] as String;
      final opts = Map<String, dynamic>.from(map['opts'] as Map? ?? {});
      _handleRequest(reqId, url, opts);
    });
    _rt.onMessage('lx_result', (dynamic args) {
      final map = Map<String, dynamic>.from(args as Map);
      final id = map['id'] as int;
      final completer = _dispatchCompleters.remove(id);
      if (completer == null) return;
      final err = map['error'];
      if (err != null) {
        completer.complete(LxDispatchResult(error: err.toString()));
      } else {
        completer.complete(LxDispatchResult(result: map['result']));
      }
    });
  }

  void _handleRequest(int reqId, String url, Map<String, dynamic> opts) {
    // 异步体：HTTP 完成后回写并冲刷事件循环。不得在 onMessage 内直接 await。
    () async {
      try {
        final resp = await _http(LxHttpRequest(url: url, opts: opts));
        if (_closed) return;
        final bodyJson = jsonEncode(resp.body);
        // v2.5.7-pre2：透传响应头（pre1 恒为空对象，部分源会读 headers）。
        final headersJson = jsonEncode(resp.headers);
        _rt.evaluate(
            '__lxResolveRequest($reqId, ${resp.statusCode}, $bodyJson, false, $headersJson)');
        _rt.executePendingJob();
      } catch (e) {
        if (_closed) return;
        final errJson = jsonEncode(e.toString());
        _rt.evaluate('__lxResolveRequest($reqId, 0, $errJson, true, {})');
        _rt.executePendingJob();
      }
    }();
  }

  /// 加载一个洛雪音源脚本（同步执行；脚本会在加载时 `send(inited)`）。
  void loadScript(String script) {
    final res = _rt.evaluate(script);
    if (res.isError) {
      throw LxScriptException('音源脚本加载失败: ${res.stringResult}');
    }
  }

  /// 音源声明：通常含 `sources`（各子源的音质/动作）。
  Map<String, dynamic>? get inited => _inited;

  /// 底层 QuickJS / JSCore 运行时（测试与调试用，如校验 `utils.crypto`）。
  JavascriptRuntime get rawRuntime => _rt;

  /// 派发一个 LX 事件（如 `'request'`，data 为 `{action, source, info}`）。
  ///
  /// 立即返回；处理器可通过 `lx.request` 异步取数，结果经 `lx_result` 回传。
  /// v2.5.7-pre2：超时在这里统一处理并从待决表移除，避免脚本永远不回
  /// `lx_result` 时泄漏 Completer（原来外层 `.timeout` 只抛异常、不清表）。
  Future<LxDispatchResult> dispatch(
    String event,
    Map<String, dynamic> data, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final id = ++_dispatchId;
    final completer = Completer<LxDispatchResult>();
    _dispatchCompleters[id] = completer;
    final payload = {'event': event, 'data': data};
    _rt.evaluate('__lxDispatch($id, ${jsonEncode(payload)})');
    _rt.executePendingJob();
    return completer.future.timeout(timeout, onTimeout: () {
      _dispatchCompleters.remove(id);
      return LxDispatchResult(error: 'timeout after ${timeout.inSeconds}s');
    });
  }

  /// 释放运行时。
  void close() {
    _closed = true;
    _eventLoop?.cancel();
    _eventLoop = null;
    for (final c in _dispatchCompleters.values) {
      if (!c.isCompleted) c.completeError('runtime closed');
    }
    _dispatchCompleters.clear();
    _rt.dispose();
  }
}
