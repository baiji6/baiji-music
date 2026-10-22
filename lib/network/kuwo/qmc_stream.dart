// QMC 边下边播 —— 本地流式解密 + 本地中继服务 (Dart)
//
// 思路: QMC 解密是 1:1 的异或流, 解密后长度 == 加密长度,
//       且 cipher.decrypt(data, offset) 支持任意文件偏移 → 可做随机访问。
//       因此: 用 HTTP Range 向 CDN 分段取加密数据, 边取边解, 再通过
//       本机 HttpServer 以标准音频流(支持 Range)喂给播放器, 实现边下边播。
//
// 实现要点（v2.4.0-fix1 修正）:
//   1. **真流式**: 用 http.Client.send() 拿 StreamedResponse, 逐块解密逐块
//      下发, 不再把整个文件读进内存（旧实现无 Range 时会一次性读满
//      145MB, 手机上直接 OOM）。
//   2. **ekey 不进 URL**: 旧实现把上百字符的 ekey 塞进 query, URL 过长且
//      密钥暴露在日志/历史里。改为服务端分配短 token, 会话表在内存中维护。
//   3. **Range 透传**: 播放器的 Range 请求原样转给 CDN, 并把 CDN 的
//      Content-Range 回传, 保证拖动进度条能精确 seek。
//   4. **Content-Type 正确**: mflac/flac → audio/flac, mgg/ogg → audio/ogg,
//      mp3 → audio/mpeg, aac → audio/aac, mp4 → audio/mp4。
//   5. **磁盘播放缓存**（v2.4.0-fix2）: 解密后的音频按 256 KiB 块落盘，
//      见 [PlaybackCache]。libmpv 自带的 `--cache-on-disk` 在本项目用法下
//      不落盘，所以「清理缓存」清不到播放缓存；改由中继自己写。
//      块命中 → 直接读盘；未命中 → 按块向 CDN 取、解密、落盘、下发。
//      任何缓存异常都退回第 3 条的直连流式路径，不影响播放。
//
// 依赖:
//   dependencies:
//     http: ^1.6.0

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/app_logger.dart';
import '../../player/playback_cache.dart';
import 'qmc_cipher.dart';

/// 浏览器 UA —— 酷我 CDN 对 UA 有一定要求，带上更稳。
const String _cdnUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// 一首 QMC 加密音轨（持有解密器 + 远端地址）。
class QmcTrack {
  final String url;
  final String ekey;
  final QmcCipher cipher;
  final http.Client _client;
  int? _size;

  QmcTrack({required this.url, required this.ekey, http.Client? client})
      : cipher = QmcKeyDerivation.createCipherFromEkey(ekey),
        _client = client ?? http.Client();

  /// 探测远端文件大小（用 Range: bytes=0-0 读 Content-Range）。
  Future<int> size({Map<String, String>? headers}) async {
    if (_size != null) return _size!;
    final resp = await _client
        .get(Uri.parse(url), headers: {'Range': 'bytes=0-0', ...?headers})
        .timeout(const Duration(seconds: 15));
    final cr = resp.headers['content-range'];
    if (cr != null) {
      final m = RegExp(r'/(\d+)').firstMatch(cr);
      if (m != null) return _size = int.parse(m.group(1)!);
    }
    final cl = resp.headers['content-length'];
    if (cl != null) return _size = int.parse(cl);
    throw StateError('无法获取文件大小');
  }

