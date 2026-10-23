// 酷我 `f=ar` 协议编解码测试（v2.4.1）。
//
// 向量来源分两类：
//   1. **固化向量**：`EkeyCipher.encrypt(key="kwks&@69")` 在当前实现下的
//      输出。EkeyCipher 是酷我的 **DES 变体（LSB-first）**，与标准 DES
//      表不同（见 qmc_cipher.dart 文件头），因此没有公开 KAT 可对；
//      它的正确性由两组真实数据锚定 —— `test/kuwo_qmc_test.dart` 的
//      线上加密音轨，以及沙箱内真实酷我服务端的 f=ar 实测（kuwo_auth.dart
//      文件头）。固化向量的作用是**锁死现状**：将来任何改动（改表、轮密钥
//      顺序、填充规则）都会让这里红掉，必须显式确认。
//   2. **真实响应样本形态**：账密登录失败时服务端真实返回的 JSON
//      （`{"result":"fail","msg":"用户名不存在",...}`），用 EkeyCipher
//      以 sx 为密钥密封后交给 openResponse 解开 —— 与线上传输形制一致。
import 'dart:convert';
import 'dart:typed_data';

import 'package:baiji_music/network/kuwo/kuwo_cipher.dart';
import 'package:baiji_music/network/kuwo/qmc_cipher.dart';
import 'package:flutter_test/flutter_test.dart';

/// 酷我的 DES 变体在 key="kwks&@69" 下的固化向量（输入长度标注在注释里，
/// 长度决定补零块数，是填充规则的一部分）。
const String _vecLen24 = 'Sy1Jlx5q/p5Yrx/f1drHCVV1Hh/+dAsLJOq3zbyhfzE=';
const String _vecLen25 = 'q9SUEF5l8EZX2QX0/CYlAz8KlTw5JKt7uYp42hTM5lQ=';
const String _vecLen42 =
    '3rIFSVtGCUAO2MtJWaOWJzG1+9ZTdjlJPK3cZQXGwNp64/Sxqa2Nq/hX/Oag0R9Z';
const String _vecCn = 'Sy1Jlx5q/p5rRKdWgxjnhXj/42QMh9i6aBcQLutuBG6IPBox1N3g/Q==';
const String _vecLen8 = 'k4KbGX57oVEk6rfNvKF/MQ==';

/// 以 sx 密封的真实失败响应样本（线上形制）。
const String _respFail =
    '4O9RPiE3zZdgJV9an0inyGfDH0TR3cl0wTlqphYV7TXgYy+GA4aq8ax4PVE10cZz90Se/7G7/lUDCM/4XfViZ7ff3/uNdbcd';

