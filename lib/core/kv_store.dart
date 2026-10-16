import 'package:shared_preferences/shared_preferences.dart';

/// 键值存储的轻量封装（底层 SharedPreferences，六端可用）。
class KvStore {
  KvStore._(this._prefs);

  final SharedPreferences _prefs;

  static KvStore? _instance;

  /// 初始化（应用启动时调用一次）。
  static Future<KvStore> ensureInit() async {
    if (_instance != null) return _instance!;
    final prefs = await SharedPreferences.getInstance();
    _instance = KvStore._(prefs);
    return _instance!;
  }

  static KvStore get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('KvStore 未初始化，请先调用 ensureInit()');
    }
    return i;
  }

  String? getString(String key, {String? def}) =>
      _prefs.getString(key) ?? def;

  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);

  int getInt(String key, {int def = 0}) => _prefs.getInt(key) ?? def;

  Future<void> setInt(String key, int value) => _prefs.setInt(key, value);

  bool getBool(String key, {bool def = false}) => _prefs.getBool(key) ?? def;

  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);

  double? getDouble(String key) => _prefs.getDouble(key);

  Future<void> setDouble(String key, double value) =>
      _prefs.setDouble(key, value);

  Future<void> remove(String key) => _prefs.remove(key);

  Future<void> clear() => _prefs.clear();

  /// 全量键值快照（备份用，v2.3.0）。
  ///
  /// 返回所有键与对应的原始值（String/int/bool/double）。
  /// 备份服务按白名单挑键，这里不做过滤。
  Map<String, Object> snapshot() {
    final out = <String, Object>{};
    for (final key in _prefs.getKeys()) {
      final v = _prefs.get(key);
      if (v != null) out[key] = v;
    }
    return out;
  }

  /// 写回一批键值（恢复备份用）。与快照键类型不符的条目跳过。
  Future<int> restore(Map<String, Object> kv) async {
    var n = 0;
    for (final e in kv.entries) {
      final v = e.value;
      try {
        if (v is String) {
          await _prefs.setString(e.key, v);
        } else if (v is int) {
          await _prefs.setInt(e.key, v);
        } else if (v is bool) {
          await _prefs.setBool(e.key, v);
        } else if (v is double) {
          await _prefs.setDouble(e.key, v);
        } else {
          continue;
        }
        n++;
      } catch (_) {/* 单键失败不阻断整体恢复 */}
    }
    return n;
  }
}