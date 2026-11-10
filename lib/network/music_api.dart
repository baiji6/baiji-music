import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/pure_lx_mode.dart';
import 'package:baiji_music/lx/lx_music_api.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/kuwo/kuwo_api.dart';
import 'package:baiji_music/network/kugou/kugou_api.dart';
import 'package:baiji_music/network/kugou/kugou_auth.dart';
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
    // 洛雪音源由用户导入的 JS 插件取流，不依赖任何平台账号；
    // 视为「可用」，避免 UI 把洛雪模式误显示成未登录。
    if (source == Source.lx) return true;
    if (source == Source.kuwo) return KuwoAuth.isLoggedIn;
    if (source == Source.kugou) return KugouAuth.isLoggedIn;
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

  /// 覆盖扩展名（网易云响应里的真实 `type`）；为空时按音质枚举推断。
  final String? _extOverride;

  /// QMCv2 ekey（QQ 加密档位 / 洛雪源返回的加密直链；url 已是本地解密中继地址）。
  final String ekey;

  /// 洛雪音源实际请求的档位（如 flac / hires），用于 UI 提示「已降级」。
  final String lxQuality;

  const PlayUrlResult._(this.url, this.qq, this.ne,
      [this._extOverride, this.kuwo, this.ekey = '', this.kugou, this.lxQuality = '']);

  static const empty = PlayUrlResult._('', null, null);

  /// 洛雪音源取流结果：无对应平台音质枚举，单独带档位字符串与扩展名。
  factory PlayUrlResult.lx(
    String url, {
    String ext = '',
    String quality = '',
    String ekey = '',
  }) =>
      PlayUrlResult._(url, null, null, ext.isEmpty ? null : ext, null, ekey,
          null, quality);

  bool get isEmpty => url.isEmpty;
  bool get isNotEmpty => url.isNotEmpty;

  /// 落盘扩展名。
  String get ext => _extOverride ?? kuwo?.ext ?? kugou?.ext ?? ne?.ext ?? qq?.ext ?? '.mp3';

  /// 音质标签；无则空串。
  String get label => kuwo?.label ??
      kugou?.label ??
      qq?.label ??
      ne?.label ??
      (lxQuality.isEmpty ? '' : '洛雪 $lxQuality');

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
    if (source == Source.lx) {
      // 洛雪音源只提供 musicUrl（取流），不提供搜索：搜索仍走原生 QQ
      // （免登录），结果改标为 lx 并带上默认子源，播放时由洛雪插件取链。
      // 这正是「未登录平台账号也能用洛雪音源取流播放」的入口。
      final list = await AppServices.instance.qq.search
          .searchByType(keyword, page: page, num: num);
      return list
          .map((s) => s.copyWith(source: Source.lx, lxSource: LxSubSource.tx))
          .toList();
    }
    return AppServices.instance.qq.search.searchByType(keyword,
        page: page, num: num);
  }

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
    // 洛雪歌曲的档位由插件 `inited.sources[].qualitys` 声明，不属于任何
    // 原生平台的音质标记体系，无需（也无法）查原生详情接口。
    if (song.isLocal || song.isLx || song.qualityCodes.isNotEmpty) return song;
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

  /// 纯洛雪 / 洛雪歌曲的统一取流入口（v2.5.7-pre2）。
  ///
  /// 按 [song] 的来源平台挑选用户实际选中的档位：网易云走 ne、酷我走
  /// kuwo、酷狗走 kugou、其余（QQ / 洛雪）走 qq —— 只传 QQ 档位会让
  /// 其它平台用户在音质弹层里的选择失效。子源、洛雪档位名与 musicInfo
  /// 由 [LxMusicApi.musicUrlForSong] 统一映射。
  static Future<PlayUrlResult> _playUrlViaLx(
    Song song,
    Quality qqQuality,
    NeteaseQuality neQuality, {
    KuwoQuality? kuwo,
    KugouQuality? kugou,
  }) async {
    final dynamic want;
    if (song.isNetease) {
      want = neQuality;
    } else if (song.isKuwo) {
      want = kuwo ?? KuwoQuality.playbackDefault;
    } else if (song.isKugou) {
      want = kugou ?? KugouQuality.playbackDefault;
    } else {
      want = qqQuality;
    }
    final r = await LxMusicApi.instance.musicUrlForSong(song, want);
    if (!r.ok) {
      AppLog.w('MusicApi',
          '洛雪取流失败 [${r.reasonText}] ${r.error}（子源 ${r.subSource}）');
      return PlayUrlResult.empty;
    }
    // 部分洛雪源返回 mflac/mgg + ekey：复用 QQ/酷我同一条本地 QMC
    // 流式解密中继；明文直链则原样返回。
    final url = await LxMusicApi.resolveEncrypted(r.url, r.ekey, r.format);
    AppLog.d('MusicApi',
        '洛雪源 ${r.pluginName} 取链成功（${r.quality}，子源 ${r.subSource}）');
    return PlayUrlResult.lx(url,
        ext: lxExt(r.format, r.url), quality: r.quality, ekey: r.ekey);
  }

  /// 按歌曲来源取播放直链，并一并返回**服务端实际提供**的音质。
  ///
  /// 服务端普遍存在"请求成功但返回更低音质"的情况（未登录/无版权/未开通会员），
  /// 因此实际音质必须反查，不能直接采信请求值：
  /// - QQ：从直链文件名前缀（如 `M500003N9y0a72Ioo.mp3`）反查；
  /// - 网易云：直接取响应里的 `level` 字段。
  static Future<PlayUrlResult> playUrlInfo(
    Song song, Quality qqQuality, NeteaseQuality neQuality,
    {KuwoQuality? kuwoQuality, KugouQuality? kugouQuality}) async {
    // 纯洛雪模式（v2.5.7-pre2）：关闭内置音源后，所有网络歌曲（含从
    // QQ/网易/酷我/酷狗搜索到的）一律只由洛雪 JS 音源取流；洛雪歌曲
    // 无论开关状态都走这里。子源由 musicUrlForSong 按 song.source 推断，
    // 天然绕开 search(Source.lx) 固定 tx 的旧路径。
    if (PureLxMode.shouldUseLx(song)) {
      return _playUrlViaLx(song, qqQuality, neQuality,
          kuwo: kuwoQuality, kugou: kugouQuality);
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

  /// 洛雪源返回格式 → 落盘扩展名（带点）。`format` 可能是 mflac / mgg /
  /// flac / mp3，也可能为空，此时从直链文件名兜底。
  static String lxExt(String format, String url) {
    final f = format.toLowerCase();
    if (f.contains('flac')) return '.flac';
    if (f.contains('mgg') || f.contains('ogg')) return '.ogg';
    if (f.contains('mp3')) return '.mp3';
    if (f.contains('m4a') || f.contains('aac')) return '.m4a';
    final m = RegExp(r'\.([a-zA-Z0-9]+)(?:\?|$)').firstMatch(url);
    final e = m?.group(1)?.toLowerCase();
    return e != null ? '.$e' : '.mp3';
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

  /// 按来源取歌词。
  static Future<String> lyric(Song song) async {
    if (song.isKugou) {
      final l = await KugouApi.lyric(song.mid, song.name, song.singer);
      return l.isEmpty ? '' : _kugouLyricsToRaw(l);
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