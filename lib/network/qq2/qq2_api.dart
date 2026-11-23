// QQ 音乐 2 网络层（v2.6.5，下架歌曲专用）。
//
// 三个接口各司其职：
//   1. 搜索：POST https://c.wwwweb.top/music/search
//      返回 data[]：id / mid / name / artist / album / albummid。
//      官方搜索对下架歌返回 `query forbid`，只有这条通道能搜到。
//   2. 封面：GET http://molan.guoyue2010.cn/cover.php
//      ?action=qq_cover&songmid=<mid>&size=<size>
//      返回 data.artwork 直链（服务端从歌手/其他版本反查专辑 mid，
//      官方详情里 album.mid 已被清空，自己拼不出封面）。
//   3. 取流：GET http://molan.guoyue2010.cn/qmc.php?id=<mid>&level=<level>
//      header X-API-key: <用户在设置页填写的 key，绝不内置>。
//      返回 data.url（QMCv2 加密直链）+ data.ekey；解密复用 QQ 的
//      QmcRelayServer。level 全 9 档见 models.Qq2Quality。
//
// 歌词不走这里：直接复用 LyricApi.qq(song)，按 mid 请求官方
// PlayLyricInfo —— 下架歌的 QRC 逐字数据仍在歌词库，实测可解。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/app_logger.dart';
import '../../core/kv_store.dart';
import '../../models/models.dart';

/// 单条搜索结果。
class Qq2Song {
  final String mid;
  final int id;
  final String name;
  final String singer;
  final String album;
  final String albumMid;

  const Qq2Song({
    required this.mid,
    this.id = 0,
    this.name = '',
    this.singer = '',
    this.album = '',
    this.albumMid = '',
  });
}

/// qmc.php 取流结果。
class Qq2StreamInfo {
  final String url;
  final String ekey;

  /// 服务端返回的 quality 字面值（请求档与命中档可能不同）。
  final String quality;

  /// 从 URL 文件名前缀反查的实际档位；识别不出时为空。
  final Quality? actualQuality;

  final String cover;
  final String songName;
  final String singer;
  final String album;

  /// 形如「4分13秒」的可读时长（解析失败为 0 毫秒）。
  final int durationMs;

  const Qq2StreamInfo({
    required this.url,
    required this.ekey,
    this.quality = '',
    this.actualQuality,
    this.cover = '',
    this.songName = '',
    this.singer = '',
    this.album = '',
    this.durationMs = 0,
  });

  bool get isUsable => url.isNotEmpty && ekey.isNotEmpty;
}

class Qq2Api {
  Qq2Api._();

  static const String searchBase = 'https://c.wwwweb.top/music/search';
  static const String coverBase = 'http://molan.guoyue2010.cn/cover.php';
  static const String streamBase = 'http://molan.guoyue2010.cn/qmc.php';

