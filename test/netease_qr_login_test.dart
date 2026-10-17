// 网易云扫码登录的解析测试。
//
// 样本来源：
// - unikey 响应：**真实接口抓包**（EAPI POST interface3.music.163.com
//   /eapi/login/qrcode/unikey，body {"type":1}）；
// - 轮询码值 800/801/802/803：沙箱实测 801（新 key），其余按网易云
//   桌面端行为与倾听（NeteaseCloudMusicApi）login.py 的码值表固化；
// - Set-Cookie 样本：按网易云登录响应的一般形态构造（MUSIC_U + __csrf，
//   带 Path/Expires/HttpOnly 属性段）。
import 'package:baiji_music/network/netease_qr_login.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('qrContent', () {
    test('拼 H5 登录页地址（codekey 即 unikey）', () {
      expect(
        NeteaseQrLogin.qrContent('abc-123'),
        'https://music.163.com/login?codekey=abc-123',
      );
    });
  });

  group('parseUnikey', () {
    test('真实样本：code=200 且带 unikey', () {
      // 实测：{"code":200,"unikey":"273c3c8c-81c0-4856-92ad-92be0246e9ed"}
      final unikey = NeteaseQrLogin.parseUnikey({
        'code': 200,
        'unikey': '273c3c8c-81c0-4856-92ad-92be0246e9ed',
      });
      expect(unikey, '273c3c8c-81c0-4856-92ad-92be0246e9ed');
    });

    test('code 非 200 / 缺 unikey 都抛错', () {
      expect(
        () => NeteaseQrLogin.parseUnikey({'code': 400, 'unikey': 'x'}),
        throwsA(isA<Exception>()),
      );
      expect(
        () => NeteaseQrLogin.parseUnikey({'code': 200}),
        throwsA(isA<Exception>()),
      );
      expect(
        () => NeteaseQrLogin.parseUnikey(<String, dynamic>{}),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('mapPollCode', () {
    test('800 = 过期', () {
      expect(NeteaseQrLogin.mapPollCode(800), NeteaseQrEvent.expired);
    });

    test('801 = 等待扫码（实测新 key 的返回）', () {
      expect(NeteaseQrLogin.mapPollCode(801), NeteaseQrEvent.waiting);
    });

    test('802 = 已扫码待确认', () {
      expect(NeteaseQrLogin.mapPollCode(802), NeteaseQrEvent.scanned);
    });

    test('803 = 登录成功', () {
      expect(NeteaseQrLogin.mapPollCode(803), NeteaseQrEvent.done);
    });

    test('未知码按等待处理（继续轮询，不中断）', () {
      expect(NeteaseQrLogin.mapPollCode(999), NeteaseQrEvent.waiting);
      expect(NeteaseQrLogin.mapPollCode(-1), NeteaseQrEvent.waiting);
    });
  });

  group('buildCookieFromSetCookie', () {
    test('提取 name=value，丢掉 Path/Expires 等属性段', () {
      final cookie = NeteaseQrLogin.buildCookieFromSetCookie([
        'MUSIC_U=00ABCDEF; Path=/; Expires=Wed, 01 Jan 2026 00:00:00 GMT',
        '__csrf=xyz123; Path=/; HttpOnly',
      ]);
      expect(cookie, 'MUSIC_U=00ABCDEF; __csrf=xyz123');
    });

    test('同名后者覆盖前者（刷新会话时后写的值生效）', () {
      final cookie = NeteaseQrLogin.buildCookieFromSetCookie([
        'MUSIC_U=old; Path=/',
        'MUSIC_U=new; Path=/',
      ]);
      expect(cookie, 'MUSIC_U=new');
    });

    test('空值 / 畸形项被跳过', () {
      final cookie = NeteaseQrLogin.buildCookieFromSetCookie([
        '',
        '   ',
        'novalue',
        '=noval',
        'MUSIC_U=ok; Path=/',
      ]);
      expect(cookie, 'MUSIC_U=ok');
    });

    test('空列表得到空串', () {
      expect(NeteaseQrLogin.buildCookieFromSetCookie(const []), '');
    });
  });
}
