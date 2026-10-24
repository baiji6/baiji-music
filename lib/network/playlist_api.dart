// 三平台歌单详情（#143 推荐歌单 / #145 我的歌单 共用）。
//
// 端点（2026-10 沙箱实测）：
//   QQ 音乐 : GET c.y.qq.com/v8/fcg-bin/fcg_v8_playlist_cp.fcg?id=<dissid>
//             → data.cdlist[0]（dissname / logo / nickname / songlist）
//   网易云   : GET music.163.com/api/playlist/detail?id=<id>
//             → result（name / coverImgUrl / creator.nickname / tracks）
//   酷我音乐 : GET nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=<id>&...
//             （必须带 keyset=pl2012 & identity=kuwo & vipver=...，
//             缺参数一律 PARAM_ERROR；与 share_playlist_api 同源）
//             → name/uname/musiclist[]（id=rid）
//             注意：网页端 www.kuwo.cn/api/www/... 已加签不可用。
//
// 歌曲解析复用现成映射：QQ 走 Song.fromTrack，网易云走 NeteaseApi.toSong，
// 避免同一个字段在这里再写一遍（封面档位、歌手拼接等规则都在那边）。
import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/hot_search_api.dart'
    show HotPlaylist, getJsonWithRetry;
import 'package:baiji_music/network/kuwo/kuwo_auth.dart';
import 'package:baiji_music/network/music_api.dart';

/// 一个歌单的详情。
class PlaylistDetail {
  const PlaylistDetail({
    required this.id,
    required this.name,
    required this.cover,
    required this.creator,
    required this.songs,
    this.desc = '',
  });

  final String id;
  final String name;
  final String cover;
  final String creator;
  final List<Song> songs;

  /// 歌单简介（QQ 有 desc，网易云取 description）。
  final String desc;

  /// 只带歌单信息、不带曲目（接口只返回元信息时用）。
  factory PlaylistDetail.infoOnly({
    required String id,
    required String name,
    String cover = '',
    String creator = '',
    String desc = '',
  }) =>
      PlaylistDetail(
        id: id,
        name: name,
        cover: cover,
        creator: creator,
        desc: desc,
        songs: const [],
      );
}

/// 取歌单详情；不支持或失败返回 null（调用方提示即可）。
abstract final class PlaylistApi {
  /// QQ 音乐歌单详情。
  static Future<PlaylistDetail?> qq(String dissid) async {
    try {
      final url = Uri.parse('https://c.y.qq.com/v8/fcg-bin/fcg_v8_playlist_cp.fcg')
          .replace(queryParameters: {
        'id': dissid,
        'format': 'json',
        'newsong': '1',
      }).toString();
      final data = await getJsonWithRetry(url, headers: const {
        'Referer': 'https://y.qq.com/',
        'User-Agent': 'Mozilla/5.0',
      });
      final list = (data['data']?['cdlist'] ?? const []) as List<dynamic>;
      if (list.isEmpty) return null;
      final cd = Map<String, dynamic>.from(list.first as Map);
      final songs = <Song>[];
      for (final s in (cd['songlist'] ?? const []) as List<dynamic>) {
        if (s is! Map<String, dynamic>) continue;
        final song = Song.fromTrack(s);
        if (song.mid.isEmpty) continue;
        songs.add(song);
      }
      return PlaylistDetail(
        id: dissid,
        name: (cd['dissname'] ?? '').toString(),
        cover: _https((cd['logo'] ?? '').toString()),
        creator: (cd['nickname'] ?? '').toString(),
        desc: (cd['desc'] ?? '').toString(),
        songs: songs,
      );
    } catch (e) {
      AppLog.w('PlaylistApi', 'QQ 歌单详情失败 id=$dissid: $e');
      return null;
    }
  }

  /// 网易云歌单详情。
  static Future<PlaylistDetail?> netease(String id) async {
    try {
      final url = Uri.parse('https://music.163.com/api/playlist/detail')
          .replace(queryParameters: {'id': id}).toString();
      final data = await getJsonWithRetry(url, headers: const {
        'Referer': 'https://music.163.com/',
        'User-Agent': 'Mozilla/5.0',
      });
      final r = data['result'];
      if (r is! Map<String, dynamic>) return null;
      final songs = <Song>[];
      for (final t in (r['tracks'] ?? const []) as List<dynamic>) {
        if (t is! Map<String, dynamic>) continue;
        final song = AppServices.instance.netease.api.toSong(t);
        if (song == null) continue;
        songs.add(song);
      }
      final cr = r['creator'];
      return PlaylistDetail(
        id: id,
        name: (r['name'] ?? '').toString(),
        cover: _https((r['coverImgUrl'] ?? '').toString()),
        creator: cr is Map ? (cr['nickname'] ?? '').toString() : '',
        desc: (r['description'] ?? '').toString(),
        songs: songs,
      );
    } catch (e) {
      AppLog.w('PlaylistApi', '网易云歌单详情失败 id=$id: $e');
      return null;
    }
  }