  /// API Key 的存储键。只由设置页写入，代码里没有默认值。
  static const String keyPref = 'qq2_api_key';

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 25),
    validateStatus: (_) => true,
  ));

  /// 当前 key；KvStore 尚未初始化（单测/启动早期）时返回空串。
  static String get apiKey {
    try {
      return KvStore.instance.getString(keyPref)?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  static bool get hasApiKey => apiKey.isNotEmpty;

  static Future<void> setApiKey(String key) =>
      KvStore.instance.setString(keyPref, key.trim());

  /// 搜索（page 从 1 起）。
  static Future<List<Qq2Song>> search(String keyword,
      {int page = 1, int num = 20}) async {
    final resp = await _dio.post<String>(
      searchBase,
      data: <String, dynamic>{
        'keyword': keyword,
        'page': page < 1 ? 1 : page,
        'limit': num < 1 ? 20 : num,
      },
      options: Options(
        contentType: Headers.jsonContentType,
        headers: const <String, String>{'Accept': 'application/json'},
      ),
    );
    final list = parseSearchResponse(_decode(resp.data));
    AppLog.d('Qq2Api', '搜索 $keyword → ${list.length} 首');
    return list;
  }

  /// 解析搜索响应（纯函数，便于离线单测）。
  static List<Qq2Song> parseSearchResponse(dynamic raw) {
    final out = <Qq2Song>[];
    if (raw is! Map) return out;
    final data = raw['data'];
    if (data is! List) return out;
    for (final item in data) {
      if (item is! Map) continue;
      final mid = item['mid']?.toString() ?? '';
      if (mid.isEmpty) continue;
      out.add(Qq2Song(
        mid: mid,
        id: item['id'] is num ? (item['id'] as num).toInt() : 0,
        name: item['name']?.toString() ?? '',
        singer: item['artist']?.toString() ?? '',
        album: item['album']?.toString() ?? '',
        albumMid: item['albummid']?.toString() ?? '',
      ));
    }
    return out;
  }

  /// 封面尺寸降级链：从大到小逐个尝试，直到拿到「能真正加载」的图片。
  ///
  /// cover.php 对每个 size 都会拼出一个 y.gtimg.cn URL，但服务端只是按
  /// `T002R<size>x<size>M000<mid>.jpg` 拼字符串，并不保证该尺寸的图片真的
  /// 存在（下架歌尤其常见「大图是空壳、小图才有」）。所以不能只看接口返回，
  /// 必须探一下 HEAD：2xx 且 JPEG/PNG 才算可用，否则降一档重试。
  static const List<int> coverSizes = <int>[1500, 1200, 800, 500, 300];

  /// 取封面直链：按 [coverSizes] 从大到小降级，全失败返回空串（列表用渐变
  /// 占位兜底）。
  ///
  /// 降到最小档 300 仍拿不到可用图片 → 判定官方已删除封面文件，不再尝试
  /// 更小尺寸或其它通道，直接返回空串交给 UI 渐变占位。
  static Future<String> cover(String mid, {int? size}) async {
    if (mid.isEmpty) return '';
    // 指定 size 时只试这一档（测试/特殊场景用）；默认走完整降级链。
    final sizes = size != null ? <int>[size] : coverSizes;
    for (final s in sizes) {
      String artwork;
      try {
        final resp = await _dio.get<String>(
          coverBase,
          queryParameters: <String, dynamic>{
            'action': 'qq_cover',
            'songmid': mid,
            'size': s,
          },
        );
        artwork = parseCoverResponse(_decode(resp.data)) ?? '';
      } catch (e) {
        AppLog.w('Qq2Api', '封面 $mid size=$s 请求失败: $e');
        continue;
      }
      if (artwork.isEmpty) {
        // 这一档服务端没给 URL，直接降下一档。
        continue;
      }
      // HEAD 探测图片是否真能加载（短超时，避免拖慢搜索首屏）。
      if (await _coverLoadable(artwork)) return artwork;
      AppLog.i('Qq2Api', '封面 $mid size=$s 图片不可加载，降级重试');
    }
    return '';
  }

  /// 解析 cover.php 响应，取 artwork 直链。纯函数，便于离线单测。
  ///
  /// code 非 0 / data 非 Map / artwork 为空 → 返回 null。
  static String? parseCoverResponse(dynamic raw) {
    if (raw is! Map) return null;
    if (raw['code'] is num && (raw['code'] as num).toInt() != 0) return null;
    final data = raw['data'];
    if (data is! Map) return null;
    final artwork = data['artwork']?.toString() ?? '';
    return artwork.isEmpty ? null : artwork;
  }

  /// HEAD 探测图片是否可加载：2xx 且 content-type 是图片即认为可用。
  ///
  /// y.gtimg.cn 无 HEAD 时部分 CDN 节点会回 405，此时退化为 range GET 1 字节。
  /// 网络异常一律当作「本档不可用」交给上层降级。
  static Future<bool> _coverLoadable(String url) async {
    try {
      final resp = await _dio.head<Object?>(
        url,
        options: Options(
          connectTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 4),
        ),
      );
      final code = resp.statusCode ?? 0;
      if (code >= 200 && code < 300) {
        final ct = resp.headers.value(Headers.contentTypeHeader) ?? '';
        // 没有 content-type 也放行（部分节点 HEAD 不返回头，但状态码正常）。
        return ct.isEmpty ||
            ct.startsWith('image/') ||
            ct.contains('octet-stream');
      }
      // 405/501：CDN 不支持 HEAD，改 range GET 验证。
      if (code == 405 || code == 501) {
        final r = await _dio.get<List<int>>(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            headers: <String, String>{'Range': 'bytes=0-0'},
            connectTimeout: const Duration(seconds: 4),
            receiveTimeout: const Duration(seconds: 4),
          ),
        );
        return (r.statusCode ?? 0) >= 200 && (r.statusCode ?? 0) < 300;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 取流。未设置 key / 服务端报错时抛 [StateError]，交给上层降级提示。
  static Future<Qq2StreamInfo> getStream(String mid, Quality quality) async {
    final key = apiKey;
    if (key.isEmpty) {
      throw StateError('请先在设置页填写 QQ 音乐 2 的 API Key');
    }
    final resp = await _dio.get<String>(
      streamBase,
      queryParameters: <String, dynamic>{
        'id': mid,
        // qmc.php 的 level 是档位名（lossless/zpqj/…），不是文件名前缀；
        // 传错会被当成未知档静默回落到 standard。
        'level': levelOf(quality),
      },
      options: Options(headers: <String, String>{'X-API-key': key}),
    );
    final raw = _decode(resp.data);
    if (raw is! Map) {
      throw StateError('qmc.php 返回格式错误（HTTP ${resp.statusCode}）');
    }
    final code = raw['code'] is num ? (raw['code'] as num).toInt() : -1;
    if (code != 200) {
      throw StateError(raw['msg']?.toString() ?? '取流失败（code $code）');
    }
    final data = raw['data'];
    if (data is! Map) throw StateError('qmc.php 无 data 字段');
    final url = data['url']?.toString() ?? '';
    final ekey = data['ekey']?.toString() ?? '';
    if (url.isEmpty || ekey.isEmpty) {
      throw StateError('qmc.php 返回的直链或 ekey 为空');
    }
    return Qq2StreamInfo(
      url: url,
      ekey: ekey,
      quality: data['quality']?.toString() ?? '',
      actualQuality: Qq2Quality.fromUrl(url),
      cover: data['cover']?.toString() ?? '',
      songName: data['songname']?.toString() ?? '',
      singer: data['singer']?.toString() ?? '',
      album: data['album']?.toString() ?? '',
      durationMs: _parseInterval(data['interval']?.toString() ?? ''),
    );
  }

  /// [Quality.code]（文件名前缀）→ qmc.php 的 `level` 参数。
  static String levelOf(Quality q) {
    switch (q.code) {
      case 'O4M0':
        return 'low';
      case 'O6M0':
        return 'standard';
      case 'O8M0':
        return 'exhigh';
      case 'F0M0':
        return 'lossless';
      case 'RSM1':
        return 'hires';
      case 'Q0M0':
        return 'zpyz';
      case 'Q0M1':
        return 'zpqj';
      case 'D0M1':
        return 'dolby';
      case 'AIM0':
        return 'jymaster';
      default:
        return 'standard';
    }
  }

  /// 「3分45秒」/「4分13秒」→ 毫秒。
  static int _parseInterval(String s) {
    final m = RegExp(r'(\d+)\s*分\s*(\d+)\s*秒').firstMatch(s);
    if (m == null) return 0;
    return ((int.tryParse(m.group(1)!) ?? 0) * 60 +
            (int.tryParse(m.group(2)!) ?? 0)) *
        1000;
  }

  static dynamic _decode(String? body) {
    if (body == null || body.isEmpty) return null;
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}
