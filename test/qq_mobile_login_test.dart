// QQ 音乐「手机 App 扫码登录」的解析测试。
//
// 样本来源：
// - CreateQRCode 的 qrcode 字段：**真实接口抓包**（最小 comm 直打
//   u.y.qq.com/cgi-bin/musicu.fcg），带 `data:image/png;base64,` 前缀；
// - cookies 事件载荷：结构按倾听（qqmusic-api）`login.py` 的
//   `_handle_mobile_message` 解析逻辑固化（沙箱无人扫码，未抓到真实载荷，
//   但事件类型 scanned/canceled/timeout/loginFailed/cookies 均在 MQTT 实测
//   链路上验证过，见 mqtt_ws_test.dart 与 test/zz_live_qr_test.dart 的实测记录）。
import 'dart:convert';

import 'package:baiji_music/network/qq_mobile_login.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实抓包的 qrcode 字段（data URI 形态）。
const qrDataUriSample =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAJYAAACWAQMAAAAGz+OhAAAABlBMVEX///8AAABVwtN+AAABYElEQVR4nLzWva3EIBAE4EEEhJRAJ3ZjJ9tP15jdCSVsSIA8T7v2na6AxYRfBsz+gCTbLEFi7cBMsj9iHUCDnkJiAvDyt8K9BUHuQMGUKIMMeYPerY00BG7Qu40xfb8g6/U1P2862CwbU/6TV4m1/eTF0ezMgryVT0jcjfXKBmL95s/bAO5pz1t+qyEd3NyN5E7KgkgAUzoE7tbBHcAqa+2lhTZZNh6woungef3bt0e4mnY6IJ/5XfXn7kz6Gkqy+tVKKjwR5OVukZoNLFhrrIlthKFgtrmgXdv+CO6mdaQZtzriQcv4Q8YTq8QamWj5c7frTYOVcjrIu95cTfvQlM/cy9Vc77t5mh011lgb0vnpsY5mcyGQEitKm4bYtYPkP4nspcEi8YjpPJ9llUjdfnjmPsqQ32RFaBhlgTqPItOeDg4wfb9ZFhun6WjzZ/dxtHvfXQBte7RB5Gz/AQAA//8MGqgTSL8TrwAAAABJRU5ErkJggg==';

/// 结构按倾听源码固化的 cookies 事件载荷。
const cookiesPayloadSample =
    '{"cookies":{"qqmusic_uin":{"value":"123456789"},"qqmusic_key":{"value":"Q_H_L_abcdefg"}}}';

void main() {
  group('parseCreateQr', () {
    test('真实样本：取出 qrcodeID 与 PNG 字节', () {
      final qr = QqMobileLogin.parseCreateQr({
        'qrcodeID': 'AqkgaGsYbkp02lSTrZZhmE9',
        'qrcode': qrDataUriSample,
      });
      expect(qr.qrcodeId, 'AqkgaGsYbkp02lSTrZZhmE9');
      // PNG 魔数
      expect(qr.image.take(4), [0x89, 0x50, 0x4E, 0x47]);
      expect(qr.image.length, greaterThan(300));
    });

    test('兼容裸 base64（无 data: 前缀）', () {
      final raw = qrDataUriSample.split(',').last;
      final qr = QqMobileLogin.parseCreateQr({
        'qrcodeID': 'id2',
        'qrcode': raw,
      });
      expect(qr.image.take(4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('缺 qrcodeID 或 qrcode 时抛错', () {
      expect(
        () => QqMobileLogin.parseCreateQr({'qrcode': qrDataUriSample}),
        throwsA(isA<Exception>()),
      );
      expect(
        () => QqMobileLogin.parseCreateQr({'qrcodeID': 'x'}),
        throwsA(isA<Exception>()),
      );
      expect(
        () => QqMobileLogin.parseCreateQr(<String, dynamic>{}),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('parseCookiesPayload', () {
    test('取出换票需要的 uin 与 key', () {
      final c = QqMobileLogin.parseCookiesPayload(cookiesPayloadSample);
      expect(c.uin, '123456789');
      expect(c.key, 'Q_H_L_abcdefg');
    });

    test('缺 cookies / 缺 value / 非 JSON 都抛错', () {
      expect(
        () => QqMobileLogin.parseCookiesPayload('{"foo":1}'),
        throwsA(isA<Exception>()),
      );
      expect(
        () => QqMobileLogin.parseCookiesPayload('{"cookies":{"qqmusic_uin":{}}}'),
        throwsA(isA<Exception>()),
      );
      expect(
        () => QqMobileLogin.parseCookiesPayload('[1,2,3]'),
        throwsA(isA<Exception>()),
      );
      expect(
        () => QqMobileLogin.parseCookiesPayload('not json'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('clientId', () {
    test('毫秒时间戳 + 4 位随机数（倾听同款格式）', () {
      final id = QqMobileLogin.clientId();
      expect(id.length, greaterThanOrEqualTo(14));
      expect(int.tryParse(id), isNotNull);
    });
  });

  group('exchangeTicket', () {
    test('uin 不是数字时本地抛错（不发请求）', () async {
      expect(
        () => QqMobileLogin.exchangeTicket('qr', 'not-a-number', 'key'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('JSON 编解码一致性', () {
    test('cookies 样本可被 jsonDecode 还原成同一结构', () {
      final decoded = jsonDecode(cookiesPayloadSample) as Map<String, dynamic>;
      expect((decoded['cookies'] as Map)['qqmusic_uin']['value'], '123456789');
    });
  });
}
