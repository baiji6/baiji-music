import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_logger.dart';
import 'kv_store.dart';

/// 检查结果的状态。
///
/// 旧实现只返回 `UpdateInfo?`，把「已是最新」和「请求失败」混为一谈，
/// 网络不通时手动检查也是一句"当前已是最新版本"，等于没有反馈。
enum UpdateState {
  /// 已是最新（或已忽略该版本）。
  upToDate,

  /// 发现新版本。
  available,

  /// 检查失败（网络 / 限流 / 接口异常）。
  failed,
}

/// 一次检查更新的完整结果。
class UpdateCheckOutcome {
  const UpdateCheckOutcome._(this.state, {this.info, this.message});

  const UpdateCheckOutcome.upToDate() : this._(UpdateState.upToDate);

  const UpdateCheckOutcome.failed(String msg)
      : this._(UpdateState.failed, message: msg);

  const UpdateCheckOutcome.available(UpdateInfo i)
      : this._(UpdateState.available, info: i);

  final UpdateState state;
  final UpdateInfo? info;
  final String? message;
}

/// 版本检查服务：查询 GitHub Releases 获取最新版本信息。
///
/// 相对旧实现的几处修正：
/// 1. 不再只查 `/releases/latest`——该接口会跳过 pre-release 与 draft，
///    历史上有 `v2.0.10-fix1` 这类修订版 tag，用它能查到却不会命中；
///    改为拉取最近若干条 release 自行比较版本号。
/// 2. 版本号解析容忍后缀：`v2.0.11-fix2` 以前会因 `int.tryParse('11-fix2')`
///    返回 null 而整个解析失败，导致永远不提示更新。
/// 3. 比较时补齐位数：2.0 与 2.0.0 视为同一版本，不再误报更新。
/// 4. 支持「忽略此版本」，避免每次启动都弹同一个版本。
class UpdateChecker {
  UpdateChecker._();

  static final UpdateChecker instance = UpdateChecker._();

  static const String _repo = 'baiji6/baiji-music';
  static const String _listUrl =
      'https://api.github.com/repos/$_repo/releases?per_page=20';

