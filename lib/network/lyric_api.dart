/// 歌词获取：QQ 音乐 / 网易云。
///
/// QQ 侧对齐 Lyrico-Plugins `qq/source.js` 的 `getLyricsForSong`：
/// 请求 `music.musichallSong.PlayLyricInfo` / `GetPlayLyricInfo`，取 `lyric`
/// （QRC，可能是加密密文）、`trans`（译文）、`roma`（罗马音）。
library;

import 'dart:convert';

import '../core/app_logger.dart';
import '../lyrics/lyric_model.dart';
import '../lyrics/lyric_parser.dart';
import '../models/models.dart';
import 'music_api.dart';
import 'netease/netease_client.dart';
import 'qq_music_client.dart';

/// 歌词请求入口。
class LyricApi {
  LyricApi._();

  /// 按来源取结构化歌词；失败返回空歌词（不抛异常）。
  static Future<Lyrics> of(Song song) async {
    try {
      if (song.isNetease) return await netease(song);
      return await qq(song);
    } catch (e) {
      AppLog.w('LyricApi', '获取歌词失败: $e');
      return Lyrics.empty;
    }
  }

  // ==================== QQ 音乐 ====================

  static Future<Lyrics> qq(Song song) async {
    final client = AppServices.instance.qq;
    final digits = RegExp(r'^\d+$');

    String b64(String s) => base64.encode(utf8.encode(s));

    // 优先数字 songID：songId > 纯数字 mid > songMID 字符串
    final int? numericId =
        song.songId > 0 ? song.songId : (digits.hasMatch(song.mid) ? int.tryParse(song.mid) : null);

    final param = <String, dynamic>{
      if (numericId != null) 'songID': numericId else 'songMID': song.mid,
      'songName': b64(song.name),
      'albumName': b64(song.album),
      'singerName': b64(song.singer),
      'crypt': 1,
      'qrc': 1,
      'trans': 1,
      'roma': 1,
      'cv': 2111,
      'ct': 19,
      'lrc_t': 0,
      'qrc_t': 0,
      'roma_t': 0,
      'trans_t': 0,
      'type': 0,
      // duration 为毫秒，接口 interval 要秒
      'interval': song.duration > 0 ? song.duration ~/ 1000 : 0,
    };

    final data = await client.execute(BizRequest(
      module: 'music.musichallSong.PlayLyricInfo',
      method: 'GetPlayLyricInfo',
      param: param,
    ));

    final main = _str(data['lyric']) ?? _str(data['qrc']) ?? '';
    final trans = _str(data['trans']) ?? '';
    final roma = _str(data['roma']) ?? '';

    if (main.isEmpty && trans.isEmpty) {
      AppLog.i('LyricApi', 'QQ 歌词为空 song=${song.name}');
      return Lyrics.empty;
    }

    return LyricParser.parse(
      main,
      translation: trans.isEmpty ? null : trans,
      romanization: roma.isEmpty ? null : roma,
    );
  }

  // ==================== 网易云 ====================

  static Future<Lyrics> netease(Song song) async {
    final json = await AppServices.instance.netease.postApi(
      '${NeteaseClient.apiBase}/song/lyric',
      <String, String>{
        'id': '${song.songId}',
        'cp': 'false',
        'tv': '0',
        'lv': '-1',
        'rv': '0',
        'kv': '-1',
        'yv': '0',
        'ytv': '0',
        'yrv': '0',
      },
    );
    final lrc = (json['lrc'] as Map<String, dynamic>?)?['lyric'] as String? ?? '';
    final tlyric =
        (json['tlyric'] as Map<String, dynamic>?)?['lyric'] as String? ?? '';
    final content = lrc.isNotEmpty ? lrc : tlyric;
    if (content.isEmpty) return Lyrics.empty;

    return LyricParser.parse(
      content,
      translation:
          tlyric.isEmpty || tlyric == lrc ? null : tlyric,
    );
  }

  /// 字段可能是字符串，也可能是嵌套 map（不同接口形态），统一取文本。
  static String? _str(dynamic v) {
    if (v is String) return v.isEmpty ? null : v;
    if (v is Map<String, dynamic>) {
      for (final k in const ['content', 'lyric', 'qrc']) {
        final inner = v[k];
        if (inner is String && inner.isNotEmpty) return inner;
      }
    }
    return null;
  }
}
