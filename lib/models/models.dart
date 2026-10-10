/// 通用数据模型：音质枚举、歌曲、登录凭证。
///
/// 与 Android 原生工程 `network/Model.kt`、`data/Credential.kt` 1:1 对应，
/// 保证六端共享同一套 JSON 结构与字段命名。
library;

import 'dart:convert';

// ==================== 音源标识 ====================

/// 音源常量（与 [Song.source] 约定一致）。
class Source {
  static const String qq = 'qq';
  static const String netease = 'netease';

  /// 本地文件（扫描本机磁盘得到，不走任何网络接口）。
  static const String local = 'local';
}

// ==================== QQ 音质枚举 ====================

/// QQ 音乐音质枚举（对应 `network/Model.kt` 的 Quality）。
class Quality {
  final String code;
  final String ext;
  final String label;
  final int bitrate;

  const Quality(this.code, this.ext, this.label, this.bitrate);

  static const dtsX = Quality('DT03', '.mp4', 'DTS:X', 0);
  static const atmosDb = Quality('D004', '.mp4', '杜比全景声', 0);
  static const atmos71 = Quality('Q003', '.ogg', '臻品全景声 7.1', 0);
  static const atmos51 = Quality('Q001', '.flac', '臻品全景声 5.1', 0);
  static const atmos2 = Quality('Q000', '.flac', '臻品音质', 0);
  static const master = Quality('AI00', '.flac', '臻品母带', 0);
  static const flac = Quality('F000', '.flac', 'SQ 无损', 0);
  static const hires = Quality('RS01', '.flac', 'Hi-Res', 0);
  static const nac = Quality('TL01', '.nac', 'NAC 音质', 128);
  static const ogg640 = Quality('O801', '.ogg', 'OGG 640', 0);
  static const ogg320 = Quality('O800', '.ogg', 'OGG 320', 320);
  static const ogg192 = Quality('O600', '.ogg', 'OGG 192', 192);
  static const mp3_320 = Quality('M800', '.mp3', 'MP3 320', 320);
  static const mp3_128 = Quality('M500', '.mp3', 'MP3 128', 128);
  static const aac192 = Quality('C600', '.m4a', 'AAC 192', 192);
  static const aac96 = Quality('C400', '.m4a', 'AAC 96', 96);
  static const aac48 = Quality('C200', '.m4a', 'AAC 48', 48);

  /// 播放默认音质（128k）。
  static const playbackDefault = mp3_128;

  /// 下载可选音质（与 Kotlin DOWNLOAD_OPTIONS 顺序一致）。
  static const downloadOptions = [
    dtsX,
    atmosDb,
    atmos71,
    atmos51,
    atmos2,
    master,
    flac,
    hires,
    nac,
    ogg640,
    ogg320,
    ogg192,
    mp3_320,
    mp3_128,
    aac192,
    aac96,
    aac48,
  ];

  static const playbackOptions = downloadOptions;

  static Quality? fromCode(String? code) {
    if (code == null) return null;
    for (final q in downloadOptions) {
      if (q.code == code) return q;
    }
    return null;
  }

  /// 从播放链接的文件名前缀推断服务器实际提供音质。
  static Quality? fromUrlPrefix(String url) {
    final name = url.split('/').last.split('?').first;
    if (name.isEmpty) return null;
    final prefix4 = name.length >= 4 ? name.substring(0, 4) : name;
    for (final q in downloadOptions) {
      if (q.code == prefix4) return q;
    }
    for (final q in downloadOptions) {
      if (name.startsWith(q.code)) return q;
    }
    return null;
  }

  String filenameFor(String mid) => '$code$mid$mid$ext';

  String inferExt() => ext;

  @override
  String toString() => 'Quality($code,$label)';
}

// ==================== 网易云音质枚举 ====================

/// 网易云音质等级（对应 `network/netease/NeteaseQuality.kt`）。
class NeteaseQuality {
  final String level;
  final String label;
  final String ext;

  const NeteaseQuality(this.level, this.label, this.ext);

  static const dolby = NeteaseQuality('dolby', '杜比全景声', '.mp4');
  static const jymaster = NeteaseQuality('jymaster', '超清母带', '.flac');
  static const sky = NeteaseQuality('sky', '沉浸环绕声', '.flac');
  static const jyeffect = NeteaseQuality('jyeffect', '高清环绕声', '.flac');
  static const hires = NeteaseQuality('hires', 'Hi-Res', '.flac');
  static const lossless = NeteaseQuality('lossless', '无损 FLAC', '.flac');
  static const exhigh = NeteaseQuality('exhigh', '极高 320k', '.mp3');
  static const standard = NeteaseQuality('standard', '标准 128k', '.mp3');

