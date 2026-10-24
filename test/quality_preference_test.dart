// 音质偏好（#140 / #141）契约测试。
//
// #140：设置页应该能设置酷我的默认音质（之前只有 QQ / 网易云两项）。
// #141：播放页切音质**不能**写默认偏好，只作用于当前这一首。
//
// media_kit 的 Player 依赖 native 库，测试环境建不出实例，因此只覆盖
// 偏好层的纯逻辑：临时覆盖优先级、不被持久化、换歌失效、设置页落盘。
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
    PlayerController.instance.loadDefaultQuality();
  });

  group('#140 酷我默认音质可设置', () {
    test('saveKuwoQuality 落盘并可回读', () async {
      final p = PlayerController.instance;
      expect(p.currentKuwoQuality, KuwoQuality.playbackDefault);

      p.saveKuwoQuality(KuwoQuality.flac);
      expect(p.currentKuwoQuality.id, KuwoQuality.flac.id);

      // 模拟重启：重新从 KV 载入
      p.loadDefaultQuality();
      expect(p.currentKuwoQuality.id, KuwoQuality.flac.id);
    });

    test('播放页可选档位与模型一致（不为空且含默认档）', () {
      final options = KuwoQuality.playbackOptions;
      expect(options.isNotEmpty, isTrue);
      expect(options.map((q) => q.id),
          contains(KuwoQuality.playbackDefault.id));
    });
  });

  group('#141 播放页切音质不污染默认偏好', () {
    test('switchKuwoQuality 只改临时档，偏好不变、不落盘', () async {
      final p = PlayerController.instance;
      p.saveKuwoQuality(KuwoQuality.flac);
      final before = p.currentKuwoQuality.id;

      // 播放页切换（不 await 内部取流：这里只关心偏好层副作用）
      await _ignoreNetwork(() => p.switchKuwoQuality(KuwoQuality.hires));

      expect(p.currentKuwoQuality.id, before,
          reason: '默认偏好不应被播放页切换改写');
      expect(p.effectiveKuwoQuality.id, KuwoQuality.hires.id,
          reason: '当前这首应按临时档取流');
      // 落盘值仍是旧偏好
      final p2 = PlayerController.instance;
      p2.loadDefaultQuality();
      expect(p2.currentKuwoQuality.id, before);
    });

    test('换歌后临时档失效，回到偏好', () async {
      final p = PlayerController.instance;
      p.saveKuwoQuality(KuwoQuality.flac);
      await _ignoreNetwork(() => p.switchKuwoQuality(KuwoQuality.hires));
      expect(p.effectiveKuwoQuality.id, KuwoQuality.hires.id);

      // 换一首歌：play() 会清空临时覆盖。这里不建真实 Player（native），
      // 直接验证 _tempSong 语义：传入不同 song 后 effective 回到偏好。
      final other = Song(
        mid: 'other-mid',
        songId: 100001,
        name: '另一首',
        singer: '某人',
        album: '某专辑',
        albumMid: 'other-album',
        duration: 100000,
        cover: '',
        source: Source.kuwo,
      );
      await _ignoreNetwork(() => p.play(other, ''));
      expect(p.effectiveKuwoQuality.id, KuwoQuality.flac.id);
    });

    test('设置页改默认会清掉同平台临时档', () async {
      final p = PlayerController.instance;
      p.saveKuwoQuality(KuwoQuality.flac);
      await _ignoreNetwork(() => p.switchKuwoQuality(KuwoQuality.hires));

      p.saveKuwoQuality(KuwoQuality.master);
      expect(p.effectiveKuwoQuality.id, KuwoQuality.master.id,
          reason: '设置页改默认后应立即按新默认生效，而不是残留的临时档');
    });

    test('QQ / 网易云同样不被播放页切换污染', () async {
      final p = PlayerController.instance;
      p.saveDefaultQuality(Quality.flac);
      p.saveNeteaseQuality(NeteaseQuality.lossless);

      await _ignoreNetwork(() => p.switchQuality(Quality.mp3_320));
      await _ignoreNetwork(
          () => p.switchNeteaseQuality(NeteaseQuality.standard));

      expect(p.currentQuality.code, Quality.flac.code);
      expect(p.currentNeteaseQuality.level, NeteaseQuality.lossless.level);
      expect(p.effectiveQuality.code, Quality.mp3_320.code);
      expect(p.effectiveNeteaseQuality.level, NeteaseQuality.standard.level);
    });
  });
}

/// 播放页切换会触发取流（无网络 / 无 native 实例会抛或空转），
/// 这里只关心偏好层副作用，网络异常一律吞掉。
Future<void> _ignoreNetwork(Future<void> Function() body) async {
  try {
    await body();
  } catch (_) {
    // ignore
  }
}
