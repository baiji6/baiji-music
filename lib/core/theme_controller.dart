import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'kv_store.dart';

/// 主题偏好：莫奈取色开关 + 壁纸种子缓存。
///
/// 根组件（`main.dart` 的 `_BaijiMusicAppState`）监听本控制器：
/// 开关变化 / 种子解析完成 → 重建 MaterialApp 与 Miuix 主题。
/// 明暗切换不走这里——那由系统亮度 + `WidgetsBindingObserver` 驱动。
class ThemeController extends ChangeNotifier {
  ThemeController._();

  static final ThemeController instance = ThemeController._();

  static const String _kMonet = 'appearance_monet';

  bool _monet = false;

  /// 壁纸取色种子。null = 平台不支持（或尚未解析），此时回退品牌紫。
  Color? _seed;

  /// 种子是否已尝试解析过（避免每次切换开关都打平台通道）。
  bool _seedTried = false;

  /// 莫奈取色是否开启。
  bool get monet => _monet;

  /// 当前壁纸种子（可能为 null）。
  Color? get seed => _seed;

  /// 启动时恢复偏好；开启莫奈时顺带解析一次壁纸种子。
  Future<void> load() async {
    _monet = KvStore.instance.getBool(_kMonet);
    if (_monet) await _resolveSeed();
    notifyListeners();
  }

  /// 切换莫奈取色。
  Future<void> setMonet(bool v) async {
    if (v == _monet) return;
    _monet = v;
    if (v) {
      await _resolveSeed();
    } else {
      _seed = null;
      _seedTried = false;
    }
    notifyListeners();
    await KvStore.instance.setBool(_kMonet, v);
  }

  /// 解析种子。不在此处通知——调用方（load/setMonet）统一在末尾通知一次，
  /// 避免一次用户操作触发两次重建。
  Future<void> _resolveSeed() async {
    if (_seedTried) return;
    _seedTried = true;
    _seed = await MonetSeed.resolve();
  }
}

/// 系统壁纸取色种子（Android 读壁纸强调色，其他平台返回 null）。
class MonetSeed {
  MonetSeed._();

  static Color? _cached;
  static bool _tried = false;

  /// 取一次系统壁纸种子；结果进程内缓存，失败/不支持返回 null。
  static Future<Color?> resolve() async {
    if (_tried) return _cached;
    _tried = true;
    try {
      _cached = await DynamicColorPlugin.getAccentColor();
    } catch (_) {
      // 平台通道不存在 / 抛异常：当作不支持动态取色。
      _cached = null;
    }
    return _cached;
  }
}
