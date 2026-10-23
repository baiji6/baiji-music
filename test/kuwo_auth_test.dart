// 酷我登录核心（协议纯函数 / 设备身份 / 会话持久化）测试，v2.4.1。
//
// **不发任何网络请求**：这里只覆盖不碰线的部分 —— 设备身份形制、查询串
// 组装依赖的校验、会话 JSON、口令加密、监听器。真正打服务器的链路在
// kuwo_cipher_test.dart（协议层）+ 沙箱实测（见 kuwo_auth.dart 文件头）。
import 'dart:convert';

import 'package:baiji_music/core/app_version.dart';
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/network/kuwo/kuwo_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, String>{});
  // KvStore 是 SharedPreferences 的轻量封装，酷我登录的设备身份/会话都走它
  setUpAll(() async {
    await KvStore.ensureInit();
  });

  // 每个用例跑完把静态态清干净，避免串味
  setUp(() async {
    await KuwoAuth.clearAll();
  });

  group('KuwoDevice 形制', () {
    test('首次生成：32 位 hex + 10 位纯数字 app_uid', () async {
      final d = await KuwoAuth.device();
      expect(d.deviceUser, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(d.androidId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(d.appUid, matches(RegExp(r'^[1-9][0-9]{9}$')));
      // 类 UUIDv4：b[6] 高 4 位置 4 → hex 串第 13 个字符（index 12）是 '4'；
      // b[8] 高 2 位置 10 → index 16 ∈ {8,9,a,b}
      expect(d.deviceUser[12], '4');
      expect(d.androidId[12], '4');
      expect('89ab', contains(d.deviceUser[16]));
      expect('89ab', contains(d.androidId[16]));
    });

    test('设备身份持久化：第二次取到同一份', () async {
      final a = await KuwoAuth.device();
      final b = await KuwoAuth.device();
      expect(b.deviceUser, a.deviceUser);
      expect(b.androidId, a.androidId);
      expect(b.appUid, a.appUid);
    });

    test('deviceUser 与 androidId 相互独立（两个键各存一份）', () async {
      final d = await KuwoAuth.device();
      expect(d.deviceUser, isNot(d.androidId));
    });

    test('本地值损坏时自愈（长度不对就重新生成）', () async {
      await KvStore.instance.setString('kuwo_device_user', 'tooshort');
      await KvStore.instance.setString('kuwo_device_app_uid', '0123');
      final d = await KuwoAuth.device();
      expect(d.deviceUser, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(d.appUid, matches(RegExp(r'^[1-9][0-9]{9}$')));
    });

    test('clearAll 之后重新生成', () async {
      final a = await KuwoAuth.device();
      await KuwoAuth.clearAll();
      final b = await KuwoAuth.device();
      expect(b.deviceUser, isNot(a.deviceUser));
    });

    test('metadata 串形制（官方原生传输的 Cookies 头）', () async {
      final d = await KuwoAuth.device();
      final m = d.metadata();
      expect(m, startsWith('user=${d.deviceUser},ct=11,cv=12220,'));
      expect(m, contains('chid=newpcguanwangmobile'));
      expect(m, contains('QIMEI36=${KuwoAuthConst.qimei36}'));
      expect(m, contains('tmeAppID=kwplayer'));
      expect(m, contains('loginUid=0,loginSid=0'));
      expect(m, contains('appUid=${d.appUid}'));
      expect(m, endsWith(','));
    });

    test('metadata 注入登录态', () async {
      final d = await KuwoAuth.device();
      final m = d.metadata(loginUid: '501214651', loginSid: 'abc123');
      expect(m, contains('loginUid=501214651'));
      expect(m, contains('loginSid=abc123'));
    });
  });

  group('KuwoSession JSON', () {
    test('toJson / fromJson 往返', () {
      const s = KuwoSession(
        uid: '501214651',
        sid: 'sid-abc',
        nickname: '健康一直都在jk',
        avatar: 'http://img4.kuwo.cn/x.jpg',
        username: '13800138000',
      );
      final back = KuwoSession.fromJson(jsonDecode(jsonEncode(s.toJson()))
          as Map<String, dynamic>);
      expect(back, isNotNull);
      expect(back!.uid, s.uid);
      expect(back.sid, s.sid);
      expect(back.nickname, s.nickname);
      expect(back.avatar, s.avatar);
      expect(back.username, s.username);
      expect(back.isValid, isTrue);
    });

    test('缺 uid / sid 一律视为无效（fromJson 返回 null）', () {
      expect(KuwoSession.fromJson({'sid': 'x'}), isNull);
      expect(KuwoSession.fromJson({'uid': 'x'}), isNull);
      expect(KuwoSession.fromJson({'uid': '', 'sid': ''}), isNull);
      expect(KuwoSession.fromJson({}), isNull);
    });

    test('isValid 要求 uid 与 sid 都非空', () {
      const a = KuwoSession(uid: '', sid: 'x');
      const b = KuwoSession(uid: 'x', sid: '');
      expect(a.isValid, isFalse);
      expect(b.isValid, isFalse);
    });
  });

  group('手机号校验', () {
    test('合法号段放行', () {
      for (final p in [
        '13800138000',
        '15912345678',
        '17700001111',
        '18612345678',
        '19900002222',
      ]) {
        expect(KuwoAuth.isValidPhone(p), isTrue, reason: p);
      }
    });

    test('非法号段拒绝', () {
      for (final p in [
        '12345678901', // 第二位 2
        '12000000000', // 第二位 2
        '10000000000', // 第二位 0
        '10200000000', // 第二位 0
        '1380013800', // 10 位
        '138001380000', // 12 位
        '1380013800a', // 带字母
        '', // 空
        '23800138000', // 2 开头
      ]) {
        expect(KuwoAuth.isValidPhone(p), isFalse, reason: p);
      }
    });
  });

  group('短信 secret', () {
    // 参考值由 Python hashlib（权威 MD5）独立算出：
    //   md5u(md5u("imbadboy@!153") + md5u(phone + "4" + tm))
    test('向量一', () {
      expect(KuwoAuth.smsSecret('13800138000', '1792731987'),
          'A0D5D4FB34172467E148AF9F6E7F8AB1');
    });

    test('向量二', () {
      expect(KuwoAuth.smsSecret('15912345678', '1700000000000'),
          '71FA10C02098CF7527BF7C556BCFEDCA');
    });

    test('输出恒为 32 位大写十六进制', () {
      final s = KuwoAuth.smsSecret('13800138000', '1792731987');
      expect(s, matches(RegExp(r'^[0-9A-F]{32}$')));
    });
  });

  group('口令加密（SM4-CBC）', () {
    test('加解密往返', () {
      for (final pw in ['p@ssw0rd', '中文口令测试', 'a', '0123456789abcdef']) {
        expect(KuwoAuth.decryptPassword(KuwoAuth.encryptPassword(pw)), pw);
      }
    });

    test('密文不是明文（落盘的串看不出原口令）', () {
      final enc = KuwoAuth.encryptPassword('p@ssw0rd');
      expect(enc, isNot(contains('p@ssw0rd')));
      expect(enc, matches(RegExp(r'^[A-Za-z0-9+/=]+$')));
    });

    test('坏密文返回 null（不抛）', () {
      expect(KuwoAuth.decryptPassword(''), isNull);
      expect(KuwoAuth.decryptPassword('not-base64!!'), isNull);
      expect(KuwoAuth.decryptPassword('QUJD'), isNull); // 3 字节非 16 倍数
    });
  });

  group('会话持久化生命周期', () {
    test('restore：空本地 → null', () async {
      expect(await KuwoAuth.restore(), isNull);
      expect(KuwoAuth.isLoggedIn, isFalse);
    });

    test('restore：坏 JSON → null（不崩）', () async {
      await KvStore.instance.setString('kuwo_session', 'not-json{{{');
      expect(await KuwoAuth.restore(), isNull);
      await KvStore.instance.setString('kuwo_session', '"a string"');
      expect(await KuwoAuth.restore(), isNull);
    });

    test('restore：合法会话原样恢复', () async {
      await KvStore.instance.setString('kuwo_session', jsonEncode({
        'uid': '501214651',
        'sid': 'sid-abc',
        'nickname': 'nick',
        'avatar': 'http://x/y.jpg',
        'username': '13800138000',
      }));
      final s = await KuwoAuth.restore();
      expect(s, isNotNull);
      expect(KuwoAuth.isLoggedIn, isTrue);
      expect(s!.uid, '501214651');
      expect(s.nickname, 'nick');
      expect(s.username, '13800138000');
    });

    test('logout：清会话但保留设备身份与已存口令', () async {
      await KvStore.instance.setString('kuwo_session',
          jsonEncode({'uid': '1', 'sid': '2'}));
      await KvStore.instance.setString('kuwo_username', '13800138000');
      await KvStore.instance.setString(
          'kuwo_password_enc', KuwoAuth.encryptPassword('pw'));
      await KuwoAuth.restore();
      await KuwoAuth.logout();
      expect(KuwoAuth.isLoggedIn, isFalse);
      expect(KuwoAuth.savedUsername, '13800138000');
      expect(KuwoAuth.hasSavedPassword, isTrue);
      // 设备身份仍在
      final d = await KuwoAuth.device();
      expect(d.deviceUser, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('clearAll：连设备身份一起清', () async {
      await KuwoAuth.device();
      await KvStore.instance.setString('kuwo_username', 'u');
      await KvStore.instance.setString('kuwo_password_enc', 'e');
      await KuwoAuth.clearAll();
      expect(KuwoAuth.savedUsername, '');
      expect(KuwoAuth.hasSavedPassword, isFalse);
      final d = await KuwoAuth.device();
      expect(d.deviceUser, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('savedUsername / hasSavedPassword 默认空', () {
      expect(KuwoAuth.savedUsername, '');
      expect(KuwoAuth.hasSavedPassword, isFalse);
    });
  });

  group('会话变化监听', () {
    test('logout / clearAll 会通知监听者，移除后不再通知', () async {
      var hits = 0;
      void listener() => hits++;
      KuwoAuth.addListener(listener);
      await KuwoAuth.logout();
      expect(hits, 1);
      await KuwoAuth.clearAll();
      expect(hits, 2);
      KuwoAuth.removeListener(listener);
      await KuwoAuth.logout();
      expect(hits, 2);
    });

    test('重复移除不抛', () {
      void listener() {}
      KuwoAuth.addListener(listener);
      KuwoAuth.removeListener(listener);
      KuwoAuth.removeListener(listener);
    });
  });

  group('协议常量', () {
    test('登录/短信/续期路径与版本号', () {
      expect(KuwoAuthConst.host, 'https://i.kuwo.cn');
      expect(KuwoAuthConst.passwordPath, '/US_NEW/kuwo/login_kw');
      expect(KuwoAuthConst.smsSendPath, '/US_NEW/kuwo/send_sms');
      expect(KuwoAuthConst.smsLoginPath, '/US_NEW/kuwo/login_sms');
      expect(KuwoAuthConst.autoLoginPath, '/US_NEW/kuwo/login/auto_login');
      expect(KuwoAuthConst.profilePath, '/userinfo/lua_get_user_and_follow');
      expect(KuwoAuthConst.clientVersion, '12.2.2.0');
      // QIMEI36 是 36 位设备指纹（名字里的 36 就是长度）
      expect(KuwoAuthConst.qimei36, matches(RegExp(r'^[0-9a-f]{36}$')));
      expect(KuwoAuthConst.smsCodeLength, 5);
      // rom 标识必须跟 App 版本号联动（升级不会忘）
      expect(KuwoAuthConst.rom, 'baiji_music/${AppVersion.current}');
    });
  });
}
