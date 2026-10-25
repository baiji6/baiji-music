// v2.4.0-fix2 回归测试：
//   1. 酷我音质档位补齐（7 → 18，与 KuwoLink.qualityRules 一一对应）
//   2. 平台标识 getter（Song.sourceShort / sourceFull）不再把酷我显示成 QQ
//   3. 播放缓存（PlaybackCache）块读写 / 清理
//   4. 解密中继的「块路径」：Range 正确性、缓存命中不再回源、seek 任意偏移
//   5. QQ 直链接入（v2.4.2）：注入式 cipher（TEA ekey 在网络层解好），
//      中继对两种 ekey 封装（酷我 DES / QQ TEA）走同一条通道
//
// 中继测试用**真实 ekey + 真实 QMC v2 密钥派生链**（与 kuwo_qmc_test.dart 同源），
// 再按 256 KiB 块放大到 2 个整块以上，覆盖跨块 Range 请求。
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:baiji_music/core/cache_manager.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/kuwo/kuwo_link.dart';
import 'package:baiji_music/decrypt/qmc.dart';
import 'package:baiji_music/network/kuwo/qmc_cipher.dart';
import 'package:baiji_music/network/kuwo/qmc_stream.dart';
import 'package:baiji_music/player/playback_cache.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实 ekey（酷我 rid=7149583，mflac 母带档）—— 与 kuwo_qmc_test.dart 同源。
const String _ekey =
    'bTgBdGLJnnTNvrhvqftrAyZVw7SZHjZ7+sySatLRSm90PxvdlDre34YNNj3VANugw4EkqZmW'
    'XQr0wYe4SVMBHptMnxZTeoOg24zd+vK2r5lxbelKgwi+t0yRMcjU9VYpnKHZCzCosTaLvOiJ'
    '8zaMIfCijshYFQ5qOuiIlGlXJ4dyRNjbtz/tyWH8UMGVH0l4rKw6Yw9wn4jDGfqhQ9ksmzK5'
    'YQPmJBqyRUUjn1Wh8GOmQ5ksV+694I7nVrEoUoeejGlDmmfaMOAXa2MDuJiN4SBUAkp3pUGr'
    'bhB/F77+UXRjDK5dQ/oWOvqIa0lJ6rDqxV2IkijXkFpG8oVW56A0eBzIiCAmOYml5J96Bl5y'
    'YulGOhhlmS1saE3k/jPqE82UJcVOgT1m4zjTePw7+aQsMBSf05D2++au5LCj/3aZYxZVj/+E'
    'RyBhm4c2oXL/qk1+Z9U15QU6F7LEDjQXoyh5Pe14pIitSoq6vwqhbPgM3RRrRsJTteHNRvFY'
    'xRLWfRT+AAHMRyTPpJgTJtErh+tRqOhjwfNRnqDBkwRNYsZaINSV70kfrNC1D2mD8lEjOr5C'
    'BZO06RnaHXn83DgeKkWGjkhqK/1aPh7kjNZzoNL0SuIBsFLhsGCNtX7n9VvF9suH8+cMR64w'
    'IAddEzGVWgbPx475gEbBzphMeAtcfjacevNE/WolZMM2qQLXCuVvG/wQkNfgQmLWbfToCPJM'
    'ToPaNoZukf3AKB1kC4NYIGFniWvbCFaa/aQ/JVx95ssOqVYSl8CdC8r2jRAbjxCX4fLI1ZBK'
    'h4oeuz0mLUHcqfO0rme+Js8zl5gbD9zrBIfVOBVwR2qfTzXkK0HIQ3CNlIKY5tCRREsNWF9D'
    'QKfOXqZ7oLm1Xu7gicCrd72MLgwoVrJUH2YGIXVWnr6eDRKAK+sW7dFpyLukud09kNIqDSlr'
    '6UWWg+NNA4Zvxg==';

class FakePathProvider extends PathProviderPlatform {
  FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationCachePath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getExternalStoragePath() async => root;

