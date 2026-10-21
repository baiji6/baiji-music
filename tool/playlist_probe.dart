// 三平台分享歌单全量解析实测（v2.4.0-fix1）
//
// 用法: dart run tool/playlist_probe.dart
import 'dart:io';

import 'package:baiji_music/network/share_playlist_api.dart';

Future<void> main() async {
  final cases = <String, String>{
    'qq': 'https://i2.y.qq.com/n3/other/pages/details/playlist.html?id=9151817147',
    'kuwo': 'https://m.kuwo.cn/newh5app/playlist_detail/3711088534',
    'netease': 'https://music.163.com/m/playlist?id=18510386873&creatorId=8991620506',
  };
  for (final e in cases.entries) {
    final sw = Stopwatch()..start();
    try {
      final pl = await SharePlaylist.parse(e.value);
      stdout.writeln('${e.key}: ${pl.name} | 曲目 ${pl.tracks.length} 首 | '
          '${sw.elapsedMilliseconds}ms | 首曲: ${pl.tracks.isEmpty ? "-" : pl.tracks.first.name}');
    } catch (err) {
      stdout.writeln('${e.key}: 失败 $err');
    }
  }
}
