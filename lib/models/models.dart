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

  /// 酷我音乐（v2.4.0 新增平台）。
  static const String kuwo = 'kuwo';

  /// 本地文件（扫描本机磁盘得到，不走任何网络接口）。
  static const String local = 'local';
}

/// 酷我音质枚举（v2.4.0 新增平台）。
///
/// 酷我的音质用 `br` 串标识（`{bitrate}k{format}`），与 QQ/网易云的
/// 「档位」概念一致但参数不同，因此单列一套枚举。
class KuwoQuality {
  /// 音质 id（与酷我接口的 N_MINFO 一致，如 `master` / `flac` / `320k`）。
  final String id;

  /// 展示名。
  final String label;

  /// 容器格式（flac / mflac / mp3 / ogg / aac）。
  final String format;

  /// 比特率（kbps）。
  final int bitrate;

  /// 落盘扩展名。
  final String ext;

  const KuwoQuality(this.id, this.label, this.format, this.bitrate, this.ext);

  /// 酷我接口的 `br` 参数。
  String get br => '${bitrate}k$format';

  // ==================== 全部音质（v2.4.0-fix2 补齐）====================
  //
  // 与 `network/kuwo/kuwo_link.dart` 的 `KuwoLink.qualityRules` 一一对应，
  // 顺序即音质从高到低。id 与酷我接口 `N_MINFO` 里的 `level` 字段一致，
  // 会被持久化（`DownloadManager.kuwoQuality` /
  // `PlayerController.currentKuwoQuality`），因此 **id 不可随意变更**。
  //
  // v2.4.0 只有 7 档，用户反馈「音质不全」（接口实际支持 18 档），
  // 这里按接口真实档位补齐；旧版本用过的 id（master / hires / flac /
  // '300k' / '320k' / '128k' / '48k'）全部保留，无需迁移。

  static const atmos714 =
      KuwoQuality('atmos_714', '全景声 7.1.4', 'mgg', 24000, '.flac');
  static const vinyl =
      KuwoQuality('vinyl', '黑胶音质', 'flac', 23000, '.flac');
  static const bcms =
      KuwoQuality('bcms', '臻品音质 BCMS', 'mgg', 22000, '.flac');
  static const master =
      KuwoQuality('master', '臻品母带', 'mflac', 20900, '.flac');
  static const atmosPlus =
      KuwoQuality('atmos_plus', '全景声 5.1', 'mflac', 20501, '.flac');
  static const atmos =
      KuwoQuality('atmos', '全景声 2.0', 'mflac', 20201, '.flac');
  static const dolbyEac3 =
      KuwoQuality('dolby_dd7', '杜比全景声 E-AC-3', 'mp4', 11700, '.mp4');
  static const dolby640 =
      KuwoQuality('dolby_640', '杜比全景声 640', 'mp4', 11600, '.mp4');
  static const dolby448 =
      KuwoQuality('dolby_448', '杜比全景声 448', 'mp4', 11500, '.mp4');
  static const dolbyAc4 =
      KuwoQuality('dolby_ac4', '杜比全景声 AC-4', 'mp4', 11000, '.mp4');
  static const hires =
      KuwoQuality('hires', 'Hi-Res 无损', 'flac', 4000, '.flac');
  static const flac =
      KuwoQuality('flac', '无损 FLAC', 'flac', 2000, '.flac');
  static const mp3_320 =
      KuwoQuality('320k', '极高 320k', 'mp3', 320, '.mp3');
  static const ogg =
      KuwoQuality('300k', '极高 OGG 300k', 'ogg', 300, '.ogg');
  static const ogg192 =
      KuwoQuality('192k', '高品质 OGG 192k', 'ogg', 192, '.ogg');
  static const mp3_128 =
      KuwoQuality('128k', '标准 128k', 'mp3', 128, '.mp3');
  static const ogg100 =
      KuwoQuality('100k', '高清 OGG 100k', 'ogg', 100, '.ogg');
  static const aac =
      KuwoQuality('48k', '省流 AAC', 'aac', 48, '.aac');