  static const playbackDefault = exhigh;

  static const downloadOptions = [
    dolby,
    jymaster,
    sky,
    jyeffect,
    hires,
    lossless,
    exhigh,
    standard,
  ];

  static const playbackOptions = downloadOptions;

  static NeteaseQuality? fromLevel(String? level) {
    if (level == null) return null;
    for (final q in downloadOptions) {
      if (q.level == level) return q;
    }
    return null;
  }

  @override
  String toString() => 'NeteaseQuality($level,$label)';
}

// ==================== 歌曲 ====================

/// 用专辑 mid 拼 QQ 音乐专辑封面 URL。
///
/// 搜索接口（`DoSearchForQQMusicMobile` / `do_search_v2`）返回的 `album`
/// 只有 `{id, mid, name, pmid, subtitle, time_public, title}`，**不含 `picUrl`**，
/// 因此封面必须回退到按 `T002R{size}x{size}M000{albumMid}.jpg` 规则拼，
/// 与原生 `SongAdapter` 的 `song.cover.ifEmpty { albumMid -> photo_new }` 一致。
///
/// 默认取 **1500**（实测最大档）：`photo_new` 支持 150/300/500/800/1500，
/// 请求 2000 / 3000 会返回 404。降级由 [CoverUrl.candidates] + `CoverImage`
/// 在真实加载失败时逐级下探（800 → 500 → 300）。
String qqAlbumCoverUrl(String albumMid, {int size = 1500}) =>
    'https://y.qq.com/music/photo_new/T002R${size}x${size}M000$albumMid.jpg';

/// 歌曲信息（对应 `network/Model.kt` 的 Song）。
class Song {
  final String mid;
  final int songId;
  final String name;
  final String singer;
  final String album;
  final String albumMid;
  final int duration;
  final String cover;

  /// 音源：qq / netease / local。
  final String source;

  // ---- 本地音乐专用字段（网络歌曲为默认值） ----

  /// 本地文件的绝对路径。非空即代表这是本地歌曲，可据此直接播放。
  final String localPath;

  /// 文件字节数，与 [localMtime] 一起构成增量扫描指纹。
  final int localSize;

  /// 文件最后修改时间（毫秒），与 [localSize] 一起构成增量扫描指纹。
  final int localMtime;

  /// 容器格式：mp3 / flac / m4a / ogg / wav（仅本地歌曲有值）。
  final String format;

  const Song({
    required this.mid,
    required this.songId,
    required this.name,
    required this.singer,
    required this.album,
    required this.albumMid,
    required this.duration,
    required this.cover,
    this.source = Source.qq,
    this.localPath = '',
    this.localSize = 0,
    this.localMtime = 0,
    this.format = '',
  });

  bool get isNetease => source == Source.netease;

  /// 是否本地文件歌曲。判定依据是 [localPath]，比看 `source` 更可靠——
  /// 历史持久化数据可能缺 `source` 字段但仍有路径。
  bool get isLocal => localPath.isNotEmpty;

  /// 实际可展示的封面 URL。
  ///
  /// `cover` 为空时（QQ 搜索接口不返回 `picUrl`；或历史/播放列表等旧持久化数据）
  /// 回退用 `albumMid` 拼 QQ 专辑图，等价于原生 `SongAdapter` 的兜底逻辑。
  /// 网易云歌曲 `cover` 一般自带，不参与此兜底。
  ///
  /// 本地歌曲不走 QQ 专辑图兜底：它的 `cover` 来自文件内嵌封面（缓存后的
  /// 本地路径）或为空（此时 UI 显示占位图标）。
  String get coverUrl {
    if (isLocal) return cover;
    if (cover.isNotEmpty) return cover;
    if (!isNetease && albumMid.isNotEmpty) return qqAlbumCoverUrl(albumMid);
    return '';
  }

