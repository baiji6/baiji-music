import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/models/models.dart';

/// 「内置音源（需登录）」总开关 / 纯洛雪模式（v2.5.7-pre2）。
///
/// 内置音源指 QQ / 网易云 / 酷我 / 酷狗等需要登录账号（或会员）才能取流
/// 的原生平台接口。关闭后进入**纯洛雪模式**：所有网络歌曲一律只由用户
/// 导入的洛雪 JS 音源取流，跳过原生取链，且取链失败时不回退原生平台
/// （见 `SourceFallback.onFailure` / `PlayerController._tryFallback`）。
///
/// 放在 core 层：被 network / player / ui 三方共同依赖，且不反向依赖任何
/// 一层。默认开启，保持 v2.5.7-pre1 的行为。
class PureLxMode {
  PureLxMode._();

  static const String kNativeEnabledKey = 'lx:native_source_enabled';

  /// 内置（原生平台）音源是否启用。
  ///
  /// [KvStore] 未初始化（纯测试环境）时默认 true，与自动切源开关
  /// [SourceFallback.enabled] 的兜底写法一致。
  static bool nativeEnabled() {
    try {
      return KvStore.instance.getBool(kNativeEnabledKey, def: true);
    } catch (_) {
      return true;
    }
  }

  /// 是否处于纯洛雪模式（内置音源已关闭）。
  static bool get pureLx => !nativeEnabled();

  static Future<void> setNativeEnabled(bool value) async {
    try {
      await KvStore.instance.setBool(kNativeEnabledKey, value);
    } catch (_) {
      AppLog.w('PureLxMode', '写入内置音源开关失败（KvStore 未初始化）');
    }
  }

  /// [song] 是否应当只走洛雪取流。
  ///
  /// - 本地歌曲：永远 false（不涉及任何网络音源）；
  /// - 洛雪歌曲（`source == lx`）：永远 true，与开关无关；
  /// - 其它网络歌曲：由纯洛雪开关决定，[pureLxOverride] 供单测注入。
  static bool shouldUseLx(Song song, {bool? pureLxOverride}) {
    if (song.isLocal) return false;
    if (song.isLx) return true;
    return pureLxOverride ?? pureLx;
  }
}
