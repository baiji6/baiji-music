// MV 统一入口：按歌曲平台分发到对应实现，并处理 mvId 兜底查询。
//
// mvId 的来源（v2.4.3）：
//   - QQ    搜索/详情的 track.mv.vid（字符串型，如 w0026q7f01a）
//   - 网易  v3 song detail 的 songs[0].mv（数字）
//   - 酷我  搜索接口不带 MVID → mvId 留空，播放时用 rid 现查
//   - 酷狗  搜索响应的 MvHash（v2.5.4；32 位 hex）
//
// 因此 [resolveMvId] 对 QQ/网易有兜底查询（历史持久化数据没有 mvId 时，
// 点 MV 按钮现查一次详情）；酷我不需要（本就按 rid 播放）；酷狗从进程内
// 缓存回查（搜索时已解析出 MvHash）。
library;

import 'dart:async';

import '../../core/app_logger.dart';
import '../../models/models.dart';
import '../kugou/kugou_api.dart';
import '../netease/netease_client.dart';
import '../qq_music_client.dart';
import '../song_api.dart';
import 'kugou_mv.dart';
import 'kuwo_mv.dart';
import 'mv_source.dart';
import 'netease_mv.dart';
import 'qq_mv.dart';

/// MV 解析结果：源 + 是否走了兜底查询（UI 可据此缓存 mvId）。
class MvResolveResult {
  const MvResolveResult({required this.source, this.mvId = ''});

  final MvSource source;

  /// 兜底查询出来的 mvId（调用方可回写缓存）。
  final String mvId;
}

class MvApi {
  MvApi._();

  /// 各平台 MV 功能可用性：本地歌曲不支持。
  static bool supportedFor(Song song) => !song.isLocal;

  /// 默认请求画质。
  static const MvQuality defaultQuality = MvQuality.q1080p;

  /// 统一拉源入口。
  ///
  /// [mvId] 为空时先走 [resolveMvId] 兜底；酷我永远允许空 mvId（走 rid）。
  static Future<MvResolveResult> fetch(
    Song song, {
    required QQMusicClient qq,
    required NeteaseClient netease,
    MvQuality quality = defaultQuality,
    String? mvId,
  }) async {
    if (song.isLocal) throw const MvUnavailable('本地歌曲没有 MV');

    var id = (mvId ?? song.mvId).trim();
    if (id.isEmpty && !song.isKuwo && !song.isKugou) {
      id = await resolveMvId(song, qq: qq, netease: netease);
    }

    final MvSource? source;
    switch (song.source) {
      case Source.netease:
        if (id.isEmpty) throw const MvUnavailable('该歌曲没有 MV');
        source = await NeteaseMvApi.getSource(netease, id, quality);
        break;
      case Source.kuwo:
        source = await KuwoMvApi.getSource(song.songId.toString(), quality,
            vid: id.isEmpty ? null : id);
        break;
      case Source.kugou:
        // v2.5.4：酷狗 MV 用 `MvHash`（32 位 hex）。历史持久化数据里
        // 没有 mvId 时从进程内缓存回查。
        if (id.isEmpty) {
          final cached = KugouApi.cachedSong(song.mid);
          id = cached?.mvHash ?? '';
        }
        if (id.isEmpty) throw const MvUnavailable('该歌曲没有 MV');
        source = await KugouMvApi.getSource(id, quality);
        break;
      default:
        if (id.isEmpty) throw const MvUnavailable('该歌曲没有 MV');
        source = await QQMvApi.getSource(id, quality);
        break;
    }
    if (source == null || !source.isUsable) {
      throw const MvUnavailable('未拿到可播放的 MV 源');
    }
    return MvResolveResult(source: source, mvId: id);
  }

  /// 可选画质列表（点击画质切换时用）。酷我 legacy 档不可选，固定一档。
  static Future<List<MvQuality>> availableQualities(
    Song song, {
    required String mvId,
  }) async {
    if (song.source == Source.qq && QQMvApi.isVidValid(mvId)) {
      try {
        return await QQMvApi.availableQualities(mvId);
      } catch (e) {
        AppLog.w('MvApi', 'availableQualities: $e');
      }
    }
    if (song.source == Source.kugou) {
      // v2.5.4：酷狗有 4K（`rq` 档），通用回退列表里没有，必须实测。
      try {
        final list = await KugouMvApi.availableQualities(mvId);
        if (list.isNotEmpty) return list;
      } catch (e) {
        AppLog.w('MvApi', '酷狗画质列表获取失败: $e');
      }
    }
    return const [MvQuality.q240p, MvQuality.q360p, MvQuality.q480p,
      MvQuality.q720p, MvQuality.q1080p];
  }

  /// mvId 兜底查询：QQ 查歌曲详情、网易查 v3 song detail、酷我返回空。
  ///
  /// v2.5.4：酷狗从进程内缓存回查 `MvHash`（**不能**走 QQ 详情查询——
  /// 酷狗 mid 是 29 位 MixSongID，`int.tryParse` 溢出必然查不到）。
  static Future<String> resolveMvId(
    Song song, {
    required QQMusicClient qq,
    required NeteaseClient netease,
  }) async {
    try {
      if (song.isNetease) {
        return await fetchNeteaseMvId(song.songId);
      }
      if (song.isKuwo) return '';
      if (song.isKugou) {
        return KugouApi.cachedSong(song.mid)?.mvHash ?? '';
      }
      // QQ：getDetail 返回的就是 track_info，其 mv.vid 是目标
      final trackInfo = await SongApi(qq).getDetail(song.mid);
      final mv = trackInfo is Map<String, dynamic> ? trackInfo['mv'] : null;
      if (mv is Map<String, dynamic>) {
        final vid = mv['vid']?.toString() ?? '';
        if (QQMvApi.isVidValid(vid)) return vid;
      }
      return '';
    } catch (e) {
      AppLog.w('MvApi', 'resolveMvId(${song.mid}) 失败: $e');
      return '';
    }
  }
}

/// 带去重的异步缓存（mvId 回写用，进程内即可）。
class MvIdCache {
  final Map<String, String> _cache = {};
  final Map<String, Future<String>> _ongoing = {};

  /// 与 [MvApi.waitOngoing] 同型语义：避免同曲并发重复查询。
  Future<String> resolve(
    Song song, {
    required QQMusicClient qq,
    required NeteaseClient netease,
  }) {
    final key = '${song.source}:${song.mid}';
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);
    return _ongoing.putIfAbsent(key, () async {
      try {
        final id = await MvApi.resolveMvId(song, qq: qq, netease: netease);
        _cache[key] = id;
        return id;
      } finally {
        unawaited(_ongoing.remove(key));
      }
    });
  }

  String? peek(String source, String mid) => _cache['$source:$mid'];
}
