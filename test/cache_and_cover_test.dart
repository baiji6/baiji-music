import 'dart:convert';
import 'dart:typed_data';

import 'package:baiji_music/core/album_saver.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:baiji_music/core/cache_manager.dart';
import 'package:baiji_music/metadata/audio_tagger.dart';
import 'package:baiji_music/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song({String singer = '周杰伦', String name = '晴天'}) => Song(
      mid: 'm1',
      songId: 1,
      name: name,
      singer: singer,
      album: '叶惠美',
      albumMid: 'a1',
      duration: 269,
      cover: '',
      source: Source.qq,
    );

void main() {
  // CacheManager 的偏好都存在 KvStore 里，测试环境要先起 SharedPreferences 模拟
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await KvStore.ensureInit();
  });

  group('CacheManager.formatBytes', () {
    test('按量级选单位', () {
      expect(CacheManager.formatBytes(0), '0 B');
      expect(CacheManager.formatBytes(512), '512 B');
      expect(CacheManager.formatBytes(1024), '1.0 KB');
      expect(CacheManager.formatBytes(1536), '1.5 KB');
      expect(CacheManager.formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(CacheManager.formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('负数与超大值不崩', () {
      expect(CacheManager.formatBytes(-1), '0 B');
      expect(CacheManager.formatBytes(1 << 62), isNotEmpty);
    });
  });

  group('封面魔数识别与扩展名', () {
    test('guessMime 能认出 gif / webp', () {
      final gif = Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
      expect(AudioTagger.guessMime(gif), 'image/gif');

      final webp = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, // RIFF
        0x57, 0x45, 0x42, 0x50, // WEBP
      ]);
      expect(AudioTagger.guessMime(webp), 'image/webp');

      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
      expect(AudioTagger.guessMime(png), 'image/png');
    });

    test('未知字节按 jpeg 处理', () {
      expect(AudioTagger.guessMime(Uint8List.fromList([1, 2, 3])), 'image/jpeg');
    });
  });

  group('AlbumSaver 文件名', () {
    test('不含扩展名——gal 原生会自己拼 .jpg', () {
      // 长按封面保存后相册里应显示「歌手 - 歌名」，而不是「歌手 - 歌名.jpg.jpeg」
      final name = AlbumSaver.fileStem(_song());
      expect(name, '周杰伦 - 晴天');
      expect(name.contains('.jpg'), isFalse);
      expect(name.contains('.'), isFalse);
    });

    test('非法字符被替换掉', () {
      final name = AlbumSaver.fileStem(_song(singer: 'A/B', name: 'C:D?"<>|'));
      expect(name.contains(RegExp(r'[/\\:*?"<>|]')), isFalse);
    });

    test('超长名截断到 120 字以内', () {
      final name = AlbumSaver.fileStem(_song(singer: 'x' * 200, name: 'y' * 200));
      expect(name.length, lessThanOrEqualTo(120));
    });

    test('空歌手与空歌名有占位', () {
      final name = AlbumSaver.fileStem(_song(singer: '', name: ''));
      expect(name, contains('未知歌手'));
      expect(name, contains('未知歌曲'));
    });
  });

  group('Credential 往返', () {
    test('toJsonString 三字段足够 buildComm 使用', () {
      final c = Credential(musicid: 123, musickey: 'Q_H_L_k', loginType: 2);
      final m = jsonDecode(c.toJsonString()) as Map<String, dynamic>;
      expect(m['musicid'], 123);
      expect(m['musickey'], 'Q_H_L_k');
      expect(m['loginType'], 2);
    });

    test('fromDict 能吃别名与字符串数字', () {
      final c = Credential.fromDict({
        'str_musicid': 'o0123456789',
        'musickey': 'Q_H_L_k',
        'musicid': '123456',
      });
      expect(c.strMusicid, 'o0123456789');
      expect(c.musicid, 123456);
      // 没给 loginType 时按票据前缀推断
      expect(c.loginType, 2);
    });

    test('微信票据推断为 loginType 1', () {
      final c = Credential.fromDict({'musickey': 'W_X_abc'});
      expect(c.loginType, 1);
    });
  });

  group('缓存管理默认值', () {
    test('未设置时内存上限夹在 16~1024', () {
      final mb = CacheManager.memoryLimitMb;
      expect(mb, greaterThanOrEqualTo(16));
      expect(mb, lessThanOrEqualTo(1024));
    });

    test('未设置自定义目录时 customRoot 为空（用系统默认）', () {
      expect(CacheManager.customRoot, '');
    });
  });
}
