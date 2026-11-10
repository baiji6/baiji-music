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

// 语法错误：加载即抛异常，用于验证「加载失败不再被静默吞」。
const String _pluginBroken = '''
// ==UserScript==
// @name 坏音源
// @version 0.0.1
// ==/UserScript==
const broken = ;
''';

// 正常加载但从不 send(inited)：模拟宿主环境不兼容的音源。
const String _pluginNoInited = '''
// ==UserScript==
// @name 无声明音源
// @version 0.0.2
// ==/UserScript==
globalThis.__lx_probe_no_inited = 1;
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

    test('musicInfo 按 LX-X 标准构造，主键字段按平台区分', () {
      Song song({
        String mid = 'mid1',
        int songId = 99,
        String source = Source.qq,
        String hash = '',
      }) =>
          Song(
            mid: mid,
            songId: songId,
            name: '歌名',
            singer: '歌手',
            album: '专辑',
            albumMid: 'ALBUM_MID',
            duration: 123000,
            cover: '',
            source: source,
            hash: hash,
          );

      // QQ：用 mid（songmid）。hash 必须为空，否则 ikun 的
      // `hash ?? songmid` 会优先取到一个错误值导致取链失败。
      final tx = LxMusicApi.musicInfoOf(song(), LxSubSource.tx);
      expect(tx['songmid'], 'mid1');
      expect(tx['id'], 'mid1');
      expect(tx['hash'], '');
      expect(tx['strMediaMid'], 'mid1');
      expect(tx['source'], 'tx');
      expect(tx['name'], '歌名');
      expect(tx['interval'], '2:03');
      expect(tx['albumName'], '专辑');
      expect(tx['songId'], 99);
      expect(tx['meta'], isA<Map>());
      expect((tx['types'] as List), isNotEmpty);
      expect(tx['_types'], isA<Map>());

      // 网易云：用 id（mid 形如 ne$id）。
      final wy = LxMusicApi.musicInfoOf(
          song(mid: 'ne12345', songId: 12345, source: Source.netease),
          LxSubSource.wy);
      expect(wy['id'], '12345');
      expect(wy['songmid'], '12345');
      expect(wy['hash'], '');

      // 酷我：用 id（rid）。
      final kw = LxMusicApi.musicInfoOf(
          song(mid: '1234567', source: Source.kuwo), LxSubSource.kw);
      expect(kw['id'], '1234567');
      expect(kw['songmid'], '1234567');
      expect(kw['hash'], '');

      // 酷狗：用真 FileHash，而不是 albumAudioId（Song.mid）。
      final kg = LxMusicApi.musicInfoOf(
          song(
              mid: 'ALBUM_AUDIO_ID',
              source: Source.kugou,
              hash: 'REAL_FILE_HASH'),
          LxSubSource.kg);
      expect(kg['hash'], 'REAL_FILE_HASH');
      expect((kg['meta'] as Map)['hash'], 'REAL_FILE_HASH');
      expect(kg['songmid'], 'ALBUM_AUDIO_ID');
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

    test('不兼容音源加载失败可见化（loadErrors），不再静默吞', () async {
      repo = await makeRepo([_pluginBroken, _pluginNoInited, _pluginOk]);
      api = LxMusicApi(repo: repo);
      await api.ensureLoaded();

      final errs = api.loadErrors;
      expect(errs.containsKey('坏音源'), isTrue,
          reason: '语法错误音源应记录加载失败');
      expect(errs['坏音源'], isNotEmpty);
      expect(errs.containsKey('无声明音源'), isTrue,
          reason: '加载成功但未声明 inited 也应提示');
      expect(errs['无声明音源'], contains('inited'));
      expect(errs.containsKey('测试插件A'), isFalse,
          reason: '正常音源不应出现在错误表');
      // 坏音源未进入运行时池；另外两个加载成功。
      expect(api.loadedCount, 2);
    });

    test('musicInfo interval 边界与 meta 结构固化', () {
      final s = Song(
        mid: '001X',
        songId: 5,
        name: 'N',
        singer: 'S',
        album: 'A',
        albumMid: 'AM',
        duration: 0,
        cover: '',
        source: Source.qq,
      );
      final m = LxMusicApi.musicInfoOf(s, LxSubSource.tx);
      expect(m['interval'], '');
      expect(m['typeUrl'], isA<Map>());
      expect((m['typeUrl'] as Map).isEmpty, isTrue);
      expect(m['strMediaMid'], '001X');
      expect(m['album'], 'A');
      expect(m['albumId'], 'AM');
      final meta = m['meta'] as Map;
      expect(meta['songId'], 5);
      expect(meta['songmid'], '001X');
      expect(meta['strMediaMid'], '001X');
      expect(meta['hash'], '');
      expect(meta['qualitys'], isA<List>());
      expect(meta['_qualitys'], isA<Map>());
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
