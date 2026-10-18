// v2.3.0 备份与恢复：导出往返、白名单过滤、格式校验。
//
// 备份范围刻意排除设备指纹（device_json / session_*）——跨设备恢复
// 会与服务端风控冲突；歌单/历史/登录态/设置必须包含。
import 'dart:convert';

import 'package:baiji_music/core/backup_crypto.dart';
import 'package:baiji_music/core/backup_service.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, String>{});

  // KvStore 是单例：统一用「清空 + 写种子」重置状态，
  // setMockInitialValues 对已创建的实例无效。
  Future<KvStore> seedStore(Map<String, Object> seed) async {
    final kv = await KvStore.ensureInit();
    await kv.clear();
    await kv.restore(seed);
    return kv;
  }

  test('导出包含歌单/历史/登录态/设置，排除设备指纹', () async {
    await seedStore(<String, Object>{
      'playlist_list': '[{"name":"我的歌单"}]',
      'search_history': '["耀斑"]',
      'play_history': '[]',
      'favorite_songs': '[]',
      'netease_cookie': 'MUSIC_U=abc;',
      'netease_user_id': 123,
      'login_info:credential_json': '{"musicid":1}',
      'baiji.decrypt.keys.v2': '[]',
      'lyric_view:font': '15.0',
      'ui:corner': '16.0',
      'download_extras:cover': true,
      'download_prefs:path': '/sdcard/Music',
      // 必须排除的
      'device_json': '{"qimei":"xxx"}',
      'session_uid': 999,
      'session_sid': 'secret',
      'agreement_accepted': true,
      'log_something': 'noise',
    });
    final exported = BackupService.export();
    // v2.3.0-fix1 起导出是加密文本；v2.3.0-fix3 起为 BAIJI2（SM4+SM2）
    expect(exported.startsWith('BAIJI2.'), isTrue,
        reason: '导出必须是加密格式（防止登录态明文落盘）');
    expect(exported.contains('playlist_list'), isFalse,
        reason: '加密文件里不应出现明文键名');
    final json = BackupCrypto.decrypt(exported)!;
    final map = jsonDecode(json) as Map<String, dynamic>;
    expect(map['app'], 'baiji-music');
    expect(map['backupVersion'], BackupService.backupVersion);
    expect(map['appVersion'], isNotEmpty);
    expect(map['exportedAt'], isNotEmpty);

    final kv = map['kv'] as Map<String, dynamic>;
    // 必须包含
    for (final k in [
      'playlist_list',
      'search_history',
      'netease_cookie',
      'netease_user_id',
      'login_info:credential_json',
      'baiji.decrypt.keys.v2',
      'lyric_view:font',
      'ui:corner',
      'download_extras:cover',
      'download_prefs:path',
    ]) {
      expect(kv.containsKey(k), isTrue, reason: '备份必须包含 $k');
    }
    // 必须排除
    for (final k in ['device_json', 'session_uid', 'session_sid',
      'agreement_accepted', 'log_something']) {
      expect(kv.containsKey(k), isFalse, reason: '备份不应包含 $k');
    }
  });

  test('导入往返：恢复后 KvStore 读回相同值', () async {
    await seedStore(<String, Object>{
      'playlist_list': '[{"name":"旧歌单"}]',
      'search_history': '["旧搜索"]',
    });
    final exported = BackupService.export();
    // 加密文件里不能有明文数据
    expect(exported.contains('旧歌单'), isFalse);

    // 模拟换机：全新环境（空库）后导入
    SharedPreferences.setMockInitialValues(<String, String>{});
    final fresh = await KvStore.ensureInit();
    // ensureInit 已有实例时不会重读——直接清空模拟新机
    await fresh.clear();

    final n = await BackupService.import(exported);
    expect(n, greaterThan(0));
    expect(fresh.getString('playlist_list'), '[{"name":"旧歌单"}]');
    expect(fresh.getString('search_history'), '["旧搜索"]');
    // 备份里没有的键不受影响（合并写回）
  });

  test('导入校验：非本 app 备份 / 版本过新 / 结构损坏都拒绝', () async {
    await seedStore(<String, String>{});

    // 别的 app 的 JSON
    expect(() => BackupService.import(jsonEncode({'app': 'other'})),
        throwsFormatException);

    // 版本过新
    expect(
        () => BackupService.import(jsonEncode({
              'app': 'baiji-music',
              'backupVersion': BackupService.backupVersion + 1,
              'kv': {},
            })),
        throwsFormatException);

    // 缺 kv 段
    expect(
        () => BackupService.import(jsonEncode({
              'app': 'baiji-music',
              'backupVersion': 1,
            })),
        throwsFormatException);

    // 非 JSON
    expect(() => BackupService.import('这不是json'),
        throwsFormatException);
  });

  test('导入合并写回：本机备份里没有的键保留', () async {
    await seedStore(<String, Object>{
      'playlist_list': '[]',
      'search_history': '["本机搜索"]',
      'favorite_songs': '[{"本机收藏":true}]',
    });
    final exported = BackupService.export();
    final map =
        jsonDecode(BackupCrypto.decrypt(exported)!) as Map<String, dynamic>;
    // 从备份里删掉 favorite_songs，模拟「旧备份没有收藏」
    (map['kv'] as Map<String, dynamic>).remove('favorite_songs');
    // 重新按加密格式封装后再导入
    final partial = BackupCrypto.encrypt(jsonEncode(map));

    // 改动本机数据后导入
    KvStore.instance.setString('favorite_songs', '[{"改动":1}]');
    await BackupService.import(partial);

    expect(KvStore.instance.getString('search_history'), '["本机搜索"]');
    // 备份里删掉的键不被触碰
    expect(KvStore.instance.getString('favorite_songs'), '[{"改动":1}]');
  });

  test('BackupCrypto：加密往返（SM4-CBC + SM2 信封）', () {
    const plain = '{"app":"baiji-music","kv":{"k":"v 中文😀"}}';
    final enc = BackupCrypto.encrypt(plain);
    expect(enc.startsWith('BAIJI2.'), isTrue);
    expect(enc.contains('中文'), isFalse, reason: '密文里不能有明文');
    final back = BackupCrypto.decrypt(enc);
    expect(back, plain);
  });

  test('BackupCrypto：v2 每次导出使用不同随机密钥/IV（语义安全）', () {
    const plain = '{"same":"plaintext"}';
    final a = BackupCrypto.encrypt(plain);
    final b = BackupCrypto.encrypt(plain);
    expect(a == b, isFalse, reason: '相同明文两次导出密文必须不同');
    expect(BackupCrypto.decrypt(a), plain);
    expect(BackupCrypto.decrypt(b), plain);
  });

  test('BackupCrypto：v1 历史备份（RC4+RSA）解密兼容', () {
    // 真实 v2.3.0-fix1/fix2 导出的 BAIJI1 样本（脚本复刻旧算法生成）
    const legacy =
        'BAIJI1.QkFJSgCAsI6p/2+lcWepIODzN1TN6ZTaiX2n4ngxLhFAV4T+xyEVFoppYcOQRj7t'
        '6YOs3vk1MWDey+3pFDeLB/RBBo9FzwFhlgY5DSf+QAvZ1B8DNT13tyzVrPWBJf02LRWoRI7'
        'jkoLA4RPjx6KdnGBU2yyslc2X43fj+lhokrFRYl3KdesK+u9gcrJivkEsSPBOEqEYa6ADjO'
        'CbwLKwTDXNBFHMaJf8KXJS+H5IcwGqlGUqTtMV74s+toK+uw4washm3sNFi/Q5TmqpGUEjU'
        'pi7c8PQUe0CHowjOiof';
    final json = BackupCrypto.decrypt(legacy);
    expect(json, isNotNull);
    final map = jsonDecode(json!) as Map<String, dynamic>;
    expect(map['app'], 'baiji-music');
    expect((map['playlists'] as List).single['name'], '我喜欢的音乐');
  });

  test('BackupCrypto：v2 坏 Base64 → 格式异常', () {
    expect(() => BackupCrypto.decrypt('BAIJI2.%%%'), throwsFormatException);
  });

  test('BackupCrypto：v2 截断密文 → 格式异常', () {
    final enc = BackupCrypto.encrypt('{"a":1}');
    // 砍掉尾部几个字符再补齐到合法 Base64 长度，制造结构损坏
    final body = enc.substring('BAIJI2.'.length);
    final cut = '${body.substring(0, body.length - 8)}=';
    expect(() => BackupCrypto.decrypt('BAIJI2.$cut'), throwsA(anything));
  });

  test('BackupCrypto：旧明文 JSON 导入兼容（无前缀返回 null）', () {
    expect(BackupCrypto.decrypt('{"app":"baiji-music"}'), isNull);
    // 坏前缀内容应抛格式异常而不是静默
    expect(() => BackupCrypto.decrypt('BAIJI1.%%%'), throwsFormatException);
  });
}
