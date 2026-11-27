import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/kuwo/kuwo_api.dart';
import 'package:baiji_music/network/kugou/kugou_api.dart';
import 'package:baiji_music/network/kugou/kugou_auth.dart';
import 'package:baiji_music/network/migu/migu_api.dart';
import 'package:baiji_music/network/joox/joox_api.dart';
import 'package:baiji_music/network/qishui/qishui_api.dart';
import 'package:baiji_music/network/qishui/qishui_relay.dart';
import 'package:baiji_music/network/qq2/qq2_api.dart';
import 'package:baiji_music/network/thirdparty/thirdparty_stream_api.dart';
import 'package:baiji_music/core/third_party_source.dart';
import '../decrypt/qmc.dart';
import '../lyrics/lyric_model.dart';
import '../decrypt/qmc_ekey.dart';
import 'kuwo/qmc_stream.dart';
import 'package:baiji_music/network/kuwo/kuwo_auth.dart';
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

  bool isLoggedIn(String source) {
    if (source == Source.kuwo) return KuwoAuth.isLoggedIn;
    if (source == Source.kugou) return KugouAuth.isLoggedIn;
    // 咪咕走匿名取流，无账号体系（v2.6.0）。
    if (source == Source.migu) return false;
    // JOOX 走匿名取流（molan 网关 key 内置），无账号体系（v2.6.0）。
    if (source == Source.joox) return false;
    // 汽水走匿名取流（molan 网关 key 内置），无账号体系（v2.6.1）。
    if (source == Source.qishui) return false;
    // QQ 音乐 2 走用户自填的 API Key，无账号体系（v2.6.5）。
    if (source == Source.qq2) return false;
    return source == Source.netease ? netease.isLoggedIn() : qq.isLoggedIn();
  }
}

/// 取流结果：直链 + 服务端**实际**提供的音质。
///
/// 播放器据此在 UI 上提示"已降级"，下载器据此决定落盘扩展名
/// （避免"请求 FLAC 实际拿到 MP3"却存成 `.flac`）。
class PlayUrlResult {
  final String url;

  /// QQ 实际音质（QQ 歌曲才有，网易云为 null）。
  final Quality? qq;

  /// 网易云实际音质（网易云歌曲才有，QQ 为 null）。
  final NeteaseQuality? ne;

  /// 酷我实际音质（酷我歌曲才有，其余为 null）。
  final KuwoQuality? kuwo;

  /// 酷狗实际音质（酷狗歌曲才有，其余为 null）。
  final KugouQuality? kugou;

  /// 咪咕实际音质（咪咕歌曲才有，v2.6.0）。
  final MiguQuality? migu;

  /// JOOX 实际音质（JOOX 歌曲才有，v2.6.0）。
  final JooxQuality? joox;

  /// 汽水实际音质（汽水歌曲才有，v2.6.1，仅 medium 单档）。
  final QishuiQuality? qishui;

  /// 覆盖扩展名（网易云响应里的真实 `type`）；为空时按音质枚举推断。
  final String? _extOverride;

  /// 覆盖展示名（第三方音源 v2.6.7：无平台枚举时用规范音质串的展示名）。
  final String? _labelOverride;

  /// QMCv2 ekey（QQ 加密档位才有；url 已是本地解密中继地址）。
  final String ekey;

  const PlayUrlResult._(this.url, this.qq, this.ne,
      [this._extOverride,
      this.kuwo,
      this.ekey = '',
      this.kugou,
      this.migu,
      this.joox,
      this.qishui,
      this._labelOverride]);

  /// 第三方聚合音源结果（v2.6.7）：明文直链，扩展名 / 展示名由调用方按
  /// 规范音质串传入（无对应平台的 Quality 枚举）。
  factory PlayUrlResult.thirdParty(String url,
          {required String ext, required String label}) =>
      PlayUrlResult._(url, null, null, ext, null, '', null, null, null, null,
          label);

  static const empty = PlayUrlResult._('', null, null);

  bool get isEmpty => url.isEmpty;
  bool get isNotEmpty => url.isNotEmpty;

