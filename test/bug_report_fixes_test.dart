// Bug 报告修复回归测试（资料库静态审查报告）。
//
// 覆盖本次实际修复且改变了行为的点；纯防御性 / 终态单例方法
// （如 dispose 关闭广播流）因会污染进程级单例，不在共享单例上破坏性调用，
// 其正确性由静态分析与代码审查保证。
import 'package:baiji_music/core/cover_url.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/player/player_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await KvStore.ensureInit();
    await KvStore.instance.clear();
  });

  group('Bug 修复：CoverUrl.primary 空封面', () {
    test('无可用封面（albumMid 与 cover 皆空）返回空串而非抛 StateError', () {
      final song = Song(
        mid: 'm',
        songId: 1,
        name: 'n',
        singer: 's',
        album: 'a',
        albumMid: '',
        duration: 1,
        cover: '',
      );
      // 原实现直接 candidates(song).first，空列表会抛 StateError
      expect(() => CoverUrl.primary(song), returnsNormally);
      expect(CoverUrl.primary(song), '');
    });
  });

  group('Bug 修复：Song.fromTrack 字段类型容错', () {
    test('mid/name/singer 为非字符串类型时不抛，回落 toString', () {
      final track = <String, dynamic>{
        'mid': 123, // 非字符串
        'name': 456, // 非字符串
        'singer': 789, // 非字符串
        'album': 'a',
        'interval': 200,
        'id': 1,
      };
      // 原实现用 `t['mid'] as String?`，int 会抛 TypeError
      expect(() => Song.fromTrack(track), returnsNormally);
      final s = Song.fromTrack(track);
      expect(s.mid, '123');
      expect(s.name, '456');
      expect(s.singer, '789');
      expect(s.duration, 200000);
    });
  });

  group('Bug 修复：PlayerController.release 复用安全', () {
    test('release 多次调用不抛（底层 player 为 null 时安全）', () {
      final pc = PlayerController.instance;
      expect(() => pc.release(), returnsNormally);
      expect(() => pc.release(), returnsNormally);
    });

    test('release 不关闭广播流：之后 setRate 仍能正常广播', () async {
      final pc = PlayerController.instance;
      pc.release(); // 关键：不应关闭 12 个 final 广播流
      final seen = <double>[];
      final sub = pc.onRateChanged.listen(seen.add);
      await pc.setRate(1.5);
      await Future<void>.delayed(Duration.zero);
      expect(seen, contains(1.5));
      await sub.cancel();
      await pc.setRate(1.0); // 复位，避免污染其它用例
    });
  });
}
