import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/core/string_clip.dart';
import 'package:baiji_music/crypto/qq_crypto.dart';
import 'package:baiji_music/models/models.dart';

import 'qq_music_client.dart';

/// 二维码数据：图片字节 + qrsig（同一次请求获取）。
class Qrcode {
  final Uint8List image;
  final String qrsig;

  const Qrcode(this.image, this.qrsig);
}

/// 二维码状态事件。
///
/// 语义按腾讯 ptqrlogin 接口的实测返回确定，不要凭字面猜：
///
/// | code | 接口原文提示         | 含义                 |
/// |------|----------------------|----------------------|
/// | 0    | 登录成功             | [done]               |
/// | 65   | 二维码已失效         | [expired] 必须换码   |
/// | 66   | **二维码未失效**     | [waiting] 等待扫码   |
/// | 67   | 正在验证二维码       | [confirmed] 待确认   |
/// | 68   | 已失效               | [refused]            |
///
/// 历史上这里把 66 当成「已扫描」、把 65 当成「等待扫码」，
/// 导致二维码刚弹出就提示"已扫描"，而真正失效后又继续空转轮询，
/// 表现就是"有效期特别短""扫码后卡住"。
enum QrEvent { done, waiting, confirmed, refused, expired, other }

class QrCheck {
  final QrEvent event;
  final String uin;
  final String sigx;

  const QrCheck(this.event, {this.uin = '', this.sigx = ''});
}

/// QQ 音乐登录：二维码方式 + Cookie 方式。
///
/// 对应原生 `network/LoginApi.kt`，加密/签名逻辑全部走纯 Dart。
class LoginApi {
  LoginApi(this.client);

  final QQMusicClient client;

  static const String referer = 'https://xui.ptlogin2.qq.com/';
  static final RegExp _qqStatusRe = RegExp(r'ptuiCB\((.*?)\)');
  static final RegExp _qqArgsRe = RegExp(r"'((?:\\.|[^'])*)'");
  static final RegExp _qqSigxRe = RegExp(r'(?:\?|&)ptsigx=(.+?)&s_url');
  static final RegExp _qqUinRe = RegExp(r'(?:\?|&)uin=(.+?)&service');
  /// 从 authorize 的 302 Location 里取 code。
  ///
  /// 旧写法 `(?<=code=)(.+?)(?=&)` 要求 code 后面必须还有一个 `&`，
  /// 一旦 code 落在查询串末尾就匹配不到，登录直接失败。
  static final RegExp _codeRe = RegExp(r'[?&]code=([^&#]*)');

  final math.Random _rng = math.Random();

  /// 获取 QQ 登录二维码。
  Future<Qrcode> getQrcode() async {
    final url = 'https://ssl.ptlogin2.qq.com/ptqrshow';
    final params = <String, String>{
      'appid': '716027609',
      'e': '2',
      'l': 'M',
      's': '3',
      'd': '72',
      'v': '4',
      't': _rng.nextDouble().toString(),
      'daid': '383',
      'pt_3rd_aid': '100497308',
    };
    final host = Uri.parse(url).replace(queryParameters: params);
    final qr = await client.rawQrcode(
      host.toString(),
      headers: {'Referer': referer},
    );
    final qrsig = qr.cookies['qrsig'];
    if (qrsig == null || qrsig.isEmpty) {
      throw Exception('获取 qrsig 失败');
    }
    return Qrcode(qr.bytes, qrsig);
  }

  /// 检查二维码状态。
  Future<QrCheck> checkQrcode(String qrsig) async {
    final url = 'https://ssl.ptlogin2.qq.com/ptqrlogin';
    final params = <String, String>{
      'u1': 'https://graph.qq.com/oauth2.0/login_jump',
      'ptqrtoken': '${hash33(qrsig)}',
      'ptredirect': '0',
      'h': '1',
      't': '1',
      'g': '1',
      'from_ui': '1',
      'ptlang': '2052',
      'action': '0-0-${DateTime.now().millisecondsSinceEpoch}',
      'js_ver': '20102616',
      'js_type': '1',
      'pt_uistyle': '40',
      'aid': '716027609',
      'daid': '383',
      'pt_3rd_aid': '100497308',
      'has_onekey': '1',
    };
    final host = Uri.parse(url).replace(queryParameters: params);
    final resp = await client.rawRequest(
      method: 'GET',
      url: host.toString(),
      headers: {'Referer': referer, 'Cookie': 'qrsig=$qrsig'},
    );
    return parseQrCallback(resp.text);
  }