  static const String _kIgnored = 'update:ignored_tag';

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
  ));

  String? _currentVersion;

  /// 当前 App 版本号（首次调用会缓存）。
  Future<String> getCurrentVersion() async {
    if (_currentVersion != null) return _currentVersion!;
    try {
      final info = await PackageInfo.fromPlatform();
      _currentVersion = info.version;
      return _currentVersion!;
    } catch (e) {
      AppLog.w('UpdateChecker', '读取版本号失败: $e');
      return '0.0.0';
    }
  }

  /// 用户选择忽略的版本 tag；下一次启动不再提示它。
  String? get ignoredTag => KvStore.instance.getString(_kIgnored);

  Future<void> ignore(String tag) =>
      KvStore.instance.setString(_kIgnored, tag);

  /// 检查是否有新版本。
  ///
  /// [force] 为 true 时忽略「此版本已忽略」的记录（设置页手动检查用）。
  Future<UpdateCheckOutcome> check({bool force = false}) async {
    try {
      final current = _parseVersion(await getCurrentVersion());
      if (current == null) {
        return const UpdateCheckOutcome.failed('无法读取当前版本号');
      }

      final resp = await _dio.get(
        _listUrl,
        options: Options(headers: {'Accept': 'application/vnd.github.v3+json'}),
      );
      if (resp.statusCode != 200) {
        AppLog.w('UpdateChecker', 'API 返回 ${resp.statusCode}');
        return UpdateCheckOutcome.failed('GitHub 接口返回 ${resp.statusCode}');
      }

      final list = resp.data;
      if (list is! List) {
        return const UpdateCheckOutcome.failed('GitHub 接口数据格式异常');
      }

      UpdateInfo? best;
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        // draft 是未发布稿，绝不能拿来提示更新
        if (item['draft'] == true) continue;
        final tag = (item['tag_name'] as String?) ?? '';
        final v = _parseVersion(tag);
        if (v == null) continue;
        if (!_isNewer(v, current)) continue;
        if (best != null && !_isNewer(v, best.version)) continue;
        best = UpdateInfo(
          tag: tag,
          version: v,
          url: (item['html_url'] as String?) ??
              'https://github.com/$_repo/releases',
          body: (item['body'] as String?) ?? '',
          name: (item['name'] as String?) ?? '',
        );
      }

      if (best == null) {
        AppLog.i('UpdateChecker', '当前已是最新版本');
        return const UpdateCheckOutcome.upToDate();
      }
      if (!force && ignoredTag == best.tag) {
        AppLog.i('UpdateChecker', '版本 ${best.tag} 已被忽略，不再提示');
        return const UpdateCheckOutcome.upToDate();
      }
      AppLog.i('UpdateChecker', '发现新版本 ${best.tag}');
      return UpdateCheckOutcome.available(best);
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) {
        return const UpdateCheckOutcome.failed(
            'GitHub 接口限流（每小时 60 次），请稍后再试');
      }
      final msg = switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout =>
          '连接 GitHub 超时，请检查网络',
        DioExceptionType.connectionError => '无法连接 GitHub，请检查网络',
        _ => '检查更新失败：${e.message ?? e}',
      };
      AppLog.w('UpdateChecker', msg);
      return UpdateCheckOutcome.failed(msg);
    } catch (e) {
      AppLog.w('UpdateChecker', '检查更新失败: $e');
      return UpdateCheckOutcome.failed('检查更新失败：$e');
    }
  }

  /// 跳转到 GitHub Release 页面。
  Future<bool> openRelease(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return false;
  }

  /// 解析版本字符串为整数列表。
  ///
  /// 兼容：`v2.1.0` / `2.1` / `v2.0.11-fix2` / `2.1.0+7`。
  /// 非数字段（如后缀 `-fix2`、`+7`）会被截断丢弃，只保留开头的数字部分。
  static List<int>? _parseVersion(String v) {
    var clean = v.trim().replaceFirst(RegExp(r'^[vV]'), '');
    // 截断到第一个非「数字或点」的位置（如 `-fix2`、`+7` 这类后缀）
    final m = RegExp(r'^\d+(?:\.\d+)*').firstMatch(clean);
    if (m == null) return null;
    clean = m.group(0)!;
    if (clean.isEmpty) return null;
    final parts = clean.split('.');
    if (parts.any((p) => p.isEmpty)) return null;
    final parsed = parts.map(int.tryParse).toList();
    if (parsed.any((p) => p == null)) return null;
    return parsed.cast<int>();
  }

  /// 逐位比较；位数不同时按 0 补齐，避免 `2.0` 与 `2.0.0` 被判为有新版本。
  static bool _isNewer(List<int> latest, List<int> current) {
    final n = latest.length > current.length ? latest.length : current.length;
    for (var i = 0; i < n; i++) {
      final a = i < latest.length ? latest[i] : 0;
      final b = i < current.length ? current[i] : 0;
      if (a > b) return true;
      if (a < b) return false;
    }
    return false;
  }
}

class UpdateInfo {
  const UpdateInfo({
    required this.tag,
    required this.version,
    required this.url,
    required this.body,
    this.name = '',
  });

  final String tag;
  final List<int> version;
  final String url;
  final String body;
  final String name;

  /// 截断到指定字数，且不切断代理对（emoji 等）。
  String summary([int max = 200]) {
    final text = body.trim();
    final runes = text.runes.toList();
    if (runes.length <= max) return text;
    return '${String.fromCharCodes(runes.take(max))}…';
  }
}

// ==================== 测试钩子 ====================
//
// 版本解析与比较是第 6 项「检查更新没反应」的根因所在，需要单测固化。
// Dart 的私有成员无法跨库访问，这里开两个只做转发的钩子，
// 保证 `_parseVersion` / `_isNewer` 仍是真私有（对外 API 不变）。

/// 仅供测试：解析版本字符串。
List<int>? checkerDebugParse(String v) => UpdateChecker._parseVersion(v);

/// 仅供测试：判断 [latest] 是否比 [current] 新。
bool checkerDebugIsNewer(String latest, String current) {
  final a = UpdateChecker._parseVersion(latest);
  final b = UpdateChecker._parseVersion(current);
  if (a == null || b == null) return false;
  return UpdateChecker._isNewer(a, b);
}
