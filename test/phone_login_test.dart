// 手机验证码登录的纯函数测试（v2.4.2-pre2，仿倾听）。
//
// 网络层不测（需真实手机号收码），这里固化两类「踩过坑就没法回退」的
// 契约：QQ SendPhoneAuthCode 响应的事件映射 + 网易云 Set-Cookie 拼装。
import 'package:baiji_music/core/kv_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:baiji_music/network/login_api.dart';
import 'package:baiji_music/network/netease/netease_client.dart';
import 'package:flutter_test/flutter_test.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await KvStore.ensureInit();
  });

  group('QQ SendPhoneAuthCode 响应解析（QqPhoneSend.parse）', () {
    test('code=0 → 已下发', () {
      final r = QqPhoneSend.parse({'code': 0, 'data': <String, dynamic>{}});
      expect(r.event, QqPhoneSendEvent.sent);
    });

    test('code=20276 → 需要滑块，带 securityURL', () {
      final r = QqPhoneSend.parse({
        'code': 20276,
        'data': {
          'securityURL': 'https://captcha.qq.com/verify?appid=xxx',
          'errTip': '',
        },
      });
      expect(r.event, QqPhoneSendEvent.captcha);
      expect(r.securityUrl, 'https://captcha.qq.com/verify?appid=xxx');
    });

    test('code=100001 → 过于频繁', () {
      final r =
          QqPhoneSend.parse({'code': 100001, 'data': <String, dynamic>{}});
      expect(r.event, QqPhoneSendEvent.frequency);
    });

    test('code=104400（假号实测响应）→ error 且带服务端 errMsg', () {
      // 2026-10-25 沙箱对 12345678901 的真实响应（不发短信，纯参数校验）
      final r = QqPhoneSend.parse({
        'code': 104400,
        'data': {
          'errMsg': "failed to SendSMSAuthCode: ec=104400, "
              "err='bad request: phoneNo is invalid'",
          'securityURL': '',
          'errTip': '',
        },
      });
      expect(r.event, QqPhoneSendEvent.error);
      expect(r.code, 104400);
      expect(r.message, contains('phoneNo is invalid'));
    });

    test('缺 data 段时不崩', () {
      final r = QqPhoneSend.parse(<String, dynamic>{});
      expect(r.event, QqPhoneSendEvent.error);
    });
  });

  group('QQ 短信登录错误文案（LoginApi.phoneLoginErrorTip）', () {
    test('20271 → 验证码错误', () {
      expect(LoginApi.phoneLoginErrorTip(20271, {}), contains('验证码错误'));
    });

    test('20279 → 设备数量超限', () {
      expect(LoginApi.phoneLoginErrorTip(20279, {}), contains('设备数量'));
    });

    test('未知码回退服务端 errTip', () {
      expect(LoginApi.phoneLoginErrorTip(99999, {'errTip': '自定义错误'}),
          contains('自定义错误'));
    });
  });

  group('网易云 Set-Cookie → Cookie 串（buildCookieFromSetCookie）', () {
    test('丢弃属性段、同名后者覆盖、空值跳过', () {
      final cookie = NeteaseClient.buildCookieFromSetCookie([
        'MUSIC_U=abc123; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT',
        '__csrf=xyz789; Path=/; Max-Age=100',
        'MUSIC_R_T=; Max-Age=0', // 空值丢掉
        'MUSIC_U=def456; Path=/', // 同名后者覆盖
      ]);
      expect(cookie, contains('MUSIC_U=def456'));
      expect(cookie, contains('__csrf=xyz789'));
      expect(cookie.contains('MUSIC_R_T'), isFalse);
      expect(cookie.contains('Path'), isFalse);
      expect(cookie.contains('Expires'), isFalse);
    });

    test('csrfToken 从当前 Cookie 取 __csrf', () {
      final client = NeteaseClient();
      client.cookie = 'MUSIC_U=k1; __csrf=csrf9; NMTID=xx';
      expect(client.csrfToken, 'csrf9');
    });
  });

  group('网易云验证码登录响应映射（纯数据层）', () {
    test('NeteaseLoginException 的 toString 是纯文案', () {
      const e = NeteaseLoginException(503, '验证码错误');
      expect(e.toString(), '验证码错误');
    });
  });
}
