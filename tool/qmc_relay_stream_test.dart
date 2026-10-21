// 流式首字节延迟测试：验证「边下边解边发」而非整文件缓冲
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:baiji_music/network/kuwo/qmc_stream.dart';

Future<void> main(List<String> args) async {
  final relay = QmcRelayServer();
  await relay.start();
  final local = relay.urlFor(args[0], args[1], ext: 'flac');
  stdout.writeln('本地: $local');

  final req = http.Request('GET', Uri.parse(local));
  final resp = await http.Client().send(req);
  stdout.writeln('状态: ${resp.statusCode}  content-length: ${resp.headers['content-length']}');

  var total = 0;
  var chunks = 0;
  final sw = Stopwatch()..start();
  int? firstByteMs;
  await for (final c in resp.stream) {
    firstByteMs ??= sw.elapsedMilliseconds;
    total += c.length; chunks++;
    if (chunks <= 3) stdout.writeln('  chunk#$chunks ${c.length} 字节 @${sw.elapsedMilliseconds}ms');
  }
  sw.stop();
  stdout.writeln('首字节延迟: ${firstByteMs}ms');
  stdout.writeln('总字节: $total  块数: $chunks  总耗时: ${sw.elapsedMilliseconds}ms');
  await relay.stop();
}
