/// 备份与恢复（v2.3.0）。
///
/// 把用户数据导出成一个 JSON 文件：歌单、播放/搜索历史、收藏、
/// 本地音乐库索引、网易云与 QQ 登录态、解密密钥库、全部个性化设置。
/// 换机/重装时导入即可恢复，不用重新登录、重建歌单、重调设置。
///
/// 覆盖范围按 **键白名单**（[includedKeys] / [includedPrefixes]）从
/// [KvStore] 快照里挑——刻意排除设备指纹（`device_json` / `session_*`，
/// 跨设备恢复会与服务端冲突）、日志与协议同意标记。
///
/// JSON 结构：
/// ```json
/// {
///   "app": "baiji-music",
///   "backupVersion": 1,
///   "appVersion": "2.3.0",
///   "exportedAt": "2026-10-16T12:00:00.000",
///   "kv": { "playlist_list": "...", "lyric_view:font": "15.0", ... }
/// }
/// ```
library;

import 'dart:convert';

import 'app_logger.dart';
import 'app_version.dart';
import 'kv_store.dart';

class BackupService {
  BackupService._();

  /// 备份文件格式版本。结构变化时递增。
  static const int backupVersion = 1;

  /// 精确纳入备份的键（用户数据与登录态）。
  static const List<String> includedKeys = <String>[
    // 歌单 / 历史 / 收藏
    'playlist_list',
    'search_history',
    'play_history',
    'favorite_songs',
    // 本地音乐库
    'local_songs',
    'local_fingerprints',
    'local_scan_dirs',
    // 登录态
    'netease_cookie',
    'netease_user_id',
    'login_info:credential_json',
    // 解密密钥库
    'baiji.decrypt.keys.v2',
    // 播放偏好
    'default_quality',
    'default_netease_quality',
    'play_mode',
    'play_rate',
  ];

  /// 按前缀纳入备份的键（各类设置，将来加新设置自动覆盖）。
  static const List<String> includedPrefixes = <String>[
    'lyric_view:',
    'ui:',
    'download_extras:',
    'download_prefs:',
    'cache:',
  ];

  /// 是否纳入备份。设备指纹（device_json / session_*）刻意排除：
  /// 恢复到别的设备后 qimei/session 与真实设备不一致，反而引发风控。
  static bool _included(String key) {
    if (includedKeys.contains(key)) return true;
    for (final p in includedPrefixes) {
      if (key.startsWith(p)) return true;
    }
    return false;
  }

  /// 当前可备份的条数（UI 展示用）。
  static int countBackupItems() =>
      KvStore.instance.snapshot().keys.where(_included).length;

  /// 导出为 JSON 字符串。
  static String export() {
    final all = KvStore.instance.snapshot();
    final kv = <String, Object>{
      for (final e in all.entries)
        if (_included(e.key)) e.key: e.value,
    };
    return const JsonEncoder.withIndent('  ').convert(<String, Object>{
      'app': 'baiji-music',
      'backupVersion': backupVersion,
      'appVersion': AppVersion.current,
      'exportedAt': DateTime.now().toIso8601String(),
      'kv': kv,
    });
  }

  /// 从 JSON 恢复。返回恢复的条目数；格式不对抛 [FormatException]。
  ///
  /// 恢复是**合并写回**：只覆盖备份里存在的键，本机多出来的数据保留。
  /// 内存中的各 Store（歌单/设置等）都是启动时读 KvStore 的静态快照，
  /// 恢复后需要重启应用才完全生效。
  static Future<int> import(String raw) async {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('备份文件结构不正确');
    }
    if (decoded['app'] != 'baiji-music') {
      throw const FormatException('不是白姬音乐的备份文件');
    }
    final version = decoded['backupVersion'];
    if (version is! int || version > backupVersion) {
      throw FormatException(
          '备份版本过新（backupVersion=$version），请先升级应用');
    }
    final kv = decoded['kv'];
    if (kv is! Map<String, dynamic>) {
      throw const FormatException('备份缺少 kv 数据段');
    }
    final n = await KvStore.instance
        .restore(kv.map((k, v) => MapEntry(k, v as Object)));
    AppLog.i('BackupService', '恢复备份：$n 条（备份来自 ${decoded['appVersion']}，'
        '导出于 ${decoded['exportedAt']}）');
    return n;
  }
}
