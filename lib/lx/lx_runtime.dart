import 'dart:async';
import 'dart:convert';

import 'package:baiji_music/core/app_logger.dart';

import 'lx_bootstrap.dart';
import 'lx_crypto.dart';
import 'lx_engine.dart';
import 'lx_engine_factory.dart';

/// 一次 [lx.request] 的 Dart 侧请求描述。
///
/// `opts` 对应洛雪源脚本里 `request(url, opts, cb)` 的 `opts`：
/// `method` / `headers` / `body` / `form` / `formData` / `timeout` /
/// `binary` / `follow_max`（与 LX-X preload 的 options 对齐）。
class LxHttpRequest {
  final String url;
  final Map<String, dynamic> opts;

  LxHttpRequest({required this.url, required this.opts});
}

/// 一次 [lx.request] 的 Dart 侧响应。
///
/// `body` 默认按文本返回；`binary=true` 时是字节的 base64，由 bootstrap
/// 还原成 Uint8Array 交给脚本（LX-X 的 `binary` 选项语义）。
class LxHttpResponse {
  final int statusCode;
  final String body;
  final Map<String, String> headers;
  final String statusMessage;
  final bool binary;

  LxHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
    this.statusMessage = '',
    this.binary = false,
  });
}

/// HTTP 桥实现：Dart 侧用 Dio（或测试桩）完成 [lx.request]。
typedef LxHttpRequestHandler = Future<LxHttpResponse> Function(
    LxHttpRequest request);

/// [dispatch] 的结果。
///
/// 洛雪取流处理器返回 URL 字符串、`{ url, quality, ekey, format, ... }`，
/// 或 LX-X 兼容的 `{ data: { url, ekey, ... } }`；这里统一归一成 [url]。
class LxDispatchResult {
  final dynamic result;
  final String? error;

  LxDispatchResult({this.result, this.error});

  bool get isError => error != null;

  Map? get _map => result is Map ? result as Map : null;

  /// 取流链接：本身是字符串则直接取，否则取 `{url}` 或 `{data:{url}}`。
  String? get url {
    if (isError) return null;
    if (result is String) return result as String;
    final m = _map;
    if (m == null) return null;
    final u = m['url'];
    if (u is String) return u;
    final nested = m['data'];
    if (nested is Map && nested['url'] is String) return nested['url'] as String;
    return null;
  }

  /// 任意附加字段（如 `ekey` / `format` / `quality`），兼容嵌套 `data`。
  dynamic field(String name) {
    final m = _map;
    if (m == null) return null;
    if (m.containsKey(name)) return m[name];
    final nested = m['data'];
    if (nested is Map && nested.containsKey(name)) return nested[name];
    return null;
  }
}

class LxScriptException implements Exception {
  final String message;

  LxScriptException(this.message);

  @override
  String toString() => 'LxScriptException: $message';
}

/// 洛雪音源 JS 运行时宿主（v2.5.7-pre3 对齐 LX-X preload，双引擎）。
///
/// 底层由 [createLxEngine] 按平台选择：Android / Linux / Windows 用
/// QuickJS 2024-01-13，iOS / macOS 用系统 JavaScriptCore。注入
/// [lxBootstrapJs] 引导脚本，实现 LX 契约的原生桥：`request` / `send` /
/// `on` / `inited` / `console` / `utils.crypto` / `setTimeout` /
/// `currentScriptInfo.rawScript`。
///
/// **异步桥不依赖 `eval` 重入**：JS 的 `lx.request` 通过 `sendMessage`
/// 把请求交给 Dart，通道处理器同步登记后立即返回（绝不在此 await），
/// 异步 HTTP / 定时器完成后由 Dart 调 `eval(...)` 回写，并
/// `executePendingJobs()` 让引擎跑完 Promise 的 `.then`。
class LxRuntime {
  final LxJsEngine _engine;
  final LxHttpRequestHandler _http;
  final Map<int, Completer<LxDispatchResult>> _dispatchCompleters = {};
  final Map<int, Timer> _timers = <int, Timer>{};
  final Map<int, Timer> _intervalTimers = <int, Timer>{};
  final Set<int> _abortedRequests = <int>{};
  Map<String, dynamic>? _inited;
  String _rawScript = '';
  int _dispatchId = 0;
  bool _closed = false;
  Timer? _eventLoop;

