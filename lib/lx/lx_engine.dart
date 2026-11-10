/// 洛雪音源 JS 引擎抽象层（v2.5.7-pre3）。
///
/// Android / Linux / Windows 使用 vendored QuickJS 2024-01-13
/// （`quickjs_runtime`，pure-Dart FFI + Native Assets 六端自编译），
/// iOS / macOS 使用系统 JavaScriptCore（`flutter_js`，App Store 3.3.2 合规）。
///
/// 两套引擎对 [LxRuntime] 暴露完全一致的接口：同步执行、`sendMessage`
/// 通道注册、pending jobs 冲刷、释放。这样 `lib/lx/lx_bootstrap.dart`
/// 与全部取流 / 宿主业务逻辑都不需要区分引擎。
library;

/// 引擎种类。
enum LxEngineKind {
  /// QuickJS 2024-01-13（Android / Linux / Windows）。
  quickjs2024,

  /// 系统 JavaScriptCore（iOS / macOS）。
  jscore,
}

/// 一次同步执行的结果，语义对齐 flutter_js 的 `JsEvalResult`：
/// [isError] 为真时 [stringResult] 是错误文本，否则是归一化后的结果文本。
class LxEvalResult {
  final bool isError;
  final String stringResult;

  const LxEvalResult(this.isError, this.stringResult);
}

/// 引擎无关的洛雪 JS 运行时句柄。
abstract class LxJsEngine {
  LxEngineKind get kind;

  /// 同步执行一段 JS，返回归一化后的结果。
  LxEvalResult eval(String code);

  /// 冲刷 pending jobs，让 Promise 的 `.then` 得到执行。
  void executePendingJobs();

  /// 注册一个 `sendMessage` 通道处理器。
  ///
  /// [payload] 与 flutter_js 一致，是 `jsonDecode(message)` 之后的对象；
  /// 处理器返回值会被原样回传给 JS（QuickJS 侧经 JSON 编解码还原）。
  void registerChannel(
      String channel, dynamic Function(dynamic payload) handler);

  /// 释放引擎。
  void close();
}
