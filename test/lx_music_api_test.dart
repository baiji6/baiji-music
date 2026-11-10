import 'dart:io';

import 'package:baiji_music/lx/lx_music_api.dart';
import 'package:baiji_music/lx/lx_source.dart';
import 'package:baiji_music/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const String _pluginOk = '''
// ==UserScript==
// @name 测试插件A
// @version 1.0.0
// ==/UserScript==
const { EVENT_NAMES, on, send } = globalThis.lx
send(EVENT_NAMES.inited, { status: true, sources: {
  kw: { name: 'kw', type: 'music', actions: ['musicUrl'], qualitys: ['128k', 'flac'] },
  tx: { name: 'tx', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] }
} })
on(EVENT_NAMES.request, async ({ action, source, info }) => {
  if (action !== 'musicUrl') throw new Error('unsupported action')
  return 'http://cdn/a.flac?type=' + info.type + '&id=' + info.musicInfo.songmid + '&src=' + source
})
''';

const String _pluginFail = '''
// ==UserScript==
// @name 测试插件B
// @version 1.0.0
// ==/UserScript==
const { EVENT_NAMES, on, send } = globalThis.lx
send(EVENT_NAMES.inited, { status: true, sources: {
  kw: { name: 'kw', type: 'music', actions: ['musicUrl'], qualitys: ['128k'] }
} })
on(EVENT_NAMES.request, async () => { throw new Error('boom') })
''';

void main() {
  group('LxQuality 音质映射 / 裁剪', () {
    test('App 各平台音质对象 → 洛雪档位', () {
      expect(LxQuality.from(Quality.mp3_128), '128k');
      expect(LxQuality.from(Quality.mp3_320), '320k');
      expect(LxQuality.from(Quality.flac), 'flac');
      expect(LxQuality.from(Quality.hires), 'hires');
      expect(LxQuality.from(Quality.master), 'master');
      expect(LxQuality.from(NeteaseQuality.exhigh), '320k');
      expect(LxQuality.from(NeteaseQuality.lossless), 'flac');
      expect(LxQuality.from(NeteaseQuality.hires), 'hires');
      expect(LxQuality.from('flac24bit'), 'flac24bit');
      expect(LxQuality.from(null), '128k');
    });

    test('按插件声明裁剪 / 降级', () {
      expect(LxQuality.pick('flac', ['128k', 'flac']), 'flac');
      expect(LxQuality.pick('master', ['128k', 'flac']), 'flac');
      expect(LxQuality.pick('hires', ['128k', '320k']), '320k');
      expect(LxQuality.pick('master', []), 'master');
    });
  });

  group('LxSubSource 平台映射', () {
    test('原生平台 → 洛雪子源', () {
      expect(LxSubSource.fromApp(Source.qq), 'tx');
      expect(LxSubSource.fromApp(Source.netease), 'wy');
      expect(LxSubSource.fromApp(Source.kuwo), 'kw');
      expect(LxSubSource.fromApp(Source.kugou), 'kg');
    });
  });

  group('LxMusicApi 取流路由', () {
    late Directory temp;
    late LxSourceRepo repo;
    late LxMusicApi api;

    Future<LxSourceRepo> makeRepo(List<String> scripts) async {
      temp = await Directory.systemTemp.createTemp('lx_api_test');
      final r = LxSourceRepo(directory: () async => temp);
      for (var i = 0; i < scripts.length; i++) {
        await r.add(script: scripts[i], sourceUrl: 'https://example/p$i.js');
      }
      return r;
    }

    tearDown(() async {
      api.closeAll();
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('加载插件并 dispatch musicUrl 拿到直链', () async {
      repo = await makeRepo([_pluginOk]);
      api = LxMusicApi(repo: repo);
      await api.ensureLoaded();
      expect(api.loadedCount, 1);
      expect(api.availableSubSources(), containsAll(<String>['kw', 'tx']));

      final res = await api.musicUrl(
        subSource: 'kw',
        quality: 'flac',
        musicInfo: LxMusicApi.musicInfoOf(
            Song(
              mid: '001XYZ',
              songId: 1,
              name: '测试曲',
              singer: '歌手',
              album: '专辑',
              albumMid: '',
              duration: 200000,
              cover: '',
              source: Source.lx,
              lxSource: 'kw',
            ),
            'kw'),
      );
      expect(res.ok, isTrue);
      expect(res.url, contains('type=flac'));
      expect(res.url, contains('id=001XYZ'));
      expect(res.pluginName, '测试插件A');
    });

    test('请求档位超出插件声明时自动降级', () async {
      repo = await makeRepo([_pluginOk]);
      api = LxMusicApi(repo: repo);
      final res = await api.musicUrlForSong(
        Song(
          mid: 'abc',
          songId: 2,
          name: 'x',
          singer: '',
          album: '',
          albumMid: '',
          duration: 0,
          cover: '',
          source: Source.lx,
          lxSource: 'kw',
        ),
        Quality.master,
      );
      // kw 只声明 128k/flac，master 降到 flac
      expect(res.ok, isTrue);
      expect(res.url, contains('type=flac'));
      expect(res.quality, 'flac');
    });

    test('某插件取链失败自动切到下一个插件', () async {
      repo = await makeRepo([_pluginFail, _pluginOk]);
      api = LxMusicApi(repo: repo);
      final res = await api.musicUrl(
        subSource: 'kw',
        quality: '128k',
        musicInfo: {'songmid': 'S1'},
      );
      expect(res.ok, isTrue);
      expect(res.pluginName, '测试插件A');
    });

    test('所有插件都失败返回 empty；无插件支持该子源也返回 empty', () async {
      repo = await makeRepo([_pluginFail]);
      api = LxMusicApi(repo: repo);
      expect((await api.musicUrl(
              subSource: 'kw', quality: '128k', musicInfo: {'songmid': 'x'}))
          .ok, isFalse);
      expect((await api.musicUrl(
              subSource: 'wy', quality: '128k', musicInfo: {'songmid': 'x'}))
          .ok, isFalse);
    });

    test('musicInfo 同时给出 songmid / hash / 基本信息', () {
      final m = LxMusicApi.musicInfoOf(
        Song(
          mid: 'mid1',
          songId: 99,
          name: '歌名',
          singer: '歌手',
          album: '专辑',
          albumMid: '',
          duration: 123000,
          cover: '',
        ),
        'kg',
      );
      expect(m['songmid'], 'mid1');
      expect(m['hash'], 'mid1');
      expect(m['songId'], 99);
      expect(m['source'], 'kg');
      expect(m['name'], '歌名');
    });

    test('无 ekey 时不走中继，带 ekey 时换成本地解密地址', () async {
      const url = 'http://cdn/x.mflac';
      expect(await LxMusicApi.resolveEncrypted(url, '', 'mflac'), url);
      final relayed = await LxMusicApi.resolveEncrypted(url, 'TEST_EKEY', 'mflac');
      expect(relayed, contains('127.0.0.1'));
      expect(relayed, contains('.flac'));
      expect(relayed, isNot(equals(url)));
    });

    test('失败结果带结构化原因（pluginsNotLoaded / subSourceUnsupported / pluginError）',
        () async {
      repo = await makeRepo([_pluginFail]);
      api = LxMusicApi(repo: repo);

      final allFail = await api.musicUrl(
          subSource: 'kw', quality: '128k', musicInfo: {'songmid': 'x'});
      expect(allFail.ok, isFalse);
      expect(allFail.reason, LxFailReason.pluginError);
      expect(allFail.reasonText, contains('取链失败'));
      expect(allFail.error, contains('boom'));

      final noSub = await api.musicUrl(
          subSource: 'wy', quality: '128k', musicInfo: {'songmid': 'x'});
      expect(noSub.reason, LxFailReason.subSourceUnsupported);
      expect(noSub.reasonText, contains('子源'));

      final emptyTemp = await Directory.systemTemp.createTemp('lx_no_plugin');
      try {
        final emptyApi =
            LxMusicApi(repo: LxSourceRepo(directory: () async => emptyTemp));
        final notLoaded = await emptyApi.musicUrl(
            subSource: 'kw', quality: '128k', musicInfo: {'songmid': 'x'});
        expect(notLoaded.reason, LxFailReason.pluginsNotLoaded);
        expect(notLoaded.reasonText, contains('未加载'));
        emptyApi.closeAll();
      } finally {
        if (await emptyTemp.exists()) await emptyTemp.delete(recursive: true);
      }
    });

    test('pluginInfos 暴露插件声明（音源测试页下拉数据源）', () async {
      repo = await makeRepo([_pluginOk, _pluginFail]);
      api = LxMusicApi(repo: repo);
      await api.ensureLoaded();
      final infos = api.pluginInfos;
      expect(infos.length, 2);
      final ok = infos.firstWhere((i) => i.name == '测试插件A');
      expect(ok.sources.containsKey('kw'), isTrue);
      expect(ok.supports('kw'), isTrue);
      expect(ok.supports('mg'), isFalse);
      expect(ok.qualitysOf('kw'), containsAll(<String>['128k', 'flac']));
      expect(ok.display, contains('测试插件A'));
    });

    test('pluginId 只命中指定插件，不被其它插件静默补链', () async {
      repo = await makeRepo([_pluginFail, _pluginOk]);
      api = LxMusicApi(repo: repo);
      await api.ensureLoaded();
      final infos = api.pluginInfos;
      final failId = infos.firstWhere((i) => i.name == '测试插件B').id;
      final okId = infos.firstWhere((i) => i.name == '测试插件A').id;

      // 不指定 pluginId：B 失败后自动切到 A（原行为保留）。
      final auto = await api.musicUrl(
          subSource: 'kw', quality: '128k', musicInfo: {'songmid': 'x'});
      expect(auto.ok, isTrue);
      expect(auto.pluginName, '测试插件A');

      // 单独测 B：不能因为 A 可用就误判 B 可用。
      final onlyFail = await api.musicUrl(
        subSource: 'kw',
        quality: '128k',
        musicInfo: {'songmid': 'x'},
        pluginId: failId,
      );
      expect(onlyFail.ok, isFalse);
      expect(onlyFail.reason, LxFailReason.pluginError);

      // 单独测 A：正常拿到直链。
      final onlyOk = await api.musicUrl(
        subSource: 'kw',
        quality: '128k',
        musicInfo: {'songmid': 'x'},
        pluginId: okId,
      );
      expect(onlyOk.ok, isTrue);
      expect(onlyOk.pluginName, '测试插件A');

      // 不存在的 id：如实失败。
      final missing = await api.musicUrl(
        subSource: 'kw',
        quality: '128k',
        musicInfo: {'songmid': 'x'},
        pluginId: 'not-exist',
      );
      expect(missing.ok, isFalse);
      expect(missing.reason, LxFailReason.pluginsNotLoaded);
      expect(missing.error, contains('not-exist'));
    });
  });

  group('LxPlayResult 失败原因文案', () {
    test('reasonText 中文映射覆盖全部原因', () {
      expect(LxPlayResult.failed(LxFailReason.pluginsNotLoaded).reasonText,
          contains('未加载'));
      expect(LxPlayResult.failed(LxFailReason.subSourceUnsupported).reasonText,
          contains('子源'));
      expect(LxPlayResult.failed(LxFailReason.qualityUnsupported).reasonText,
          contains('音质'));
      expect(LxPlayResult.failed(LxFailReason.pluginError).reasonText,
          contains('取链失败'));
      expect(LxPlayResult.failed(LxFailReason.timeout).reasonText,
          contains('超时'));
      expect(LxPlayResult.failed(LxFailReason.emptyUrl).reasonText,
          contains('空链接'));
      expect(LxPlayResult.empty.reasonText, isEmpty);
    });
  });
}
