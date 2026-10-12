import 'package:flutter_miuix/miuix.dart';

/// 全局 Miuix Snackbar 宿主状态。
///
/// 播放页、封面长按保存、各功能页都要弹轻量提示，而这些调用点不一定在
/// 同一个 BuildContext 子树里（例如 [_CoverArt] 这种深层子组件）。
/// 用一个进程级宿主状态 + 各页面脚手架上的 [MiuixSnackbarHost] 挂载，
/// 任何地方都能弹，视觉仍是 Miuix 的毛玻璃 snackbar。
final appSnackbarHostState = MiuixSnackbarHostState();

/// 弹一条全局提示。
void showAppSnack(String message) {
  appSnackbarHostState.showSnackbar(message);
}
