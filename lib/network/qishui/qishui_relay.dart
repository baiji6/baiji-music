// 汽水 CENC 加密档 —— 本地解密中继服务（v2.6.2）。
//
// 与 QMC（异或流、可随机访问）不同，汽水 CENC（cenc-aes-ctr）解密需要
// 解析整段 MP4 box 结构（stsz/senc/stco/mdat）并重建成干净 MP4 或 FLAC，
// 无法按任意偏移流式解密。因此本中继的做法是：
//   1. 首次请求时把加密流整段下载并用同档 spade_a 解密成明文，落一个临时文件；
//   2. 之后按标准 HTTP Range 从明文文件读区间喂给播放器，保证拖动进度条可 seek；
//   3. 同一会话只解密一次（Completer 去重），多个 Range 请求复用同一明文文件。
//
// 播放器拿到的是 `http://127.0.0.1:<port>/qishui/<token>`，
// token 只在内存里映射到 (远端 url, spade_a)，密钥不进日志/历史。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/app_logger.dart';
import 'qishui_cenc.dart';

class _QishuiCencSession {
  final String url;
  final String spadeA;
  final String ext;

  final Completer<String> _plain = Completer<String>();
  bool _started = false;

  _QishuiCencSession(this.url, this.spadeA, this.ext);

  /// 确保明文文件就绪，返回其路径（并发请求复用同一次解密）。
  Future<String> plainPath() {
    if (!_started) {
      _started = true;
      unawaited(_prepare());
    }
    return _plain.future;
  }

  Future<void> _prepare() async {
    final tmpDir = Directory.systemTemp;
    final outPath = '${tmpDir.path}${Platform.pathSeparator}'
        'qm_qishui_${identityHashCode(this)}_${DateTime.now().microsecondsSinceEpoch}.$ext';
    final out = File(outPath);
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers['User-Agent'] = 'Mozilla/5.0';
      req.headers['Accept'] = '*/*';
      final resp = await client.send(req).timeout(const Duration(seconds: 60));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('HTTP ${resp.statusCode}', uri: Uri.parse(url));
      }
      final bytes = await resp.stream.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      final encrypted = bytes.takeBytes();
      if (encrypted.isEmpty) throw StateError('空加密流');
      final result = qishuiDecrypt(encrypted, spadeA: spadeA);
      await out.writeAsBytes(result.buffer);
      AppLog.i('QishuiCenc',
          '解密完成 $ext ${result.sampleCount} 样本 ${result.buffer.length} 字节');
      if (!_plain.isCompleted) _plain.complete(outPath);
    } catch (e, st) {
      AppLog.w('QishuiCenc', '解密失败: $e');
      AppLog.d('QishuiCenc', st.toString().split('\n').take(3).join('\n'));
      try {
        if (await out.exists()) await out.delete();
      } catch (_) {}
      if (!_plain.isCompleted) _plain.completeError(e);
    } finally {
      client.close();
    }
  }
}

/// 汽水 CENC 本地解密中继（单例）。
class QishuiCencRelayServer {
  QishuiCencRelayServer._();

  static final QishuiCencRelayServer instance = QishuiCencRelayServer._();

  HttpServer? _server;
  final Map<String, _QishuiCencSession> _sessions = {};
  int _seq = 0;

  int? get port => _server?.port;

  Future<int> _ensure() async {
    final s = _server;
    if (s != null) return s.port;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((req) => unawaited(_handle(req)));
    AppLog.i('QishuiCenc', '本地解密中继启动 127.0.0.1:${server.port}');
    return server.port;
  }

