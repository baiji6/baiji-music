import 'dart:convert';

import 'package:dio/dio.dart';

import 'lx_source.dart';
import 'lx_version.dart';

/// 单个音源的一次检测结果。
class LxUpdateOutcome {
  const LxUpdateOutcome({
    required this.sourceId,
    required this.name,
    required this.currentVersion,
    required this.latestVersion,
    this.hasUpdate = false,
    this.applied = false,
    this.error,
  });

  final String sourceId;
  final String name;
  final String currentVersion;
  final String latestVersion;

  /// 远端版本是否比本地新。
  final bool hasUpdate;

  /// 是否已自动下载替换脚本（并刷新版本号）。
  final bool applied;

  /// 失败原因（网络异常 / 无更新地址 / 远端无 `@version`）。
  final String? error;

  bool get isError => error != null;

  /// 供 UI 直接展示的一句话状态。
  String get summary {
    if (isError) return error!;
    if (applied) return '已自动更新到 $currentVersion';
    if (hasUpdate) return '发现新版本 $currentVersion → $latestVersion';
    return '已是最新 $currentVersion';
  }
}

/// 下载远端脚本文本。可注入以便单测用假数据，默认走 Dio。
typedef LxFetch = Future<String> Function(String url);

/// 洛雪音源「检测更新 + 自动更新」。
///
/// - 检测：对 [LxSource.updateUrl] 非空的源 GET 之，解析新脚本头信息的
///   `@version`，用 [SourceVersion.compare] 判断是否更新；
/// - 自动更新：当「全局自动更新」或「该源单源自动更新」开启时，发现更新
///   即下载替换脚本、刷新元数据里的版本号，并回调 [onSourcesChanged]
///   通知运行时重载（由 UI / `LxMusicApi` 注入）。
///
/// 手动「检测更新」与启动静默检测走同一入口 [checkAll]，区别只在
/// [respectSwitch]：为 false 时只检测不落盘（用于「仅查看」）。
class LxUpdateChecker {
  LxUpdateChecker({
    required this.repo,
    LxFetch? fetch,
    this.onSourcesChanged,
  }) : _fetch = fetch ?? _dioFetch;

  final LxSourceRepo repo;
  final LxFetch _fetch;
  final Future<void> Function()? onSourcesChanged;

  static Future<String> _dioFetch(String url) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.plain,
    ));
    final resp = await dio.get(url);
    if (resp.statusCode != 200) {
      throw 'HTTP ${resp.statusCode}';
    }
    final data = resp.data;
    if (data is String) return data;
    if (data is List<int>) return utf8.decode(data);
    throw '响应不是文本';
  }

  /// 遍历所有带更新地址的源做检测。
  ///
  /// [respectSwitch] 为 true（默认）时，按全局/单源开关决定是否自动替换；
  /// 设为 false 则只返回检测结果、不改动脚本。
  Future<List<LxUpdateOutcome>> checkAll({bool respectSwitch = true}) async {
    final sources = await repo.all();
    final globalAuto = await repo.globalAutoUpdate();
    final now = DateTime.now().millisecondsSinceEpoch;
    final outcomes = <LxUpdateOutcome>[];
    var anyApplied = false;

    for (final s in sources) {
      final shouldApply =
          respectSwitch && (globalAuto || s.autoUpdate);
      final outcome = await checkOne(s, autoApply: shouldApply, now: now);
      outcomes.add(outcome);
      if (outcome.applied) anyApplied = true;
    }

    await repo.setLastCheckAt(now);
    final reload = onSourcesChanged;
    if (anyApplied && reload != null) {
      await reload();
    }
    return outcomes;
  }

  /// 检测单个源。[autoApply] 为真且确有更新时才落盘替换。
  Future<LxUpdateOutcome> checkOne(
    LxSource s, {
    bool autoApply = false,
    int? now,
  }) async {
    final ts = now ?? DateTime.now().millisecondsSinceEpoch;
    if (!s.canCheckUpdate) {
      return LxUpdateOutcome(
        sourceId: s.id,
        name: s.name,
        currentVersion: s.version,
        latestVersion: s.latestVersion,
        error: '未设置更新地址',
      );
    }

    try {
      final remote = await _fetch(s.updateUrl);
      final meta = LxSource.parseHeader(remote);
      final latest = (meta['version'] ?? '').trim();
      if (latest.isEmpty) {
        return LxUpdateOutcome(
          sourceId: s.id,
          name: s.name,
          currentVersion: s.version,
          latestVersion: s.latestVersion,
          error: '远端脚本缺少 @version',
        );
      }

      final hasUpdate = SourceVersion.isNewer(latest, s.version);
      var updated = s.copyWith(
        lastCheckedAt: ts,
        latestVersion: hasUpdate ? latest : '',
      );
      var applied = false;

      if (hasUpdate && autoApply && _looksLikeSource(remote)) {
        await repo.writeScript(s, remote);
        updated = updated.copyWith(version: latest, latestVersion: '');
        applied = true;
      }
      await repo.update(updated);

      return LxUpdateOutcome(
        sourceId: s.id,
        name: s.name,
        currentVersion: updated.version,
        latestVersion: latest,
        hasUpdate: hasUpdate,
        applied: applied,
      );
    } catch (e) {
      // 检测失败也要记录检测时间，避免每次启动反复重试同一失败源。
      await repo.update(s.copyWith(lastCheckedAt: ts));
      return LxUpdateOutcome(
        sourceId: s.id,
        name: s.name,
        currentVersion: s.version,
        latestVersion: s.latestVersion,
        error: '检测失败：$e',
      );
    }
  }

  /// 防止把错误页 / 空响应当成音源脚本写盘：至少要有版本头与合理长度。
  static bool _looksLikeSource(String script) {
    if (script.length < 100) return false;
    final meta = LxSource.parseHeader(script);
    return meta.containsKey('version') || meta.containsKey('name');
  }
}
