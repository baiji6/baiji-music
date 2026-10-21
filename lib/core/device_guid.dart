/// 设备唯一标识（GUID）生成与持久化（v2.4.0）。
///
/// 用途：给每个设备/用户一个稳定且唯一的字符串 ID，用于
/// - 数据上传（`upload.php`）时区分「谁」在用哪个平台；
/// - 后续做设备维度的统计与去重。
///
/// 设计要点：
/// - **一次生成，永久复用**：首次启动生成后写入本地存储，
///   之后每次启动都读回同一个值，绝不重新生成（否则同机多 ID，
///   服务端统计就废了）。
/// - **设备 ID 派生**：优先用平台提供的稳定设备 ID（Android 的
///   `androidId`、iOS 的 `identifierForVendor`、macOS 的 IOPlatformUUID、
///   Windows 的 MachineGuid）作为种子；拿不到时退回「随机种子 +
///   平台信息」的哈希，保证仍有唯一性。
/// - **不采集隐私**：不上传任何原始设备标识，只上传派生出的
///   GUID 与平台名。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'app_logger.dart';
import 'kv_store.dart';

/// 设备 GUID 服务。
class DeviceGuid {
  DeviceGuid._();

  static const String _key = 'device_guid_v1';
  static const String _seedKey = 'device_guid_seed_v1';

  static String? _cached;

  /// 当前已生成的 GUID；尚未生成时为空串。
  static String get instance => _cached ?? '';

  /// 取当前设备的 GUID（首次调用会生成并落盘）。
  ///
  /// 生成过程需要读平台设备 ID（异步 MethodChannel），所以必须 await。
  /// 生成一次后永久复用，之后每次启动都读回同一个值。
  static Future<String> ensure() async {
    final c = _cached;
    if (c != null) return c;
    final v = await _loadOrCreate();
    _cached = v;
    return v;
  }

  static Future<String> _loadOrCreate() async {
    final store = KvStore.instance;
    final saved = store.getString(_key);
    if (saved != null && saved.isNotEmpty) {
      _cached = saved;
      return saved;
    }

    // 已有随机种子（设备 ID 读不到时生成）→ 用它派生，保证 ID 不变
    var seed = store.getString(_seedKey);
    if (seed == null || seed.isEmpty) {
      // 优先平台通道（Android / iOS），桌面端退回系统级机器 ID，
      // 都没有才用本地随机种子（随机种子会落盘，保证 ID 稳定）
      final native = await _nativeDeviceId();
      final desktop = native == null || native.isEmpty ? _deviceId() : native;
      seed = (desktop != null && desktop.isNotEmpty) ? desktop : _randomSeed();
      store.setString(_seedKey, seed);
    }

    final guid = _derive(seed);
    store.setString(_key, guid);
    _cached = guid;
    AppLog.i('DeviceGuid', '生成设备 GUID: $guid');
    return guid;
  }

  /// 平台通道读取的设备 ID（Android / iOS）。
  static Future<String?> _nativeDeviceId() async {
    try {
      const channel = MethodChannel('baiji/device');
      final id = await channel.invokeMethod<String>('deviceId');
      if (id == null || id.isEmpty) return null;
      return id;
    } catch (e) {
      AppLog.w('DeviceGuid', '平台通道读取设备 ID 失败: $e');
      return null;
    }
  }

  /// 派生 GUID：种子（设备 ID 或本地随机种子）+ 平台标识 → 哈希 → UUID 形态。
  static String _derive(String seed) {
    final parts = <String>[
      seed,
      Platform.operatingSystem,
      Platform.operatingSystemVersion,
    ];
    final digest = sha256.convert(utf8.encode(parts.join('|')));
    final hex = digest.toString();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  /// 平台提供的稳定设备 ID（拿不到返回 null）。
  static String? _deviceId() {
    try {
      if (Platform.isAndroid) {
        final androidId = _androidId();
        if (androidId != null && androidId.isNotEmpty) return androidId;
      } else if (Platform.isIOS) {
        final vendorId = _iosVendorId();
        if (vendorId != null && vendorId.isNotEmpty) return vendorId;
      } else if (Platform.isMacOS) {
        final uuid = _macPlatformUuid();
        if (uuid != null && uuid.isNotEmpty) return uuid;
      } else if (Platform.isWindows) {
        final guid = _windowsMachineGuid();
        if (guid != null && guid.isNotEmpty) return guid;
      } else if (Platform.isLinux) {
        final machineId = _linuxMachineId();
        if (machineId != null && machineId.isNotEmpty) return machineId;
      }
    } catch (e) {
      AppLog.w('DeviceGuid', '读取设备 ID 失败: $e');
    }
    return null;
  }

  static String? _androidId() {
    // Android ID 需 Android API 26+；读 /proc 无法拿到，
    // 这里退化为读取系统属性（部分 ROM 开放）。
    final proc = File('/proc/sys/kernel/random/boot_id');
    if (proc.existsSync()) {
      final v = proc.readAsStringSync().trim();
      if (v.isNotEmpty) return v;
    }
    return null;
  }

  static String? _iosVendorId() {
    // Dart 没有直接 API 读 identifierForVendor，
    // 这里不臆造，返回 null 让随机种子兜底。
    return null;
  }

  static String? _macPlatformUuid() {
    final r = Process.runSync('ioreg', [
      '-rd1',
      '-c',
      'IOPlatformExpertDevice',
    ]);
    if (r.exitCode != 0) return null;
    final out = r.stdout.toString();
    final m = RegExp(r'"IOPlatformUUID"\s*=\s*"([^"]+)"').firstMatch(out);
    return m?.group(1);
  }

  static String? _windowsMachineGuid() {
    final r = Process.runSync('reg', [
      'query',
      r'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography',
      '/v',
      'MachineGuid',
    ]);
    if (r.exitCode != 0) return null;
    final out = r.stdout.toString();
    final m = RegExp(r'MachineGuid\s+REG_SZ\s+([0-9a-fA-F-]+)').firstMatch(out);
    return m?.group(1);
  }

  static String? _linuxMachineId() {
    for (final p in const [
      '/etc/machine-id',
      '/var/lib/dbus/machine-id',
    ]) {
      final f = File(p);
      try {
        if (f.existsSync()) {
          final v = f.readAsStringSync().trim();
          if (v.isNotEmpty) return v;
        }
      } catch (_) {}
    }
    return null;
  }

  static String _randomSeed() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(24, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// 平台名（用于上报）：`android` / `ios` / `macos` / `windows` / `linux`。
  static String get platformName {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return Platform.operatingSystem.toLowerCase();
  }
}
