// 酷狗网关签名 / 取链参数的回归锁。
//
// v2.5.0 曾把 gateway salt 的一个字符顺序抄错（...092lski→应为 ...092lksi），
// 导致搜索与取链一律返回 `error_code 20006 err signature`，表现是「酷狗无法
// 搜索」；同时把 filename 后缀（128kmp3/320kmp3）误当成取链 `quality` 参数，
// 被服务端判为 `error_code 20010`。这里把上游 HotDownloader 的权威常量与
// 签名向量逐字节锁死，防止再次抄错。
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/kugou/kugou_cipher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('酷狗网关签名常量', () {
    test('gateway salt 与 HotDownloader client.rs 的 SALT 逐字节一致', () {
      // 权威来源：crates/hotdownloader-core/src/platforms/kugou/client.rs
      //   const SALT: &str = "OIlwieks28dk2k092lksi2UIkp";
      // 特别注意 `...092lksi...`（ks），不是 `...092lski...`（sk）。
      expect(kugouGatewaySalt, 'OIlwieks28dk2k092lksi2UIkp');
      expect(kugouGatewaySalt.length, 26);
    });

    test('三套 salt 互不混淆', () {
      expect(kugouLyricSalt, 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA');
      expect(kugouUrlKeySalt, '57ae12eb6890223e355ccfcb74edf70d');
      expect(kugouGatewaySalt, isNot(kugouLyricSalt));
    });
  });

  group('签名 / key 向量', () {
    test('kugouSign = md5(SALT + 按 key 排序的无分隔 k=v 拼接 + body + SALT)',
        () {
      const params = <String, String>{
        'appid': '1005',
        'clienttime': '1700000000',
        'clientver': '20489',
        'dfid': '-',
        'keyword': '晴天',
        'mid': '0123456789abcdef0123456789abcdef',
        'page': '1',
        'pagesize': '20',
        'uuid': '-',
      };
      // 用权威 salt 手算的期望值（与 Rust signature_with_salt 对齐）。
      expect(kugouSign(params, kugouGatewaySalt),
          '636d1da11ad5585d5dfbc1fde9e7dd5c');
    });

    test('kugouSign 的 body 参与拼接', () {
      const params = <String, String>{'a': '1'};
      final withBody = kugouSign(params, kugouGatewaySalt, body: '{}');
      final noBody = kugouSign(params, kugouGatewaySalt);
      expect(withBody, isNot(noBody));
    });

    test('kugouUrlKey = md5(hash + URL_KEY_SALT + appid + mid + userid)', () {
      expect(
        kugouUrlKey('b3a52a7a958bf0aed0ebfba2e9a818b7',
            '0123456789abcdef0123456789abcdef'),
        '584a651db79934c532846f48ff0b182b',
      );
    });

    test('kugouBuildQuery 按 key 排序并做 URL 编码', () {
      final q = kugouBuildQuery(const {'b': '空 格', 'a': '1'});
      expect(q, 'a=1&b=%E7%A9%BA%20%E6%A0%BC');
    });
  });

  group('取链 quality 参数（v2.5.0 回归）', () {
    test('四档 qualityTag 是服务端认可的 128/320/flac/high', () {
      expect(KugouQuality.k128.qualityTag, '128');
      expect(KugouQuality.k320.qualityTag, '320');
      expect(KugouQuality.flac.qualityTag, 'flac');
      expect(KugouQuality.hires.qualityTag, 'high');
    });

    test('qualityTag 不含 filename 后缀（128kmp3/320kmp3 会被判 20010）', () {
      for (final q in KugouQuality.downloadOptions) {
        expect(q.qualityTag, isNot(contains('mp3')));
      }
    });

    test('id 仍是持久化约定的 filename 后缀，与 qualityTag 分离', () {
      expect(KugouQuality.k128.id, '128kmp3');
      expect(KugouQuality.k320.id, '320kmp3');
      expect(KugouQuality.flac.id, 'flac');
      expect(KugouQuality.hires.id, 'hires');
      expect(KugouQuality.fromId('128kmp3'), KugouQuality.k128);
    });
  });
}
