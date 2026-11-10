import 'dart:io';

import 'package:baiji_music/lx/lx_music_api.dart';
import 'package:baiji_music/lx/lx_source.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:baiji_music/network/source_fallback.dart';
import 'package:flutter_test/flutter_test.dart';

const String _plugin = '''
// ==UserScript==
// @name 补链插件
// @version 1.0.0
// ==/UserScript==
const { EVENT_NAMES, on, send } = globalThis.lx
send(EVENT_NAMES.inited, { status: true, sources: {
  tx: { name: 'tx', type: 'music', actions: ['musicUrl'], qualitys: ['128k', 'flac'] }
} })
on(EVENT_NAMES.request, async ({ action, info }) => {
  return 'http://cdn/fallback.flac?type=' + info.type
})
''';

Song _song({String source = Source.qq, String lxSource = ''}) => Song(
      mid: '001ABC',
      songId: 7,
      name: '测试歌曲',
      singer: '歌手',
      album: '专辑',
      albumMid: '',
      duration: 180000,
      cover: '',
      source: source,
      lxSource: lxSource,
    );

void main() {
  group('SourceFallback 取链失败自动切源', () {
    late Directory temp;
    late LxSourceRepo repo;
    late LxMusicApi api;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('lx_fallback_test');
      repo = LxSourceRepo(directory: () async => temp);
      await repo.add(script: _plugin, sourceUrl: 'https://example/p.js');
      api = LxMusicApi(repo: repo);
      // 模拟 App 启动时的运行时预热：热路径按 loadedCount 短路。
      await api.ensureLoaded();
    });
    tearDown(() async {
      api.closeAll();
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('原生取链失败 → 洛雪音源补链', () async {
      final out = await SourceFallback.onFailure(
        _song(),
        Quality.flac,
        enabledOverride: true,
        lxApi: api,
      );
      expect(out, isNotNull);
      expect(out!.ok, isTrue);
      expect(out.from, contains('补链插件'));
      expect(out.result.url, contains('http://cdn/fallback.flac'));
      expect(out.result.label, contains('洛雪'));
    });

    test('开关关闭时不切换', () async {
      final out = await SourceFallback.onFailure(
        _song(),
        Quality.flac,
        enabledOverride: false,
        lxApi: api,
      );
      expect(out, isNull);
    });

    test('没有可用插件时不切换', () async {
      final emptyTemp = await Directory.systemTemp.createTemp('lx_fb_empty');
      final emptyRepo = LxSourceRepo(directory: () async => emptyTemp);
      final emptyApi = LxMusicApi(repo: emptyRepo);
      final out = await SourceFallback.onFailure(
        _song(),
        Quality.flac,
        enabledOverride: true,
        lxApi: emptyApi,
      );
      expect(out, isNull);
      emptyApi.closeAll();
      if (await emptyTemp.exists()) await emptyTemp.delete(recursive: true);
    });

    test('本地歌曲不参与切换', () async {
      final local = _song().copyWith(localPath: '/tmp/a.flac');
      final out = await SourceFallback.onFailure(
        local,
        Quality.flac,
        enabledOverride: true,
        lxApi: api,
      );
      expect(out, isNull);
    });

    test('洛雪取链失败 → 回退原生（注入取链器）', () async {
      final out = await SourceFallback.onFailure(
        _song(source: Source.lx, lxSource: 'tx'),
        Quality.flac,
        enabledOverride: true,
        nativeFetch: (Song s, dynamic q) async {
          expect(s.source, Source.qq);
          return PlayUrlResult.lx('http://native/qq.mp3', quality: '128k');
        },
      );
      expect(out, isNotNull);
      expect(out!.from, 'QQ 音乐');
      expect(out.result.url, contains('native'));
    });

    test('洛雪与原生都失败 → null', () async {
      final out = await SourceFallback.onFailure(
        _song(source: Source.lx, lxSource: 'tx'),
        Quality.flac,
        enabledOverride: true,
        nativeFetch: (Song s, dynamic q) async => PlayUrlResult.empty,
      );
      expect(out, isNull);
    });

    test('纯洛雪模式整体短路：lx 与 qq 歌曲都不回退原生 / 不二次补链',
        () async {
      var nativeCalls = 0;
      Future<PlayUrlResult> nativeFetch(Song s, dynamic q) async {
        nativeCalls++;
        return PlayUrlResult.lx('http://native/qq.mp3', quality: '128k');
      }

      final outLx = await SourceFallback.onFailure(
        _song(source: Source.lx, lxSource: 'tx'),
        Quality.flac,
        enabledOverride: true,
        pureLxOverride: true,
        lxApi: api,
        nativeFetch: nativeFetch,
      );
      expect(outLx, isNull);

      // 非纯洛雪时这条会走「洛雪补链」成功；纯洛雪下也必须整体短路，
      // 否则会二次打同一个洛雪网关。
      final outQq = await SourceFallback.onFailure(
        _song(),
        Quality.flac,
        enabledOverride: true,
        pureLxOverride: true,
        lxApi: api,
        nativeFetch: nativeFetch,
      );
      expect(outQq, isNull);
      expect(nativeCalls, 0);
    });
  });
}