  /// 落盘扩展名。
  String get ext => _extOverride ??
      kuwo?.ext ??
      kugou?.ext ??
      migu?.ext ??
      joox?.ext ??
      qishui?.ext ??
      ne?.ext ??
      qq?.ext ??
      '.mp3';

  /// 音质标签；无则空串。
  String get label => _labelOverride ??
      kuwo?.label ??
      migu?.label ??
      joox?.label ??
      qishui?.label ??
      qq?.label ??
      ne?.label ??
      '';

  @override
  String toString() => 'PlayUrlResult($label)';
}

/// 音源路由：按来源分发到 QQ 音乐或网易云的实现。
///
/// 对应原生 `network/MusicApi.kt`。
class MusicApi {
  MusicApi._();

  /// QQ 加密直链的流式解密中继（与酷我各一个实例，端口互不干扰）。
  static QmcRelayServer? _qqRelay;
  static Future<QmcRelayServer> _ensureQqRelay() async {
    final r = _qqRelay;
    if (r != null) return r;
    final server = QmcRelayServer();
    await server.start();
    return _qqRelay = server;
  }

  /// 汽水 CENC 加密档的本地解密中继（v2.6.2，全音质）。
  /// 单例常驻；真正的 bind 由 [QishuiCencRelayServer.serve] 幂等完成。
  static QishuiCencRelayServer get _qishuiRelay => QishuiCencRelayServer.instance;

  static bool isLoggedIn(String source) => AppServices.instance.isLoggedIn(source);

  /// 按来源搜索。
  static Future<List<Song>> search(String source, String keyword,
      {int page = 1, int num = 20}) async {
    if (source == Source.netease) {
      return AppServices.instance.netease.api
          .search(keyword, limit: num, offset: (page - 1) * num);
    }
    if (source == Source.kuwo) {
      return searchKuwo(keyword, page: page, num: num);
    }
    if (source == Source.kugou) {
      return searchKugou(keyword, page: page, num: num);
    }
    if (source == Source.migu) {
      return searchMigu(keyword, page: page, num: num);
    }
    if (source == Source.joox) {
      return searchJoox(keyword, page: page, num: num);
    }
    if (source == Source.qishui) {
      return searchQishui(keyword, page: page, num: num);
    }
    if (source == Source.qq2) {
      return searchQq2(keyword, page: page, num: num);
    }
    return AppServices.instance.qq.search.searchByType(keyword,
        page: page, num: num);
  }

  /// 汽水搜索（v2.6.1，匿名 api-vehicle /v2/search/type）。
  static Future<List<Song>> searchQishui(String keyword,
      {int page = 1, int num = 20}) async {
    final list = await QishuiApi.search(keyword, page: page, num: num);
    return list.map(qishuiSongToSong).toList();
  }

  /// 汽水歌曲 → 通用 [Song]。
  ///
  /// mid 用字符串 itemId（取流/歌词共用）；音质靠 qishui2.php 探测，留空由
  /// [ensureQualityCodes] 按实际可用档位补全（v2.6.2）。
  static Song qishuiSongToSong(QishuiSong s) => Song(
        mid: s.itemId,
        songId: int.tryParse(s.itemId) ?? 0,
        name: s.name,
        singer: s.singer,
        album: s.album,
        albumMid: '',
        duration: s.durationSeconds * 1000,
        cover: s.cover,
        source: Source.qishui,
      );

  /// QQ 音乐 2 搜索（v2.6.5，下架歌曲专用）。
  ///
  /// 搜索接口不返回封面，逐首走 cover.php 反查（限量、分批并发，
  /// 避免一屏 20 首同时打网关）；失败的留空，UI 自然显示渐变占位。
  static Future<List<Song>> searchQq2(String keyword,
      {int page = 1, int num = 20}) async {
    final list = await Qq2Api.search(keyword, page: page, num: num);
    final covers = List<String>.filled(list.length, '');
    for (var i = 0; i < list.length && i < 12; i += 6) {
      final batch = list.skip(i).take(6).toList();
      final got = await Future.wait(batch.map((s) => Qq2Api.cover(s.mid)));
      for (var k = 0; k < got.length; k++) {
        covers[i + k] = got[k];
      }
    }
    return <Song>[
      for (var i = 0; i < list.length; i++)
        qq2SongToSong(list[i], cover: covers[i]),
    ];
  }

