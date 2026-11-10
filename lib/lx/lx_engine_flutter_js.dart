import 'package:flutter_js/flutter_js.dart';

import 'lx_engine.dart';

/// iOS / macOS 引擎：flutter_js 走系统 JavaScriptCore。
///
/// `getJavascriptRuntime(xhr: false)` 在 Apple 端返回 JSCore 实现；
/// `onMessage` 正是 `lib/lx/lx_bootstrap.dart` 里 `sendMessage(channel, payload)`
/// 的目标，因此这里只需把 [LxJsEngine] 的接口一一映射过去。
class LxFlutterJsEngine implements LxJsEngine {
  final JavascriptRuntime _rt;

  LxFlutterJsEngine() : _rt = getJavascriptRuntime(xhr: false);

  @override
  LxEngineKind get kind => LxEngineKind.jscore;

  @override
  LxEvalResult eval(String code) {
    final r = _rt.evaluate(code);
    return LxEvalResult(r.isError, r.stringResult);
  }

  @override
  void executePendingJobs() => _rt.executePendingJob();

  @override
  void registerChannel(
      String channel, dynamic Function(dynamic payload) handler) {
    // flutter_js 内部对 message 做 jsonDecode(message) 再交给 handler，
    // 并把 handler 返回值原样回传给 JS——与 LxJsEngine 的约定完全一致。
    _rt.onMessage(channel, handler);
  }

  @override
  void close() => _rt.dispose();
}
