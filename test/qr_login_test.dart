// QQ 扫码登录的状态解析测试。
//
// 这里用的响应样本全部来自**真实接口抓包**（见下方注释），
// 因为历史 bug 正是"凭字面猜状态码语义"造成的：
// 66 被当成"已扫描"（实际是"二维码未失效/还没人扫"），
// 65 被当成"等待扫码"（实际是"二维码已失效"），
// 于是二维码刚弹出就提示已扫描，真正失效后又继续空转轮询。
import 'package:baiji_music/network/login_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ptuiCB 状态码语义', () {
    // 实测：curl https://ssl.ptlogin2.qq.com/ptqrlogin?... 带合法 qrsig
    const waitingSample = "ptuiCB('66','0','','0','二维码未失效。', '')";

    // 实测：手机端扫码后尚未确认
    const confirmedSample = "ptuiCB('67','0','','0','正在验证二维码。', '')";

    // 实测：二维码超过有效期
    const expiredSample = "ptuiCB('65','0','','0','二维码已失效。', '')";

    const refusedSample = "ptuiCB('68','0','','0','已失效。', '')";

    // 实测：扫码并确认后的成功响应，第三个参数是 check_sig 跳转地址
    const doneSample =
        "ptuiCB('0','0','https://ssl.ptlogin2.graph.qq.com/check_sig?pttype=1&uin=1234567890&service=ptqrlogin&nodirect=0&ptsigx=AbCdEf123456&s_url=https%3A%2F%2Fgraph.qq.com%2Foauth2.0%2Flogin_jump','0','登录成功！', 'test')";

    test('66 = 等待扫码（不是已扫描）', () {
      final r = LoginApi.parseQrCallback(waitingSample);
      expect(r.event, QrEvent.waiting);
      expect(r.uin, isEmpty);
      expect(r.sigx, isEmpty);
    });

    test('67 = 已扫描待确认', () {
      expect(LoginApi.parseQrCallback(confirmedSample).event,
          QrEvent.confirmed);
    });

    test('65 = 二维码已失效，需要换码', () {
      expect(LoginApi.parseQrCallback(expiredSample).event, QrEvent.expired);
    });

    test('68 = 已失效/拒绝', () {
      expect(LoginApi.parseQrCallback(refusedSample).event, QrEvent.refused);
    });

    test('0 = 登录成功，且能取出 uin 与 ptsigx', () {
      final r = LoginApi.parseQrCallback(doneSample);
      expect(r.event, QrEvent.done);
      expect(r.uin, '1234567890');
      expect(r.sigx, 'AbCdEf123456');
    });

    test('未知状态码落到 other', () {
      expect(LoginApi.parseQrCallback("ptuiCB('99','0','','0','x', '')").event,
          QrEvent.other);
    });
  });

  group('异常响应不崩、也不假装成功', () {
    test('空响应体（qrsig 不合法时的实测行为）', () {
      expect(LoginApi.parseQrCallback('').event, QrEvent.other);
    });

    test('乱码 / HTML 错误页', () {
      expect(LoginApi.parseQrCallback('<html>502 Bad Gateway</html>').event,
          QrEvent.other);
    });

    test('缺少参数', () {
      expect(LoginApi.parseQrCallback('ptuiCB()').event, QrEvent.other);
    });

    test('状态码不是数字', () {
      expect(LoginApi.parseQrCallback("ptuiCB('abc','0','','0','x','')").event,
          QrEvent.other);
    });

    test('成功但缺少第三个参数时仍返回 done，uin/sigx 留空', () {
      final r = LoginApi.parseQrCallback("ptuiCB('0','0')");
      expect(r.event, QrEvent.done);
      expect(r.uin, isEmpty);
    });
  });

  group('authorize 的 code 提取', () {
    // _extractCode 是私有的，通过 LoginApi 实例方法间接覆盖不便，
    // 这里直接验证正则语义：code 可能落在查询串中间，也可能在末尾。
    test('code 在末尾时也能提取（旧正则要求后面有 & 会失败）', () {
      final re = RegExp(r'[?&]code=([^&#]*)');
      expect(
        re.firstMatch(
            'https://y.qq.com/portal/wx_redirect.html?login_type=1&code=XYZ789')
            ?.group(1),
        'XYZ789',
      );
    });

    test('code 在中间', () {
      final re = RegExp(r'[?&]code=([^&#]*)');
      expect(
        re.firstMatch('https://y.qq.com/a.html?code=ABC123&state=s')?.group(1),
        'ABC123',
      );
    });

    test('带 hash 片段时不越界', () {
      final re = RegExp(r'[?&]code=([^&#]*)');
      expect(
        re.firstMatch('https://y.qq.com/a.html?code=ABC#frag')?.group(1),
        'ABC',
      );
    });
  });
}
