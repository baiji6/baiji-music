/// 全局界面偏好（与歌词无关的 UI 设置）。
///
/// 目前只有一项：**界面圆角**——App 内自绘卡片（GlassCard 等）的统一圆角。
/// Miuix 自带组件（开关 / 滑块 / 对话框）的圆角由库内部决定，不在这里管。
library;

import 'package:flutter/material.dart';

import 'kv_store.dart';

class UiSettings extends ChangeNotifier {
  UiSettings._();

  static final UiSettings instance = UiSettings._();

  /// 圆角可调范围（逻辑像素）。下限 8 保留"卡片感"，0 太割手。
  static const double minCorner = 8.0;
  static const double maxCorner = 28.0;
  static const double defaultCorner = 16.0;

  static const String _prefs = 'ui';
  static const String _kCorner = 'corner_radius';

  double _cornerRadius = defaultCorner;

  /// 全局界面圆角（逻辑像素）。
  double get cornerRadius => _cornerRadius;

  /// 启动时恢复（main 里调用一次）。
  Future<void> load() async {
    final stored = KvStore.instance.getDouble('$_prefs:$_kCorner');
    _cornerRadius = (stored ?? defaultCorner).clamp(minCorner, maxCorner).toDouble();
    notifyListeners();
  }

  Future<void> setCornerRadius(double v) {
    final next = v.clamp(minCorner, maxCorner).toDouble();
    if (next == _cornerRadius) return Future.value();
    _cornerRadius = next;
    notifyListeners();
    return KvStore.instance.setDouble('$_prefs:$_kCorner', next);
  }

  /// 恢复默认圆角。
  Future<void> resetCorner() => setCornerRadius(defaultCorner);
}