  /// QQ 音乐 2 搜索结果 → 通用 [Song]。
  static Song qq2SongToSong(Qq2Song s, {String cover = ''}) => Song(
        mid: s.mid,
        songId: s.id,
        name: s.name,
        singer: s.singer,
        album: s.album,
        albumMid: s.albumMid,
        duration: 0,
        cover: cover,
        source: Source.qq2,
      );

  /// JOOX 搜索（v2.6.0，官方 avatar.api.joox.com 接口）。
  static Future<List<Song>> searchJoox(String keyword,
      {int page = 1, int num = 20}) async {
    final list = await JooxApi.search(keyword, page: page, num: num);
    return list.map(jooxSongToSong).toList();
  }

  /// JOOX 歌曲 → 通用 [Song]。
  ///
  /// mid 用字符串 songmid（取流 key），songId 用数字（歌词 track key 也
  /// 可从 mid 反查，这里存数字备用）。qualityCodes 留空，由探针探测。
  static Song jooxSongToSong(JooxSong s) => Song(
        mid: s.songMid,
        songId: int.tryParse(s.songId) ?? 0,
        name: s.name,
        singer: s.singer,
        album: s.album,
        albumMid: '',
        duration: s.durationSeconds * 1000,
        cover: s.cover,
        source: Source.joox,
        mvId: s.mvId,
      );

  /// 咪咕搜索（v2.6.0，洛雪同源 jadeite v3 接口 + MD5 签名）。
  static Future<List<Song>> searchMigu(String keyword,
      {int page = 1, int num = 20}) async {
    final list = await MiguApi.search(keyword, page: page, num: num);
    return list.map(miguSongToSong).toList();
  }

  /// 咪咕歌曲 → 通用 [Song]。
  ///
  /// 咪咕用 songId 做取流主键，塞进 [Song.mid]；albumId 放到 [albumMid]，
  /// 播放时用于 listen-url 的 `albumId` 参数。`qualityCodes` 留空——咪咕
  /// 音质由探针探测（见 [MiguApi.probeQualityCodes] / [ensureQualityCodes]），
  /// 而非搜索响应里的 audioFormats。
  static Song miguSongToSong(MiguSong s) => Song(
        mid: s.songId,
        songId: int.tryParse(s.songId) ?? 0,
        name: s.name,
        singer: s.singer,
        album: s.album,
        albumMid: s.albumId,
        duration: s.durationSeconds * 1000,
        cover: s.cover,
        source: Source.migu,
        mvId: s.mvId,
      );

  /// 酷我搜索（v2.4.0 新增平台）。
  ///
  /// 酷我搜索接口用 `pn`（页码，0 起）+ `rn`（每页条数）分页，
  /// 与 QQ/网易云的语义不同，这里做一次换算。
  static Future<List<Song>> searchKuwo(String keyword,
      {int page = 1, int num = 20}) async {
    final list = await KuwoApi.search(
      keyword,
      pn: (page - 1) * num,
      rn: num,
    );
    return list.map(kuwoSongToSong).toList();
  }

  /// 酷狗搜索（v2.5.0 新增平台，抄 HotDownloader）。
  static Future<List<Song>> searchKugou(String keyword,
      {int page = 1, int num = 20}) async {
    final list = await KugouApi.search(keyword, page: page, num: num);
    return list.map(kugouSongToSong).toList();
  }

  /// 酷我歌曲 → 通用 [Song]。
  ///
  /// 酷我用 `rid` 做主键，统一塞进 [Song.mid]（与 QQ 的 mid 位置一致，
  /// 便于复用到历史/收藏/队列等已有逻辑）。
  static Song kuwoSongToSong(KuwoSong s) => Song(
        mid: s.rid,
        songId: int.tryParse(s.rid) ?? 0,
        name: s.name,
        singer: s.artist,
        album: s.album,
        albumMid: '',
        duration: s.durationSeconds * 1000,
        cover: s.pic,
        source: Source.kuwo,
        qualityCodes: s.qualities.map((q) => q.id).toSet(),
      );