  @override
  Future<String?> getDownloadsPath() async => root;
}

/// flutter_test 默认在 binding 初始化时把 `HttpOverrides.global` 换成
/// 「一律回 400 的空响应」的假实现（`setupHttpOverrides`，
/// 见 `flutter_test/lib/src/_binding_io.dart`），
/// 于是任何 `HttpClient()` 都发不出真实请求。
///
/// 中继测试要起真 `HttpServer` 并且真的去取数据，所以在该组 `setUpAll` 里
/// 把 `HttpOverrides.global` 置回 `null`——`HttpOverrides.current` 返回 null 时
/// `HttpClient()` 工厂会直接造真实的 `_HttpClient`，即恢复默认行为。
/// （`flutter test` 每个测试文件一个独立 isolate，不会影响别的文件。）

/// 假的酷我 CDN：按 Range 返回密文字节，并记录每次请求的 Range 头。
class _FakeCdn {
  _FakeCdn(this.body);
  final Uint8List body;
  final List<String> ranges = <String>[];
  HttpServer? _server;

  int get requestCount => ranges.length;

  Future<int> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      final r = req.headers.value(HttpHeaders.rangeHeader);
      ranges.add(r ?? '');
      var start = 0;
      var end = body.length - 1;
      if (r != null) {
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(r);
        if (m != null) {
          start = int.parse(m.group(1)!);
          end = int.parse(m.group(2)!);
        }
      }
      if (start >= body.length || end < start) {
        req.response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..write('nope');
        await req.response.close();
        return;
      }
      final to = min(end, body.length - 1);
      final res = req.response;
      res
        ..statusCode = HttpStatus.partialContent
        ..headers.contentType = ContentType('audio', 'flac')
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-$to/${body.length}');
      res.add(Uint8List.sublistView(body, start, to + 1));
      await res.close();
    });
    return _server!.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }
}

/// 带 Range 取一次中继数据。
Future<Uint8List> _fetch(String url, {int? start, int? end}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    if (start != null || end != null) {
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=${start ?? 0}-${end ?? ''}');
    }
    final res = await req.close();
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
    }
    return Uint8List.fromList(bytes);
  } finally {
    client.close(force: true);
  }
}