  /// [engineOverride] 仅供双引擎契约测试强制指定实现；生产路径恒为 null，
  /// 由 [createLxEngine] 按平台选择（Apple → JSCore，其余 → QuickJS 2024）。
  LxRuntime({
    required LxHttpRequestHandler http,
    LxEngineKind? engineOverride,
  })
      // 保留 `http` 命名参数（对外 API），故私有字段用初始化列表赋值。
      // ignore: prefer_initializing_formals
      : _http = http,
        _engine = createLxEngine(override: engineOverride) {
    _setupBridge();
    final res = _engine.eval(lxBootstrapJs);
    if (res.isError) {
      throw LxScriptException('宿主引导脚本加载失败: ${res.stringResult}');
    }
    // 驱动引擎事件循环：保证 Promise 的 .then（如回传 lx_result）被执行。
    // Apple 端走 JSCore，executePendingJobs 是空操作，无害。
    _eventLoop = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_closed) return;
      try {
        _engine.executePendingJobs();
      } catch (_) {
        /* 运行时已不可用 */
      }
    });
  }

  void _setupBridge() {
    // 同步加密桥：bootstrap 里 `utils.crypto.*` 经 sendMessage('lx_crypto', …)
    // 同步取回结果（hash 返回 hex，random/AES/RSA 返回 base64）。此回调必须
    // 同步返回值，不得 await。
    _engine.registerChannel('lx_crypto', handleLxCrypto);
    // currentScriptInfo.rawScript 的同步 getter：避免把大段脚本文本拼进 evaluate。
    _engine.registerChannel('lx_raw_script', (dynamic _) => _rawScript);
    _engine.registerChannel('lx_console', (dynamic args) {
      try {
        final map = Map<String, dynamic>.from(args as Map);
        final level = map['level']?.toString() ?? 'log';
        final text = (map['args'] as List? ?? const <dynamic>[]).join(' ');
        AppLog.d('LxScript', '[$level] $text');
      } catch (_) {
        /* 日志通道不能反过来打断脚本 */
      }
    });
    _engine.registerChannel('lx_inited', (dynamic args) {
      // args 已是 jsonDecode 后的对象：{ data: 规范化后的 init info }
      final map = Map<String, dynamic>.from(args as Map);
      _inited = map['data'] as Map<String, dynamic>?;
      AppLog.d('LxRuntime', '音源 inited: ${_inited?['sources']}');
    });
    _engine.registerChannel('lx_send', (dynamic args) {
      AppLog.d('LxRuntime', 'lx.send: $args');
    });
    _engine.registerChannel('lx_update_alert', (dynamic args) {
      AppLog.d('LxRuntime', '音源更新提示: $args');
    });
    // LX-X preload 用原生 setTimeout 驱动脚本；这里用 Dart Timer 回写。
    _engine.registerChannel('lx_set_timeout', (dynamic args) {
      try {
        final map = Map<String, dynamic>.from(args as Map);
        final id = map['id'] as int;
        final ms = (map['ms'] as num?)?.toInt() ?? 0;
        _timers.remove(id)?.cancel();
        _timers[id] = Timer(Duration(milliseconds: ms), () {
          _timers.remove(id);
          if (_closed) return;
          try {
            _engine.eval('__lxFireTimeout($id)');
            _engine.executePendingJobs();
          } catch (_) {
            /* 运行时已不可用 */
          }
        });
      } catch (_) {
        /* 定时器通道不能打断脚本 */
      }
    });
    _engine.registerChannel('lx_clear_timeout', (dynamic args) {
      try {
        final map = Map<String, dynamic>.from(args as Map);
        final id = map['id'] as int;
        _timers.remove(id)?.cancel();
      } catch (_) {}
    });
    _engine.registerChannel('lx_set_interval', (dynamic args) {
      try {
        final map = Map<String, dynamic>.from(args as Map);
        final id = map['id'] as int;
        final ms = (map['ms'] as num?)?.toInt() ?? 0;
        _intervalTimers.remove(id)?.cancel();
        _intervalTimers[id] = Timer.periodic(
            Duration(milliseconds: ms < 1 ? 1 : ms), (_) {
          if (_closed) return;
          try {
            _engine.eval('__lxFireInterval($id)');
            _engine.executePendingJobs();
          } catch (_) {
            /* 运行时已不可用 */
          }
        });
      } catch (_) {
        /* 定时器通道不能打断脚本 */
      }
    });
    _engine.registerChannel('lx_clear_interval', (dynamic args) {
      try {
        final map = Map<String, dynamic>.from(args as Map);
        final id = map['id'] as int;
        _intervalTimers.remove(id)?.cancel();
      } catch (_) {}
    });
    // lx.request 返回的 abort 函数：标记后忽略迟到的响应，不回写已废弃回调。
    _engine.registerChannel('lx_abort_request', (dynamic args) {
      try {
        final map = Map<String, dynamic>.from(args as Map);
        _abortedRequests.add(map['reqId'] as int);
      } catch (_) {}
    });
    _engine.registerChannel('lx_request', (dynamic args) {
      // QuickJsRuntime2 的 sendMessage 是**同步**调用，此处不得 await；
      // 用 IIFE 派发异步工作，完成后经 evaluate 回写。
      final map = Map<String, dynamic>.from(args as Map);
      final reqId = map['reqId'] as int;
      final url = map['url'] as String;
      final opts = Map<String, dynamic>.from(map['opts'] as Map? ?? {});
      _handleRequest(reqId, url, opts);
    });
    _engine.registerChannel('lx_result', (dynamic args) {
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
        if (_closed || _abortedRequests.remove(reqId)) return;
        final bodyJson = jsonEncode(resp.body);
        final headersJson = jsonEncode(resp.headers);
        final statusJson = jsonEncode(resp.statusMessage);
        // LX-X 回调签名：(err, resp, body)，resp 含 statusMessage / headers。
        _engine.eval('__lxResolveRequest($reqId, ${resp.statusCode}, '
            '$statusJson, $bodyJson, false, $headersJson, ${resp.binary})');
        _engine.executePendingJobs();
      } catch (e) {
        if (_closed) return;
        _abortedRequests.remove(reqId);
        final errJson = jsonEncode(e.toString());
        _engine.eval('__lxResolveRequest($reqId, 0, "", $errJson, true, {}, false)');
        _engine.executePendingJobs();
      }
    }();
  }

  /// 加载一个洛雪音源脚本（同步执行；脚本会在加载时 `send(inited)`）。
  ///
  /// [scriptInfo] 注入 `lx.currentScriptInfo`（name / version / author /
  /// homepage / description）；`rawScript` 由同步 getter 提供，不进 evaluate。
  void loadScript(String script, {Map<String, dynamic>? scriptInfo}) {
    _rawScript = script;
    if (scriptInfo != null) {
      final info = <String, dynamic>{
        'name': scriptInfo['name'] ?? '',
        'description': scriptInfo['description'] ?? '',
        'version': scriptInfo['version'] ?? '',
        'author': scriptInfo['author'] ?? '',
        'homepage': scriptInfo['homepage'] ?? '',
      };
      final r = _engine.eval('__lxSetScriptInfo(${jsonEncode(info)})');
      if (r.isError) {
        AppLog.w('LxRuntime', '注入 currentScriptInfo 失败: ${r.stringResult}');
      }
    }
    final res = _engine.eval(script);
    if (res.isError) {
      throw LxScriptException('音源脚本加载失败: ${res.stringResult}');
    }
    // 脚本可能在微任务里 send(inited) / 发起 checkUpdate，冲刷一次。
    _engine.executePendingJobs();
  }

  /// 音源声明（已按 LX-X 规范化：`sources[sub] = {type, actions, qualitys}`）。
  Map<String, dynamic>? get inited => _inited;

  /// 引擎无关的同步求值（测试与调试用，如校验 `utils.crypto`）。
  ///
  /// 返回归一化后的文本结果；替代旧版直接暴露 `rawRuntime` 的做法，
  /// 让宿主契约测试在 QuickJS 2024 与 JSCore 两套引擎上都能原样运行。
  String eval(String expr) => _engine.eval(expr).stringResult;

  /// 派发一个 LX 事件（如 `'request'`，data 为 `{action, source, info}`）。
  ///
  /// 立即返回；处理器可通过 `lx.request` 异步取数，结果经 `lx_result` 回传。
  /// 超时统一在这里处理并从待决表移除，避免脚本永远不回 `lx_result` 时
  /// 泄漏 Completer。
  Future<LxDispatchResult> dispatch(
    String event,
    Map<String, dynamic> data, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final id = ++_dispatchId;
    final completer = Completer<LxDispatchResult>();
    _dispatchCompleters[id] = completer;
    final payload = {'event': event, 'data': data};
    _engine.eval('__lxDispatch($id, ${jsonEncode(payload)})');
    _engine.executePendingJobs();
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
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    for (final t in _intervalTimers.values) {
      t.cancel();
    }
    _intervalTimers.clear();
    for (final c in _dispatchCompleters.values) {
      if (!c.isCompleted) c.completeError('runtime closed');
    }
    _dispatchCompleters.clear();
    _engine.close();
  }
}
