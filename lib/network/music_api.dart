import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/netease/netease_client.dart';
import 'package:baiji_music/network/qq_music_client.dart';

/// 全局服务容器（对应原生 `App.kt` 的 api / netease 单例）。
///
/// 六端共享同一套实例；播放器/下载器/UI 通过这里取客户端。
class AppServices {
  AppServices._();

  static final AppServices instance = AppServices._();

  late final QQMusicClient qq = QQMusicClient();
  late final NeteaseClient netease = NeteaseClient();

  bool isLoggedIn(String source) =>
      source == Source.netease ? netease.isLoggedIn() : qq.isLoggedIn();
}

/// 取流结果：直链 + 服务端**实际**提供的音质。
///
/// 播放器据此在 UI 上提示"已降级"，下载器据此决定落盘扩展名
/// （避免"请求 FLAC 实际拿到 MP3"却存成 `.flac`）。
class PlayUrlResult {
  final String url;

  /// QQ 实际音质（QQ 歌曲才有，网易云为 null）。
  final Quality? qq;

  /// 网易云实际音质（网易云歌曲才有，QQ 为 null）。
  final NeteaseQuality? ne;

  /// 覆盖扩展名（网易云响应里的真实 `type`）；为空时按音质枚举推断。
  final String? _extOverride;

  const PlayUrlResult._(this.url, this.qq, this.ne, [this._extOverride]);

  static const empty = PlayUrlResult._('', null, null);

  bool get isEmpty => url.isEmpty;
  bool get isNotEmpty => url.isNotEmpty;

  /// 落盘扩展名。
  String get ext => _extOverride ?? ne?.ext ?? qq?.ext ?? '.mp3';

  /// 音质标签；无则空串。
  String get label => qq?.label ?? ne?.label ?? '';

  @override
  String toString() => 'PlayUrlResult($label)';
}

/// 音源路由：按来源分发到 QQ 音乐或网易云的实现。
///
/// 对应原生 `network/MusicApi.kt`。
class MusicApi {
  MusicApi._();

  static bool isLoggedIn(String source) => AppServices.instance.isLoggedIn(source);

  /// 按来源搜索。
  static Future<List<Song>> search(String source, String keyword,
      {int page = 1, int num = 20}) async {
    if (source == Source.netease) {
      return AppServices.instance.netease.api
          .search(keyword, limit: num, offset: (page - 1) * num);
    }
    return AppServices.instance.qq.search.searchByType(keyword,
        page: page, num: num);
  }

  /// 按来源获取相关搜索建议；失败时返回空列表。
  static Future<List<String>> suggestions(String source, String keyword,
      {int num = 8}) async {
    try {
      if (source == Source.netease) {
        return await AppServices.instance.netease.api
            .suggestions(keyword, limit: num);
      }
      return await AppServices.instance.qq.search.suggestions(keyword, num: num);
    } catch (e) {
      AppLog.w('MusicApi', '获取相关搜索失败: $e');
      return const [];
    }
  }

  /// 按歌曲来源取播放直链。
  static Future<String> playUrl(
      Song song, Quality qqQuality, NeteaseQuality neQuality) async =>
      (await playUrlInfo(song, qqQuality, neQuality)).url;

  /// 按歌曲来源取播放直链，并一并返回**服务端实际提供**的音质。
  ///
  /// 服务端普遍存在"请求成功但返回更低音质"的情况（未登录/无版权/未开通会员），
  /// 因此实际音质必须反查，不能直接采信请求值：
  /// - QQ：从直链文件名前缀（如 `M500003N9y0a72Ioo.mp3`）反查；
  /// - 网易云：直接取响应里的 `level` 字段。
  static Future<PlayUrlResult> playUrlInfo(
      Song song, Quality qqQuality, NeteaseQuality neQuality) async {
    if (song.isNetease) {
      final r =
          await AppServices.instance.netease.api.songUrl(song.songId, neQuality);
      if (!r.isUsable()) return PlayUrlResult.empty;
      return PlayUrlResult._(
        r.url,
        null,
        NeteaseQuality.fromLevel(r.level) ?? neQuality,
        r.ext.isNotEmpty ? r.ext : null,
      );
    }
    final url =
        await AppServices.instance.qq.song.getPlayUrl(song.mid, qqQuality);
    if (url.isEmpty) return PlayUrlResult.empty;
    return PlayUrlResult._(url, Quality.fromUrlPrefix(url) ?? qqQuality, null);
  }

  /// QQ 音质降级链：[from] 起向下最多 6 档，并保证末档兜底到 MP3 128。
  ///
  /// `downloadOptions` 已按高→低排列；从 [from] 之后截取即为"只降不升"。
  static List<Quality> qqDowngradeChain(Quality from) {
    final all = Quality.downloadOptions;
    // 按 code 比对而非 identity，避免将来换成值相等枚举时出错
    final i = all.indexWhere((q) => q.code == from.code);
    final rest = i < 0 ? all : all.sublist(i + 1);
    final chain = <Quality>[from, ...rest.take(5)];
    if (!chain.any((q) => q.code == Quality.mp3_128.code)) {
      chain.add(Quality.mp3_128);
    }
    return chain;
  }

  /// 网易云音质降级链：[from] 起向下，`downloadOptions` 已按高→低排列。
  static List<NeteaseQuality> neteaseDowngradeChain(NeteaseQuality from) {
    final all = NeteaseQuality.downloadOptions;
    final i = all.indexWhere((q) => q.level == from.level);
    return i < 0 ? all : all.sublist(i);
  }

  /// 按来源取歌词。
  static Future<String> lyric(Song song) async {
    if (song.isNetease) {
      return AppServices.instance.netease.api.lyric(song.songId);
    }
    return AppServices.instance.qq.song.getLyrics(song.mid);
  }
}