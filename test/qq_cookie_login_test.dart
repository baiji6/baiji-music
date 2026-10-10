// QQ 音乐 Cookie 登录的解析测试（QQ 登录 + 微信登录）。
//
// 样本是**真实浏览器 cookie**，不是手写构造：
// 微信样本来自 y.qq.com 用微信账号登录后复制出来的整段 Cookie。
//
// 之所以要专门覆盖微信：两种登录的 cookie 只差一个字段——
// 微信登录的 cookie 里根本没有 `uin` 键，账号 id 放在 `wxuin`（19 位大整数），
// 而这个值在后续请求中填的就是 `uin` 的位置。
// 原实现只认 `uin` / `qqmusic_uin` / `uin_android` / `w_uin` / `u`，
// 于是微信 cookie 一律报「Cookie 中缺少 uin」，登录直接失败。
import 'package:baiji_music/network/login_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 微信登录（网页端 y.qq.com → 微信账号）的真实 Cookie。
/// 注意：没有 `uin`，取而代之的是 `wxuin=1152921505204879592`；
/// 票据 `W_X_` 开头；同时存在语义相反的 `tmeLoginType=1` 与 `login_type=2`。
const String wxCookieSample =
    'pgv_pvid=2955ce7504dd99aa; video_omgid=1349247e3ada7446adbe65a8a26f1194; '
    '_qimei_uuid42=1aa0a1535281004ff0d1b35ce12b94d325cb3b6a13; '
    '_qimei_fingerprint=d76d63a12901f1dc687f21595862784d; '
    'fqm_pvqid=a2a3271a-3f7a-48e0-ac58-e97ae5f2978e; '
    '_tme_did=secid_v1_67894f3e01dbf5883bac30a634a01832f7dd; '
    'music_ignore_pskey=202306271436Hn@vBj; pgv_info=ssid=s2945370822; '
    'ts_last=y.qq.com/; ts_refer=ADTAGmyqq; ts_uid=9448904372; '
    '_qpsvr_localtk=0.26942757774267445; '
    'qlogin_uid=3a6f792a0fa3f3869e04fdbd048ce945; '
    'qm_keyst=W_X_63b0aM5vlp02qhQc_XzTyoAdbSqQ75NhdorvIrEg0Sa1nVD1Ef7Y4SMuoJhMSIHmYj1rFdFOUDj2YeFcqYCL48hqjvHcuRQ; '
    'euin=oK6kowEAoK4z7K-z7eclNK4qoc**; psrf_qqopenid=; psrf_qqunionid=; '
    'qqmusic_key=W_X_63b0aM5vlp02qhQc_XzTyoAdbSqQ75NhdorvIrEg0Sa1nVD1Ef7Y4SMuoJhMSIHmYj1rFdFOUDj2YeFcqYCL48hqjvHcuRQ; '
    'tmeLoginType=1; wxunionid=oqFLxsgKvUNHa-LNQrJD9Z587HeI; '
    'psrf_qqrefresh_token=; wxuin=1152921505204879592; '
    'psrf_qqaccess_token=; '
    'wxrefresh_token=1_7YUU8XZJFLl-FsA7kFAoRJcbpoEF_KxEoDZ8vexr03V36LMaB8-gVCEAAeVn4aN20yfvkL6AWiwIPkOwzMHLXdkoUiL47nSMKIiBQHJAvvE1fsPMIg; '
    'wxopenid=opCFJw7n5qtv6zOZg2Y3qBLOeSSQ; login_type=2';

/// QQ 账号登录的典型 Cookie（票据以 `Q_H_L_` 开头，loginType=2）。
const String qqCookieSample =
    'pgv_pvid=1234567890; pgv_rsid=1234567890; '
    'uin=o0123456789; '
    'qm_keyst=Q_H_L_abcdefghijklmnopqrstuvwxyz0123456789; '
    'qqmusic_key=Q_H_L_abcdefghijklmnopqrstuvwxyz0123456789; '
    'euin=oK6kowEAoK4z7K-z7eclNK4qoc**; '
    'login_type=1; tmeLoginType=2';

