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
      Song song, Quality qqQuality, NeteaseQuality neQuality) async {
    if (song.isNetease) {
      final url =
          await AppServices.instance.netease.api.songUrl(song.songId, neQuality);
      return url.url;
    }
    return AppServices.instance.qq.song.getPlayUrl(song.mid, qqQuality);
  }

  /// 按来源取歌词。
  static Future<String> lyric(Song song) async {
    if (song.isNetease) {
      return AppServices.instance.netease.api.lyric(song.songId);
    }
    return AppServices.instance.qq.song.getLyrics(song.mid);
  }
}