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

  Future<void> remove(String key) => _prefs.remove(key);

  Future<void> clear() => _prefs.clear();
}