  /// 酷狗歌曲 → 通用 [Song]。
  ///
  /// 酷狗用 `MixSongID`（album_audio_id）做主键，塞进 [Song.mid]；
  /// 各音质 hash 由 [KugouApi] 在播放/取链时按 [qualityCodes] 反查。
  ///
  /// v2.5.4：带上 `mvId`（酷狗的 `MvHash`，32 位 hex），
  /// 播放页的 MV 按钮才能直接拉到播放源。
  static Song kugouSongToSong(KugouSong s) => Song(
        mid: s.albumAudioId,
        songId: int.tryParse(s.albumAudioId) ?? 0,
        name: s.name,
        singer: s.singer,
        album: s.album,
        albumMid: '',
        duration: s.durationSeconds * 1000,
        cover: s.pic,
        source: Source.kugou,
        mvId: s.mvHash,
        qualityCodes: s.qualities.map((q) => q.id).toSet(),
      );

  /// 音质标记按需补全缓存（进程内）。key = `source:mid`，避免同一首歌
  /// 反复查详情接口。
  static final Map<String, Set<String>> _qualityCache =
      <String, Set<String>>{};

  /// 按需补全 [song] 的 `qualityCodes`（v2.4.10）。
  ///
  /// 历史 / 收藏 / 歌单里持久化的旧 Song 没有音质标记，或分享歌单、
  /// 歌单详情等接口构造时没带上，UI 会因此回退全量档位，表现为
  /// 「每首歌都一样」。这里按平台查一次歌曲详情（都是与账号身份无关的
  /// 歌曲级标记），成功后返回带 qualityCodes 的新 Song；失败静默返回原
  /// 对象，UI 仍回退全量，不会比现在更差。仅在打开音质弹层时调用。
  static Future<Song> ensureQualityCodes(Song song) async {
    if (song.isLocal || song.qualityCodes.isNotEmpty) return song;
    final key = '${song.source}:${song.mid}';
    final cached = _qualityCache[key];
    if (cached != null && cached.isNotEmpty) {
      return song.copyWith(qualityCodes: cached);
    }
    try {
      Set<String> codes = const <String>{};
      if (song.isNetease) {
        if (song.songId > 0) {
          final list = await AppServices.instance.netease.api
              .songDetailSongs(<int>[song.songId]);
          if (list.isNotEmpty) codes = list.first.qualityCodes;
        }
      } else if (song.isKuwo) {
        final info = await KuwoApi.songInfo(song.mid);
        if (info != null) {
          codes = info.qualities.map((q) => q.id).toSet();
        }
      } else if (song.isKugou) {
        // v2.5.4：优先用进程内缓存（搜索时已用权威档位接口探测过，
        // 结果最准）；缓存没有再按歌名重搜（旧逻辑可能匹配到同名
        // 不同版本的歌）。
        final cached = KugouApi.cachedSong(song.mid);
        if (cached != null && cached.qualities.isNotEmpty) {
          codes = cached.qualities.map((q) => q.id).toSet();
        } else {
          final list = await KugouApi.search(song.name, num: 1);
          if (list.isNotEmpty) {
            codes = list.first.qualities.map((q) => q.id).toSet();
          }
        }
      } else if (song.isMigu) {
        // v2.6.0：咪咕音质靠探针逐档 Range 探测派生 URL 是否存在，
        // 探测时机就在这里（打开音质弹层 / 首次播放），避免搜索风暴。
        codes = await MiguApi.probeQualityCodes(song.mid,
            albumId: song.albumMid);
      } else if (song.isJoox) {
        // v2.6.0：JOOX 音质逐档请求 molan express 接口探测实际可用性。
        codes = await JooxApi.probeQualityCodes(song.mid);
      } else if (song.isQishui) {
        // v2.6.2：qishui2.php 一次返回全 14 档，按 Q 编号映射实际可用档位。
        codes = await QishuiApi.probeQualityCodes(song.mid);
      } else if (song.isQq2) {
        // v2.6.5：qmc.php 服务端内部已有降级链，客户端不做逐档探测，
        // 直接展示全部 9 档（避免每次打开音质弹层都打 9 次网关）。
        codes = Qq2Quality.downloadOptions.map((q) => q.code).toSet();
      } else {
        final track = await AppServices.instance.qq.song.getDetail(song.mid);
        if (track != null) codes = Quality.availableCodesFrom(track['file']);
      }
      if (codes.isNotEmpty) {
        _qualityCache[key] = codes;
        return song.copyWith(qualityCodes: codes);
      }
    } catch (e) {
      AppLog.w('MusicApi', '音质标记补全失败 $key: $e');
    }
    return song;
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
      Song song, Quality qqQuality, NeteaseQuality neQuality) async =>
      (await playUrlInfo(song, qqQuality, neQuality)).url;

