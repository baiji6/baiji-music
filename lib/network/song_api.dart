import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/string_clip.dart';
import 'package:baiji_music/crypto/qq_crypto.dart';
import 'package:baiji_music/models/models.dart';

import 'qq_music_client.dart';

/// QQ 音乐歌曲接口：详情、播放链接、歌词（对应原生 `network/SongApi.kt`）。
class SongApi {
  SongApi(this.client);

  final QQMusicClient client;

  static const String songUrlFallbackDomain =
      'https://isure.stream.qqmusic.qq.com/';

  /// 获取歌曲详情（把 song_id 转 mid 或取歌曲信息）。
  Future<Map<String, dynamic>?> getDetail(String mid) async {
    final param = <String, dynamic>{};
    if (_isDigits(mid)) {
      param['song_id'] = int.tryParse(mid) ?? 0;
    } else {
      param['song_mid'] = mid;
    }
    final data = await client.execute(BizRequest(
      module: 'music.pf_song_detail_svr',
      method: 'get_song_detail_yqq',
      param: param,
    ));
    final track = data['track_info'];
    return track is Map<String, dynamic> ? track : null;
  }

  /// 获取单个播放链接（无效返回空串）。
  Future<String> getPlayUrl(String mid, Quality quality) async {
    final urls = await getPlayUrls([mid], quality);
    return urls[mid] ?? '';
  }

  /// 批量获取播放链接。
  Future<Map<String, String>> getPlayUrls(
      List<String> mids, Quality quality) async {
    if (mids.isEmpty) return const {};
    final type = quality;
    final filenameArr = mids.map((m) => type.filenameFor(m)).toList();
    final uin =
        client.credential.strMusicid.isNotEmpty ? client.credential.strMusicid : client.credential.musicid.toString();

    final param = <String, dynamic>{
      'guid': client.device.openUdid(),
      'songmid': mids,
      'songtype': List<int>.filled(mids.length, 0),
      'filename': filenameArr,
      'uin': uin,
      'loginflag': 1,
      'platform': '23',
      'h5queryversion': 1,
      'nettype': '',
      'jsonpCallback': 'jsonp1',
      'cms': 0,
      'firstlogin': 1,
      'newver': 1,
      'nohash': 0,
      'format': 'json',
      'inCharset': 'utf-8',
      'outCharset': 'utf-8',
      'notice': 0,
      'needNewCode': 0,
      'songmid_pre': '',
      'soundname': '',
      'bitrate': type.bitrate,
      'quality': type.code,
    };

    final data = await client.execute(BizRequest(
      module: 'music.vkey.GetVkey',
      method: 'UrlGetVkey',
      param: param,
    ));
    final sipArr = data['sip'];
    final sip = sipArr is List
        ? sipArr.map((e) => e.toString()).toList()
        : <String>[];
    final midUrlInfo = data['midurlinfo'];
    final result = <String, String>{};
    if (midUrlInfo is List) {
      for (final item in midUrlInfo) {
        if (item is! Map<String, dynamic>) continue;
        final m = item['songmid'] as String? ?? '';
        final purl = item['purl'] as String? ?? '';
        if (m.isEmpty || purl.isEmpty) continue;
        final url = purl.startsWith('http://') || purl.startsWith('https://')
            ? purl
            : (sip.isNotEmpty
                ? sip[_randomIndex(sip.length)] + purl
                : songUrlFallbackDomain + purl);
        result[m] = url;
        final actual = Quality.fromUrlPrefix(url);
        AppLog.d(
            'SongApi',
            'GetVkey 请求音质=${type.code}(${type.label}) 返回=${actual?.code ?? '未知'} '
            'url_pref=${url.split('/').last.split('?').first.clip(4)}');
      }
    }
    return result;
  }

  /// 获取歌词（优先 QRC 解密，其次翻译）。
  Future<String> getLyrics(String mid) async {
    final param = <String, dynamic>{
      if (_isDigits(mid)) 'songId': int.tryParse(mid) ?? 0 else 'songMID': mid,
      'crypt': 1,
      'lrc_t': 0,
      'qrc': 1,
      'qrc_t': 0,
      'roma': 0,
      'roma_t': 0,
      'trans': 1,
      'trans_t': 0,
      'type': 1,
      'userIP': '127.0.0.1',
      'ct': QQMusicClient.ct,
      'cv': QQMusicClient.cv,
    };
    final data = await client.execute(BizRequest(
      module: 'music.musichallSong.PlayLyricInfo',
      method: 'GetPlayLyricInfo',
      param: param,
    ));
    final lyric = data['lyric'];
    if (lyric is! Map<String, dynamic>) return '';
    final qrc = lyric['qrc'] as String? ?? '';
    if (qrc.isNotEmpty) {
      try {
        return qrcDecrypt(qrc);
      } catch (_) {
        return lyric['trans'] as String? ?? '';
      }
    }
    return lyric['trans'] as String? ?? '';
  }

  bool _isDigits(String s) => s.isNotEmpty && s.codeUnits.every((c) => c >= 0x30 && c <= 0x39);

  int _randomIndex(int n) => DateTime.now().microsecondsSinceEpoch % n;
}