  /// 从 QQ 音乐搜索/详情接口的 track JSON 解析。
  factory Song.fromTrack(Map<String, dynamic> t) {
    final mid = t['mid'] as String? ?? '';
    final name = (t['name'] as String? ?? '').isNotEmpty
        ? t['name'] as String
        : (t['title'] as String? ?? '');
    final albumRaw = t['album'];
    final albumObj = albumRaw is Map<String, dynamic> ? albumRaw : null;
    final albumName = (albumRaw is String && albumRaw.isNotEmpty)
        ? albumRaw
        : (albumObj?['name'] as String? ?? '');
    final albumMid = albumObj?['mid'] as String? ?? '';

    String singer = '';
    final singerArr = t['singer'] as List<dynamic>?;
    if (singerArr != null) {
      singer = singerArr.map((e) {
        if (e is Map<String, dynamic>) {
          return (e['name'] as String? ?? '');
        } else if (e is String) {
          return e;
        }
        return '';
      }).where((s) => s.isNotEmpty).join(' / ');
    } else {
      singer = (t['singer'] as String? ?? '').isNotEmpty
          ? t['singer'] as String
          : (t['singerName'] as String? ?? '');
    }

    // 封面：优先 album.picUrl.s；搜索接口返回的 album 不含 picUrl，
    // 此时回退用 albumMid 拼 QQ 专辑图（见 qqAlbumCoverUrl）。
    final picUrlObj = albumObj?['picUrl'];
    var cover = '';
    if (picUrlObj is Map<String, dynamic>) {
      cover = picUrlObj['s'] as String? ?? '';
    } else if (picUrlObj is String) {
      cover = picUrlObj;
    }
    if (cover.isEmpty && albumMid.isNotEmpty) {
      cover = qqAlbumCoverUrl(albumMid);
    }
    final duration = ((t['interval'] as num?)?.toInt() ?? 0) * 1000;

    return Song(
      mid: mid,
      songId: (t['id'] as num?)?.toInt() ?? 0,
      name: name,
      singer: singer,
      album: albumName,
      albumMid: albumMid,
      duration: duration,
      cover: cover,
    );
  }

  /// 从 JSON Map 还原（用于本地持久化读取）。
  factory Song.fromJson(Map<String, dynamic> map) => Song(
        mid: map['mid'] as String? ?? '',
        songId: (map['songId'] as num?)?.toInt() ?? 0,
        name: map['name'] as String? ?? '',
        singer: map['singer'] as String? ?? '',
        album: map['album'] as String? ?? '',
        albumMid: map['albumMid'] as String? ?? '',
        duration: (map['duration'] as num?)?.toInt() ?? 0,
        cover: map['cover'] as String? ?? '',
        source: map['source'] as String? ?? Source.qq,
        localPath: map['localPath'] as String? ?? '',
        localSize: (map['localSize'] as num?)?.toInt() ?? 0,
        localMtime: (map['localMtime'] as num?)?.toInt() ?? 0,
        format: map['format'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'mid': mid,
        'songId': songId,
        'name': name,
        'singer': singer,
        'album': album,
        'albumMid': albumMid,
        'duration': duration,
        'cover': cover,
        'source': source,
        if (localPath.isNotEmpty) 'localPath': localPath,
        if (localPath.isNotEmpty) 'localSize': localSize,
        if (localPath.isNotEmpty) 'localMtime': localMtime,
        if (format.isNotEmpty) 'format': format,
      };

  /// 拷贝并覆盖部分字段（本地歌曲刷新元数据时用）。
  Song copyWith({
    String? mid,
    int? songId,
    String? name,
    String? singer,
    String? album,
    String? albumMid,
    int? duration,
    String? cover,
    String? source,
    String? localPath,
    int? localSize,
    int? localMtime,
    String? format,
  }) =>
      Song(
        mid: mid ?? this.mid,
        songId: songId ?? this.songId,
        name: name ?? this.name,
        singer: singer ?? this.singer,
        album: album ?? this.album,
        albumMid: albumMid ?? this.albumMid,
        duration: duration ?? this.duration,
        cover: cover ?? this.cover,
        source: source ?? this.source,
        localPath: localPath ?? this.localPath,
        localSize: localSize ?? this.localSize,
        localMtime: localMtime ?? this.localMtime,
        format: format ?? this.format,
      );

  @override
  String toString() => 'Song($source:$mid,$name)';
}

// ==================== 登录凭证 ====================

/// QQ 音乐登录凭证（对应 `data/Credential.kt`）。
class Credential {
  String openid;
  String refreshToken;
  String accessToken;
  int expiredAt;
  int musicid;
  String musickey;
  String unionid;
  String strMusicid;
  String refreshKey;
  int musickeyCreateTime;
  int keyExpiresIn;
  int firstLogin;
  int bindAccountType;
  int needRefreshKeyIn;
  String encryptUin;
  int loginType;

