import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/kuwo/kuwo_api.dart';
import '../decrypt/qmc.dart';
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

  /// 覆盖扩展名（网易云响应里的真实 `type`）；为空时按音质枚举推断。
  final String? _extOverride;

  /// QMCv2 ekey（QQ 加密档位才有；url 已是本地解密中继地址）。
  final String ekey;

  const PlayUrlResult._(this.url, this.qq, this.ne,
      [this._extOverride, this.kuwo, this.ekey = '']);

  static const empty = PlayUrlResult._('', null, null);

  bool get isEmpty => url.isEmpty;
  bool get isNotEmpty => url.isNotEmpty;

  /// 落盘扩展名。
  String get ext => _extOverride ?? kuwo?.ext ?? ne?.ext ?? qq?.ext ?? '.mp3';

  /// 音质标签；无则空串。
  String get label => kuwo?.label ?? qq?.label ?? ne?.label ?? '';

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
      );

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
    {KuwoQuality? kuwoQuality}) async {
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

  /// 下载侧的 QQ 音质替换（v2.4.2-pre8）。
  ///
  /// 臻品 DTS:X（DT03）由 `dts_glue` 原生管线**播放时**解码，下载侧不下发
  /// 原始 `dtsx` mp4（本地播放内核不支持，下下来听不了），换成最近的
  /// 全景声档。播放侧不受影响（`PlayerController` 有独立的 DT03 分支）。
  static Quality qqDownloadSubstitute(Quality q) =>
      q.code == Quality.dtsX.code ? Quality.atmosEac3Plus : q;

  /// 网易云音质降级链：[from] 起向下，`downloadOptions` 已按高→低排列。
  static List<NeteaseQuality> neteaseDowngradeChain(NeteaseQuality from) {
    final all = NeteaseQuality.downloadOptions;
    final i = all.indexWhere((q) => q.level == from.level);
    return i < 0 ? all : all.sublist(i);
  }

  /// 按来源取歌词。
  static Future<String> lyric(Song song) async {
    if (song.isKuwo) {
      return KuwoApi.lyric(song.mid);
    }
    if (song.isNetease) {
      return AppServices.instance.netease.api.lyric(song.songId);
    }
    return AppServices.instance.qq.song.getLyrics(song.mid);
  }
}