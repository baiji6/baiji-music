// 三平台 —— 分享歌单链接解析（提取歌单 id → 拉取曲目列表）
//   QQ音乐   : 链接 /playlist/{disstid}    详情 fcg_v8_playlist_cp.fcg
//   网易云   : 链接 /playlist?id={id}       详情 api/playlist/detail
//   酷我音乐 : 链接 /playlist_detail/{pid}  详情 nplserver pl.svc (op=getlistinfo)
library;


import 'hot_search_api.dart';

String _joinArtists(List<dynamic>? arr) =>
    (arr ?? []).map((a) => a is Map ? (a['name'] ?? '') : a).join('/');

/// 解析出的歌单曲目。
class PlaylistTrack {
  final String name;
  final String artist;
  final String album;
  final int durationSeconds;
  final String rid;

  const PlaylistTrack({
    required this.name,
    required this.artist,
    required this.album,
    required this.durationSeconds,
    required this.rid,
  });
}

/// 分享歌单解析结果。
class SharedPlaylist {
  final String source;
  final String id;
  final String name;
  final String creator;
  final String cover;
  final int trackCount;
  final List<PlaylistTrack> tracks;

  const SharedPlaylist({
    required this.source,
    required this.id,
    required this.name,
    required this.creator,
    required this.cover,
    required this.trackCount,
    required this.tracks,
  });
}

// ───────────────────────────── QQ音乐 ─────────────────────────────
class QqPlaylist {
  static const Map<String, String> headers = {
    'Referer': 'https://y.qq.com/',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
  };

