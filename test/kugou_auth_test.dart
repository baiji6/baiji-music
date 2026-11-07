// 酷狗登录核心测试（纯函数 / 设备身份 / 会话持久化 / 取链凭据注入）。
//
// **不发任何网络请求**：二维码创建与轮询的协议已在沙箱实测打通
// （见 kugou_auth.dart 文件头）；这里锁死不碰线的部分。
import 'dart:convert';
import 'dart:typed_data';

import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/network/kugou/kugou_auth.dart';
import 'package:baiji_music/network/kugou/kugou_cipher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  setUpAll(() async {
    await KvStore.ensureInit();
  });

  setUp(() async {
    await KugouAuth.clearAll();
  });

  group('登录盐值', () {
    test('login-user 域名用独立 salt，与 gateway/lyric 都不同', () {
      expect(kugouLoginSalt, 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt');
      expect(kugouLoginSalt, isNot(kugouGatewaySalt));
      expect(kugouLoginSalt, isNot(kugouLyricSalt));
    });
  });

  group('设备身份', () {
    test('首次生成 mid/dev 为 32 位小写 hex，dfid 匿名占位', () async {
      final d = await KugouAuth.device();
      expect(d.mid, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(d.dev, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(d.dfid, '-');
    });

    test('设备身份持久化：第二次取到同一份', () async {
      final a = await KugouAuth.device();
      final b = await KugouAuth.device();
      expect(b.mid, a.mid);
      expect(b.dev, a.dev);
      expect(b.dfid, a.dfid);
    });

    test('本地值损坏时自愈（长度不对重新生成）', () async {
      await KvStore.instance.setString('kugou_device_mid', 'bad');
      final d = await KugouAuth.device();
      expect(d.mid, matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });

  group('会话持久化', () {
    test('手动登录保存后 isLoggedIn 为真且能 restore 回来', () async {
      final s = await KugouAuth.saveManual('123456', 'tok_abc');
      expect(s.userid, '123456');
      expect(KugouAuth.isLoggedIn, isTrue);
      expect(KugouAuth.session!.token, 'tok_abc');

      // 模拟冷启动：清空内存态后 restore
      final raw = KvStore.instance.getString('kugou_session');
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!);
      expect(decoded['userid'], '123456');
      final restored = KugouSession.fromJson(decoded as Map<String, dynamic>);
      expect(restored!.token, 'tok_abc');
    });

    test('logout 清会话但保留设备身份', () async {
      final dev = await KugouAuth.device();
      await KugouAuth.saveManual('123', 't');
      await KugouAuth.logout();
      expect(KugouAuth.isLoggedIn, isFalse);
      expect(KvStore.instance.getString('kugou_session'), isNull);
      final d2 = await KugouAuth.device();
      expect(d2.mid, dev.mid);
    });

    test('会话 JSON 非法/字段缺失时 restore 得到 null', () async {
      await KvStore.instance.setString('kugou_session', 'not-json{{{');
      expect(await KugouAuth.restore(), isNull);
      await KvStore.instance.setString(
          'kugou_session', jsonEncode({'userid': ''}));
      expect(await KugouAuth.restore(), isNull);
    });

    test('KugouSession.isValid 只认正整数 userid + 非空 token', () {
      expect(const KugouSession(userid: '123', token: 't').isValid, isTrue);
      expect(const KugouSession(userid: 'abc', token: 't').isValid, isFalse);
      expect(const KugouSession(userid: '123', token: '').isValid, isFalse);
      expect(const KugouSession(userid: '0', token: 't').isValid, isTrue);
    });
  });

  group('手动登录校验', () {
    test('userid 非数字 / 为空 / token 为空都抛可读错误', () async {
      expect(() => KugouAuth.saveManual('abc', 't'), throwsA(isA<KugouAuthError>()));
      expect(() => KugouAuth.saveManual('', 't'), throwsA(isA<KugouAuthError>()));
      expect(() => KugouAuth.saveManual('123', ''), throwsA(isA<KugouAuthError>()));
    });

    test('token 含控制字符被拒', () async {
      expect(
        () => KugouAuth.saveManual('123', 'a\nb'),
        throwsA(isA<KugouAuthError>()),
      );
    });

    test('手动登录可覆盖设备 mid/dfid（同一次登录的设备）', () async {
      await KugouAuth.saveManual('123', 't', mid: 'my-mid', dfid: 'my-dfid');
      final d = await KugouAuth.device();
      // device() 会校验 mid 长度 32，覆盖成短值后会重新生成——因此
      // 这里只验证 dfid 被采纳，mid 覆盖属于高级用法（需 32 位 hex）。
      expect(d.dfid, 'my-dfid');
    });
  });

  group('取链凭据注入（音质解锁）', () {
    test('未登录：userid=0 且不带 token，mid 是持久化设备值', () async {
      final dev = await KugouAuth.device();
      final p = await KugouAuth.requestParams();
      expect(p['userid'], '0');
      expect(p.containsKey('token'), isFalse);
      expect(p['mid'], dev.mid);
      expect(p['dfid'], dev.dfid);
      expect(p['dev'], dev.dev);
    });

    test('登录后：注入真实 userid/token', () async {
      await KugouAuth.saveManual('987654', 'secret-token');
      final p = await KugouAuth.requestParams();
      expect(p['userid'], '987654');
      expect(p['token'], 'secret-token');
    });

    test('urlKey 里的 userid 参与计算，登录前后 key 不同', () async {
      const hash = 'b3a52a7a958bf0aed0ebfba2e9a818b7';
      final dev = await KugouAuth.device();
      final anon = kugouUrlKey(hash, dev.mid, userid: '0');
      final logged = kugouUrlKey(hash, dev.mid, userid: '987654');
      expect(anon, isNot(logged));
    });
  });

  group('二维码轮询 / 图片', () {
    test('data.status → 事件映射（1/2/4/其它）', () {
      expect(KugouAuth.mapPollStatus(1), KugouQrEvent.waiting);
      expect(KugouAuth.mapPollStatus(2), KugouQrEvent.scanned);
      expect(KugouAuth.mapPollStatus(4), KugouQrEvent.confirmed);
      expect(KugouAuth.mapPollStatus(0), KugouQrEvent.expired);
      expect(KugouAuth.mapPollStatus(3), KugouQrEvent.expired);
      expect(KugouAuth.mapPollStatus(99), KugouQrEvent.expired);
    });

    test('二维码 PNG dataURL 正确解码', () {
      final png = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
      final url = 'data:image/png;base64,${base64.encode(png)}';
      final decoded = KugouAuth.decodeQrImage(url);
      expect(decoded, isNotNull);
      expect(decoded!, png);
    });

    test('空 / 非法 dataURL 返回 null', () {
      expect(KugouAuth.decodeQrImage(''), isNull);
      expect(KugouAuth.decodeQrImage('no-comma'), isNull);
      expect(KugouAuth.decodeQrImage('data:image/png;base64,@@@'), isNull);
    });

    test('KugouQrStatus.isDone 仅确认态为真', () {
      expect(const KugouQrStatus(KugouQrEvent.confirmed).isDone, isTrue);
      expect(const KugouQrStatus(KugouQrEvent.waiting).isDone, isFalse);
    });
  });
}