void main() {
  group('KuwoCipher 常量与密钥', () {
    test('queryKey 是酷我公开常量', () {
      expect(KuwoCipher.queryKey, 'kwks&@69');
    });

    test('_keyOf 只接受 8 字节密钥（通过 sealQuery/openResponse 体现）', () {
      // sx 必须 8 位纯数字，否则 openResponse 直接拒
      expect(() => KuwoCipher.openResponse(_respFail, '179273000'),
          throwsA(isA<FormatException>()));
      expect(() => KuwoCipher.openResponse(_respFail, '1792730a'),
          throwsA(isA<FormatException>()));
    });
  });

  group('sealQuery（q 参数）', () {
    test('固化向量：24 字节查询串（3 个整块）', () {
      expect(KuwoCipher.sealQuery('username=abc&sx=17927300'), _vecLen24);
    });

    test('固化向量：25 字节查询串（非 8 倍数，补到 32）', () {
      expect(
          KuwoCipher.sealQuery('mobile=13800138000&type=4'), _vecLen25);
    });

    test('固化向量：42 字节查询串（跨 6 块）', () {
      expect(
          KuwoCipher.sealQuery('uid=501214651&sid=abc123def456&sx=17927319'),
          _vecLen42);
    });

    test('固化向量：URL 编码后的中文', () {
      expect(KuwoCipher.sealQuery('username=%E4%B8%AD%E6%96%87&sx=17927300'),
          _vecCn);
    });

    test('固化向量：长度恰为 8 的倍数时仍补满一整块', () {
      expect(KuwoCipher.sealQuery('abcdefgh'), _vecLen8);
      // 16 字节密文 → base64 24 字符
      expect(_vecLen8.length, 24);
    });

    test('输出是合法 Base64，且长度 = ceil((len+8)/8)*8 的 4/3', () {
      final q = KuwoCipher.sealQuery('username=abc&sx=17927300');
      expect(() => base64.decode(q), returnsNormally);
      expect(base64.decode(q).length, 32); // (24 + 8) 补到 32
    });

    test('协议形制：q 能被 EkeyCipher.decrypt 原样解回', () {
      // 这正是服务端做的事：用 "kwks&@69" 解出我们的查询串
      for (final plain in [
        'username=abc&sx=17927300',
        'mobile=13800138000&type=4&tm=1792731987&secret=A0D5D4FB34172467E148AF9F6E7F8AB1',
        'username=%E4%B8%AD%E6%96%87%E6%B5%8B%E8%AF%95&sx=17927300',
        'x=1',
        'abcdefgh',
        'abcdefghijklmno', // 15 字节 → 补到 16
      ]) {
        final q = KuwoCipher.sealQuery(plain);
        final back = EkeyCipher.decrypt(
            base64.decode(q), Uint8List.fromList(utf8.encode('kwks&@69')));
        // 去尾部 \0（酷我的填充规则）后必须与原文一致
        var end = back.length;
        while (end > 0 && back[end - 1] == 0) {
          end--;
        }
        expect(utf8.decode(Uint8List.sublistView(back, 0, end)), plain,
            reason: 'plain=$plain');
      }
    });

    test('超出明文上限直接拒绝', () {
      expect(() => KuwoCipher.sealQuery('a' * (KuwoCipher.maxPlain + 1)),
          throwsArgumentError);
      // 正好等于上限放行
      expect(() => KuwoCipher.sealQuery('a' * KuwoCipher.maxPlain),
          returnsNormally);
    });
  });

  group('openResponse（响应体）', () {
    test('解开真实失败样本（线上形制）', () {
      expect(
        KuwoCipher.openResponse(_respFail, '17927300'),
        '{"result":"fail","msg":"用户名不存在","enum":"3","status":1136}',
      );
    });

    test('往返：任意 JSON 文本', () {
      final sx = '17927300';
      for (final json in [
        '{"result":"succ","msg":"ok","tm":"1792731987","status":200}',
        '{"a":"中文评论内容","b":[1,2,3]}',
        '{}',
        'x', // 1 字节 → 补到 8
        'abcdefgh', // 恰 8 → 补满 16
        '{"nickname":"健康一直都在jk","picture":"http://img4.kuwo.cn/x.jpg"}',
      ]) {
        final sealed = base64.encode(EkeyCipher.encrypt(
            Uint8List.fromList(utf8.encode(json)),
            Uint8List.fromList(utf8.encode(sx))));
        expect(KuwoCipher.openResponse(sealed, sx), json, reason: json);
      }
    });

    test('容忍首尾空白（服务端偶发带换行）', () {
      expect(
        KuwoCipher.openResponse('  $_respFail\n', '17927300'),
        '{"result":"fail","msg":"用户名不存在","enum":"3","status":1136}',
      );
    });

    test('坏输入：空响应体', () {
      expect(() => KuwoCipher.openResponse('', '17927300'),
          throwsA(isA<FormatException>()));
    });

    test('坏输入：不是合法 Base64', () {
      expect(() => KuwoCipher.openResponse('!!!!not-base64!!!!', '17927300'),
          throwsA(isA<FormatException>()));
    });

    test('坏输入：Base64 解出来不是 8 的倍数', () {
      // "QUJD" → 3 字节
      expect(() => KuwoCipher.openResponse('QUJD', '17927300'),
          throwsA(isA<FormatException>()));
    });

    test('坏输入：超出大小预算', () {
      expect(
          () => KuwoCipher.openResponse(
              'A' * (KuwoCipher.maxResponse + 1), '17927300'),
          throwsA(isA<FormatException>()));
    });
  });

  group('响应密钥 sx', () {
    test('newResponseKey 取毫秒时间戳前 8 位', () {
      expect(KuwoCipher.newResponseKey(1792731987123), '17927319');
      expect(KuwoCipher.newResponseKey(1792730000000), '17927300');
      expect(KuwoCipher.newResponseKey(999999999999), '99999999');
    });

    test('isValidResponseKey 只认 8 位纯数字', () {
      expect(KuwoCipher.isValidResponseKey('17927319'), isTrue);
      expect(KuwoCipher.isValidResponseKey('00000000'), isTrue);
      expect(KuwoCipher.isValidResponseKey('1792731'), isFalse); // 7 位
      expect(KuwoCipher.isValidResponseKey('179273190'), isFalse); // 9 位
      expect(KuwoCipher.isValidResponseKey('1792731a'), isFalse); // 带字母
      expect(KuwoCipher.isValidResponseKey('1792731 '), isFalse); // 带空格
      expect(KuwoCipher.isValidResponseKey(''), isFalse);
    });
  });
}
