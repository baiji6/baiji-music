/// 歌词获取：QQ 音乐 / 网易云。
///
/// QQ 侧对齐 Lyrico-Plugins `qq/source.js` 的 `getLyricsForSong`：
/// 请求 `music.musichallSong.PlayLyricInfo` / `GetPlayLyricInfo`，取 `lyric`
/// （QRC，可能是加密密文）、`trans`（译文）、`roma`（罗马音）。
///
/// 网易云侧走 `POST /api/song/lyric/v1`（v1 接口才返回 `yrc` 逐字，
/// 且需登录 Cookie），同一次响应里同时可能带 `lrc`（逐行）、
/// `yrc`（**逐字**）、`tlyric`（译文）、`romalrc`（罗马音）。有 `yrc` 时优先用它。
library;

import 'dart:convert';

import '../core/app_logger.dart';
import '../local/local_scanner.dart';
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
  ///
  /// **本地歌曲必须先分流**：`song.isLocal` 既不是 netease 也不是可用的
  /// QQ mid（本地 mid 只是文件路径的 hashCode），直接落进 [qq] 必然失败——
  /// 请求拿回来的只会是"歌曲不存在"，于是本地内嵌歌词永远显示不出来。
  static Future<Lyrics> of(Song song) async {
    try {
      if (song.isLocal) return await local(song);
      if (song.isNetease) return await netease(song);
      return await qq(song);
    } catch (e) {
      AppLog.w('LyricApi', '获取歌词失败: $e');
      return Lyrics.empty;
    }
  }

  // ==================== 本地文件 ====================

  /// 本地歌曲歌词：先找同目录的外挂 `.lrc`，再读文件内嵌标签。
  ///
  /// 读取与解密都由 [LocalScanner.readLyricFor] 完成；解析交给
  /// [LyricParser]——它能处理 LRC / 增强 LRC / QRC 逐字 / YRC 逐字 / TTML，
  /// 也会自动解密 QQ 的 QRC 密文，所以内嵌的是逐字歌词也能直接染色。
  static Future<Lyrics> local(Song song) async {
    final raw = await LocalScanner.readLyricFor(song);
    if (raw.trim().isEmpty) {
      AppLog.i('LyricApi', '本地歌曲无歌词: ${song.localPath}');
      return Lyrics.empty;
    }
    return LyricParser.parse(raw);
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

    // **逐字密文可能在 qrc 或 lyric 任何一个字段**（fix5 实测：
    // `crypt:1` 时逐字 QRC 密文就在 `lyric` 字段里，`qrc` 反而为空，
    // 且不同登录态/客户端版本下服务端可能改变放置位置）。
    // 所以两个候选都解析，**优先返回带词级时间轴的结果**；
    // 都没有词级时退回 lyric 的逐行结果——宁可逐行不能没词。
    final qrc = _str(data['qrc']);
    final lrc = _str(data['lyric']) ?? '';
    final trans = _str(data['trans']) ?? '';
    final roma = _str(data['roma']) ?? '';

    AppLog.d('LyricApi',
        'QQ 歌词响应 song=${song.name} qrc=${qrc == null ? "无" : "len=${qrc.length}"} '
        'lyric=${lrc.isEmpty ? "无" : "len=${lrc.length}"} '
        'trans=${trans.isEmpty ? "无" : "有"} roma=${roma.isEmpty ? "无" : "有"}');

    if (qrc == null && lrc.isEmpty && trans.isEmpty) {
      AppLog.i('LyricApi', 'QQ 歌词为空 song=${song.name}');
      return Lyrics.empty;
    }

    Lyrics? fallback;
    if (qrc != null && qrc.isNotEmpty) {
      final ly = LyricParser.parse(
        qrc,
        translation: trans.isEmpty ? null : trans,
        romanization: roma.isEmpty ? null : roma,
      );
      if (ly.hasWordTiming) {
        AppLog.d('LyricApi',
            'QQ qrc 解析出逐字歌词 song=${song.name} lines=${ly.length}');
        return ly;
      }
      if (ly.isNotEmpty) fallback ??= ly;
    }
    if (lrc.isNotEmpty) {
      final ly = LyricParser.parse(
        lrc,
        translation: trans.isEmpty ? null : trans,
        romanization: roma.isEmpty ? null : roma,
      );
      if (ly.hasWordTiming) {
        AppLog.d('LyricApi',
            'QQ lyric 字段解析出逐字歌词（密文在 lyric） song=${song.name} lines=${ly.length}');
        return ly;
      }
      if (ly.isNotEmpty) fallback ??= ly;
    }
    if (fallback != null) {
      AppLog.d('LyricApi',
          'QQ 无逐字数据，使用逐行歌词 song=${song.name} lines=${fallback.length}');
      return fallback;
    }
    return Lyrics.empty;
  }

  // ==================== 网易云 ====================

  /// 网易云歌词。
  ///
  /// **必须走 `/song/lyric/v1`**（v2.2.9-fix2）：老接口 `/song/lyric`
  /// 无论什么参数都**不会**返回 `yrc`（逐字），这就是"有逐字歌词的歌曲
  /// 获取到逐行歌词"的根因——实测晴天（id=186016）老接口响应里连 `yrc`
  /// 键都没有。v1 接口在带登录 Cookie（MUSIC_U）时返回 `yrc`；
  /// 未登录时没有 `yrc`，`lrc` 是**混合格式**（JSON 制作信息行 + 经典
  /// LRC 行），由 [LyricParser] 的混合分支解析成逐行歌词。
  ///
  /// `cv` 为客户端版本号（社区通用值），缺了部分网关不给 v1 响应。
  static Future<Lyrics> netease(Song song) async {
    final client = AppServices.instance.netease;
    final json = await client.postApi(
      '${NeteaseClient.apiBase}/song/lyric/v1',
      <String, String>{
        'id': '${song.songId}',
        'cp': 'false',
        'cv': '4747474',
        'tv': '0',
        'lv': '0',
        'rv': '0',
        'kv': '0',
        'yv': '0',
        'ytv': '0',
        'yrv': '0',
      },
    );

    String pick(String key) =>
        (json[key] as Map<String, dynamic>?)?['lyric'] as String? ?? '';

    final yrc = pick('yrc');
    final lrc = pick('lrc');
    final tlyric = pick('tlyric');
    final romalrc = pick('romalrc');
    final klyric = pick('klyric');

    // fix5 诊断日志：真机上若仍是逐行，看这里就能定位是「没拿到 yrc」
    // 还是「拿到了没解析出来」。
    AppLog.d('LyricApi',
        '网易云歌词响应 song=${song.name} 登录=${client.isLoggedIn()} '
        'yrc=${yrc.isEmpty ? "无" : "len=${yrc.length}"} '
        'lrc=${lrc.isEmpty ? "无" : "len=${lrc.length}"} '
        'klyric=${klyric.isEmpty ? "无" : "有"} tlyric=${tlyric.isEmpty ? "无" : "有"}');

    // 优先逐字；没有则退回逐行（v1 未登录时是混合格式）；
    // 再退回（韩语）音译。
    final content = yrc.isNotEmpty ? yrc : (lrc.isNotEmpty ? lrc : klyric);
    if (content.isEmpty) {
      AppLog.i('LyricApi', '网易云歌词为空 song=${song.name}');
      return Lyrics.empty;
    }

    final parsed = LyricParser.parse(
      content,
      translation: tlyric.isEmpty ? null : tlyric,
      romanization: romalrc.isEmpty ? null : romalrc,
    );
    if (yrc.isNotEmpty && !parsed.hasWordTiming) {
      // 拿到了 yrc 却没解析出词级——这是解析端 bug，立即在日志里暴露
      AppLog.w('LyricApi',
          '网易云 yrc 有数据但解析无词级（解析端异常） song=${song.name}');
    } else {
      AppLog.d('LyricApi',
          '网易云解析结果 song=${song.name} lines=${parsed.length} '
          '词级=${parsed.hasWordTiming}');
    }
    return parsed;
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