void main() {
  group('微信登录 Cookie', () {
    test('没有 uin 键时用 wxuin 当账号 id', () {
      final cred = LoginApi.parseCookieCredentials(wxCookieSample);

      expect(cred.strMusicid, '1152921505204879592');
      expect(cred.musicid, 1152921505204879592);
      expect(cred.isLoggedIn(), isTrue);
    });

    test('19 位的 wxuin 不溢出 Dart int', () {
      final cred = LoginApi.parseCookieCredentials(wxCookieSample);
      // 微信 uin 是 1.15e18，QQ 号通常不到 10 位；这里锁死「不被截断成 32 位」。
      expect(cred.musicid.toString(), '1152921505204879592');
      expect(cred.musicid, greaterThan(0x7FFFFFFF));
    });

    test('票据取自 qm_keyst 且 W_X_ 前缀判为微信登录', () {
      final cred = LoginApi.parseCookieCredentials(wxCookieSample);
      expect(cred.musickey, startsWith('W_X_'));
      expect(cred.loginType, 1);
    });

    test('wxunionid / wxopenid 不写入 unionid、openid', () {
      // 这三个字段与 QQ 互联的 unionid/openid 不是一回事，
      // 填进去只会让后续接口拿错语义的标识去鉴权。
      final cred = LoginApi.parseCookieCredentials(wxCookieSample);
      expect(cred.unionid, isEmpty);
      expect(cred.openid, isEmpty);
    });
  });

  group('QQ 登录 Cookie', () {
    test('行为与改动前一致', () {
      final cred = LoginApi.parseCookieCredentials(qqCookieSample);
      expect(cred.strMusicid, 'o0123456789');
      expect(cred.musicid, 123456789);
      expect(cred.musickey, startsWith('Q_H_L_'));
      expect(cred.loginType, 2);
    });

    test('uin 的各种变体都被识别', () {
      const key = 'Q_H_L_key';
      for (final name in ['uin', 'qqmusic_uin', 'uin_android', 'w_uin', 'u']) {
        final cred = LoginApi.parseCookieCredentials('$name=10001; qm_keyst=$key');
        expect(cred.musicid, 10001, reason: '$name 应被识别');
      }
    });

    test('uin 与 wxuin 同时存在时优先取 uin', () {
      // 现实中不会同时出现，但真出现了也不该被 wxuin 悄悄顶掉。
      final cred = LoginApi.parseCookieCredentials(
          'uin=10001; wxuin=1152921505204879592; qm_keyst=Q_H_L_key');
      expect(cred.strMusicid, '10001');
    });
  });

  group('通用容错', () {
    test('浏览器复制的 "Cookie: xxx" 前缀会被剥掉', () {
      final cred = LoginApi.parseCookieCredentials(
          'Cookie: uin=10001; qm_keyst=Q_H_L_key');
      expect(cred.musicid, 10001);
    });

    test('值带引号时去引号', () {
      final cred =
          LoginApi.parseCookieCredentials('uin="10001"; qm_keyst="Q_H_L_key"');
      expect(cred.strMusicid, '10001');
      expect(cred.musickey, 'Q_H_L_key');
    });

    test('尾随分号与多余空格不影响解析', () {
      final cred = LoginApi.parseCookieCredentials(
          '  uin=10001 ;   qm_keyst=Q_H_L_key ;  ');
      expect(cred.musicid, 10001);
      expect(cred.musickey, 'Q_H_L_key');
    });

    test('只有 qqmusic_key 也能登录', () {
      final cred = LoginApi.parseCookieCredentials('wxuin=20002; qqmusic_key=W_X_k');
      expect(cred.musickey, 'W_X_k');
      expect(cred.musicid, 20002);
    });

    test('缺 uin/wxuin 时报明确错误', () {
      expect(
        () => LoginApi.parseCookieCredentials('qm_keyst=W_X_key'),
        throwsA(isA<Exception>()),
      );
    });

    test('缺票据时报明确错误', () {
      expect(
        () => LoginApi.parseCookieCredentials('wxuin=1152921505204879592'),
        throwsA(isA<Exception>()),
      );
    });

    test('空 Cookie 抛异常', () {
      expect(() => LoginApi.parseCookieCredentials('   '),
          throwsA(isA<Exception>()));
    });

    test('uin 里混入非数字字符时能剥离', () {
      // QQ 的 uin 常带 o 前缀（o0123456789）
      final cred =
          LoginApi.parseCookieCredentials('uin=o0123456789; qm_keyst=Q_H_L_key');
      expect(cred.musicid, 123456789);
    });
  });
}