  /// 读取 `[start, end]` 闭区间的明文（自动带 Range 请求 + 解密）。
  Future<Uint8List> readRange(int start, int end,
      {Map<String, String>? headers}) async {
    final resp = await _client
        .get(Uri.parse(url),
            headers: {'Range': 'bytes=$start-$end', ...?headers})
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200 && resp.statusCode != 206) {
      throw StateError('HTTP ${resp.statusCode}');
    }
    return cipher.decrypt(Uint8List.fromList(resp.bodyBytes), start);
  }

  /// 流式读取：从 `[start]` 开始，每块 `[chunkSize]` 字节边下边解。
  Stream<Uint8List> stream({
    int start = 0,
    int chunkSize = 128 * 1024,
    int? end,
    Map<String, String>? headers,
  }) async* {
    final total = end ?? await size(headers: headers);
    var pos = start;
    while (pos < total) {
      final to = _mathMin(pos + chunkSize - 1, total - 1);
      yield await readRange(pos, to, headers: headers);
      pos = to + 1;
    }
  }

  /// 解密本地已下载的 QMC 文件（整文件）。
  static Uint8List decryptFileSync(String path, String ekey) {
    final cipher = QmcKeyDerivation.createCipherFromEkey(ekey);
    final bytes = File(path).readAsBytesSync();
    return cipher.decrypt(bytes, 0);
  }

  /// 解密本地文件的指定区间（可用于边读边解）。
  static Uint8List decryptFileRange(
      String path, String ekey, int start, int length) {
    final cipher = QmcKeyDerivation.createCipherFromEkey(ekey);
    final f = File(path).openSync();
    try {
      f.setPositionSync(start);
      final buf = f.readSync(length);
      return cipher.decrypt(buf, start);
    } finally {
      f.closeSync();
    }
  }

  void close() => _client.close();
}

int _mathMin(int a, int b) => a < b ? a : b;

/// 块服务路径走不通的信号（CDN 不认 Range / 忽略 Range 等）。
///
/// 抛它就等于告诉 [_QmcRelayServer._pipeCached]「什么都还没写，请退回直连」。
class _BlockModeUnavailable implements Exception {
  const _BlockModeUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'BlockModeUnavailable($reason)';
}

/// 中继会话：token → 远端地址 + 密钥。
class _RelaySession {
  final String url;
  final String ekey;
  QmcCipher? _cipher;

  /// 已探测到的远端总大小（0 = 还没探测）。
  int size = 0;

  _RelaySession(this.url, this.ekey);

  /// 解密器惰性创建（ekey 非法时才在请求期报错，而不是启动就崩）。
  QmcCipher get cipher =>
      _cipher ??= QmcKeyDerivation.createCipherFromEkey(ekey);

  /// 播放缓存的寻址键。优先用 ekey——它对应唯一一份密文，
  /// 换一次直链（CDN 地址里的时效参数会变）也能命中上次的缓存。
  String get cacheKey => PlaybackCache.keyOf(ekey.isNotEmpty ? ekey : url);
}

/// 本地中继服务: 把远端 QMC 流解密后以标准音频流暴露给播放器
///   GET `http://127.0.0.1:<port>/stream.<ext>?t=<token>`
///   支持 HTTP Range → 播放器可拖动进度条
class QmcRelayServer {
  /// 0 = 由系统分配空闲端口（避免 8899 被占用时启动失败）。
  final int port;
  HttpServer? _server;
  final Map<String, _RelaySession> _sessions = {};
  final http.Client _client = http.Client();
  int _seq = 0;

  QmcRelayServer({this.port = 0});