  /// 按歌曲来源取播放直链，并一并返回**服务端实际提供**的音质。
  ///
  /// 服务端普遍存在"请求成功但返回更低音质"的情况（未登录/无版权/未开通会员），
  /// 因此实际音质必须反查，不能直接采信请求值：
  /// - QQ：从直链文件名前缀（如 `M500003N9y0a72Ioo.mp3`）反查；
  /// - 网易云：直接取响应里的 `level` 字段。
  static Future<PlayUrlResult> playUrlInfo(
    Song song, Quality qqQuality, NeteaseQuality neQuality,
    {KuwoQuality? kuwoQuality,
    KugouQuality? kugouQuality,
    MiguQuality? miguQuality,
    JooxQuality? jooxQuality,
    QishuiQuality? qishuiQuality}) async {
    // v2.6.7：关掉「内置音源」开关且已填 key 时，取流走第三方聚合接口。
    // 仅覆盖六个平台（JOOX / QQ2 / 本地无第三方通道，自动落到内置逻辑）。
    // 第三方失败（无该档 / 网络异常）静默回退内置，用户无感。
    if (ThirdPartySource.instance.shouldUseThirdParty) {
      final t = await ThirdPartyStreamApi.fetch(
        song,
        qqQuality: qqQuality,
        neQuality: neQuality,
        kuwoQuality: kuwoQuality,
        kugouQuality: kugouQuality,
        miguQuality: miguQuality,
        qishuiQuality: qishuiQuality,
      );
      if (t != null) {
        AppLog.i('MusicApi',
            '第三方音源取流 ${song.source}:${song.mid} → ${t.quality}');
        return PlayUrlResult.thirdParty(t.url,
            ext: ThirdPartyStreamApi.extOf(t.quality),
            label: ThirdPartyStreamApi.labelOf(t.quality));
      }
    }
    if (song.isQq2) {
      // v2.6.5：qmc.php 返回 QMCv2 加密流 + ekey，复用 QQ 的本地解密中继。
      // key 由用户在设置页填写，未填时抛错交给上层提示。
      final q = qqQuality.code.isEmpty ? Qq2Quality.playbackDefault : qqQuality;
      final info = await Qq2Api.getStream(song.mid, q);
      final cipher = InPlaceQmcCipher(
          QmcV2Cipher(qmcEkeyDecrypt(info.ekey)).decrypt);
      final relay = await _ensureQqRelay();
      final actual = info.actualQuality ?? q;
      final playUrl = relay.urlFor(info.url, info.ekey,
          ext: actual.ext.replaceFirst('.', ''), cipher: cipher);
      AppLog.d('MusicApi',
          'QQ2 档 ${q.code} → 实际 ${actual.code}（${info.quality}），走本地 QMC 中继');
      return PlayUrlResult._(playUrl, actual, null, actual.ext, null, info.ekey);
    }
    if (song.isQishui) {
      // v2.6.2：按档位名请求 qishui2.php；命中加密档（hi_res/spatial/
      // lowest 或降级落到加密份）时用本地 CENC 中继解密成可播直链。
      final q = qishuiQuality ?? QishuiQuality.playbackDefault;
      final info = await QishuiApi.getStream(song.mid, quality: q.id);
      if (!info.isUsable) return PlayUrlResult.empty;
      var playUrl = info.url;
      if (info.encrypted) {
        final ext = info.outputExt.replaceFirst('.', '');
        playUrl = await _qishuiRelay.serve(info.url, info.spadeA, ext: ext);
        AppLog.d('MusicApi',
            '汽水加密档 ${info.actualCode} 走本地 CENC 解密中继（ext=$ext）');
      }
      final actual = info.quality ?? q;
      return PlayUrlResult._(playUrl, null, null, info.outputExt, null, '',
          null, null, null, actual);
    }
    if (song.isJoox) {
      final q = jooxQuality ?? JooxQuality.playbackDefault;
      final info = await JooxApi.getExpress(song.mid, q);
      if (info.url.isEmpty) return PlayUrlResult.empty;
      return PlayUrlResult._(info.url, null, null, null, null, '', null, null, q);
    }
    if (song.isMigu) {
      final q = miguQuality ?? MiguQuality.playbackDefault;
      final listen = await MiguApi.getListenUrl(song.mid, albumId: song.albumMid);
      if (listen.url.isEmpty) return PlayUrlResult.empty;
      // 128k 基础直链直接去掉签名 query 即可用；其它档按路径替换派生。
      final url = MiguApi.deriveUrl(listen.url, q);
      return PlayUrlResult._(url, null, null, null, null, '', null, q);
    }
    if (song.isKugou) {
      final r = await KugouApi.playUrlWithFallback(
        song.mid, song.name, song.singer,
        kugouQuality ?? KugouQuality.playbackDefault,
      );
      if (r.url.isEmpty) return PlayUrlResult.empty;
      return PlayUrlResult._(r.url, null, null, null, null, '', r.quality);
    }
    if (song.isKuwo) {
      final r = await KuwoApi.playUrlWithFallback(
        song.mid,
        kuwoQuality ?? KuwoQuality.playbackDefault,
      );
      if (r.playUrl.isEmpty) return PlayUrlResult.empty;
      return PlayUrlResult._(r.playUrl, null, null, r.ext,
          KuwoQuality.fromId(r.qualityId) ?? kuwoQuality);
    }
    if (song.isNetease) {
      final r =
          await AppServices.instance.netease.api.songUrl(song.songId, neQuality);
      if (!r.isUsable()) return PlayUrlResult.empty;
      return PlayUrlResult._(
        r.url,
        null,
        NeteaseQuality.fromLevel(r.level) ?? neQuality,
        r.ext.isNotEmpty ? r.ext : null,
      );
    }
    // QQ：v2.4.2 起「杜比全景声」D004 是 AC-4，本机（media_kit 的
    // ffmpeg 白名单没有 ac4 解码器）放不出。先把请求档位换成最近的
    // 可用档；服务端还会"请求高档位返回低档位"，回来的若是 AC-4 就
    // 按实际档位再换一次（下载等直连入口没有降级链兜底）。
    var useQq = qqDecodableSubstitute(qqQuality);
    var r = await AppServices.instance.qq.song.getPlayUrlEx(song.mid, useQq);
    var url = r.url;
    if (url.isEmpty) return PlayUrlResult.empty;
    var ekey = r.ekey;
    var actual = Quality.fromUrlPrefix(url) ?? useQq;
    if (Quality.undecodableCodes.contains(actual.code)) {
      final retry = qqDecodableSubstitute(actual);
      AppLog.w('MusicApi',
          'QQ 请求 ${useQq.code} 实际返回 ${actual.code}（AC-4 本机不可解码），改请求 ${retry.code}');
      final r2 = await AppServices.instance.qq.song.getPlayUrlEx(song.mid, retry);
      if (r2.url.isNotEmpty) {
        url = r2.url;
        ekey = r2.ekey;
        actual = Quality.fromUrlPrefix(url) ?? retry;
      }
    }
    // 加密档位（FLAC/母带/杜比等）：直链是 QMCv2 加密流，走本地
    // 流式解密中继（与酷我同一条通道，ekey 是 TEA 包装需先解）。
    var playUrl = url;
    if (ekey.isNotEmpty) {
      final cipher = InPlaceQmcCipher(QmcV2Cipher(qmcEkeyDecrypt(ekey)).decrypt);
      final relay = await _ensureQqRelay();
      playUrl = relay.urlFor(url, ekey,
          ext: actual.ext.replaceFirst('.', ''), cipher: cipher);
      AppLog.d('MusicApi',
          'QQ 加密档位 ${actual.code} 走本地解密中继（ekey ${ekey.length} 字符）');
    }
    return PlayUrlResult._(playUrl, actual, null, null, null, ekey);
  }

