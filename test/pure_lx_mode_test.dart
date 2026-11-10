import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/core/pure_lx_mode.dart';
import 'package:baiji_music/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song({
  String source = Source.qq,
  String localPath = '',
  String lxSource = '',
}) =>
    Song(
      mid: '001ABC',
      songId: 7,
      name: '测试歌曲',
      singer: '歌手',
      album: '专辑',
      albumMid: '',
      duration: 180000,
      cover: '',
      source: source,
      localPath: localPath,
      lxSource: lxSource,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 本文件刻意不在顶层 setUp 里 ensureInit，以便首条用例覆盖「KvStore
  // 未初始化」的兜底分支。每个测试文件是独立 isolate，故 KvStore 的
  // 单例在本文件开始时必为 null。
  test('KvStore 未初始化时默认开启内置音源（不抛异常）', () {
    expect(PureLxMode.nativeEnabled(), isTrue);
    expect(PureLxMode.pureLx, isFalse);
  });

  group('内置音源开关持久化', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await KvStore.ensureInit();
    });

    test('默认开启；关闭 → 纯洛雪；重新开启 → 保持现状', () async {
      expect(PureLxMode.nativeEnabled(), isTrue);
      expect(PureLxMode.pureLx, isFalse);
      await PureLxMode.setNativeEnabled(false);
      expect(PureLxMode.nativeEnabled(), isFalse);
      expect(PureLxMode.pureLx, isTrue);
      await PureLxMode.setNativeEnabled(true);
      expect(PureLxMode.nativeEnabled(), isTrue);
      expect(PureLxMode.pureLx, isFalse);
    });
  });

  group('shouldUseLx 取流路由（纯函数）', () {
    test('本地歌曲永远不走洛雪', () {
      final local = _song(localPath: '/tmp/a.flac');
      expect(PureLxMode.shouldUseLx(local, pureLxOverride: true), isFalse);
      expect(PureLxMode.shouldUseLx(local, pureLxOverride: false), isFalse);
    });

    test('洛雪歌曲无论开关都走洛雪', () {
      final lx = _song(source: Source.lx, lxSource: 'tx');
      expect(PureLxMode.shouldUseLx(lx, pureLxOverride: false), isTrue);
      expect(PureLxMode.shouldUseLx(lx, pureLxOverride: true), isTrue);
    });

    test('其它网络歌曲由纯洛雪开关 / override 决定', () {
      final qq = _song();
      expect(PureLxMode.shouldUseLx(qq, pureLxOverride: true), isTrue);
      expect(PureLxMode.shouldUseLx(qq, pureLxOverride: false), isFalse);

      final kuwo = _song(source: Source.kuwo);
      expect(PureLxMode.shouldUseLx(kuwo, pureLxOverride: true), isTrue);
    });
  });
}