  Future<int> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle);
    return _server!.port;
  }

  /// 供播放器使用的地址。
  ///
  /// [trackUrl] / [ekey] 只在服务端内存里保存，URL 上只带一个短 token。
  String urlFor(String trackUrl, String ekey, {String ext = 'flac'}) {
    final token = 's${_seq++}';
    _sessions[token] = _RelaySession(trackUrl, ekey);
    final p = _server?.port ?? port;
    return 'http://127.0.0.1:$p/stream.$ext?t=$token';
  }

  Future<void> _handle(HttpRequest req) async {
    HttpResponse? res;
    try {
      final token = req.uri.queryParameters['t'];
      final session = token == null ? null : _sessions[token];
      if (session == null) {
        res = req.response
          ..statusCode = HttpStatus.badRequest
          ..write('missing or unknown token');
        await res.close();
        return;
      }

      // 客户端的 Range 请求（播放器拖进度条时会带）
      final range = req.headers.value(HttpHeaders.rangeHeader);
      int? start;
      int? end;
      if (range != null) {
        final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
        if (m != null) {
          if (m.group(1)!.isNotEmpty) start = int.tryParse(m.group(1)!);
          if (m.group(2)!.isNotEmpty) end = int.tryParse(m.group(2)!);
        }
      }
      // 明显非法的区间（end < start）直接拒
      if (start != null && end != null && end < start) {
        res = req.response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..write('invalid range');
        await res.close();
        return;
      }

      // v2.4.0-fix2：先试「带磁盘播放缓存」的块服务路径。
      //
      // 契约：返回 true = 这个请求已经被完整处理（响应已关闭）；
      //       返回 false = 什么都还没写，调用方可以安全退回直连路径。
      // 一旦开始写响应头，块路径就会自己把响应收尾（失败时回 502），
      // 不会再抛给外层——否则外层无法区分「能不能退回」。
      try {
        if (await _pipeCached(req, session, start, end)) return;
      } catch (e) {
        AppLog.w('QmcRelay', '块缓存路径异常，退回直连: $e');
      }

      // 向 CDN 发请求（Range 原样透传）
      final cdnReq = http.Request('GET', Uri.parse(session.url));
      if (start != null || end != null) {
        final from = start ?? 0;
        final to = end == null ? '' : '$end';
        cdnReq.headers['Range'] = 'bytes=$from-$to';
      }
      cdnReq.headers['User-Agent'] = _cdnUa;
      cdnReq.headers['Accept'] = '*/*';
      cdnReq.headers['Referer'] = 'https://www.kuwo.cn/';

      final cdnResp = await _client.send(cdnReq);
      if (cdnResp.statusCode != 200 && cdnResp.statusCode != 206) {
        // CDN 拒绝区间（416）：多半是播放器请求超出了文件末尾。
        // 探测真实大小后把区间夹回合法范围重试一次，避免整条链路失败。
        if (cdnResp.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
            start != null) {
          final total = await _probeSize(session.url);
          if (total > 0) {
            // start 也可能越界（播放器拖过了文件末尾）→ 夹回合法范围
            final clampedStart = start < total ? start : 0;
            final clampedEnd =
                (end != null && end < total && end >= clampedStart)
                    ? end
                    : total - 1;
            final retry = http.Request('GET', Uri.parse(session.url));
            retry.headers['Range'] = 'bytes=$clampedStart-$clampedEnd';
            retry.headers['User-Agent'] = _cdnUa;
            retry.headers['Referer'] = 'https://www.kuwo.cn/';
            final retryResp = await _client.send(retry);
            if (retryResp.statusCode == 200 ||
                retryResp.statusCode == 206) {
              await _pipe(req, session, retryResp, clampedStart, clampedEnd);
              return;
            }
          }
        }
        res = req.response
          ..statusCode = HttpStatus.badGateway
          ..write('upstream ${cdnResp.statusCode}');
        await res.close();
        return;
      }

      await _pipe(req, session, cdnResp, start, end);
    } catch (e) {
      try {
        res ??= req.response;
        res
          ..statusCode = HttpStatus.internalServerError
          ..write('$e');
        await res.close();
      } catch (_) {}
    }
  }

  /// 探测远端文件总大小（Range: bytes=0-0 读 Content-Range）。
  Future<int> _probeSize(String url) async {
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers['Range'] = 'bytes=0-0';
      req.headers['User-Agent'] = _cdnUa;
      req.headers['Referer'] = 'https://www.kuwo.cn/';
      final resp = await _client.send(req);
      await resp.stream.drain<void>();
      final cr = resp.headers['content-range'];
      if (cr != null) {
        final m = RegExp(r'/(\d+)').firstMatch(cr);
        if (m != null) return int.parse(m.group(1)!);
      }
      final cl = resp.headers['content-length'];
      if (cl != null) return int.tryParse(cl) ?? 0;
    } catch (_) {}
    return 0;
  }

  // ==================== 块路径（带磁盘播放缓存）====================

  /// 用 256 KiB 块 + 磁盘缓存服务一个请求。
  ///
  /// 返回 true 表示请求已完整处理；返回 false 表示**什么都没写**，
  /// 调用方应退回 [_pipe] 直连流式路径。
  Future<bool> _pipeCached(
    HttpRequest req,
    _RelaySession session,
    int? start,
    int? end,
  ) async {
    final block = PlaybackCache.blockSize;
    final key = session.cacheKey;

    // 总大小：会话内缓存一次，避免每个 Range 请求都探测一遍
    var total = session.size;
    if (total <= 0) {
      total = await _probeSize(session.url);
      if (total <= 0) return false; // 探测不到 → 直连路径
      session.size = total;
    }

    final from = start ?? 0;
    final to = (end == null || end >= total) ? total - 1 : end;
    if (from < 0 || to < from) return false;

    final firstIdx = from ~/ block;
    final lastIdx = to ~/ block;

    // **先取第一个块**，成功才开始写响应头——这样取不到时可以
    // 干净地退回直连路径，不会写出半截响应。
    final Uint8List first;
    try {
      final hit = await PlaybackCache.instance.read(key, firstIdx);
      first = hit ?? await _fetchBlock(session, key, firstIdx, total);
    } catch (e) {
      AppLog.w('QmcRelay', '首块获取失败，退回直连: $e');
      return false;
    }

    final resp = req.response;
    final isPartial = start != null || end != null;
    resp
      ..statusCode = isPartial ? HttpStatus.partialContent : HttpStatus.ok
      ..headers.contentType = _contentType(req.uri.path)
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (isPartial) {
      resp.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $from-$to/$total');
    } else {
      resp.headers.set(HttpHeaders.contentLengthHeader, total);
    }

    var data = first;
    for (var i = firstIdx; i <= lastIdx; i++) {
      if (i > firstIdx) {
        Uint8List blockData;
        try {
          blockData = await PlaybackCache.instance.read(key, i) ??
              await _fetchBlock(session, key, i, total);
        } catch (e) {
          // 已经开始写了，只能如实收尾
          resp.statusCode = HttpStatus.badGateway;
          try {
            await resp.close();
          } catch (_) {}
          AppLog.e('QmcRelay', '块 $i 获取失败: $e');
          return true;
        }
        data = blockData;
      }
      // 本块内真正要交付的那一段
      final bs = i * block;
      final be = _mathMin(bs + block, total) - 1;
      final ds = math.max(bs, from);
      final de = _mathMin(be, to);
      if (de < ds) continue;
      final lo = ds - bs;
      final hi = de - bs + 1;
      resp.add(hi >= data.length
          ? Uint8List.sublistView(data, lo)
          : Uint8List.sublistView(data, lo, hi));
      await resp.flush();
    }
    await resp.close();
    return true;
  }

  /// 取一个块的明文（缓存未命中时向 CDN 取 + 解密 + 落盘）。
  ///
  /// 块模式走不通时抛 [_BlockModeUnavailable]，调用方据此退回直连路径。
  Future<Uint8List> _fetchBlock(
    _RelaySession session,
    String key,
    int index,
    int total,
  ) async {
    final bs = index * PlaybackCache.blockSize;
    final be = _mathMin(bs + PlaybackCache.blockSize, total) - 1;

    final cdnReq = http.Request('GET', Uri.parse(session.url));
    cdnReq.headers['Range'] = 'bytes=$bs-$be';
    cdnReq.headers['User-Agent'] = _cdnUa;
    cdnReq.headers['Accept'] = '*/*';
    cdnReq.headers['Referer'] = 'https://www.kuwo.cn/';

    final cdnResp = await _client.send(cdnReq);
    if (cdnResp.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      // 与直连路径同样的夹回重试
      final retry = http.Request('GET', Uri.parse(session.url));
      retry.headers['Range'] = 'bytes=$bs-$be';
      retry.headers['User-Agent'] = _cdnUa;
      retry.headers['Referer'] = 'https://www.kuwo.cn/';
      final retryResp = await _client.send(retry);
      if (retryResp.statusCode != 206) {
        await retryResp.stream.drain<void>();
        throw const _BlockModeUnavailable('CDN 不认 Range');
      }
      return _sliceBlock(session, key, index, bs, be, retryResp);
    }
    if (cdnResp.statusCode != 206) {
      // CDN 忽略 Range 回了 200：整文件从 0 开始。块模式处理不了
      // （要把整个文件读进内存），交回直连流式路径。
      await cdnResp.stream.drain<void>();
      throw const _BlockModeUnavailable('CDN 忽略 Range 回了 200');
    }
    return _sliceBlock(session, key, index, bs, be, cdnResp);
  }

  /// 从 CDN 响应里切出 `[bs, be]` 的明文，写入缓存并返回。
  Future<Uint8List> _sliceBlock(
    _RelaySession session,
    String key,
    int index,
    int bs,
    int be,
    http.StreamedResponse cdnResp,
  ) async {
    final body = Uint8List.fromList(await cdnResp.stream.toBytes());
    var actualStart = bs;
    final cr = cdnResp.headers['content-range'];
    if (cr != null) {
      final m = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+)', caseSensitive: false)
          .firstMatch(cr);
      if (m != null) actualStart = int.parse(m.group(1)!);
    }
    final lo = bs - actualStart;
    final hi = be - actualStart + 1;
    if (lo < 0 || hi > body.length || lo >= hi) {
      throw StateError('CDN 返回的区间与请求不符: want $bs-$be, body=${body.length}');
    }
    final slice = Uint8List.sublistView(body, lo, hi);
    final plain = session.cipher.decrypt(slice, bs);
    await PlaybackCache.instance.write(key, index, plain);
    return plain;
  }

  /// 把上游响应逐块解密、逐块下发。
  Future<void> _pipe(
    HttpRequest req,
    _RelaySession session,
    http.StreamedResponse cdnResp,
    int? requestedStart,
    int? requestedEnd,
  ) async {
    // 实际起始偏移：CDN 回 206 时以 Content-Range 为准；
    // 若 CDN 忽略 Range 回了 200，则整段从 0 开始。
    var baseOffset = 0;
    int? total;
    final cr = cdnResp.headers['content-range'];
    if (cr != null) {
      final m = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+)', caseSensitive: false)
          .firstMatch(cr);
      if (m != null) {
        baseOffset = int.parse(m.group(1)!);
        total = int.parse(m.group(3)!);
      }
    } else {
      final cl = cdnResp.headers['content-length'];
      if (cl != null) total = int.tryParse(cl);
    }

    final isPartial = cdnResp.statusCode == 206;
    final resp = req.response;
    resp
      ..statusCode =
          isPartial ? HttpStatus.partialContent : HttpStatus.ok
      ..headers.contentType = _contentType(req.uri.path)
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (isPartial && total != null) {
      final last = requestedEnd ?? (total - 1);
      final hi = last < total ? last : total - 1;
      resp.headers.set(HttpHeaders.contentRangeHeader,
          'bytes $baseOffset-$hi/$total');
    } else if (total != null) {
      resp.headers.set(HttpHeaders.contentLengthHeader, total);
    }

    // 逐块解密、逐块下发 —— 不把整个文件读进内存
    final cipher = session.cipher;
    var offset = baseOffset;
    await for (final chunk in cdnResp.stream) {
      if (chunk.isEmpty) continue;
      final plain = cipher.decrypt(Uint8List.fromList(chunk), offset);
      offset += chunk.length;
      resp.add(plain);
      // 让播放器尽快拿到数据（HTTP chunked）
      await resp.flush();
    }
    await resp.close();
  }

  static ContentType _contentType(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.mgg') || p.endsWith('.mggl') || p.endsWith('.ogg')) {
      return ContentType('audio', 'ogg');
    }
    if (p.endsWith('.mmp3') || p.endsWith('.mp3')) {
      return ContentType('audio', 'mpeg');
    }
    if (p.endsWith('.aac')) {
      return ContentType('audio', 'aac');
    }
    if (p.endsWith('.mp4')) {
      return ContentType('audio', 'mp4');
    }
    return ContentType('audio', 'flac'); // .mflac / .flac
  }

  Future<void> stop() async {
    _sessions.clear();
    _client.close();
    await _server?.close(force: true);
  }
}
