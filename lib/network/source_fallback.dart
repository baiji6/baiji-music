import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/pure_lx_mode.dart';
import 'package:baiji_music/lx/lx_music_api.dart';
import 'package:baiji_music/models/models.dart';

import 'music_api.dart';

/// 一次「自动切换音源」的结果。
class FallbackOutcome {
  const FallbackOutcome({required this.result, required this.from});

  /// 切换后拿到的取流结果。
  final PlayUrlResult result;

  /// 补充来源的可读名称（如「洛雪音源（ikun音源）」/「QQ 音乐」），
  /// 用于播放页 toast「已从 X 源补充」。
  final String from;

  bool get ok => result.isNotEmpty;
}

/// 取链失败后的自动切换音源（v2.5.7）。
///
/// 两条路径，双向兜底：
/// 1. **原生平台取链失败 → 洛雪音源补链**（主场景）：用户未登录/无会员时
///    原生接口返回空，改用已导入的洛雪 JS 插件取直链，无需任何平台账号；
///    插件内部某一个失败还会自动切到下一个插件（见 `LxMusicApi.musicUrl`）。
/// 2. **洛雪音源取链失败 → 回退原生 QQ**：洛雪模式下的搜索本就借原生 QQ
///    接口（歌曲 mid 即 QQ songmid），插件全部失效时退回原生再试一次。
///
/// 开关持久化在 [KvStore]，`KvStore` 未初始化（纯测试环境）时默认开启。
///
/// v2.5.7-pre2：纯洛雪模式下本兜底整体不生效（见 [onFailure]）。
class SourceFallback {
  SourceFallback._();

  static const String kEnabledKey = 'lx:fallback_enabled';

  static bool enabled() {
    try {
      return KvStore.instance.getBool(kEnabledKey, def: true);
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool value) async {
    try {
      await KvStore.instance.setBool(kEnabledKey, value);
    } catch (_) {
      AppLog.w('SourceFallback', '写入自动切源开关失败（KvStore 未初始化）');
    }
  }

  /// 取流失败后的自动切换入口；返回替代结果，无法补充时返回 null。
  ///
  /// [enabledOverride] / [pureLxOverride] / [lxApi] / [nativeFetch]
  /// 仅用于单测注入真实依赖。
  static Future<FallbackOutcome?> onFailure(
    Song song,
    dynamic quality, {
    bool? enabledOverride,
    bool? pureLxOverride,
    LxMusicApi? lxApi,
    Future<PlayUrlResult> Function(Song, dynamic)? nativeFetch,
  }) async {
    if (!(enabledOverride ?? enabled())) return null;
    if (song.isLocal) return null;
    // 纯洛雪模式（v2.5.7-pre2）：主取流本来就只走洛雪，失败后禁止再
    // 回退原生平台，也不做「洛雪补链」（否则会二次打同一网关）。必须
    // 整体短路：_fallbackToNative 里的 playUrlInfo(copyWith(source: qq))
    // 会被 playUrlInfo 顶部的纯洛雪分支重新接回洛雪，形成回环。
    if (pureLxOverride ?? PureLxMode.pureLx) return null;

    if (song.isLx) {
      return _fallbackToNative(song, quality, nativeFetch);
    }
    return _fallbackToLx(song, quality, lxApi ?? LxMusicApi.instance);
  }

  static Future<FallbackOutcome?> _fallbackToLx(
    Song song,
    dynamic quality,
    LxMusicApi lx,
  ) async {
    // 运行时在 App 启动时已预热（见 main.dart）；没有加载到任何插件即说明
    // 用户未导入洛雪音源，直接返回。这样取流失败的热路径上不会触发
    // 文件系统 / path_provider 平台通道访问，也避免每次失败都重复加载。
    if (lx.loadedCount == 0) return null;
    try {
      final r = await lx.musicUrlForSong(song, quality);
      if (!r.ok) return null;
      final url = await LxMusicApi.resolveEncrypted(r.url, r.ekey, r.format);
      AppLog.i('SourceFallback',
          '原生取链失败，已由洛雪插件 ${r.pluginName} 补充（${r.quality}）');
      return FallbackOutcome(
        result: PlayUrlResult.lx(
          url,
          ext: MusicApi.lxExt(r.format, r.url),
          quality: r.quality,
          ekey: r.ekey,
        ),
        from: '洛雪音源（${r.pluginName}）',
      );
    } catch (e) {
      AppLog.w('SourceFallback', '洛雪补链异常: $e');
      return null;
    }
  }

  static Future<FallbackOutcome?> _fallbackToNative(
    Song song,
    dynamic quality,
    Future<PlayUrlResult> Function(Song, dynamic)? nativeFetch,
  ) async {
    try {
      // 洛雪搜索借原生 QQ，mid 即 QQ songmid；去掉 lx 标记后走原生分支。
      final native = song.copyWith(source: Source.qq);
      final PlayUrlResult r;
      if (nativeFetch != null) {
        r = await nativeFetch(native, quality);
      } else {
        final qqQ = quality is Quality ? quality : Quality.playbackDefault;
        r = await MusicApi.playUrlInfo(native, qqQ, NeteaseQuality.standard);
      }
      if (r.isEmpty) return null;
      AppLog.i('SourceFallback', '洛雪取链失败，已回退原生 QQ 音乐');
      return FallbackOutcome(result: r, from: 'QQ 音乐');
    } catch (e) {
      AppLog.w('SourceFallback', '回退原生取链异常: $e');
      return null;
    }
  }
}