  /// QQ 音质降级链：[from] 起向下最多 6 档，并保证末档兜底到 MP3 128。
  ///
  /// `downloadOptions` 已按高→低排列；从 [from] 之后截取即为"只降不升"。
  /// v2.4.2：过滤本机无法解码的档位（QQ「杜比全景声」D004 是 AC-4，
  /// 见 [Quality.undecodableCodes]）——选中必然失败，直接给最近的可用档。
  static List<Quality> qqDowngradeChain(Quality from) {
    final all = Quality.downloadOptions;
    // 按 code 比对而非 identity，避免将来换成值相等枚举时出错
    final i = all.indexWhere((q) => q.code == from.code);
    final rest = i < 0 ? all : all.sublist(i + 1);
    final chain = <Quality>[from, ...rest.take(5)]
        .where((q) => !Quality.undecodableCodes.contains(q.code))
        .toList();
    if (!chain.any((q) => q.code == Quality.mp3_128.code)) {
      chain.add(Quality.mp3_128);
    }
    return chain;
  }

  /// 把 [q] 替换成本机可解码的最近档位（同站向下找第一档）。
  ///
  /// 用于下载等**不走降级链**的直连入口：用户选了 AC-4（D004）时，
  /// 与其下一个放不出的文件，不如直接给最近的可用档（v2.4.2）。
  static Quality qqDecodableSubstitute(Quality q) {
    if (!Quality.undecodableCodes.contains(q.code)) return q;
    final all = Quality.downloadOptions;
    final i = all.indexWhere((e) => e.code == q.code);
    for (var k = i + 1; k < all.length; k++) {
      if (!Quality.undecodableCodes.contains(all[k].code)) return all[k];
    }
    return Quality.mp3_128;
  }