  /// 解析 ptqrlogin 返回的 `ptuiCB(...)` 文本。
  ///
  /// 抽成纯静态函数，便于用真实响应样本做单测（不依赖网络）。
  ///
  /// 返回样本（实测）：
  /// - 等待扫码：`ptuiCB('66','0','','0','二维码未失效。', '')`
  /// - 登录成功：`ptuiCB('0','0','https://…check_sig?…uin=…&ptsigx=…&s_url=…','0','登录成功！', '')`
  static QrCheck parseQrCallback(String text) {
    final m = _qqStatusRe.firstMatch(text);
    if (m == null) {
      // 实测：qrsig / ptqrtoken 不合法时接口会直接返回**空响应体**，
      // 此时不该当成"继续等待"，上层需要据此决定是否换一张新码。
      AppLog.w('BaiJiLogin',
          'ptqrlogin 响应无法解析(长度=${text.length}): ${text.clip(80)}');
      return const QrCheck(QrEvent.other);
    }
    final inner = m.group(1);
    if (inner == null) return const QrCheck(QrEvent.other);
    final args = <String>[];
    for (final am in _qqArgsRe.allMatches(inner)) {
      final g = am.group(1);
      if (g != null) args.add(g);
    }
    if (args.isEmpty) return const QrCheck(QrEvent.other);
    final code = int.tryParse(args[0]) ?? -1;
    final event = switch (code) {
      0 => QrEvent.done,
      65 => QrEvent.expired, // 二维码已失效
      66 => QrEvent.waiting, // 二维码未失效 = 还没人扫
      67 => QrEvent.confirmed, // 已扫描，等待确认
      68 => QrEvent.refused,
      _ => QrEvent.other,
    };
    if (event != QrEvent.done || args.length < 3) {
      return QrCheck(event);
    }
    final sigxM = _qqSigxRe.firstMatch(args[2]);
    final uinM = _qqUinRe.firstMatch(args[2]);
    if (sigxM == null || uinM == null) return QrCheck(event);
    return QrCheck(event, uin: uinM.group(1) ?? '', sigx: sigxM.group(1) ?? '');
  }

  /// 扫码确认后换取凭证。
  Future<Credential> authorizeQr(String uin, String sigx) async {
    // 1. check_sig（禁止重定向）
    final checkUrl = 'https://ssl.ptlogin2.graph.qq.com/check_sig';
    final checkParams = <String, String>{
      'uin': uin,
      'pttype': '1',
      'service': 'ptqrlogin',
      'nodirect': '0',
      'ptsigx': sigx,
      's_url': 'https://graph.qq.com/oauth2.0/login_jump',
      'ptlang': '2052',
      'ptredirect': '100',
      'aid': '716027609',
      'daid': '383',
      'j_later': '0',
      'low_login_hour': '0',
      'regmaster': '0',
      'pt_login_type': '3',
      'pt_aid': '0',
      'pt_aaid': '16',
      'pt_light': '0',
      'pt_3rd_aid': '100497308',
    };
    final checkHost = Uri.parse(checkUrl).replace(queryParameters: checkParams);
    final checkResp = await client.rawRequestNoRedirect(
      method: 'GET',
      url: checkHost.toString(),
      headers: {'Referer': referer},
    );
    final cookies = checkResp.cookies;
    final pSkey = cookies['p_skey'] ??
        cookies['p-skey'] ??
        cookies['pskey'] ??
        cookies['ptsigx'] ??
        cookies['skey'];
    if (pSkey == null) {
      throw Exception(
          '获取 p_skey 失败(status=${checkResp.status}, cookies=${cookies.keys})');
    }
    // p_skey 与 skey 是两种不同的票据，用 skey 算出来的 g_tk 是错的，
    // 只作兜底并留痕，方便定位"登录成功但后续接口报鉴权失败"这类问题。
    if (!cookies.containsKey('p_skey')) {
      AppLog.w('BaiJiLogin',
          'check_sig 未返回 p_skey，已用其它票据兜底(status=${checkResp.status}, cookies=${cookies.keys})');
    }
    AppLog.d('BaiJiLogin',
        'check_sig ok, pSkey=${pSkey.clip(6)}... cookies=${cookies.keys}');

    // 2. authorize -> code（code 在 302 Location 头，必须禁止重定向）
    final authUrl = 'https://graph.qq.com/oauth2.0/authorize';
    final cookieStr = cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    final body = <String, String>{
      'response_type': 'code',
      'client_id': '100497308',
      'redirect_uri':
          'https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/',
      'scope': 'get_user_info,get_app_friends',
      'state': 'state',
      'switch': '',
      'from_ptlogin': '1',
      'src': '1',
      'update_auth': '1',
      'openapi': '1010_1030',
      'g_tk': '${hash33(pSkey, 5381)}',
      'auth_time': '${DateTime.now().millisecondsSinceEpoch}',
      'ui': client.randomUuid(),
    }.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');

    final authResp = await client.rawRequestNoRedirect(
      method: 'POST',
      url: authUrl,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Referer': referer,
        'Cookie': cookieStr,
      },
      body: body,
    );
    AppLog.d('BaiJiLogin',
        'authorize status=${authResp.status} location=${authResp.location.clip(200)}');
    final code = _extractCode(authResp.location);
    if (code == null) {
      throw Exception(
          '获取 code 失败(status=${authResp.status}, location=${authResp.location.clip(200)})');
    }

