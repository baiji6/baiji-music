/// 第三方取流门面（v2.6.7）。
///
/// 本类不绑定任何具体第三方 API：取流委托给当前注册的 [ThirdPartyProvider]
/// （见 [ThirdPartyProviderRegistry]）。当前内置「聆澜」；未来接入别的聚合
/// API 时实现 provider 并注册即可，调用方（MusicApi / 播放器 / 下载器）不变。
///
/// 保留的静态纯函数（clampQuality / fromQq / …）默认走聆澜实现，方便离线
/// 单测锁定映射契约；真实取流始终走 [fetch] → 当前 provider。
library;

import '../../core/third_party_source.dart';
import '../../models/models.dart';
import 'linglan_provider.dart';
import 'third_party_provider.dart';

export 'third_party_provider.dart'
    show ThirdPartyStreamInfo, ThirdPartyQuery, ThirdPartyProvider, ThirdPartyProviderRegistry;

class ThirdPartyStreamApi {
  ThirdPartyStreamApi._();

  /// 默认注册「聆澜」（懒初始化，保证任何 provider 访问前注册表就绪）。
  /// 未来新 provider 在 main 里额外 register 即可。
  static final LinglanProvider _linglan = _registerDefault();
  static LinglanProvider _registerDefault() {
    final p = const LinglanProvider();
    ThirdPartyProviderRegistry.register(p);
    return p;
  }

  /// 当前生效的 provider（按设置里的 providerId，回退到聆澜）。
  static ThirdPartyProvider get provider {
    _linglan; // 触发默认注册
    return ThirdPartyProviderRegistry.byId(ThirdPartySource.instance.providerId);
  }

  // ---- 以下静态纯函数保留兼容，默认指向聆澜（离线测试锁定映射契约用） ----

  static const List<String> rank = LinglanProvider.rank;
  static const Map<String, List<String>> platformQualities =
      LinglanProvider.platformQualities;

  static String? sourceCode(String source) => _linglan.sourceCode(source);
  static String clampQuality(String desired, String platform) =>
      _linglan.clampQuality(desired, platform);
  static String extOf(String quality) => _linglan.extOf(quality);
  static String labelOf(String quality) => _linglan.labelOf(quality);

  static String fromQq(Quality? q) => LinglanProvider.fromQq(q);
  static String fromNetease(NeteaseQuality? q) => LinglanProvider.fromNetease(q);
  static String fromKuwo(KuwoQuality? q) => LinglanProvider.fromKuwo(q);
  static String fromKugou(KugouQuality? q) => LinglanProvider.fromKugou(q);
  static String fromMigu(MiguQuality? q) => LinglanProvider.fromMigu(q);
  static String fromQishui(QishuiQuality? q) => LinglanProvider.fromQishui(q);

  static String desiredQuality(
    String platform, {
    Quality? qqQuality,
    NeteaseQuality? neQuality,
    KuwoQuality? kuwoQuality,
    KugouQuality? kugouQuality,
    MiguQuality? miguQuality,
    QishuiQuality? qishuiQuality,
  }) =>
      _linglan.desiredQuality(
        platform,
        ThirdPartyQuery(
          qqQuality: qqQuality,
          neQuality: neQuality,
          kuwoQuality: kuwoQuality,
          kugouQuality: kugouQuality,
          miguQuality: miguQuality,
          qishuiQuality: qishuiQuality,
        ),
      );

  /// 取流主入口。任一步失败返回 null，交由调用方回退内置 / 报错。
  ///
  /// key 与 provider 选择都从 [ThirdPartySource] 读取；[apiKey] 仅供离线测试
  /// 显式传入覆盖。真实播放 / 下载不传，走设置里用户自填的 key。
  static Future<ThirdPartyStreamInfo?> fetch(
    Song song, {
    String? apiKey,
    Quality? qqQuality,
    NeteaseQuality? neQuality,
    KuwoQuality? kuwoQuality,
    KugouQuality? kugouQuality,
    MiguQuality? miguQuality,
    QishuiQuality? qishuiQuality,
  }) async {
    final key = apiKey ?? ThirdPartySource.instance.apiKey;
    if (key.isEmpty) return null;
    return provider.fetch(
      song: song,
      apiKey: key,
      query: ThirdPartyQuery(
        qqQuality: qqQuality,
        neQuality: neQuality,
        kuwoQuality: kuwoQuality,
        kugouQuality: kugouQuality,
        miguQuality: miguQuality,
        qishuiQuality: qishuiQuality,
      ),
    );
  }
}