  /// 为一个加密档开流，返回播放器可打开的本地 URL。
  ///
  /// 关键：必须等明文落盘后【才】把 URL 交给播放器。CENC 需整曲下载+
  /// 解密（实测约 7 秒），若先返回 URL，播放器会立即 open，而 [_handle]
  /// 此时还在等解密、迟迟不回响应头，ffmpeg 判定打开超时（Failed to
  /// open + 等待轨道加载超时），即便稍后解密完成也只能靠上层重试补救，
  /// 表现为切档先报错、卡 7 秒才出声。等就绪再返回即可一次成功。
  /// 解密失败时清掉会话并向上抛，由播放/下载的降级链接住换下一档。
  Future<String> serve(String url, String spadeA, {String ext = 'm4a'}) async {
    final p = await _ensure();
    final token = 'q${_seq++}';
    final session = _QishuiCencSession(url, spadeA, ext);
    _sessions[token] = session;
    try {
      await session.plainPath();
    } catch (_) {
      _sessions.remove(token);
      rethrow;
    }
    return 'http://127.0.0.1:$p/qishui/$token';
  }

  String _contentType(String ext) =>
      ext == 'flac' ? 'audio/flac' : 'audio/mp4';

  Future<void> _handle(HttpRequest req) async {
    HttpResponse? res;
    var headersSent = false;
    try {
      res = req.response;
      if (req.method != 'GET' && req.method != 'HEAD') {
        res.statusCode = 405;
        await res.close();
        return;
      }
      final path = req.uri.path;
      if (!path.startsWith('/qishui/')) {
        res.statusCode = 404;
        await res.close();
        return;
      }
      final token = path.substring('/qishui/'.length);
      final session = _sessions[token];
      if (session == null) {
        res.statusCode = 404;
        await res.close();
        return;
      }

      final filePath = await session.plainPath();
      final file = File(filePath);
      if (!await file.exists()) {
        res.statusCode = 502;
        res.write('decrypted file missing');
        await res.close();
        return;
      }
      final total = await file.length();
      if (total <= 0) {
        res.statusCode = 502;
        await res.close();
        return;
      }

      // 解析 Range（播放器拖进度条会带）。
      int? start;
      int? end;
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
        if (m != null) {
          final g1 = m.group(1) ?? '';
          final g2 = m.group(2) ?? '';
          if (g1.isEmpty) {
            // 后缀区间 bytes=-N：取末尾 N 字节。
            final suffix = int.tryParse(g2);
            if (suffix != null && suffix > 0) {
              start = suffix >= total ? 0 : total - suffix;
              end = total - 1;
            }
          } else {
            start = int.tryParse(g1);
            end = g2.isEmpty ? null : int.tryParse(g2);
          }
        }
      }
      if (start != null && start >= total) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await res.close();
        return;
      }
      if (end != null && end >= total) end = total - 1;
      if (start != null && end != null && end < start) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await res.close();
        return;
      }

      final from = start ?? 0;
      final to = end ?? total - 1;
      final length = to - from + 1;
      final isPartial = start != null || end != null;

      res.statusCode = isPartial ? HttpStatus.partialContent : HttpStatus.ok;
      res.headers.set(HttpHeaders.contentTypeHeader, _contentType(session.ext));
      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      res.headers.set(HttpHeaders.contentLengthHeader, length);
      if (isPartial) {
        res.headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $from-$to/$total');
      }
      res.headers.set('Access-Control-Allow-Origin', '*');
      headersSent = true;

      if (req.method == 'HEAD') {
        await res.close();
        return;
      }
      final raf = await file.open(mode: FileMode.read);
      try {
        await raf.setPosition(from);
        var remaining = length;
        while (remaining > 0) {
          final chunk = await raf.read(remaining > 65536 ? 65536 : remaining);
          if (chunk.isEmpty) break;
          res.add(chunk);
          remaining -= chunk.length;
          await res.flush();
        }
      } finally {
        await raf.close();
      }
      await res.close();
    } catch (e) {
      AppLog.w('QishuiCenc', '中继请求异常: $e');
      try {
        res ??= req.response;
        if (headersSent) {
          // 响应头已写出（流式中途断开）不再改状态码，直接收尾。
          await res.close();
        } else {
          res.statusCode = HttpStatus.badGateway;
          await res.close();
        }
      } catch (_) {}
    }
  }
}