  /// 可选音质（高 → 低），与 `KuwoLink.qualityRules` 同序同量。
  static const downloadOptions = [
    atmos714,
    vinyl,
    bcms,
    master,
    atmosPlus,
    atmos,
    dolbyEac3,
    dolby640,
    dolby448,
    dolbyAc4,
    hires,
    flac,
    mp3_320,
    ogg,
    ogg192,
    mp3_128,
    ogg100,
    aac,
  ];

  /// 播放默认：未登录时高档位普遍不可用，128k 最稳。
  static const playbackDefault = mp3_128;

  static const playbackOptions = downloadOptions;

  static KuwoQuality? fromId(String? id) {
    if (id == null) return null;
    for (final q in downloadOptions) {
      if (q.id == id) return q;
    }
    return null;
  }

  @override
  String toString() => 'KuwoQuality($id,$label)';
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
  static const atmosEac3Plus = Quality('D003', '.mp4', '杜比全景声 815k', 0);
  static const atmosEac3 = Quality('D002', '.mp4', '杜比全景声 680k', 0);
  static const atmosEac3Lite = Quality('D001', '.mp4', '杜比全景声 475k', 0);
  static const atmosDb = Quality('D004', '.mp4', '杜比全景声 AC-4', 0);
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
  ///
  /// v2.4.2 补齐 QQ 杜比全景声系列的 E-AC-3 档（D001~D003）：
  /// 官方「杜比全景声」默认给 AC-4（D004，本机无解码器，见
  /// [undecodableCodes]），但同系列 D001~D003 是 E-AC-3(JOC)
  /// （≈475k/680k/815k），media_kit 的 ffmpeg 有 eac3 解码器，
  /// 选它们才能在本机真正听到杜比全景声。
  static const downloadOptions = [
    dtsX,
    atmosEac3Plus,
    atmosEac3,
    atmosEac3Lite,
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

  /// 本机播放器**无法解码**的音质 code（v2.4.2）。
  ///
  /// 播放走 media_kit（libmpv + 预编译 ffmpeg）。其 ffmpeg 以白名单方式
  /// 构建（见 media-kit/libmpv-android-audio-build 的 ffmpeg.sh）：
  /// ac3 / eac3 / dca / truehd 有，**ac4 没有**——上游 FFmpeg 至今没有
  /// 原生 AC-4 解码器（Jellyfin 靠自编译补丁才支持，见
  /// jellyfin/jellyfin-ffmpeg#387）。
  ///
  /// QQ 音乐「杜比全景声」D004 实测为 AC-4/mp4（沙箱 ffprobe 验证），
  /// 选中必然解码失败；同站「臻品全景声」Q003/Q001 是 ogg/flac 多声道，
  /// 可正常播放。命中这里的档位时取流层直接跳过并沿降级链下探
  /// （见 [MusicApi.qqDowngradeChain] / [PlayerController] 的解码重试），
  /// 用户无感切换到最近的可用档。
  ///
  /// 后续若换成带 AC-4 补丁的自编译 libmpv，把 code 从集合里删掉即可恢复。
  /// v2.4.2-pre4：改为可变集合——PlayerController 启动时会探测 mpv 的
  /// decoder-list，库里真有 ac4 解码器就 clear（此前硬编码导致换了
  /// 自编译库后杜比全景声仍被自动降级，永远放不出来）。
  static Set<String> undecodableCodes = {'D004'};

  /// QQ 音乐杜比全景声档位别名（v2.4.2）：官方客户端实际请求的是
  /// D005~D008，与 D001~D004 是**同一批文件**（D001=D005、D002=D006、
  /// D003=D007、D004=D008），其中 D001~D003 是 E-AC-3(JOC) 可解码，
  /// D004/D008 是 AC-4 不可解码。取流返回的 URL 前缀可能是任一写法，
  /// 这里统一归一到 D001~D004。
  static const Map<String, String> dolbyAlias = {
    'D005': 'D001',
    'D006': 'D002',
    'D007': 'D003',
    'D008': 'D004',
  };

  /// 从播放链接的文件名前缀推断服务器实际提供音质。
  static Quality? fromUrlPrefix(String url) {
    final name = url.split('/').last.split('?').first;
    if (name.isEmpty) return null;
    var code4 = name.length >= 4 ? name.substring(0, 4) : name;
    // 杜比别名归一（D005~D008 → D001~D004）
    code4 = dolbyAlias[code4] ?? code4;
    for (final q in downloadOptions) {
      if (q.code == code4) return q;
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

  /// 臻音全景声（AVS3-P3 / Audio Vivid，level=vivid，MP4 封装的 av3a 流）。
  ///
  /// 网易云接口在请求杜比全景声（dolby）时，若歌曲没有杜比内容会自动
  /// 返回臻音全景声（level=vivid / type=av3a）；实测直接请求 level=vivid
  /// 同样有效。解码由 ffmpeg 的 av3a 解码器（AVS3 参考软件集成）承担。
  static const vivid = NeteaseQuality('vivid', '臻音全景声', '.mp4');
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
    vivid,
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

  /// 是否酷我歌曲（v2.4.0）。
  bool get isKuwo => source == Source.kuwo;

  /// 平台短名（列表角标用）：网易云 / 酷我 / QQ / 本地。
  ///
  /// v2.4.0-fix2 之前各页面都写成 `isNetease ? '网易云' : 'QQ'`，
  /// 酷我歌曲会显示成「QQ」。统一走这个 getter。
  String get sourceShort {
    if (isLocal) return '本地';
    if (isKuwo) return '酷我';
    if (isNetease) return '网易云';
    return 'QQ';
  }

  /// 平台全名（弹层标题用）：网易云音乐 / 酷我音乐 / QQ 音乐。
  String get sourceFull {
    if (isLocal) return '本地音乐';
    if (isKuwo) return '酷我音乐';
    if (isNetease) return '网易云音乐';
    return 'QQ 音乐';
  }

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

// ==================== 歌曲评论 ====================

/// 一条评论（QQ / 网易云统一结构）。
///
/// 两个平台的原始字段差异很大（QQ 音乐用 `CmId/Nick/PubTime` 秒级时间戳，
/// 网易云用 `commentId/nickname/time` 毫秒时间戳），统一到本模型后 UI 层
/// 不需要关心来源，解析逻辑分别在 `qq_comment_api.dart` 与
/// `netease_comment_api.dart` 的纯函数里，可用真实抓包样本单测。
class Comment {
  const Comment({
    required this.id,
    required this.nickname,
    required this.avatarUrl,
    required this.content,
    required this.timeMs,
    this.likeCount = 0,
    this.liked = false,
    this.replyCount = 0,
    this.isHot = false,
    this.replies = const [],
  });

  /// 评论 ID（QQ 的 CmId 形如 `1!xxxx`，网易云是数字字符串）。
  final String id;

  final String nickname;
  final String avatarUrl;
  final String content;

  /// 发布时间（统一毫秒；QQ 服务端给的是秒，解析时已 ×1000）。
  final int timeMs;

  final int likeCount;

  /// 当前账号是否已点赞（未登录时恒为 false）。
  final bool liked;

  /// 回复条数（[replies] 可能只带回部分，展示用 replyCount）。
  final int replyCount;

  final bool isHot;

  /// 子评论（QQ 的 SubComments / 网易云的 beReplied，可能为空）。
  final List<Comment> replies;

  bool get hasReplies => replies.isNotEmpty;
}

/// 一页评论：热评 + 最新（网易云把置顶放在 topComments，并入 hot）。
class CommentPage {
  const CommentPage({
    this.hot = const [],
    this.latest = const [],
    this.total = 0,
    this.hasMore = false,
  });

  final List<Comment> hot;
  final List<Comment> latest;
  final int total;

  /// 是否还有更多最新评论（翻页用）。
  final bool hasMore;

  bool get isEmpty => hot.isEmpty && latest.isEmpty;
}
