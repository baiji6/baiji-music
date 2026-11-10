import 'dart:io' show Platform;

import 'lx_engine.dart';
import 'lx_engine_flutter_js.dart';
import 'lx_engine_quickjs.dart';

/// 按运行平台选择洛雪音源 JS 引擎（v2.5.7-pre3 双引擎）。
///
/// - iOS / macOS：系统 JavaScriptCore（flutter_js），满足 App Store 3.3.2
///   「第三方脚本须由 WebKit / JavaScriptCore 解释执行」的要求。
/// - Android / Linux / Windows：QuickJS 2024-01-13（quickjs_runtime），
///   对齐 LX-X 宿主，支持现代语法音源。
///
/// [override] 仅供双引擎契约测试强制跑指定实现，生产路径恒为 null。
LxJsEngine createLxEngine({LxEngineKind? override}) {
  final k = override ??
      ((Platform.isIOS || Platform.isMacOS)
          ? LxEngineKind.jscore
          : LxEngineKind.quickjs2024);
  return k == LxEngineKind.jscore
      ? LxFlutterJsEngine()
      : LxQuickJsEngine();
}
