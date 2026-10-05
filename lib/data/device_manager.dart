import 'dart:convert';

import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/crypto/qq_crypto.dart';

/// 设备信息管理器：生成/持久化设备指纹，管理 session。
///
/// 对应原生 `data/DeviceManager.kt`。首次生成后持久化，重启复用，
/// 确保服务端识别为同一台设备；QIMEI 注册结果也缓存在此。
class DeviceManager {
  static const _keyDevice = 'device_json';
  static const _keyUid = 'session_uid';
  static const _keySid = 'session_sid';
  static const _keySaveTime = 'session_save_time';

  Map<String, dynamic>? _device;

  int get sessionUid => KvStore.instance.getInt(_keyUid, def: 0);
  set sessionUid(int v) => KvStore.instance.setInt(_keyUid, v);

  String get sessionSid => KvStore.instance.getString(_keySid, def: '') ?? '';
  set sessionSid(String v) => KvStore.instance.setString(_keySid, v);

  int get sessionSaveTime => KvStore.instance.getInt(_keySaveTime, def: 0);
  set sessionSaveTime(int v) => KvStore.instance.setInt(_keySaveTime, v);

  /// 获取设备 JSON（懒加载 + 持久化，与原生实现一致）。
  Map<String, dynamic> getDevice() {
    if (_device != null) return _device!;
    final saved = KvStore.instance.getString(_keyDevice);
    Map<String, dynamic> dev;
    if (saved != null && saved.isNotEmpty) {
      try {
        dev = jsonDecode(saved) as Map<String, dynamic>;
        // 旧版本保存的设备 JSON 可能是嵌套字符串（保留兼容）
        if (dev['openUdid'] == null && dev.containsKey('device')) {
          final inner = dev['device'];
          if (inner is String) {
            dev = jsonDecode(inner) as Map<String, dynamic>;
          }
        }
      } catch (_) {
        dev = deviceMakeDefault();
      }
    } else {
      dev = deviceMakeDefault();
    }
    _device = dev;
    saveDevice();
    return dev;
  }

  void saveDevice() {
    final d = _device;
    if (d != null) {
      KvStore.instance.setString(_keyDevice, jsonEncode(d));
    }
  }

  /// 保存 QIMEI 注册结果。
  void applyQimei(String q16, String q36) {
    final d = getDevice();
    d['qimei'] = q16;
    d['qimei36'] = q36;
    d['qimeiSaveTime'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    saveDevice();
  }

  String openUdid() => getDevice()['openUdid'] as String? ?? '';

  bool isSessionValid() {
    if (sessionSaveTime == 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (now - sessionSaveTime >= 86400) return false;
    return sessionUid != 0 && sessionSid.isNotEmpty;
  }

  bool hasQimei() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final d = getDevice();
    final qimei = d['qimei'] as String? ?? '';
    final qimei36 = d['qimei36'] as String? ?? '';
    final saveTime = d['qimeiSaveTime'] as num? ?? 0;
    return qimei.isNotEmpty &&
        qimei36.isNotEmpty &&
        saveTime != 0 &&
        now - saveTime.toInt() < 86400;
  }

  String q16() => getDevice()['qimei'] as String? ?? '';
  String q36() => getDevice()['qimei36'] as String? ?? '';

  void logDebug() {
    final d = getDevice().toString();
    // ignore: avoid_print
    print('device=${d.length > 200 ? d.substring(0, 200) : d}');
  }
}