  Credential({
    this.openid = '',
    this.refreshToken = '',
    this.accessToken = '',
    this.expiredAt = 0,
    this.musicid = 0,
    this.musickey = '',
    this.unionid = '',
    this.strMusicid = '',
    this.refreshKey = '',
    this.musickeyCreateTime = 0,
    this.keyExpiresIn = 0,
    this.firstLogin = 0,
    this.bindAccountType = 0,
    this.needRefreshKeyIn = 0,
    this.encryptUin = '',
    this.loginType = 0,
  });

  bool isLoggedIn() => musicid != 0 && musickey.isNotEmpty;

  bool isExpired() {
    if (musickeyCreateTime == 0 || keyExpiresIn == 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= musickeyCreateTime + keyExpiresIn;
  }

  /// 仅序列化关键三字段（对应 Kotlin toJsonString）。
  String toJsonString() =>
      jsonEncode({'musicid': musicid, 'musickey': musickey, 'loginType': loginType});

  /// 字段别名表（兼容服务端/旧版本不同命名）。
  static const Map<String, String> alias = {
    'openid': 'openid',
    'refresh_token': 'refreshToken',
    'refreshToken': 'refreshToken',
    'access_token': 'accessToken',
    'accessToken': 'accessToken',
    'expired_at': 'expiredAt',
    'expiredAt': 'expiredAt',
    'musicid': 'musicid',
    'musickey': 'musickey',
    'unionid': 'unionid',
    'str_musicid': 'strMusicid',
    'strMusicid': 'strMusicid',
    'refresh_key': 'refreshKey',
    'refreshKey': 'refreshKey',
    'musickeycreatetime': 'musickeyCreateTime',
    'musickeyCreateTime': 'musickeyCreateTime',
    'key_expires_in': 'keyExpiresIn',
    'keyExpiresIn': 'keyExpiresIn',
    'first_login': 'firstLogin',
    'firstLogin': 'firstLogin',
    'bind_account_type': 'bindAccountType',
    'bindAccountType': 'bindAccountType',
    'need_refresh_key_in': 'needRefreshKeyIn',
    'needRefreshKeyIn': 'needRefreshKeyIn',
    'encrypt_uin': 'encryptUin',
    'encryptUin': 'encryptUin',
    'login_type': 'loginType',
    'loginType': 'loginType',
  };

  /// 从 JSON Map 还原，自动应用别名映射与类型转换。
  factory Credential.fromDict(Map<String, dynamic> data) {
    final c = Credential();
    data.forEach((k, v) {
      final target = alias[k] ?? k;
      switch (target) {
        case 'openid':
          if (v is String) c.openid = v;
        case 'refreshToken':
          if (v is String) c.refreshToken = v;
        case 'accessToken':
          if (v is String) c.accessToken = v;
        case 'expiredAt':
          c.expiredAt = _toInt(v);
        case 'musicid':
          c.musicid = _toInt(v);
        case 'musickey':
          if (v is String) c.musickey = v;
        case 'unionid':
          if (v is String) c.unionid = v;
        case 'strMusicid':
          if (v is String) c.strMusicid = v;
        case 'refreshKey':
          if (v is String) c.refreshKey = v;
        case 'musickeyCreateTime':
          c.musickeyCreateTime = _toInt(v);
        case 'keyExpiresIn':
          c.keyExpiresIn = _toInt(v);
        case 'firstLogin':
          c.firstLogin = _toInt(v);
        case 'bindAccountType':
          c.bindAccountType = _toInt(v);
        case 'needRefreshKeyIn':
          c.needRefreshKeyIn = _toInt(v);
        case 'encryptUin':
          if (v is String) c.encryptUin = v;
        case 'loginType':
          c.loginType = _toInt(v);
      }
    });
    // 若仅有 musickey 无 loginType，按前缀推断（W_X 为微信登录）
    if (!data.containsKey('login_type') &&
        !data.containsKey('loginType') &&
        c.musickey.isNotEmpty) {
      c.loginType = c.musickey.startsWith('W_X') ? 1 : 2;
    }
    return c;
  }

  static int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}