// 本地中继（QMC relay）集成自检：验证 Range 转发与解密正确性
import 'dart:io';
import 'package:http/http.dart' as http;

import 'package:baiji_music/network/kuwo/qmc_stream.dart';

Future<void> main(List<String> args) async {
  final url = args[0];
  final ekey = args[1];

  final relay = QmcRelayServer();
  await relay.start();
  final local = relay.urlFor(url, ekey, ext: 'flac');
  stdout.writeln('本地地址: $local');

  final c = http.Client();
  // 1) Range 0-99
  final r1 = await c.get(Uri.parse(local), headers: {'Range': 'bytes=0-99'});
  stdout.writeln('Range 0-99 → ${r1.statusCode} len=${r1.bodyBytes.length}');
  stdout.writeln('  前 8 字节: ${r1.bodyBytes.take(8).map((e)=>e.toRadixString(16).padLeft(2,'0')).join(' ')}');
  stdout.writeln('  是否 fLaC: ${r1.bodyBytes.take(4).join()== "fLaC".codeUnits.join(",")}');

  // 2) Range 1000-1099（跨首段，验证偏移解密）
  final r2 = await c.get(Uri.parse(local), headers: {'Range': 'bytes=1000-1099'});
  stdout.writeln('Range 1000-1099 → ${r2.statusCode} len=${r2.bodyBytes.length}');

  // 3) 同一区间再取一次，验证与首段拼接一致（seek 一致性）
  final r3 = await c.get(Uri.parse(local), headers: {'Range': 'bytes=0-1099'});
  final expect = r3.bodyBytes.sublist(1000, 1100);
  stdout.writeln('seek 一致性(1000-1099 == 0-1099 的对应片段): ${_eq(r2.bodyBytes, expect)}');

  // 4) 越界 Range
  final r4 = await c.get(Uri.parse(local), headers: {'Range': 'bytes=999999999-1000000000'});
  stdout.writeln('越界 Range → ${r4.statusCode} len=${r4.bodyBytes.length}');

  // 5) 无 Range（播放器首播常见）
  final sw = Stopwatch()..start();
  final r5 = await c.get(Uri.parse(local));
  sw.stop();
  stdout.writeln('无 Range → ${r5.statusCode} len=${r5.bodyBytes.length} 耗时 ${sw.elapsedMilliseconds}ms');

  c.close();
  await relay.stop();
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) { if (a[i] != b[i]) return false; }
  return true;
}