  /// 酷我歌单详情。
  ///
  /// 分页拉 musiclist；[fallbackName] 用于接口不回歌单名时（实测 `name`
  /// 为空、只有 uname），用列表页已经拿到的名字兜底。
  static Future<PlaylistDetail?> kuwo(String pid,
      {String fallbackName = '', String fallbackCover = ''}) async {
    try {
      const pageSize = 100;
      final songs = <Song>[];
      String name = fallbackName;
      String creator = '';
      String cover = fallbackCover;

      for (var pn = 0; pn < 10; pn++) {
        final url = Uri.parse('http://nplserver.kuwo.cn/pl.svc').replace(
            queryParameters: {
          'op': 'getlistinfo',
          'pid': pid,
          'pn': pn.toString(),
          'rn': pageSize.toString(),
          'encode': 'utf8',
          'keyset': 'pl2012',
          'identity': 'kuwo',
          'pcmp4': '1',
          'vipver': 'MUSIC_9.0.5.0_W1',
          'newver': '1',
        }).toString();
        final data = await getJsonWithRetry(url,
            headers: const {'User-Agent': 'Mozilla/5.0'});
        if ((data['result'] ?? '').toString() != 'ok') break;
        final total = (data['total'] as num?)?.toInt() ?? 0;
        if (pn == 0) {
          final n = (data['name'] ?? data['listname'] ?? data['title'] ?? '')
              .toString();
          if (n.isNotEmpty) name = n;
          creator = (data['uname'] ?? '').toString();
          final img = (data['img'] ?? '').toString();
          if (img.isNotEmpty) cover = _https(img);
        }
        final raw = (data['musiclist'] as List<dynamic>? ?? const []);
        if (raw.isEmpty) break;
        for (final e in raw) {
          if (e is! Map<String, dynamic>) continue;
          final rid = (e['id'] ?? '').toString();
          if (rid.isEmpty) continue;
          songs.add(Song(
            mid: rid,
            songId: int.tryParse(rid) ?? 0,
            name: (e['name'] ?? '').toString(),
            singer: (e['artist'] ?? '').toString(),
            album: (e['album'] ?? '').toString(),
            albumMid: '',
            duration: (int.tryParse((e['duration'] ?? '0').toString()) ?? 0) *
                1000,
            cover: '',
            source: Source.kuwo,
          ));
        }
        if (total > 0 && songs.length >= total) break;
        if (raw.length < pageSize) break;
      }
      return PlaylistDetail(
        id: pid,
        name: name,
        cover: cover,
        creator: creator,
        songs: songs,
      );
    } catch (e) {
      AppLog.w('PlaylistApi', '酷我歌单详情失败 pid=$pid: $e');
      return null;
    }
  }

  /// 按平台取歌单详情。
  ///
  static Future<PlaylistDetail?> of(String source, String id,
      {String fallbackName = '', String fallbackCover = ''}) async {
    if (source == Source.qq) return qq(id);
    if (source == Source.netease) return netease(id);
    if (source == Source.kuwo) {
      return kuwo(id, fallbackName: fallbackName, fallbackCover: fallbackCover);
    }
    return null;
  }

  /// 该平台是否支持打开歌单（取得到歌曲列表）。
  static bool canOpen(String source) =>
      source == Source.qq ||
      source == Source.netease ||
      source == Source.kuwo;

  // ================= 我的歌单（v2.4.2 #145） =================
  //
  // 登录后按账号拉本人歌单（摘要与热门歌单共用 [HotPlaylist] 承载）。
  // - QQ    : fcg_user_created_diss（hostuin=本人 uin，带 Cookie 才过隐私
  //           校验，别人的号会撞 check privacy error）；
  // - 网易云 : api/user/playlist?uid=<uid>（免登录可看公开歌单）；
  // - 酷我  : nplserver pl.svc op=getuserlist&uid=<uid>（与歌单详情同源）。
  // 未登录返回空列表，调用方显示「登录后同步」提示。

