/// 第三方取流服务provider 抽象（v2.6.7）。
///
/// 第三方音源是可插拔的：当前内置「聆澜」([LinglanProvider])，未来接入别的
/// 聚合 API 时，只需实现本接口并在 [ThirdPartyProviderRegistry] 注册即可，
/// 取流主链路（MusicApi / 播放器 / 下载器）无需改动。
///
/// 每个 provider 自己负责：
/// - 平台码映射（source → 第三方码）与 songId 生成规则；
/// - 音质映射 / 自动降级 / ext / 展示名；
/// - 真正发请求并把明文直链解析成 [ThirdPartyStreamInfo]。
library;

import '../../models/models.dart';

class ThirdPartyStreamInfo {
  final String url;

  /// 实际使用的第三方规范音质串（用于推断 ext / 展示名）。
  final String quality;

  const ThirdPartyStreamInfo({required this.url, required this.quality});
}

/// 一次取流请求的统一入参（把各平台音质打包，provider 自行挑选）。
class ThirdPartyQuery {
  const ThirdPartyQuery({
    this.qqQuality,
    this.neQuality,
    this.kuwoQuality,
    this.kugouQuality,
    this.miguQuality,
    this.qishuiQuality,
  });

  final Quality? qqQuality;
  final NeteaseQuality? neQuality;
  final KuwoQuality? kuwoQuality;
  final KugouQuality? kugouQuality;
  final MiguQuality? miguQuality;
  final QishuiQuality? qishuiQuality;
}

abstract class ThirdPartyProvider {
  const ThirdPartyProvider();

  /// provider 唯一 id（用于持久化与注册表查找），如 `linglan`。
  String get id;

  /// 展示名，如「聆澜」。
  String get displayName;

  /// 内部 Source → 本 provider 的平台码；不支持的平台返回 null。
  String? sourceCode(String source);

  /// 按平台生成 songId。
  Future<String> songIdOf(Song song, String platform);

  /// 用户所选音质 → 本 provider 的规范音质串（未经降级）。
  String desiredQuality(String platform, ThirdPartyQuery query);

  /// 把规范音质串钳到该平台支持的最高一档（自动降级）。
  String clampQuality(String desired, String platform);

  /// 规范音质串 → 落盘扩展名 / 展示名。
  String extOf(String quality);
  String labelOf(String quality);

  /// 真正发请求；失败返回 null，由调用方回退内置。
  Future<ThirdPartyStreamInfo?> fetch({
    required Song song,
    required String apiKey,
    required ThirdPartyQuery query,
  });
}

/// provider 注册表。默认只有「聆澜」，未来接入新 API 时在启动时 register。
class ThirdPartyProviderRegistry {
  ThirdPartyProviderRegistry._();

  static final Map<String, ThirdPartyProvider> _providers =
      <String, ThirdPartyProvider>{};

  static const String defaultId = 'linglan';

  static void register(ThirdPartyProvider provider) {
    _providers[provider.id] = provider;
  }

  static ThirdPartyProvider? get(String id) => _providers[id];

  static ThirdPartyProvider byId(String id) =>
      _providers[id] ?? _providers[defaultId]!;

  static Iterable<ThirdPartyProvider> get all => _providers.values;

  static bool contains(String id) => _providers.containsKey(id);
}
