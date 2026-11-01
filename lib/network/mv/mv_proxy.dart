// MV 本地中继代理 —— 给 WebView 播放注入 CDN 防盗链头。
//
// 为什么需要它（v2.4.3）：
//   三平台 MV CDN 都有防盗链（QQ 要 Referer: y.qq.com、酷我要 Referer
//   + iPhone UA、网易要 Referer: music.163.com）。WebView 加载本地
//   HTML 后 `<video>` 直接请求 CDN 拿不到自定义头（webview_flutter 不
//   支持 per-request header），所以让 `<video>` 指向本机代理，由代理
//   转发时注入头。
//
// 设计（与 qmc_stream.dart 的中继同思路，但更简单）：
//   - HttpServer 绑 127.0.0.1 随机端口；`/mv/<token>` 对应一个会话，
//     token 是 16 字节随机 hex，会话表在内存（url + headers + 过期）。
//   - Range 透传：`<video>` 的拖动进度条靠 Range 请求，代理把 Range/
//     If-Range 原样转给 CDN，206/Content-Range/Content-Length 原样
//     回传——实测三平台 CDN 都支持（酷我 206、网易 206 已验证）。
//   - http.Client.send() 流式转发，MV 100MB+ 不占内存。
//   - 会话 2 小时后自动过期（QQ expire=86400、网易 expi=3600，取小的
//     富余量；过期后 404，UI 重开页面会重新取源）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../core/app_logger.dart';
import 'mv_source.dart';

/// 一次代理会话：URL + 需要注入的头。
class _MvSession {
  final String url;
  final Map<String, String> headers;
  final DateTime expiresAt;

  _MvSession(this.url, this.headers, this.expiresAt);
}

/// 单例代理服务。MV 页面打开时 [start]，关闭时可 [stop]（幂等）。
class MvProxyServer {
  MvProxyServer._();
  static final MvProxyServer instance = MvProxyServer._();

  static const Duration _sessionTtl = Duration(hours: 2);
  static const List<String> _forwardRequestHeaders = [
    'range',
    'if-range',
    'accept',
    'accept-encoding',
  ];
  static const List<String> _forwardResponseHeaders = [
    'content-type',
    'content-length',
    'content-range',
    'accept-ranges',
    'last-modified',
    'etag',
  ];

  final http.Client _client = http.Client();
  final Map<String, _MvSession> _sessions = {};
  final math.Random _rng = math.Random.secure();

  HttpServer? _server;
  int? _port;

  /// 服务端口（未启动时 null）。
  int? get port => _port;

  /// 启动（幂等）。返回端口。
  Future<int> start() async {
    final s = _server;
    if (s != null) return _port!;
    final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4, 0, shared: false);
    _server = server;
    _port = server.port;
    unawaited(_serve(server));
    AppLog.i('MvProxy', '中继已启动 127.0.0.1:${server.port}');
    return server.port;
  }

  /// 停止并清空会话（幂等）。
  Future<void> stop() async {
    final s = _server;
    _server = null;
    _port = null;
    _sessions.clear();
    await s?.close(force: true);
  }

  /// 注册一个 MV 源，返回本机代理地址。
  Future<String> register(MvSource source) async {
    final port = await start();
    final token = _token();
    _sessions[token] = _MvSession(
      source.url,
      Map.of(source.headers),
      DateTime.now().add(_sessionTtl),
    );
    _gc();
    return 'http://127.0.0.1:$port/mv/$token';
  }

  String _token() {
    final bytes =
        List<int>.generate(16, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _gc() {
    final now = DateTime.now();
    _sessions.removeWhere((_, s) => s.expiresAt.isBefore(now));
  }

  Future<void> _serve(HttpServer server) async {
    try {
      await for (final req in server) {
        unawaited(_handle(req));
      }
    } catch (e) {
      AppLog.w('MvProxy', 'serve 异常: $e');
    }
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path.startsWith('/mv/')) {
        final token = path.substring('/mv/'.length);
        final session = _sessions[token];
        if (session == null) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        if (session.expiresAt.isBefore(DateTime.now())) {
          _sessions.remove(token);
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        await _relay(req, session);
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    } catch (e) {
      AppLog.w('MvProxy', 'handle 异常: $e');
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  /// 流式转发：Range 进、206 出。
  Future<void> _relay(HttpRequest req, _MvSession session) async {
    final headers = <String, String>{...session.headers};
    for (final h in _forwardRequestHeaders) {
      final v = req.headers.value(h);
      if (v != null) headers[h] = v;
    }

    final creq = http.Request('GET', Uri.parse(session.url));
    creq.headers.addAll(headers);
    creq.followRedirects = true;

    final resp =
        await _client.send(creq).timeout(const Duration(seconds: 30));

    final rres = req.response;
    rres.statusCode = resp.statusCode;
    resp.headers.forEach((k, v) {
      if (_forwardResponseHeaders.contains(k.toLowerCase())) {
        try {
          rres.headers.set(k, v);
        } catch (_) {}
      }
    });
    if (rres.headers.value('accept-ranges') == null &&
        resp.statusCode == 200) {
      rres.headers.set('accept-ranges', 'bytes');
    }

    await resp.stream.pipe(rres);
  }
}