void main() {
  Directory? rootDir;

  Future<Directory> ensureRoot(String prefix) async {
    if (rootDir == null) {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      await KvStore.ensureInit();
      rootDir = await Directory.systemTemp.createTemp(prefix);
      PathProviderPlatform.instance = FakePathProvider(rootDir!.path);
    }
    return rootDir!;
  }

  /// 播放缓存目录（受 CacheManager 托管）。
  Future<Directory> playbackDir() async {
    final root = await ensureRoot('baiji_test');
    return Directory('${root.path}${Platform.pathSeparator}cache'
        '${Platform.pathSeparator}${CacheManager.playbackDirName}');
  }

  Future<void> resetPlaybackCache() async {
    final dir = await playbackDir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  group('酷我音质档位（v2.4.0-fix2 补齐到接口全部 18 档）', () {
    test('downloadOptions 与 KuwoLink.qualityRules 一一对应、同序', () {
      final rules = KuwoLink.qualityRules;
      final opts = KuwoQuality.downloadOptions;
      expect(opts.length, rules.length);
      expect(opts.length, 18, reason: '接口实际支持 18 档，用户反馈「音质不全」');
      for (var i = 0; i < rules.length; i++) {
        final r = rules[i];
        expect(opts[i].id, r[2], reason: '第 $i 档 id 不一致');
        expect(opts[i].format, r[1], reason: '第 $i 档 format 不一致');
        expect(opts[i].bitrate, int.parse(r[0] as String),
            reason: '第 $i 档 bitrate 不一致');
        expect(opts[i].br, '${r[0]}k${r[1]}', reason: 'br 串必须能直接喂接口');
      }
    });

    test('音质按 bitrate 严格降序', () {
      final opts = KuwoQuality.downloadOptions;
      for (var i = 1; i < opts.length; i++) {
        expect(opts[i].bitrate, lessThan(opts[i - 1].bitrate));
      }
    });

    test('每一档都能被 fromId 找回', () {
      for (final q in KuwoQuality.downloadOptions) {
        expect(KuwoQuality.fromId(q.id)?.id, q.id);
        expect(KuwoQuality.fromId(q.id)?.label, q.label);
      }
    });

    test('旧版本持久化的 id 全部仍然有效（不需要迁移）', () {
      // v2.4.0 用过的 7 个 id
      for (final id in ['master', 'hires', 'flac', '300k', '320k', '128k', '48k']) {
        expect(KuwoQuality.fromId(id), isNotNull, reason: '旧 id $id 失效了');
      }
    });

    test('未知 id 返回 null 而不是瞎猜', () {
      expect(KuwoQuality.fromId('no_such_quality'), isNull);
      expect(KuwoQuality.fromId(null), isNull);
    });

    test('播放默认仍是 128k（未登录时高档位普遍不可用）', () {
      expect(KuwoQuality.playbackDefault.id, '128k');
      expect(KuwoQuality.playbackOptions.length, 18);
    });
  });

  group('平台标识（播放页 / 列表角标不再把酷我显示成 QQ）', () {
    Song s(String source, {String localPath = ''}) => Song(
          mid: 'm',
          songId: 1,
          name: '歌',
          singer: '手',
          album: '专',
          albumMid: 'a',
          duration: 1,
          cover: '',
          source: source,
          localPath: localPath,
        );

    test('sourceShort 覆盖四个音源', () {
      expect(s(Source.qq).sourceShort, 'QQ');
      expect(s(Source.netease).sourceShort, '网易云');
      expect(s(Source.kuwo).sourceShort, '酷我');
      expect(s(Source.local, localPath: '/x.mp3').sourceShort, '本地');
    });

    test('sourceFull 覆盖四个音源', () {
      expect(s(Source.qq).sourceFull, 'QQ 音乐');
      expect(s(Source.netease).sourceFull, '网易云音乐');
      expect(s(Source.kuwo).sourceFull, '酷我音乐');
      expect(s(Source.local, localPath: '/x.mp3').sourceFull, '本地音乐');
    });

    test('酷我歌曲 isKuwo 为真、isNetease 为假', () {
      final k = s(Source.kuwo);
      expect(k.isKuwo, isTrue);
      expect(k.isNetease, isFalse);
    });
  });

  group('播放缓存 PlaybackCache', () {
    setUp(() async {
      await ensureRoot('baiji_playback_test');
      await resetPlaybackCache();
    });

    test('块边界按 256 KiB 对齐', () {
      expect(PlaybackCache.blockSize, 256 * 1024);
      expect(PlaybackCache.blockIndexOf(0), 0);
      expect(PlaybackCache.blockIndexOf(1), 0);
      expect(PlaybackCache.blockIndexOf(PlaybackCache.blockSize - 1), 0);
      expect(PlaybackCache.blockIndexOf(PlaybackCache.blockSize), 1);
      expect(PlaybackCache.blockStart(3), 3 * PlaybackCache.blockSize);
    });

    test('keyOf 稳定且空种子返回空串', () {
      expect(PlaybackCache.keyOf('abc'), PlaybackCache.keyOf('abc'));
      expect(PlaybackCache.keyOf('abc'), isNot(PlaybackCache.keyOf('abd')));
      expect(PlaybackCache.keyOf(''), isEmpty);
      expect(PlaybackCache.keyOf('   '), isEmpty);
    });

    test('写 → 读 → 清 闭环', () async {
      final key = PlaybackCache.keyOf('track-1');
      final data =
          Uint8List.fromList(List<int>.generate(1024, (i) => i % 251));
      await PlaybackCache.instance.write(key, 0, data);
      expect(await PlaybackCache.instance.read(key, 0), data);
      expect(await PlaybackCache.instance.read(key, 1), isNull);

      final size = await PlaybackCache.instance.sizeBytes();
      expect(size, greaterThanOrEqualTo(1024));

      final freed = await PlaybackCache.instance.clear();
      expect(freed, greaterThanOrEqualTo(1024));
      expect(await PlaybackCache.instance.read(key, 0), isNull);
      expect(await PlaybackCache.instance.sizeBytes(), 0);
    });

    test('非法入参与空数据不抛异常', () async {
      expect(await PlaybackCache.instance.read('', 0), isNull);
      expect(await PlaybackCache.instance.read('k', -1), isNull);
      await PlaybackCache.instance.write('k', 0, Uint8List(0));
      await PlaybackCache.instance.write('', 0, Uint8List.fromList([1]));
      expect(await PlaybackCache.instance.read('k', 0), isNull);
    });
  });

  group('QMC 中继 · 块路径 + 播放缓存', () {
    late _FakeCdn cdn;
    late String relayUrl;
    late Uint8List plain;
    late QmcRelayServer relay;

    setUpAll(() {
      // 让本 isolate 里的 HttpClient 走真实网络：
      // flutter_test 的 `setupHttpOverrides` 会把它换成一律回 400 的假实现，
      // 置回 null 即恢复 dart:io 的默认行为（详见文件顶部的说明）。
      HttpOverrides.global = null;
    });

    setUp(() async {
      await ensureRoot('baiji_relay_test');
      await resetPlaybackCache();

      // 用真实 ekey 造一份跨多个 256 KiB 块的密文：
      // QMC v2 是 XOR 类流密码（首段查表层 + RC4 段），decrypt 自反，
      // 所以 decrypt(明文) 就是密文。
      final rnd = Random(20240717);
      final plainLen = PlaybackCache.blockSize * 2 + 12345;
      plain = Uint8List.fromList(
          List<int>.generate(plainLen, (_) => rnd.nextInt(256)));
      plain[0] = 0x66; // f
      plain[1] = 0x4C; // L
      plain[2] = 0x61; // a
      plain[3] = 0x43; // C

      final cipher = QmcKeyDerivation.createCipherFromEkey(_ekey);
      final enc = cipher.decrypt(plain, 0);

      cdn = _FakeCdn(enc);
      final cdnPort = await cdn.start();

      relay = QmcRelayServer();
      await relay.start();
      relayUrl = relay.urlFor('http://127.0.0.1:$cdnPort/track.flac', _ekey,
          ext: 'flac');
    });

    tearDown(() async {
      await cdn.stop();
    });

    test('Range 请求逐字节等于明文对应区间', () async {
      final got = await _fetch(relayUrl, start: 0, end: 1023);
      expect(got, Uint8List.sublistView(plain, 0, 1024));
    });

    test('跨块 Range（第 1 块尾 + 第 2 块头）也正确', () async {
      final s = PlaybackCache.blockSize - 100;
      final e = PlaybackCache.blockSize + 100;
      final got = await _fetch(relayUrl, start: s, end: e);
      expect(got, Uint8List.sublistView(plain, s, e + 1));
    });

    test('末块不满一个块大小时正确', () async {
      final last = PlaybackCache.blockSize * 2;
      final got = await _fetch(relayUrl, start: last, end: plain.length - 1);
      expect(got, Uint8List.sublistView(plain, last, plain.length));
    });

    test('seek 到任意偏移都正确（拖动进度条）', () async {
      for (final off in [0, 1, 127, 128, 5119, 5120, 5121, 12345, 65536]) {
        final got = await _fetch(relayUrl, start: off, end: off + 255);
        expect(got, Uint8List.sublistView(plain, off, off + 256),
            reason: '偏移 $off 解密不对');
      }
    });

    test('无 Range 请求返回整段明文', () async {
      final got = await _fetch(relayUrl);
      expect(got.length, plain.length);
      expect(got, plain);
    });

    test('第二次请求同一区间命中缓存，不再回源', () async {
      final a = await _fetch(relayUrl, start: 0, end: 4095);
      final after = cdn.requestCount;
      final b = await _fetch(relayUrl, start: 0, end: 4095);
      expect(b, a);
      expect(cdn.requestCount, after,
          reason: '缓存命中了就不该再向 CDN 发请求');
      final size = await PlaybackCache.instance.sizeBytes();
      expect(size, greaterThan(0));
    });

    test('缓存内容与明文一致（落盘的就是解密后的音频）', () async {
      await _fetch(relayUrl, start: 0, end: 4095);
      final key = PlaybackCache.keyOf(_ekey);
      final blk = await PlaybackCache.instance.read(key, 0);
      expect(blk, isNotNull);
      expect(blk!.length, min(PlaybackCache.blockSize, plain.length));
      expect(Uint8List.sublistView(blk, 0, 4096),
          Uint8List.sublistView(plain, 0, 4096));
    });

    test('清理播放缓存后不再命中', () async {
      await _fetch(relayUrl, start: 0, end: 4095);
      final before = cdn.requestCount;
      await PlaybackCache.instance.clear();
      await _fetch(relayUrl, start: 0, end: 4095);
      expect(cdn.requestCount, greaterThan(before),
          reason: '清完缓存应当回源');
    });
  });

  group('QMC 中继 · QQ 直链（v2.4.2，注入式 cipher）', () {
    // QQ 的 ekey 是 TEA 包装（decrypt/qmc_ekey.dart 解），网络层解好后
    // 把「按文件偏移原地解密」的 cipher 注入中继——这里用 512 字节随机
    // raw key 直接构造 QmcV2Cipher（自动落在 RC4 模式，与真实样本一致），
    // 不依赖任何真实 ekey / 网络。
    late _FakeCdn cdn;
    late String relayUrl;
    late Uint8List plain;
    late QmcRelayServer relay;

    setUpAll(() {
      HttpOverrides.global = null;
    });

    setUp(() async {
      await ensureRoot('baiji_relay_qq_test');
      await resetPlaybackCache();

      final rnd = Random(20260325);
      final plainLen = PlaybackCache.blockSize + 54321;
      plain = Uint8List.fromList(
          List<int>.generate(plainLen, (_) => rnd.nextInt(256)));
      plain[0] = 0x66; // f
      plain[1] = 0x4C; // L
      plain[2] = 0x61; // a
      plain[3] = 0x43; // C

      // 「加密」：QMC 流密码自反，对明文跑一遍 decrypt 即得密文
      final rawKey =
          Uint8List.fromList(List<int>.generate(512, (_) => rnd.nextInt(256)));
      final cipher = QmcV2Cipher(rawKey);
      final enc = Uint8List.fromList(plain);
      cipher.decrypt(enc, 0);

      cdn = _FakeCdn(enc);
      final cdnPort = await cdn.start();

      relay = QmcRelayServer();
      await relay.start();
      relayUrl = relay.urlFor(
        'http://127.0.0.1:$cdnPort/track.mflac',
        'qq-tea-wrapped-ekey-not-used-here',
        ext: 'flac',
        // 生产路径同款适配：QmcV2Cipher 是 void 原地语义
        cipher: InPlaceQmcCipher(QmcV2Cipher(rawKey).decrypt),
      );
    });

    tearDown(() async {
      await cdn.stop();
    });

    test('注入 cipher 后 Range 输出与明文一致', () async {
      final got = await _fetch(relayUrl, start: 0, end: 1023);
      expect(got, Uint8List.sublistView(plain, 0, 1024));
    });

    test('跨 RC4 段的 seek 与明文一致', () async {
      final s0 = 0x1400 - 100;
      final got = await _fetch(relayUrl, start: s0, end: s0 + 511);
      expect(got, Uint8List.sublistView(plain, s0, s0 + 512));
    });

    test('无 Range 整段输出与明文一致', () async {
      final got = await _fetch(relayUrl);
      expect(got, plain);
    });
  });
}