  /// 从分享链接/文本提取歌单 disstid
  static String? parseId(String input) {
    final s = input.trim();
    final url = RegExp(r'https?://[^\s]+').firstMatch(s)?.group(0) ?? s;
    for (final re in [
      RegExp(r'disstid=(\d+)'),
      RegExp(r'/playlist/(\d+)'),
      RegExp(r'[?&]id=(\d+)'),
    ]) {
      final m = re.firstMatch(url);
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// 拉取歌单详情
  ///
  /// 说明: `fcg_v8_playlist_cp.fcg` 的 `songlist` 字段本身就是**全量**
  /// （实测 2710 首的歌单返回 2163~2710 条全量），`songids` 也是全量逗号串。
  /// 历史上的「只解析出 1000 首」是因为本方法对 `songlist` 做了 `.take(limit)`，
  /// 而默认 limit=1000。现在 limit 默认为 0（不限制）。
  static Future<SharedPlaylist> detail(String disstid,
      {int limit = 0}) async {
    final url = Uri.parse('https://c.y.qq.com/v8/fcg-bin/fcg_v8_playlist_cp.fcg')
        .replace(queryParameters: {
      'type': '1',
      'id': disstid,
      'utf8': '1',
      'format': 'json',
    }).toString();
    final data = await getJsonWithRetry(url, headers: headers);
    final cdlist = (data['data']?['cdlist'] ?? const []) as List<dynamic>;
    final cd = cdlist.isEmpty
        ? null
        : Map<String, dynamic>.from(cdlist.first as Map);
    if (cd == null) throw Exception('歌单不存在: $disstid');

    final rawList = (cd['songlist'] as List<dynamic>? ?? const []);
    final songs = (limit > 0 ? rawList.take(limit) : rawList).map((e) {
      final song = Map<String, dynamic>.from(e as Map);
      return PlaylistTrack(
        name: (song['songname'] ?? '').toString(),
        artist: _joinArtists(song['singer'] as List<dynamic>?),
        album: (song['albumname'] ?? '').toString(),
        durationSeconds: (song['interval'] as num?)?.toInt() ?? 0,
        rid: (song['songmid'] ?? '').toString(),
      );
    }).toList();
    return SharedPlaylist(
      source: 'qq',
      id: disstid,
      name: (cd['dissname'] ?? '').toString(),
      creator: (cd['nickname'] ?? cd['nick'] ?? '').toString(),
      cover: (cd['logo'] ?? cd['headurl'] ?? '').toString(),
      trackCount: songs.length,
      tracks: songs,
    );
  }

  static Future<SharedPlaylist> parse(String input, {int limit = 0}) async {
    final id = parseId(input);
    if (id == null) throw ArgumentError('无法从输入解析出 QQ 歌单 id');
    return detail(id, limit: limit);
  }
}

// ───────────────────────────── 网易云音乐 ─────────────────────────────
class NeteasePlaylist {
  static const Map<String, String> headers = {
    'Referer': 'https://music.163.com/',
    'User-Agent': 'Mozilla/5.0',
  };

  /// 从分享链接/文本提取歌单 id
  static String? parseId(String input) {
    final s = input.trim();
    final url = RegExp(r'https?://[^\s]+').firstMatch(s)?.group(0) ?? s;
    for (final re in [
      RegExp(r'/playlist/(\d+)'),
      RegExp(r'[?&]id=(\d+)'),
    ]) {
      final m = re.firstMatch(url);
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// 拉取歌单详情
  ///
  /// 关键坑: `api/playlist/detail` 返回的 `tracks` 字段**只有 10 条**，
  /// 而歌单真实曲目在 `api/v6/playlist/detail` 的 `trackIds` 里（全量，实测 1996 条）。
  /// 因此这里改为：v6 拿 trackIds → 分批调 `api/v3/song/detail` 补全曲目信息。
  ///
  /// `api/v3/song/detail` 的批量上限实测为 100（200 会返回 0 条），
  /// 需要同时传 `ids`（逗号串）与 `c`（`[{"id":..,"br":128000}]`）。
  static Future<SharedPlaylist> detail(String id, {int limit = 0}) async {
    final metaUrl = Uri.parse('https://music.163.com/api/v6/playlist/detail')
        .replace(queryParameters: {'id': id}).toString();
    final meta = await getJsonWithRetry(metaUrl, headers: headers);
    final pl = (meta['playlist'] ?? meta['result']) as Map<String, dynamic>?;
    if (pl == null) throw Exception('歌单不存在: $id');

    // 全量曲目 id
    final trackIds = (pl['trackIds'] as List<dynamic>? ?? const [])
        .map((e) => (e is Map ? e['id'] : e).toString())
        .where((s) => s.isNotEmpty)
        .toList();
    final ids = limit > 0 && limit < trackIds.length
        ? trackIds.sublist(0, limit)
        : trackIds;

    // 分批补全歌曲详情
    const batchSize = 100;
    final songs = <PlaylistTrack>[];
    for (var i = 0; i < ids.length; i += batchSize) {
      final chunk = ids.sublist(
          i, (i + batchSize).clamp(0, ids.length));
      final detail = await _songDetails(chunk);
      songs.addAll(detail);
    }

    return SharedPlaylist(
      source: 'netease',
      id: id,
      name: (pl['name'] ?? '').toString(),
      creator: (pl['creator']?['nickname'] ?? '').toString(),
      cover: (pl['coverImgUrl'] ?? '').toString(),
      trackCount: songs.length,
      tracks: songs,
    );
  }

  /// 批量拉取歌曲详情（每批 ≤100 首）
  static Future<List<PlaylistTrack>> _songDetails(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final c = '[${ids.map((i) => '{"id":$i,"br":128000}').join(',')}]';
    final url = Uri.parse('https://music.163.com/api/v3/song/detail')
        .replace(queryParameters: {'ids': ids.join(','), 'c': c})
        .toString();
    final data = await getJsonWithRetry(url, headers: headers);
    final raw = (data['songs'] as List<dynamic>? ?? const []);
    return raw.map((e) {
      final song = Map<String, dynamic>.from(e as Map);
      return PlaylistTrack(
        name: (song['name'] ?? '').toString(),
        artist: _joinArtists(song['ar'] as List<dynamic>?),
        album: (song['al']?['name'] ?? '').toString(),
        durationSeconds: ((song['dt'] ?? 0) as num).toInt() ~/ 1000,
        rid: (song['id'] ?? '').toString(),
      );
    }).toList();
  }

  static Future<SharedPlaylist> parse(String input, {int limit = 0}) async {
    final id = parseId(input);
    if (id == null) throw ArgumentError('无法从输入解析出网易云歌单 id');
    return detail(id, limit: limit);
  }
}

// ───────────────────────────── 酷我音乐 ─────────────────────────────
class KuwoPlaylist {
  static const Map<String, String> headers = {'User-Agent': 'Mozilla/5.0'};

  /// 从分享链接/文本提取歌单 pid
  static String? parseId(String input) {
    final s = input.trim();
    final url = RegExp(r'https?://[^\s]+').firstMatch(s)?.group(0) ?? s;
    final m = RegExp(r'/playlist(?:_detail)?/(\d+)').firstMatch(url) ??
        RegExp(r'[?&]pid=(\d+)').firstMatch(url);
    return m?.group(1);
  }

  /// 拉取歌单详情
  ///
  /// 关键坑: `rn` 参数单次最多返回 1000 条，超过 1000 的歌单必须**分页**
  /// （`pn` 递增）。实测 1790 首的歌单用 `rn=2000` 可一次拿全，
  /// 但 2710 首的歌单会被截断，所以这里按 1000/页循环拉取。
  static Future<SharedPlaylist> detail(String pid, {int limit = 0}) async {
    const pageSize = 1000;
    final tracks = <PlaylistTrack>[];
    var total = 0;
    String name = '';
    String creator = '';
    String cover = '';

    for (var pn = 0; ; pn++) {
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
      final data = await getJsonWithRetry(url, headers: headers);
      if (pn == 0) {
        total = (data['total'] as num?)?.toInt() ?? 0;
        name = (data['name'] ?? data['listname'] ?? data['title'] ??
                data['list_title'] ?? '')
            .toString();
        creator = (data['uname'] ?? '').toString();
        cover = (data['img'] ?? '').toString();
      }
      final raw = (data['musiclist'] as List<dynamic>? ?? const []);
      if (raw.isEmpty) break;
      for (final e in raw) {
        final song = Map<String, dynamic>.from(e as Map);
        tracks.add(PlaylistTrack(
          name: (song['name'] ?? '').toString(),
          artist: (song['artist'] ?? '').toString(),
          album: (song['album'] ?? '').toString(),
          durationSeconds:
              int.tryParse((song['duration'] ?? '0').toString()) ?? 0,
          rid: (song['id'] ?? '').toString(),
        ));
      }
      // 已取满总量或达到 limit 即停止
      if (total > 0 && tracks.length >= total) break;
      if (limit > 0 && tracks.length >= limit) break;
      if (raw.length < pageSize) break;
    }

    final songs = limit > 0 && tracks.length > limit
        ? tracks.sublist(0, limit)
        : tracks;
    return SharedPlaylist(
      source: 'kuwo',
      id: pid,
      name: name,
      creator: creator,
      cover: cover,
      trackCount: songs.length,
      tracks: songs,
    );
  }

  static Future<SharedPlaylist> parse(String input, {int limit = 0}) async {
    final id = parseId(input);
    if (id == null) throw ArgumentError('无法从输入解析出酷我歌单 id');
    return detail(id, limit: limit);
  }
}

// ───────────────────────────── 统一入口 ─────────────────────────────
class SharePlaylist {
  /// 自动识别平台并解析分享歌单
  ///
  /// [limit] 为 0 时不限制（拉取全部曲目）。
  static Future<SharedPlaylist> parse(String input, {int limit = 0}) async {
    final s = input.trim();
    if (s.contains('qq.com')) {
      return QqPlaylist.parse(s, limit: limit);
    }
    if (s.contains('music.163.com') || s.contains('163cn.tv')) {
      return NeteasePlaylist.parse(s, limit: limit);
    }
    if (s.contains('kuwo.cn') || s.contains('kw.cn')) {
      return KuwoPlaylist.parse(s, limit: limit);
    }
    // 无域名线索: 依次尝试
    try {
      return await QqPlaylist.parse(s, limit: limit);
    } catch (_) {}
    try {
      return await NeteasePlaylist.parse(s, limit: limit);
    } catch (_) {}
    try {
      return await KuwoPlaylist.parse(s, limit: limit);
    } catch (_) {}
    throw ArgumentError('无法识别的歌单链接: $input');
  }
}