  /// 按平台拉「我的歌单」。
  static Future<List<HotPlaylist>> myPlaylists(String source) async {
    try {
      if (source == Source.qq) return await _myQq();
      if (source == Source.netease) return await _myNetease();
      if (source == Source.kuwo) return await _myKuwo();
    } catch (e) {
      AppLog.w('PlaylistApi', '我的歌单拉取失败 source=$source: $e');
    }
    return const [];
  }

  static Future<List<HotPlaylist>> _myQq() async {
    final cred = AppServices.instance.qq.credential;
    if (!cred.isLoggedIn() || cred.musicid == 0) return const [];
    final uin = cred.musicid;
    final cookie = 'uin=$uin; qm_keyst=${cred.musickey}; '
        'qqmusic_key=${cred.musickey}; tmeLoginType=${cred.loginType}';
    final url = Uri.parse('https://c.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss')
        .replace(queryParameters: {
      'hostUin': '0',
      'hostuin': '$uin',
      'sin': '0',
      'size': '200',
      'g_tk': '5381',
      'loginUin': '$uin',
      'format': 'json',
      'inCharset': 'utf8',
      'outCharset': 'utf-8',
      'notice': '0',
      'platform': 'yqq.json',
      'needNewCode': '0',
    }).toString();
    final data = await getJsonWithRetry(url, headers: {
      'Referer': 'https://y.qq.com/portal/profile.html',
      'User-Agent': 'Mozilla/5.0',
      'Cookie': cookie,
    });
    final list = (data['data']?['disslist'] ?? const []) as List<dynamic>;
    return list
        .map((e) {
          final j = Map<String, dynamic>.from(e as Map);
          // 特殊目录（我喜欢 / QZone 背景音乐等）的 diss_cover 可能是
          // 「?n=1」这种占位，不是真图——置空让 UI 走占位封面。
          final cover = (j['diss_cover'] ?? '').toString();
          return HotPlaylist(
            id: (j['tid'] ?? '').toString(),
            name: (j['diss_name'] ?? '').toString(),
            cover: cover.startsWith('http') ? _https(cover) : '',
            creator: '',
            playCount: (j['listen_num'] ?? '').toString(),
            trackCount: (j['song_cnt'] as num?)?.toInt(),
          );
        })
        .where((p) => p.id.isNotEmpty && p.id != '0')
        .toList();
  }

  static Future<List<HotPlaylist>> _myNetease() async {
    final uid = AppServices.instance.netease.userId;
    if (uid == 0) return const [];
    final url = Uri.parse('https://music.163.com/api/user/playlist')
        .replace(queryParameters: {
      'uid': '$uid',
      'limit': '100',
      'offset': '0',
    }).toString();
    final data = await getJsonWithRetry(url, headers: const {
      'Referer': 'https://music.163.com/',
      'User-Agent': 'Mozilla/5.0',
    });
    final list = (data['playlist'] ?? const []) as List<dynamic>;
    return list
        .map((e) => HotPlaylist.fromNetease(Map<String, dynamic>.from(e as Map)))
        .where((p) => p.id.isNotEmpty)
        .toList();
  }

  static Future<List<HotPlaylist>> _myKuwo() async {
    final session = KuwoAuth.session;
    if (session == null || !session.isValid) return const [];
    final out = <HotPlaylist>[];
    // 分页拉全（rn 上限 100 实测有效）
    for (var pn = 0; pn < 10; pn++) {
      final url = Uri.parse('http://nplserver.kuwo.cn/pl.svc').replace(
          queryParameters: {
        'op': 'getuserlist',
        'uid': session.uid,
        'pn': pn.toString(),
        'rn': '100',
        'encode': 'utf8',
        'keyset': 'pl2012',
        'identity': 'kuwo',
        'pcmp4': '1',
        'vipver': 'MUSIC_9.0.5.0_W1',
        'newver': '1',
      }).toString();
      final data = await getJsonWithRetry(url,
          headers: const {'User-Agent': 'Mozilla/5.0'});
      final list = (data['plist'] ?? const []) as List<dynamic>;
      if (list.isEmpty) break;
      for (final e in list) {
        final j = Map<String, dynamic>.from(e as Map);
        out.add(HotPlaylist(
          id: (j['id'] ?? '').toString(),
          name: (j['title'] ?? '').toString(),
          cover: _https((j['pic'] ?? '').toString()),
          creator: '',
          trackCount: (j['musicnum'] as num?)?.toInt(),
        ));
      }
      if (list.length < 100) break;
    }
    return out;
  }

  static String _https(String url) =>
      url.startsWith('http://') ? 'https://${url.substring(7)}' : url;
}
