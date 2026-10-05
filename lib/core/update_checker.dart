import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_logger.dart';

/// 版本检查服务：查询 GitHub Releases 获取最新版本信息。
class UpdateChecker {
  UpdateChecker._();

  static final UpdateChecker instance = UpdateChecker._();

  static const String _repo = 'baiji6/baiji-music';
  static const String _apiUrl = 'https://api.github.com/repos/$_repo/releases/latest';

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  String? _currentVersion;

  /// 获取当前应用版本号（异步，首次调用会缓存）。
  Future<String> getCurrentVersion() async {
    if (_currentVersion != null) return _currentVersion!;
    try {
      final info = await PackageInfo.fromPlatform();
      _currentVersion = info.version;
      return _currentVersion!;
    } catch (e) {
      AppLog.w('UpdateChecker', '读取版本号失败: $e');
      return '2.0.0';
    }
  }

  /// 检查是否有新版本。
  /// 返回 null 表示已是最新或检查失败；返回 [UpdateInfo] 表示有新版本。
  Future<UpdateInfo?> check() async {
    try {
      final resp = await _dio.get(
        _apiUrl,
        options: Options(headers: {'Accept': 'application/vnd.github.v3+json'}),
      );
      if (resp.statusCode != 200) {
        AppLog.w('UpdateChecker', 'API 返回 ${resp.statusCode}');
        return null;
      }
      final json = resp.data as Map<String, dynamic>;
      final tag = (json['tag_name'] as String?) ?? '';
      final latest = _parseVersion(tag);
      final current = _parseVersion(await getCurrentVersion());

      AppLog.i('UpdateChecker', '当前版本 $current | 最新版本 $latest (tag=$tag)');

      if (latest == null || current == null) return null;
      if (_isNewer(latest, current)) {
        return UpdateInfo(
          tag: tag,
          version: latest,
          url: json['html_url'] as String? ?? 'https://github.com/$_repo/releases',
          body: json['body'] as String? ?? '',
        );
      }
      return null;
    } catch (e) {
      AppLog.w('UpdateChecker', '检查更新失败: $e');
      return null;
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

  // 解析 "v2.1.0" -> [2, 1, 0]
  List<int>? _parseVersion(String v) {
    final clean = v.replaceFirst(RegExp(r'^[vV]'), '');
    final parts = clean.split('.').map(int.tryParse).toList();
    if (parts.any((p) => p == null)) return null;
    return parts.cast<int>();
  }

  bool _isNewer(List<int> latest, List<int> current) {
    for (var i = 0; i < latest.length && i < current.length; i++) {
      if (latest[i] > current[i]) return true;
      if (latest[i] < current[i]) return false;
    }
    return latest.length > current.length;
  }
}

class UpdateInfo {
  final String tag;
  final List<int> version;
  final String url;
  final String body;

  const UpdateInfo({
    required this.tag,
    required this.version,
    required this.url,
    required this.body,
  });
}