  /// 下载侧的 QQ 音质替换（v2.4.2-pre8 / -pre11）。
  ///
  /// 臻品 DTS:X（DT03）与索尼 360RA（RA01-04）由原生管线**播放时**解码，
  /// 下载侧不下发原始 mp4（本地播放内核不支持 dtsx/MHA1，下下来听不了），
  /// 换成最近的全景声档。播放侧不受影响（`PlayerController` 有独立分支）。
  static Quality qqDownloadSubstitute(Quality q) {
    final c = q.code;
    if (c == Quality.dtsX.code || c.startsWith('RA0')) {
      return Quality.atmosEac3Plus;
    }
    return q;
  }

  /// 网易云音质降级链：[from] 起向下，`downloadOptions` 已按高→低排列。
  static List<NeteaseQuality> neteaseDowngradeChain(NeteaseQuality from) {
    final all = NeteaseQuality.downloadOptions;
    final i = all.indexWhere((q) => q.level == from.level);
    return i < 0 ? all : all.sublist(i);
  }

  /// 咪咕音质降级链（v2.6.0）：[from] 起向下，末档兜底 128k。
  static List<MiguQuality> miguDowngradeChain(MiguQuality from) {
    final all = MiguQuality.downloadOptions;
    final i = all.indexWhere((q) => q.id == from.id);
    final rest = i < 0 ? all : all.sublist(i);
    final chain = <MiguQuality>[...rest];
    if (!chain.any((q) => q.id == MiguQuality.k128.id)) chain.add(MiguQuality.k128);
    return chain;
  }

  /// JOOX 音质降级链（v2.6.0）：[from] 起向下，末档兜底 128k。
  static List<JooxQuality> jooxDowngradeChain(JooxQuality from) {
    final all = JooxQuality.downloadOptions;
    final i = all.indexWhere((q) => q.id == from.id);
    final rest = i < 0 ? all : all.sublist(i);
    final chain = <JooxQuality>[...rest];
    if (!chain.any((q) => q.id == JooxQuality.k128.id)) chain.add(JooxQuality.k128);
    return chain;
  }

