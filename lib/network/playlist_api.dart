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
import 'package:baiji_music/network/netease/netease_client.dart';
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
      if (list.isEmpty || list.first is! Map) return null;
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
  ///
  /// 关键坑：老 `/api/playlist/detail` 对**用户自建歌单**只回前 10 首预览
  /// （trackCount 也谎报 10），导致登录账号的歌单只显示 10 首。
  /// 正确做法（与 [share_playlist_api.NeteasePlaylist] 一致）：用
  /// `/api/v6/playlist/detail` 拿元数据 + 完整 `trackIds`，再分批调
  /// `/api/v3/song/detail`（每批 ≤100，实测 200 会回 0 条）补全详情，
  /// 并按 `trackIds` 顺序还原。走 `NeteaseClient.postApi` 自动带登录
  /// Cookie，私有歌单也能取到全量。
  static Future<PlaylistDetail?> netease(String id) async {
    try {
      final client = AppServices.instance.netease;
      final json = await client.postApi(
        '${NeteaseClient.apiBase}/v6/playlist/detail',
        {'id': id, 'n': '100000', 's': '0'},
      );
      final playlist = json['playlist'];
      if (playlist is! Map<String, dynamic>) return null;

      // 全量歌曲 id（trackIds 含全部；tracks 仅前 10 预览，作兜底）
      final trackIds = (playlist['trackIds'] ?? const []) as List<dynamic>;
      final ids = <int>[];
      for (final t in trackIds) {
        if (t is Map && t['id'] is num) ids.add((t['id'] as num).toInt());
      }

      final List<Song> songs;
      if (ids.isEmpty) {
        // 极少数歌单不回 trackIds，退化到预览 tracks（旧行为兜底）
        songs = [
          for (final t in (playlist['tracks'] ?? const []) as List<dynamic>)
            if (t is Map<String, dynamic>) client.api.toSong(t)
        ].whereType<Song>().toList();
      } else {
        // 分批补详情（v3 song/detail，每批 100），按 id 顺序还原
        final fetched = <Song>[];
        for (var i = 0; i < ids.length; i += 100) {
          final end = (i + 100).clamp(0, ids.length);
          fetched.addAll(await client.api.songDetailSongs(ids.sublist(i, end)));
        }
        songs = mergeNeteaseTracks(ids, fetched);
      }

      final creator = playlist['creator'];
      return PlaylistDetail(
        id: id,
        name: (playlist['name'] ?? '').toString(),
        cover: _https((playlist['coverImgUrl'] ?? '').toString()),
        creator: creator is Map ? (creator['nickname'] ?? '').toString() : '',
        desc: (playlist['description'] ?? '').toString(),
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

  /// 纯逻辑：把全量 id 与分批拿到的 [Song] 合并成有序列表（便于单测）。
  ///
  /// [ids] 为歌单真实顺序（来自 v6 的 trackIds），[fetched] 为各批次
  /// song/detail 返回的并集（顺序/缺失不定）。按 [ids] 顺序还原，缺失的
  /// id（网易云下架/无版权曲目不返回详情）直接跳过。
  static List<Song> mergeNeteaseTracks(List<int> ids, List<Song> fetched) {
    final byId = <int, Song>{};
    for (final s in fetched) {
      byId[s.songId] = s;
    }
    return [for (final id in ids) byId[id]].whereType<Song>().toList();
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
        .whereType<Map>()
        .map((e) {
          final j = Map<String, dynamic>.from(e);
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
    // 必须走 NeteaseClient（自动带登录 Cookie）——之前裸请求不带
    // MUSIC_U，登录用户的歌单要么被当未登录、要么拉到匿名视角的
    // 公开数据，「我的歌单」页表现为永远空白（v2.4.2-pre2 修复）。
    final client = AppServices.instance.netease;
    if (!client.isLoggedIn()) return const [];
    var uid = client.userId;
    if (uid == 0) {
      // 早期 Cookie 登录（粘贴 / 旧版扫码）没落 userId——从账号信息
      // 接口解析一次并缓存，之后「我的歌单」才能按 uid 查询。
      uid = await _resolveNeteaseUid(client);
      if (uid != 0) client.userId = uid;
    }
    if (uid == 0) return const [];
    final data = await client.postApi(
      'https://music.163.com/api/user/playlist',
      {'uid': '$uid', 'limit': '100', 'offset': '0'},
    );
    if (data['code'] != 200) {
      AppLog.w('PlaylistApi', '网易云我的歌单 code=${data['code']}');
      return const [];
    }
    final list = (data['playlist'] ?? const []) as List<dynamic>;
    return list
        .whereType<Map>()
        .map((e) => HotPlaylist.fromNetease(Map<String, dynamic>.from(e)))
        .where((p) => p.id.isNotEmpty)
        .toList();
  }

  /// 从账号信息接口解析当前登录 uid（无 profile 说明 Cookie 已失效）。
  static Future<int> _resolveNeteaseUid(NeteaseClient client) async {
    try {
      final acct = await client.postApi(
        'https://music.163.com/api/nuser/account/get',
        <String, String>{},
      );
      final profile = acct['profile'];
      if (profile is Map<String, dynamic>) {
        final uid = (profile['userId'] as num?)?.toInt() ?? 0;
        if (uid != 0) {
          AppLog.i('PlaylistApi', '网易云 uid 已补齐: $uid');
        }
        return uid;
      }
    } catch (e) {
      AppLog.w('PlaylistApi', '网易云 uid 解析失败: $e');
    }
    return 0;
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
        if (e is! Map) continue;
        final j = Map<String, dynamic>.from(e);
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
