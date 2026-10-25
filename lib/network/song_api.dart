import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/string_clip.dart';
import 'package:baiji_music/crypto/qq_crypto.dart';
import 'package:baiji_music/models/models.dart';

import 'qq_music_client.dart';

/// QQ 音乐歌曲接口：详情、播放链接、歌词（对应原生 `network/SongApi.kt`）。
class SongApi {
  /// 最近一次 GetVkey 批量响应的 ekey 表（songmid -> ekey）。
  /// 仅服务 getPlayUrlEx 的单条查询；并发调用下以最后一次为准。
  final Map<String, String> _lastEkeys = {};

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
    if (mid.isEmpty) return '';
    final urls = await getPlayUrls([mid], quality);
    return urls[mid] ?? '';
  }

  /// 取播放链接并带回 ekey（v2.4.2）。
  ///
  /// QQ 对 FLAC/母带/杜比等高档位返回的是 **QMCv2 加密流**，密钥随
  /// GetVkey 响应的 `midurlinfo[].ekey` 下发（TEA 包装，见
  /// `decrypt/qmc_ekey.dart`）。直链本身无内嵌 footer，key 只能带外传，
  /// 与酷我 API 同型——播放层据此走本地流式解密中继。
  Future<({String url, String ekey})> getPlayUrlEx(
      String mid, Quality quality) async {
    final empty = (url: '', ekey: '');
    if (mid.isEmpty) return empty;
    final urls = await getPlayUrls([mid], quality);
    final url = urls[mid] ?? '';
    if (url.isEmpty) return empty;
    // getPlayUrls 走的是批量路径，这里需要单条 ekey —— 直接再发一次
    // 太浪费；改为读取批量调用里缓存的 ekey 表。
    return (url: url, ekey: _lastEkeys[mid] ?? '');
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
      // guid 可为任意值（服务端不校验），固定为 MOLAN 以保持请求一致、可复现。
      'guid': 'MOLAN',
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
        _lastEkeys[m] = (item['ekey'] ?? '').toString();
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