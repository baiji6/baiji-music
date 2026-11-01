// MV 功能单元测试（v2.4.3）——纯逻辑，不发真实网络请求。
//
// 覆盖：
//   - Song.mvId：QQ fromTrack（vt 过滤/纯数字 vid 过滤）、持久化 round-trip
//   - MvQuality：fromKey 容错
//   - QQMvApi：vid 有效性、mp4 双形态归一、code 过滤、挑流策略
//   - KuwoMvApi：anymatch key=value 行文本解析、画质映射
//   - NeteaseMvApi：data 对象/数组双形态兼容
//   - MvProxyServer：代理 URL 注册与会话隔离
import 'dart:convert';

import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/mv/kuwo_mv.dart';
import 'package:baiji_music/network/mv/mv_proxy.dart';
import 'package:baiji_music/network/mv/mv_source.dart';
import 'package:baiji_music/network/mv/netease_mv.dart';
import 'package:baiji_music/network/mv/qq_mv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Song.mvId（QQ fromTrack）', () {
    test('mv.vid 正常带出', () {
      final s = Song.fromTrack({
        'mid': '0039MnYb0qxYhV',
        'name': '晴天',
        'mv': {'id': 293791, 'vid': 'w0026q7f01a', 'vt': 0},
      });
      expect(s.mvId, 'w0026q7f01a');
    });

    test('vt != 0（翻唱/关联位）不当作 MV', () {
      final s = Song.fromTrack({
        'mid': '004OmEt53sLWcn',
        'name': '晴天',
        'mv': {'id': 0, 'vid': 'w0026q7f01a', 'vt': 1},
      });
      expect(s.mvId, '');
    });

    test('纯数字 vid（旧 mvId）不当作有效 vid', () {
      final s = Song.fromTrack({
        'mid': 'x',
        'name': 'x',
        'mv': {'id': 123, 'vid': 456, 'vt': 0},
      });
      expect(s.mvId, '');
    });

    test('无 mv 字段 → 空串，且持久化 round-trip 不丢', () {
      final s = Song.fromTrack({'mid': 'a', 'name': 'a'});
      expect(s.mvId, '');

      final s2 = Song.fromTrack({
        'mid': 'b',
        'name': 'b',
        'mv': {'id': 1, 'vid': 'v001', 'vt': 0},
      });
      final restored = Song.fromJson(jsonDecode(jsonEncode(s2.toJson()))
          as Map<String, dynamic>);
      expect(restored.mvId, 'v001');

      // 无 MV 的歌 toJson 不写入 mvId 键
      expect(s.toJson().containsKey('mvId'), isFalse);
    });
  });

  group('MvQuality.fromKey', () {
    test('标准 key 与容错', () {
      expect(MvQuality.fromKey('1080p'), MvQuality.q1080p);
      expect(MvQuality.fromKey('1080P'), MvQuality.q1080p);
      expect(MvQuality.fromKey('4k'), MvQuality.q4k);
      expect(MvQuality.fromKey('uhd'), MvQuality.q4k);
      expect(MvQuality.fromKey('2160p'), MvQuality.q4k);
      expect(MvQuality.fromKey('720'), MvQuality.q720p);
      expect(MvQuality.fromKey(''), MvQuality.q1080p);
      expect(MvQuality.fromKey(null), MvQuality.q1080p);
    });
  });

  group('QQMvApi', () {
    test('isVidValid：字符串 vid 有效，纯数字/空无效', () {
      expect(QQMvApi.isVidValid('w0026q7f01a'), isTrue);
      expect(QQMvApi.isVidValid('  w0026q7f01a '), isTrue);
      expect(QQMvApi.isVidValid('293791'), isFalse);
      expect(QQMvApi.isVidValid(''), isFalse);
      expect(QQMvApi.isVidValid(null), isFalse);
    });

    test('mp4 双形态归一 + code 过滤', () {
      // 实测响应是数组形态；map 形态（filetype 为 key）也见过
      final asMap = {
        '10': {'filetype': 10, 'code': 0, 'freeflow_url': ['http://a']},
        '20': {'filetype': 20, 'code': 1000, 'freeflow_url': []},
      };
      final streams = QQMvApi.isStreamUsableForTest({
        'filetype': 10,
        'code': 0,
        'freeflow_url': ['http://a'],
      });
      expect(streams, isTrue);
      expect(QQMvApi.isStreamUsableForTest(
          {'filetype': 40, 'code': 1000, 'freeflow_url': []}), isFalse);
      expect(asMap.length, 2);
    });

    test('挑流：精确命中 → 不超过目标的最大档 → 最低档', () {
      final usable = [
        {'filetype': 10, 'code': 0, 'freeflow_url': ['360']}, // 360p
        {'filetype': 30, 'code': 0, 'freeflow_url': ['720']}, // 720p
        {'filetype': 50, 'code': 0, 'freeflow_url': ['4k']}, // 4k
      ];
      // 请求 1080p：无精确 → 不超过 1080 的最大 = 720p
      expect(QQMvApi.pickStream(usable, MvQuality.q1080p)?['freeflow_url'],
          ['720']);
      // 请求 360p：精确命中
      expect(QQMvApi.pickStream(usable, MvQuality.q360p)?['freeflow_url'],
          ['360']);
      // 请求 240p：全都高于目标 → 最低档 360p
      expect(QQMvApi.pickStream(usable, MvQuality.q240p)?['freeflow_url'],
          ['360']);
      // 请求 4k：精确命中
      expect(QQMvApi.pickStream(usable, MvQuality.q4k)?['freeflow_url'], ['4k']);
      expect(QQMvApi.pickStream(const [], MvQuality.q1080p), isNull);
    });

    test('qualityOf：filetype 映射', () {
      expect(QQMvApi.qualityOf({'filetype': 10}).key, '360p');
      expect(QQMvApi.qualityOf({'filetype': 40}).key, '1080p');
      expect(QQMvApi.qualityOf({'filetype': 50}).key, '4k');
      expect(QQMvApi.qualityOf({'filetype': 99}).key, '480p');
    });
  });

  group('KuwoMvApi.parseKvResponse（anymatch 行文本）', () {
    test('标准解析', () {
      const body = '''
url=https://kw-bj.kuwo.cn/x/y.mp4
format=mp4
quality=MP4BD
bitrate=3553
\r\n
garbage-line-without-equals
=empty-key-ignored
''';
      final kv = KuwoMvApi.parseKvResponse(body);
      expect(kv['url'], 'https://kw-bj.kuwo.cn/x/y.mp4');
      expect(kv['format'], 'mp4');
      expect(kv['quality'], 'MP4BD');
      expect(kv['bitrate'], '3553');
      expect(kv.containsKey('garbage-line-without-equals'), isFalse);
      expect(kv.containsKey(''), isFalse);
    });

    test('画质映射表与脚本一致', () {
      expect(KuwoMvApi.responseQualityMapForTest['MP4L'], MvQuality.q240p);
      expect(KuwoMvApi.responseQualityMapForTest['MP4'], MvQuality.q360p);
      expect(KuwoMvApi.responseQualityMapForTest['MP4HV'], MvQuality.q480p);
      expect(KuwoMvApi.responseQualityMapForTest['MP4UL'], MvQuality.q720p);
      expect(KuwoMvApi.responseQualityMapForTest['MP4BD'], MvQuality.q1080p);
      expect(KuwoMvApi.requestQualityMapForTest[MvQuality.q1080p], 'MP4BD');
      expect(KuwoMvApi.requestQualityMapForTest[MvQuality.q360p], 'MP4');
    });
  });

  group('NeteaseMvApi.pickDataItemForTest（data 双形态）', () {
    test('对象形态直接用', () {
      final item = NeteaseMvApi.pickDataItemForTest({
        'url': 'http://a.mp4',
        'r': 1080,
        'size': 1,
      });
      expect(item?['url'], 'http://a.mp4');
    });

    test('数组形态取第一个有 url 的', () {
      final item = NeteaseMvApi.pickDataItemForTest([
        {'code': 404, 'url': null},
        {'url': 'http://b.mp4', 'r': 720},
      ]);
      expect(item?['url'], 'http://b.mp4');
      expect(item?['r'], 720);
    });

    test('url 全空 / 空数组 / 非法类型 → null', () {
      expect(NeteaseMvApi.pickDataItemForTest([
        {'url': null},
      ])?['url'], isNull);
      expect(NeteaseMvApi.pickDataItemForTest(const []), isNull);
      expect(NeteaseMvApi.pickDataItemForTest('junk'), isNull);
    });
  });

  group('MvProxyServer', () {
    test('register 返回 127.0.0.1 地址，多次注册互不覆盖', () async {
      final server = MvProxyServer.instance;
      final u1 = await server.register(const MvSource(
        url: 'http://example.com/a.mp4',
        videoQuality: '1080p',
        headers: {'Referer': 'https://example.com/'},
      ));
      final u2 = await server.register(const MvSource(
        url: 'http://example.com/b.mp4',
        videoQuality: '720p',
      ));
      expect(u1.startsWith('http://127.0.0.1:'), isTrue);
      expect(u1.contains('/mv/'), isTrue);
      expect(u1, isNot(u2));
      await server.stop();
    });

    test('停止后再注册会自动重启并拿到新地址', () async {
      final server = MvProxyServer.instance;
      final u1 = await server.register(const MvSource(
        url: 'http://example.com/a.mp4',
        videoQuality: '1080p',
      ));
      await server.stop();
      final u2 = await server.register(const MvSource(
        url: 'http://example.com/c.mp4',
        videoQuality: '480p',
      ));
      expect(u2.startsWith('http://127.0.0.1:'), isTrue);
      // stop 后端口会变（重新 bind(0)），token 也不复用
      expect(u2.split('/mv/').last, isNot(u1.split('/mv/').last));
      await server.stop();
    });
  });
}
