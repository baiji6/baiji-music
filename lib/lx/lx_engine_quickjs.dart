import 'dart:convert';

import 'package:quickjs_runtime/quickjs_runtime.dart';

import 'lx_engine.dart';

/// Android / Linux / Windows 引擎：vendored QuickJS 2024-01-13。
///
/// 相比 `flutter_js 0.8.7` 内置的 QuickJS 2020-11-08 / 2021-03-27，
/// 本引擎可解析 `molan.js` 等使用现代语法的洛雪音源（LX-X 同源行为）。
///
/// 关键兼容点：**注册一个名为 `sendMessage` 的全局 host function**。
/// C 桥会把 `(channel, message)` 两个参数 `JS_JSONStringify` 成 JSON 数组，
/// 并把 Dart 返回的 JSON 字符串 `JS_ParseJSON` 还原成 JS 值。这样
/// `lib/lx/lx_bootstrap.dart` 里所有 `sendMessage(channel, payloadJson)`
/// 无需任何改动即可原样工作，且与 flutter_js 的 `onMessage` 语义一致。
class LxQuickJsEngine implements LxJsEngine {
  final QuickjsRuntime _rt;
  final Map<String, dynamic Function(dynamic payload)> _channels =
      <String, dynamic Function(dynamic payload)>{};

  LxQuickJsEngine() : _rt = QuickjsRuntime() {
    _rt.registerHostFunction('sendMessage', (String argsJson) {
      try {
        final args = jsonDecode(argsJson);
        if (args is! List || args.length < 2) return null;
        final channel = args[0];
        if (channel is! String) return null;
        // 对齐 flutter_js：handler 收到的是 jsonDecode(message) 之后的对象。
        final message = args[1];
        final payload = message is String ? jsonDecode(message) : message;
        final result = _channels[channel]?.call(payload);
        // 返回 null 对应 JS undefined；否则必须是合法 JSON 字符串，
        // C 桥会 JS_ParseJSON 还原成 JS 值（String / Map / List / num…）。
        return result == null ? null : jsonEncode(result);
      } catch (_) {
        // 通道异常绝不能打断音源脚本（对齐 flutter_js 未注册通道的行为）。
        return null;
      }
    });
  }

  @override
  LxEngineKind get kind => LxEngineKind.quickjs2024;

  @override
  void registerChannel(
      String channel, dynamic Function(dynamic payload) handler) {
    _channels[channel] = handler;
  }

  @override
  LxEvalResult eval(String code) {
    final errMsg = <String?>[];
    final raw = _rt.eval(code, errMsg: errMsg);
    final failed = errMsg.isNotEmpty && errMsg.first != null;
    // 错误文本放在 stringResult，语义对齐 flutter_js 的 JsEvalResult；
    // 成功时 eval 返回的是 JS_JSONStringify 的文本（如 '"mobile"'），
    // 必须 jsonDecode 归一化，否则 LxRuntime 与既有测试的断言会失配。
    return LxEvalResult(failed, failed ? errMsg.first! : _normalize(raw));
  }

  static String _normalize(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    try {
      final v = jsonDecode(raw);
      return v is String ? v : (v?.toString() ?? '');
    } catch (_) {
      return raw;
    }
  }

  @override
  void executePendingJobs() => _rt.executePendingJobs();

  @override
  void close() => _rt.close();
}