  /// 汽水音质降级链（v2.6.2）：[from] 起向下，末档兜底 medium（明文、最稳）。
  static List<QishuiQuality> qishuiDowngradeChain(QishuiQuality from) {
    final all = QishuiQuality.downloadOptions;
    final i = all.indexWhere((q) => q.id == from.id);
    final rest = i < 0 ? all : all.sublist(i);
    final chain = <QishuiQuality>[...rest];
    if (!chain.any((q) => q.id == QishuiQuality.medium.id)) {
      chain.add(QishuiQuality.medium);
    }
    return chain;
  }

  /// 按来源取歌词。
  static Future<String> lyric(Song song) async {
    if (song.isQq2) {
      // v2.6.5：复用 QQ 官方 PlayLyricInfo（按 mid 查）。下架歌在官方
      // 搜索里查不到，但歌词库的 QRC 仍在。`type:0` 时逐字密文在
      // data.lyric（hex）或 data.qrc 里，LyricParser 会自动识别并解密。
      final param = <String, dynamic>{
        if (song.songId > 0) 'songID': song.songId else 'songMID': song.mid,
        'crypt': 1,
        'qrc': 1,
        'trans': 1,
        'roma': 0,
        'cv': 2111,
        'ct': 19,
        'lrc_t': 0,
        'qrc_t': 0,
        'roma_t': 0,
        'trans_t': 0,
        'type': 0,
        'interval': song.duration > 0 ? song.duration ~/ 1000 : 0,
      };
      final data = await AppServices.instance.qq.execute(BizRequest(
        module: 'music.musichallSong.PlayLyricInfo',
        method: 'GetPlayLyricInfo',
        param: param,
      ));
      final v = data['lyric'];
      if (v is String && v.isNotEmpty) return v;
      if (v is Map) {
        return (v['qrc'] ?? v['lyric'] ?? v['trans'] ?? '').toString();
      }
      return '';
    }
    if (song.isKugou) {
      final l = await KugouApi.lyric(song.mid, song.name, song.singer);
      return l.isEmpty ? '' : _kugouLyricsToRaw(l);
    }
    if (song.isMigu) {
      final cached = MiguApi.cachedSong(song.mid);
      final ms = cached ??
          MiguSong(
            songId: song.mid,
            copyrightId: '',
            albumId: song.albumMid,
            name: song.name,
            singer: song.singer,
            album: song.album,
          );
      return MiguApi.lyric(ms);
    }
    if (song.isJoox) {
      // JOOX QRC 逐字（已从明文 XML 提取）优先；没有则回退 LRC。
      // songId 存的是数字 id（歌词 track 接口的 key）。
      final info = await JooxApi.lyric('${song.songId}');
      return info.qrc.isNotEmpty ? info.qrc : info.lrc;
    }
    if (song.isQishui) {
      // 汽水 krc（已转成项目 YRC 逐字格式）；失败时取流响应自带的 LRC 兜底。
      final yrc = await QishuiApi.lyric(song.mid);
      if (yrc.isNotEmpty) return yrc;
      final info = await QishuiApi.getStream(song.mid);
      return info.lrc;
    }
    if (song.isKuwo) {
      return KuwoApi.lyric(song.mid);
    }
    if (song.isNetease) {
      return AppServices.instance.netease.api.lyric(song.songId);
    }
    return AppServices.instance.qq.song.getLyrics(song.mid);
  }

  /// 酷狗 [Lyrics] → 原始 LRC 文本（供下载侧 [LyricParser] 统一解析）。
  static String _kugouLyricsToRaw(Lyrics l) {
    final buf = StringBuffer();
    for (final line in l.lines) {
      final t = line.startMs;
      final mm = (t ~/ 60000).toString().padLeft(2, '0');
      final ss = ((t ~/ 1000) % 60).toString().padLeft(2, '0');
      final xx = ((t % 1000) ~/ 10).toString().padLeft(2, '0');
      buf.write('[$mm:$ss.$xx]${line.text}\n');
    }
    return buf.toString();
  }
}