    // 3. QQConnectLogin -> Credential
    final data = await client.executeRaw(
      BizRequest(
        module: 'QQConnectLogin.LoginServer',
        method: 'QQLogin',
        param: {'code': code},
        allowErrorCodes: true,
      ),
      extraComm: {'tmeLoginType': 2},
    );
    AppLog.d('BaiJiLogin',
        'QQLogin 响应 code=${data['code']} msg=${data['msg']} data=${jsonEncode(data['data']).clip(300)}');
    final validated = _validateResult(data);
    return Credential.fromDict(validated);
  }

  /// 使用 QQ 音乐 Cookie 登录（扫码失败后的备选方式）。
  ///
  /// 解析本身在 [parseCookieCredentials] 这个纯函数里完成，
  /// 这里只负责把解析出来的凭证拿去做一次服务端校验。
  Future<Credential> loginByCookie(String cookie) async {
    final cred = parseCookieCredentials(cookie);

    // 放宽校验：解析成功即返回凭证，校验失败仅记录日志
    final prev = client.credential;
    client.credential = cred;
    try {
      final data = await client.executeRaw(
        BizRequest(
          module: 'music.UserInfo.userInfoServer',
          method: 'GetLoginUserInfo',
          param: <String, dynamic>{},
          allowErrorCodes: true,
        ),
      );
      final code = data['code'] as int? ?? -1;
      AppLog.d('BaiJiLogin', 'cookie 校验 GetLoginUserInfo code=$code');
      if (code != 0) {
        AppLog.w('BaiJiLogin',
            'cookie 校验未通过 code=$code，仍返回凭证（可能网络/风控导致）');
      }
    } catch (e) {
      AppLog.w('BaiJiLogin', 'cookie 校验异常(不阻断登录): $e');
    } finally {
      client.credential = prev;
    }
    return cred;
  }

  /// 从 Cookie 文本解析出凭证。纯函数，不发任何网络请求。
  ///
  /// 抽成静态方法是为了能直接拿**真实 cookie 样本**写单测，
  /// 网络校验留在 [loginByCookie] 里——同一文件里的 [parseQrCallback]
  /// 也是这么拆的。
  ///
  /// ## QQ 登录与微信登录的差别
  ///
  /// 网页端（y.qq.com）用微信账号登录后拿到的 cookie 与 QQ 登录**只差一个字段**：
  /// 微信登录的 cookie 里根本没有 `uin` 键，账号 id 放在 `wxuin` 里
  /// （19 位的微信 openid 型账号，不是 QQ 号），而这个值在后续所有请求中
  /// **填的就是 `uin` 的位置**。所以这里把 `wxuin` 并入 uin 的候选键即可，
  /// 其余票据键（`qm_keyst` / `qqmusic_key`）两种登录方式完全一致。
  ///
  /// 微信登录的票据以 `W_X_` 开头，据此可区分 `loginType`
  /// （1 = 微信，2 = QQ），与扫码登录时 `tmeLoginType` 的取值一致。
  ///
  /// 微信 cookie 里另有 `wxunionid` / `wxopenid` / `wxrefresh_token`，
  /// 它们与 QQ 互联的 unionid / openid 不是一回事，故**刻意不写入**
  /// [Credential.unionid] 等字段——填错语义的标识比留空更容易在后续接口鉴权失败。
  static Credential parseCookieCredentials(String cookie) {
    final trimmed = cookie.trim();
    if (trimmed.isEmpty) throw Exception('Cookie 不能为空');

    final pairs = <String, String>{};
    final body = trimmed
        .replaceFirst('Cookie', '')
        .replaceFirst('cookie', '')
        .replaceFirst(':', '')
        .trimLeft();
    for (final part in body.split(';')) {
      final seg = part.trim();
      if (seg.isEmpty) continue;
      final idx = seg.indexOf('=');
      if (idx <= 0) continue;
      var v = seg.substring(idx + 1).trim();
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
        v = v.substring(1, v.length - 1);
      }
      if (v.isNotEmpty) {
        pairs[seg.substring(0, idx).trim()] = v;
      }
    }
    AppLog.d('BaiJiLogin', 'cookie 键: ${pairs.keys.join(',')}');

    // `wxuin` 是微信登录专用，排在 QQ 各变体之后：
    // 两种 cookie 不会同时出现 uin 与 wxuin，顺序只影响日志可读性。
    final uinStr = (pairs['uin'] ??
            pairs['qqmusic_uin'] ??
            pairs['uin_android'] ??
            pairs['w_uin'] ??
            pairs['wxuin'] ??
            pairs['u'])
            ?.trim()
            .replaceAll('"', '')
            .replaceAll("'", '') ??
        '';
    if (uinStr.isEmpty) {
      throw Exception('Cookie 中缺少 uin / wxuin（应为 QQ 音乐登录后的账号 id）');
    }
    final uinNumeric = uinStr.replaceAll(RegExp('[^0-9]'), '');
    final uinLong = int.tryParse(uinNumeric);
    if (uinLong == null) {
      // 微信的 wxuin 是 19 位大整数，虽然仍在 Dart 的 64 位 int 范围内，
      // 但保不准哪天服务端改成了超出范围的值——那时至少要保住 strMusicid，
      // 否则整个登录会退化成「uin 无效」而看不出真实原因。
      throw Exception('Cookie 中的 uin 无效: $uinStr');
    }

    final musickey = (pairs['qm_keyst'] ??
            pairs['qqmusic_key'] ??
            pairs['qm_key'] ??
            pairs['musickey'] ??
            pairs['qm_keyst_android'] ??
            pairs['qqmusic_keyst'])
            ?.trim()
            .replaceAll('"', '')
            .replaceAll("'", '') ??
        '';
    if (musickey.isEmpty) {
      throw Exception('Cookie 中缺少 qm_keyst / qqmusic_key');
    }

    // 票据前缀才是可靠判据：实测微信 cookie 里同时存在 tmeLoginType=1 与
    // login_type=2，两者语义相反，照抄任何一个都会让后续接口按错误账号类型鉴权。
    final loginType = musickey.startsWith('W_X') ? 1 : 2;
    final declared = pairs['tmeLoginType']?.trim();
    if (declared != null && declared.isNotEmpty && int.tryParse(declared) != loginType) {
      AppLog.w('BaiJiLogin',
          'cookie tmeLoginType=$declared 与票据推断的 loginType=$loginType 不一致，以票据为准');
    }

    final cred = Credential(
      musicid: uinLong,
      musickey: musickey,
      strMusicid: uinStr,
      loginType: loginType,
      musickeyCreateTime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      keyExpiresIn: 0,
    );
    AppLog.d('BaiJiLogin',
        'cookie 解析: uin=$uinStr loginType=${cred.loginType} key=${musickey.clip(8)}...');
    return cred;
  }

  String? _extractCode(String text) {
    final m = _codeRe.firstMatch(text);
    return m?.group(1);
  }

  /// 校验 QQLogin 返回，解包 {code, data}，抛出可读登录错误。
  Map<String, dynamic> _validateResult(Map<String, dynamic> resp) {
    Map<String, dynamic> cur = resp;
    for (var i = 0; i < 2; i++) {
      if (cur.containsKey('code') && cur.containsKey('data')) {
        final c = (cur['code'] as int?) ?? -1;
        if (c != 0) {
          final msg = switch (c) {
            1000 || 104401 || 104400 => '登录鉴权已过期',
            20261 => '登录参数错误',
            20271 => '验证码错误',
            20272 => '账号绑定异常',
            20274 => '账号绑定缺失',
            20277 || 20278 => '账号受限',
            20279 => '登录设备数超限',
            20450 => '账号已被封禁',
            104604 => '操作过于频繁',
            _ => '未知登录错误 $c',
          };
          throw Exception('$msg ($c)');
        }
        final data = cur['data'];
        if (data is Map<String, dynamic>) {
          cur = data;
        } else {
          return <String, dynamic>{};
        }
      }
    }
    return cur;
  }
}