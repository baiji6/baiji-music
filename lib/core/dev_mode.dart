/// 开发者模式开关。
///
/// 入口藏在「关于」页：连续点击版本号 10 次 → 输入密码（molan）开启。
/// 开启后设置页才会显示「开发者模式」分区（抓包调试等高级功能移入其中），
/// 避免普通用户误触网络调试开关。
library;

import 'package:flutter/material.dart';

import 'kv_store.dart';

class DevMode extends ChangeNotifier {
  DevMode._();

  static final DevMode instance = DevMode._();

  static const String _kEnabled = 'dev_mode_enabled';

  /// 开启密码（关于页连点版本号 10 次后输入）。
  static const String password = 'molan';

  /// 连点次数阈值。
  static const int tapThreshold = 10;

  /// 连点有效间隔：超过这个间隔重新计数（防误触累积）。
  static const Duration tapWindow = Duration(milliseconds: 1500);

  bool _enabled = false;

  bool get enabled => _enabled;

  /// 启动时恢复（main 里调用一次）。
  Future<void> load() async {
    _enabled = KvStore.instance.getBool(_kEnabled);
    notifyListeners();
  }

  Future<void> setEnabled(bool v) async {
    if (v == _enabled) return;
    _enabled = v;
    notifyListeners();
    await KvStore.instance.setBool(_kEnabled, v);
  }

  /// 校验密码（大小写不敏感，忽略首尾空白）。
  static bool checkPassword(String input) =>
      input.trim().toLowerCase() == password;
}
