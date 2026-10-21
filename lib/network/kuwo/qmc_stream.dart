// QMC 边下边播 —— 本地流式解密 + 本地中继服务 (Dart)
//
// 思路: QMC 解密是 1:1 的异或流, 解密后长度 == 加密长度,
//       且 cipher.decrypt(data, offset) 支持任意文件偏移 → 可做随机访问。
//       因此: 用 HTTP Range 向 CDN 分段取加密数据, 边取边解, 再通过
//       本机 HttpServer 以标准音频流(支持 Range)喂给播放器, 实现边下边播。
//
// 依赖:
//   dependencies:
//     http: ^0.13.5

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'qmc_cipher.dart';

/// 一首 QMC 加密音轨(持有解密器 + 远端地址)
class QmcTrack {
  final String url;
  final String ekey;
  final QmcCipher cipher;
  final http.Client _client;
  int? _size;

  QmcTrack({required this.url, required this.ekey, http.Client? client})
      : cipher = QmcKeyDerivation.createCipherFromEkey(ekey),
        _client = client ?? http.Client();

  /// 探测远端文件大小(用 Range: bytes=0-0 读 Content-Range)
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

  /// 读取 `[start, end]` 闭区间的明文（自动带 Range 请求 + 解密）
  Future<Uint8List> readRange(int start, int end, {Map<String, String>? headers}) async {
    final resp = await _client
        .get(Uri.parse(url),
            headers: {'Range': 'bytes=$start-$end', ...?headers})
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200 && resp.statusCode != 206) {
      throw StateError('HTTP ${resp.statusCode}');
    }
    return cipher.decrypt(Uint8List.fromList(resp.bodyBytes), start);
  }

  /// 流式读取：从 `[start]` 开始，每块 `[chunkSize]` 字节边下边解
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

  /// 解密本地已下载的 QMC 文件(整文件)
  static Uint8List decryptFileSync(String path, String ekey) {
    final cipher = QmcKeyDerivation.createCipherFromEkey(ekey);
    final bytes = File(path).readAsBytesSync();
    return cipher.decrypt(bytes, 0);
  }

  /// 解密本地文件的指定区间(可用于边读边解)
  static Uint8List decryptFileRange(String path, String ekey, int start, int length) {
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

/// 本地中继服务: 把远端 QMC 流解密后以标准音频流暴露给播放器
///   GET `http://127.0.0.1:<port>/stream?url=<加密地址>&ekey=<ekey>`
///   支持 HTTP Range → 播放器可拖动进度条
class QmcRelayServer {
  final int port;
  HttpServer? _server;
  final Map<String, QmcTrack> _cache = {};

  QmcRelayServer({this.port = 8899});

  Future<int> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle);
    return _server!.port;
  }

  /// 供播放器使用的地址
  String urlFor(String trackUrl, String ekey, {String ext = 'flac'}) {
    final q = Uri(queryParameters: {'url': trackUrl, 'ekey': ekey}).query;
    return 'http://127.0.0.1:${_server?.port ?? port}/stream.$ext?$q';
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final q = req.uri.queryParameters;
      final url = q['url'];
      final ekey = q['ekey'];
      if (url == null || ekey == null) {
        req.response
          ..statusCode = 400
          ..write('missing url/ekey')
          ..close();
        return;
      }

      final track = _cache.putIfAbsent('$url|$ekey', () => QmcTrack(url: url, ekey: ekey));
      final total = await track.size();

      // Range 解析
      final range = req.headers.value(HttpHeaders.rangeHeader);
      int start = 0;
      int end = total - 1;
      var partial = false;
      if (range != null) {
        final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
        if (m != null) {
          partial = true;
          if (m.group(1)!.isNotEmpty) start = int.parse(m.group(1)!);
          if (m.group(2)!.isNotEmpty) end = int.parse(m.group(2)!);
          if (end >= total) end = total - 1;
        }
      }
      if (start > end) start = end;

      final body = await track.readRange(start, end);
      final path = req.uri.path.toLowerCase();

      req.response
        ..statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok
        ..headers.contentType = _contentType(path)
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(HttpHeaders.contentLengthHeader, body.length);
      if (partial) {
        req.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
      }
      req.response.add(body);
      await req.response.close();
    } catch (e) {
      try {
        req.response
          ..statusCode = 500
          ..write('$e');
        await req.response.close();
      } catch (_) {}
    }
  }

  static ContentType _contentType(String path) {
    if (path.endsWith('.mgg') || path.endsWith('.mggl') || path.endsWith('.ogg')) {
      return ContentType('audio', 'ogg');
    }
    if (path.endsWith('.mmp3') || path.endsWith('.mp3')) {
      return ContentType('audio', 'mpeg');
    }
    return ContentType('audio', 'flac'); // .mflac / .mflac0 / .flac
  }

  Future<void> stop() async {
    for (final t in _cache.values) {
      t.close();
    }
    _cache.clear();
    await _server?.close(force: true);
  }
}
