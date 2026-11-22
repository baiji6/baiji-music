// 汽水 CENC 本地中继时序契约测试（v2.6.2-fix1）。
//
// 回归点：v2.6.2 的 serve() 立即返回本地 URL、解密在后台进行，播放器
// open 时明文还没落盘 → ffmpeg 打开超时（Failed to open）+ 7 秒卡顿。
// fix1 改为「解密就绪后才返回 URL」：下载/解密失败必须向上抛，绝不能
// 返回一个播放器打不开的坏 URL。这里用本地 HttpServer 精确锁定该语义，
// 纯离线、不依赖外网。
import 'dart:io';

import 'package:baiji_music/network/qishui/qishui_relay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QishuiCencRelayServer.serve 时序契约', () {
    test('远端返回 500 时 serve 抛错，不返回坏 URL', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      });
      addTearDown(() async => server.close());

      final relay = QishuiCencRelayServer.instance;
      expect(
        relay.serve('http://127.0.0.1:${server.port}/bad', 'any-spade',
            ext: 'm4a'),
        throwsA(isA<HttpException>()),
        reason: '解密失败必须抛错让上层降级，不能返回播放器打不开的坏 URL',
      );
    });

    test('空响应（0 字节）时 serve 抛 StateError，不返回坏 URL', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
      });
      addTearDown(() async => server.close());

      final relay = QishuiCencRelayServer.instance;
      expect(
        relay.serve('http://127.0.0.1:${server.port}/empty', 'any-spade',
            ext: 'flac'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
