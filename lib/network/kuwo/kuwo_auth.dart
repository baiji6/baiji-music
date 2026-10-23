// 酷我音乐登录 —— 账号密码 / 短信验证码 / 会话续期 / 个人资料
//
// 协议逆向自倾听 5.5.0.2（com.listen.musicapp）的酷我链路，并与
// TuneWeave 的 Rust 实现（tuneweave-provider-kuwo/src/client/native/）
// 交叉核对。**沙箱内已逐条实测打通**（2026-10）：
//
//   账密登录  GET https://i.kuwo.cn/US_NEW/kuwo/login_kw?f=ar&q=<DES>
//             → 实测返回 {"result":"fail","msg":"用户名不存在",...}
//               （DES 双向链路正确的直接证据）
//   发送验证码 GET https://i.kuwo.cn/US_NEW/kuwo/send_sms?f=ar&q=<DES>
//             → 实测返回 {"result":"succ","msg":"ok","tm":"<服务端token>","status":200}
//   验证码登录 GET https://i.kuwo.cn/US_NEW/kuwo/login_sms?f=ar&q=<DES>
//   会话续期  GET https://i.kuwo.cn/US_NEW/kuwo/login/auto_login?f=ar&q=<DES>
//   个人资料  GET https://i.kuwo.cn/userinfo/lua_get_user_and_follow?f=ar&q=<DES>
//
// 统一的线上形制（详见 kuwo_cipher.dart）：
//   - q 参数 = base64(DES-ECB(查询串, "kwks&@69"))，查询串内部已 form 编码，
//     外层 q **不再编码**（官方客户端直接裸拼）；
//   - 响应体 = base64(DES-ECB(JSON, sx))，sx 是请求里自带的 8 位纯数字密钥
//     （毫秒时间戳前 8 位），两边必须一致；
//   - 元数据走 `Cookies` 头（复数，官方原生传输的形制，不是 Web Cookie）：
//     `user=<device_user>,ct=11,cv=12220,chid=newpcguanwangmobile,
//      QIMEI36=<q36>,tmeAppID=kwplayer,loginUid=<uid>,loginSid=<sid>,
//      appUid=<app_uid>,rom=<rom>`
//
// 设备身份三件套（类 UUIDv4 的 32 位 hex + 纯数字 app_uid）持久化在
// SharedPreferences，首次安装时生成，之后所有请求都带同一份。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../core/app_logger.dart';
import '../../core/app_version.dart';
import '../../core/kv_store.dart';
import '../../core/sm_crypto.dart';
import 'kuwo_cipher.dart';

/// 酷我登录/协议常量。
abstract final class KuwoAuthConst {
  /// 会话交换主机（实测 https 与 http 均可，优先 https）。
  static const String host = 'https://i.kuwo.cn';

  /// 账密登录。
  static const String passwordPath = '/US_NEW/kuwo/login_kw';

  /// 发送短信验证码。
  static const String smsSendPath = '/US_NEW/kuwo/send_sms';

  /// 短信验证码登录。
  static const String smsLoginPath = '/US_NEW/kuwo/login_sms';

  /// 会话续期（换新 sid，不需要密码）。
  static const String autoLoginPath = '/US_NEW/kuwo/login/auto_login';

  /// 个人资料（昵称 / 头像）。
  static const String profilePath = '/userinfo/lua_get_user_and_follow';

  /// 客户端版本号（与倾听/官方 ar 包对齐）。
  static const String clientVersion = '12.2.2.0';

  /// 客户端来源标识。
  static const String clientSource =
      'kwplayer_ar_12.2.2.0_newpcguanwangmobile.apk';

  /// QIMEI36（设备指纹，官方 SDK 的固定占位值）。
  static const String qimei36 = 'f2ce3c2ef68ddfd1b2bea7ed00001f314716';

  /// ROM 标识（带 App 版本号，服务端可据此区分客户端来源）。
  ///
  /// 引用 [AppVersion.current] 而不是写死字符串：升级时不会忘。
  static final String rom = 'baiji_music/${AppVersion.current}';

  /// 验证码长度（酷我固定 5 位）。
  static const int smsCodeLength = 5;
}

/// 酷我登录失败（带服务端原文，可直接展示给用户）。
class KuwoAuthError implements Exception {
  KuwoAuthError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 已登录的酷我会话。
class KuwoSession {
  const KuwoSession({
    required this.uid,
    required this.sid,
    this.nickname = '',
    this.avatar = '',
    this.username = '',
  });

  final String uid;
  final String sid;
  final String nickname;
  final String avatar;

  /// 登录时用的账号（账密登录才有；短信登录为空）。
  final String username;

  bool get isValid => uid.isNotEmpty && sid.isNotEmpty;

  Map<String, String> toJson() => {
        'uid': uid,
        'sid': sid,
        'nickname': nickname,
        'avatar': avatar,
        'username': username,
      };

  static KuwoSession? fromJson(Map<String, dynamic> json) {
    final uid = (json['uid'] ?? '').toString();
    final sid = (json['sid'] ?? '').toString();
    if (uid.isEmpty || sid.isEmpty) return null;
    return KuwoSession(
      uid: uid,
      sid: sid,
      nickname: (json['nickname'] ?? '').toString(),
      avatar: (json['avatar'] ?? '').toString(),
      username: (json['username'] ?? '').toString(),
    );
  }
}

/// 短信验证码接收凭据（一次性，绑定发送时的手机号与设备）。
class KuwoSmsChallenge {
  const KuwoSmsChallenge({
    required this.phone,
    required this.serverTm,
    required this.deviceUser,
    required this.appUid,
  });

  final String phone;

  /// 服务端在 send_sms 响应里下发的 token，login_sms 必须原样带回。
  final String serverTm;

  /// 发送时使用的设备身份（login_sms 要与发送时一致）。
  final String deviceUser;
  final String appUid;
}

/// 酷我设备身份（三件套，首次生成后持久化）。
class KuwoDevice {
  const KuwoDevice({
    required this.deviceUser,
    required this.androidId,
    required this.appUid,
  });

  final String deviceUser;

  /// 32 位 hex（部分校验接口会用到）。
  final String androidId;

  /// 纯数字、不以 0 开头（官方形制）。
  final String appUid;

  /// 元数据头（`Cookies`，复数——官方原生传输形制，非 Web Cookie）。
  String metadata({String loginUid = '0', String loginSid = '0'}) =>
      'user=$deviceUser,ct=11,cv=12220,chid=newpcguanwangmobile,'
      'QIMEI36=${KuwoAuthConst.qimei36},tmeAppID=kwplayer,'
      'loginUid=$loginUid,loginSid=$loginSid,appUid=$appUid,'
      'rom=${KuwoAuthConst.rom},';
}

/// 酷我登录。
///
/// 用法：
/// ```dart
/// await KuwoAuth.restore();                 // 启动时恢复会话
/// final s = await KuwoAuth.loginWithPassword('user', 'pass');
/// final c = await KuwoAuth.sendSms('13800138000');
/// final s2 = await KuwoAuth.loginWithSms(c, '12345');
/// await KuwoAuth.logout();
/// ```
abstract final class KuwoAuth {
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.plain,
  ));

  // ---------- 持久化键 ----------
  static const _kDeviceUser = 'kuwo_device_user';
  static const _kAndroidId = 'kuwo_device_android_id';
  static const _kAppUid = 'kuwo_device_app_uid';
  static const _kSession = 'kuwo_session';
  static const _kUsername = 'kuwo_username';
  static const _kPasswordEnc = 'kuwo_password_enc';

  /// 密码本地加密用的 SM4 密钥（16 字节）。
  ///
  /// 与备份文件加密同一套国密实现；目的不是对抗逆向，而是避免口令以明文
  /// 躺在 SharedPreferences 里（酷我登录必须回传 base64 口令，见
  /// [loginWithPassword]）。
  /// 长度由单测 `口令加密` 组锁死（SM4 硬性要求 16 字节，短一字节就抛）。
  static final Uint8List _pwKey =
      Uint8List.fromList(utf8.encode('baiji_kuwo_pwd_0'));

  /// SM4-CBC 的 IV（16 字节，固定值：同一口令每次加密结果一致，
  /// 便于备份迁移后直接比对，不追求语义安全）。
  static final Uint8List _pwIv =
      Uint8List.fromList(utf8.encode('baiji_kuwo_iv_00'));

  /// 当前会话（内存态；null = 未登录）。
  static KuwoSession? _session;

  /// 当前会话（未恢复时为 null）。
  static KuwoSession? get session => _session;

  static bool get isLoggedIn => _session?.isValid ?? false;

  /// 会话变化监听（设置页 / 评论页据此刷新）。
  static final List<void Function()> _listeners = [];

  static void addListener(void Function() listener) => _listeners.add(listener);

  static void removeListener(void Function() listener) =>
      _listeners.remove(listener);

  static void _notify() {
    for (final l in List<void Function()>.of(_listeners)) {
      l();
    }
  }

  // ==================== 设备身份 ====================

  static String _randomHex32() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    // 类 UUIDv4：version/variant 位，酷我的 valid_id 也按这个形状校验
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    return b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 取（必要时生成并持久化）设备身份。
  static Future<KuwoDevice> device() async {
    final kv = KvStore.instance;
    var user = kv.getString(_kDeviceUser, def: '') ?? '';
    var android = kv.getString(_kAndroidId, def: '') ?? '';
    var appUid = kv.getString(_kAppUid, def: '') ?? '';
    if (user.length != 32) {
      user = _randomHex32();
      await kv.setString(_kDeviceUser, user);
    }
    if (android.length != 32) {
      android = _randomHex32();
      await kv.setString(_kAndroidId, android);
    }
    if (appUid.isEmpty || appUid.startsWith('0') || int.tryParse(appUid) == null) {
      final r = Random.secure();
      appUid = '9${List.generate(9, (_) => r.nextInt(10)).join()}';
      await kv.setString(_kAppUid, appUid);
    }
    return KuwoDevice(deviceUser: user, androidId: android, appUid: appUid);
  }

  // ==================== 会话持久化 ====================

  /// 启动时调用：从本地恢复会话（不发请求）。
  static Future<KuwoSession?> restore() async {
    final raw = KvStore.instance.getString(_kSession, def: '') ?? '';
    if (raw.isEmpty) {
      _session = null;
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      _session = decoded is Map<String, dynamic>
          ? KuwoSession.fromJson(decoded)
          : null;
    } catch (_) {
      _session = null;
    }
    return _session;
  }

  static Future<void> _persist(KuwoSession s) async {
    _session = s;
    await KvStore.instance.setString(_kSession, jsonEncode(s.toJson()));
    _notify();
  }

  /// 退出登录（清会话；保留设备身份与已存账号口令，便于下次一键登录）。
  static Future<void> logout() async {
    _session = null;
    await KvStore.instance.remove(_kSession);
    _notify();
  }

  /// 彻底清除（含设备身份与已存口令）。
  static Future<void> clearAll() async {
    _session = null;
    final kv = KvStore.instance;
    for (final k in [
      _kSession,
      _kUsername,
      _kPasswordEnc,
      _kDeviceUser,
      _kAndroidId,
      _kAppUid,
    ]) {
      await kv.remove(k);
    }
    _notify();
  }

  // ==================== 账号口令留存（自动重登用） ====================

  /// 已留存的账号（空 = 没存过）。
  static String get savedUsername =>
      KvStore.instance.getString(_kUsername, def: '') ?? '';

  /// 是否留着了口令（可以一键重登）。
  static bool get hasSavedPassword =>
      (KvStore.instance.getString(_kPasswordEnc, def: '') ?? '').isNotEmpty;

  static Future<void> _saveCredentials(String username, String password) async {
    final kv = KvStore.instance;
    await kv.setString(_kUsername, username);
    await kv.setString(_kPasswordEnc, encryptPassword(password));
  }

  /// SM4-CBC 加密口令（base64 落盘）。
  ///
  /// 公开：备份/迁移会话时要原样带走密文。
  static String encryptPassword(String password) {
    final plain = Uint8List.fromList(utf8.encode(password));
    final enc = SmCrypto.sm4CbcEncrypt(_pwKey, _pwIv, plain);
    return base64.encode(enc);
  }

  /// 解开口令密文；任何不合法都返回 null（调用方按"没有留存"处理）。
  static String? decryptPassword(String enc) {
    try {
      final raw = base64.decode(enc);
      if (raw.isEmpty || raw.length % 16 != 0) return null;
      return utf8.decode(SmCrypto.sm4CbcDecrypt(_pwKey, _pwIv, raw));
    } catch (_) {
      return null;
    }
  }

  // ==================== 底层请求 ====================

  /// 发一个 `f=ar` 请求并解开响应体。
  ///
  /// [plain] 是已 form 编码的查询串，**必须自带 `sx=<8位数字>`**
  /// （各登录流程自己生成，见下方）；解密响应体用的就是同一个 sx，
  /// 两边不一致服务端就解不开、我们也解不开。
  /// [metadata] 非空时作为 `Cookies` 头带上。
  static Future<Map<String, dynamic>> _postAr(
    String path,
    String plain, {
    String? metadata,
  }) async {
    // 从查询串里取回本流程的 sx（解密响应体的密钥）
    final sxMatch = RegExp(r'(?:^|&)sx=(\d{8})(?:&|$)').firstMatch(plain);
    final sx = sxMatch?.group(1);
    if (sx == null) {
      throw StateError('酷我查询串缺少 sx（响应密钥）');
    }
    final q = KuwoCipher.sealQuery(plain);
    final url = '${KuwoAuthConst.host}$path?f=ar&q=$q';
    final resp = await _dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'Accept': 'application/json',
          'Cookies': ?metadata,
        },
      ),
    );
    final body = (resp.data ?? '').toString().trim();
    if (body.isEmpty) {
      throw KuwoAuthError('酷我服务器没有返回内容');
    }
    final jsonText = KuwoCipher.openResponse(body, sx);
    return _decodeJson(jsonText);
  }

  static Map<String, dynamic> _decodeJson(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw KuwoAuthError('酷我响应格式不正确');
    }
    return decoded;
  }

  /// 组装 form 编码查询串（内层值各自编码，外层 q 不再编码）。
  static String _formEncode(Map<String, String> params) => params.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');

  // ==================== 账密登录 ====================

  /// 账号密码登录（账号可以是用户名 / 手机号 / 邮箱）。
  ///
  /// 口令以 base64 明文随查询串下发（酷我官方客户端的形制，`urlencode=0`）。
  static Future<KuwoSession> loginWithPassword(
    String username,
    String password, {
    bool remember = true,
  }) async {
    final u = username.trim();
    if (u.isEmpty) throw KuwoAuthError('请输入账号');
    if (password.isEmpty) throw KuwoAuthError('请输入密码');

    final dev = await device();
    final plain = _formEncode({
      'username': u,
      'password': base64.encode(utf8.encode(password)),
      'dev_id': dev.appUid,
      'user': dev.deviceUser,
      'dev_name': 'baiji music',
      'urlencode': '0',
      'src': KuwoAuthConst.clientSource,
      'devResolution': '0*0',
      'from': 'android',
      'devType': 'SDK',
      'sx': KuwoCipher.newResponseKey(),
      'version': KuwoAuthConst.clientVersion,
    });
    final body = await _postAr(
      KuwoAuthConst.passwordPath,
      plain,
      metadata: dev.metadata(),
    );
    final session = _parseSession(body);
    // 顺手把昵称/头像补全（失败不阻塞登录）
    final full = await _fillProfile(session);
    if (remember) await _saveCredentials(u, password);
    return full;
  }

  // ==================== 短信登录 ====================

  /// 发短信验证码。返回一次性凭据，供 [loginWithSms] 使用。
  static Future<KuwoSmsChallenge> sendSms(String phone) async {
    final p = phone.trim();
    if (!isValidPhone(p)) {
      throw KuwoAuthError('请输入 11 位中国大陆手机号');
    }
    final dev = await device();
    final tm = DateTime.now().millisecondsSinceEpoch.toString();
    // secret = MD5( MD5("imbadboy@!153") + MD5(手机号 + "4" + tm) )，均 32 位大写
    // （与 TuneWeave 的 synthetic 测试向量逐字节对齐）
    final secret = smsSecret(p, tm);
    final plain = _formEncode({
      'mobile': p,
      'type': '4',
      'tm': tm,
      'secret': secret,
      'src': KuwoAuthConst.clientSource,
      'version': KuwoAuthConst.clientVersion,
      'dev_id': dev.appUid,
      'user': dev.deviceUser,
      'dev_name': 'baiji music',
      'devType': 'SDK',
      'sx': KuwoCipher.newResponseKey(),
      'from': 'android',
      'devResolution': '0*0',
    });
    final body = await _postAr(
      KuwoAuthConst.smsSendPath,
      plain,
      metadata: dev.metadata(),
    );
    // 实测成功形如 {"result":"succ","msg":"ok","tm":"1792731987","status":200}
    final ok = (body['result'] ?? body['ret']) == 'succ';
    if (!ok) {
      throw KuwoAuthError(_errorText(body) ?? '验证码发送失败');
    }
    final serverTm = (body['tm'] ?? '').toString();
    if (serverTm.isEmpty || serverTm == '0') {
      throw KuwoAuthError('验证码发送失败（服务端未返回凭证）');
    }
    AppLog.i('KuwoAuth', '酷我验证码已发送 phone=$p');
    return KuwoSmsChallenge(
      phone: p,
      serverTm: serverTm,
      deviceUser: dev.deviceUser,
      appUid: dev.appUid,
    );
  }

  /// 用验证码登录（消费 [KuwoSmsChallenge]）。
  static Future<KuwoSession> loginWithSms(
    KuwoSmsChallenge challenge,
    String code,
  ) async {
    final c = code.trim();
    if (c.length != KuwoAuthConst.smsCodeLength || int.tryParse(c) == null) {
      throw KuwoAuthError('请输入 ${KuwoAuthConst.smsCodeLength} 位数字验证码');
    }
    final plain = _formEncode({
      'mobile': challenge.phone,
      'code': c,
      'tm': challenge.serverTm,
      'src': KuwoAuthConst.clientSource,
      'version': KuwoAuthConst.clientVersion,
      'dev_id': challenge.appUid,
      'dev_name': 'baiji music',
      'devType': 'SDK',
      'sx': KuwoCipher.newResponseKey(),
      'from': 'android',
      'devResolution': '0*0',
    });
    final body = await _postAr(
      KuwoAuthConst.smsLoginPath,
      plain,
      metadata: 'user=${challenge.deviceUser},ct=11,cv=12220,'
          'chid=newpcguanwangmobile,QIMEI36=${KuwoAuthConst.qimei36},'
          'tmeAppID=kwplayer,loginUid=0,loginSid=0,'
          'appUid=${challenge.appUid},rom=${KuwoAuthConst.rom},',
    );
    final session = _parseSession(body);
    return _fillProfile(session);
  }

  // ==================== 续期 ====================

  /// 用已有会话换新 sid（不需要密码）。
  ///
  /// 成功会更新本地会话；失败抛 [KuwoAuthError]。
  static Future<KuwoSession> renewSession(KuwoSession current) async {
    final dev = await device();
    final plain = _formEncode({
      'uid': current.uid,
      'sid': current.sid,
      'username': '',
      'password': '',
      'dev_id': dev.appUid,
      'dev_name': 'baiji music',
      'user': dev.deviceUser,
      'src': KuwoAuthConst.clientSource,
      'urlencode': '1',
      'devResolution': '0*0',
      'devType': 'SDK',
      'sx': KuwoCipher.newResponseKey(),
      'from': 'android',
      'version': KuwoAuthConst.clientVersion,
    });
    final body = await _postAr(
      KuwoAuthConst.autoLoginPath,
      plain,
      metadata: dev.metadata(
        loginUid: current.uid,
        loginSid: current.sid,
      ),
    );
    final renewed = _parseSession(body);
    return _persistAndReturn(KuwoSession(
      uid: renewed.uid,
      sid: renewed.sid,
      nickname: renewed.nickname.isNotEmpty ? renewed.nickname : current.nickname,
      avatar: renewed.avatar.isNotEmpty ? renewed.avatar : current.avatar,
      username: current.username,
    ));
  }

  /// 确保有一个可用会话：先试续期，续期失败且留过口令则重登。
  ///
  /// 返回 null 表示本地没有会话可用。
  static Future<KuwoSession?> ensureSession() async {
    final cur = _session;
    if (cur == null || !cur.isValid) return null;
    try {
      return await renewSession(cur);
    } on KuwoAuthError catch (e) {
      AppLog.w('KuwoAuth', '会话续期失败：$e');
    } catch (_) {}
    // 续期失败：有留存口令就用账密重登
    final username = savedUsername;
    final enc = KvStore.instance.getString(_kPasswordEnc, def: '') ?? '';
    final password = enc.isEmpty ? null : decryptPassword(enc);
    if (username.isNotEmpty && password != null && password.isNotEmpty) {
      try {
        AppLog.i('KuwoAuth', '会话续期失败，改用留存口令重登');
        return await loginWithPassword(username, password);
      } catch (e) {
        AppLog.w('KuwoAuth', '留存口令重登失败：$e');
      }
    }
    return null;
  }

  // ==================== 个人资料 ====================

  /// 取昵称与头像，补全会话。失败时原样返回（不阻塞登录）。
  static Future<KuwoSession> _fillProfile(KuwoSession s) async {
    try {
      final dev = await device();
      final plain = _formEncode({
        'uid': s.uid,
        'tid': s.uid,
        'src': KuwoAuthConst.clientSource,
        'version': KuwoAuthConst.clientVersion,
        'dev_id': dev.appUid,
        'app_id': dev.appUid,
        'user': dev.deviceUser,
        'sx': KuwoCipher.newResponseKey(),
        'from': 'android',
      });
      final body = await _postAr(
        KuwoAuthConst.profilePath,
        plain,
        metadata: dev.metadata(loginUid: s.uid, loginSid: s.sid),
      );
      final info = body['info'];
      if (info is List && info.isNotEmpty && info.first is Map) {
        final m = Map<String, dynamic>.from(info.first as Map);
        return await _persistAndReturn(KuwoSession(
          uid: s.uid,
          sid: s.sid,
          nickname: (m['nickname'] ?? m['nickName'] ?? '').toString(),
          avatar: (m['picture'] ?? m['pic'] ?? '').toString(),
          username: s.username,
        ));
      }
    } catch (e) {
      AppLog.w('KuwoAuth', '拉取酷我个人资料失败：$e');
    }
    return await _persistAndReturn(s);
  }

  // ==================== 解析 ====================

  /// 解析登录/续期响应，取出 uid + sid。
  ///
  /// 实测失败样本：
  ///   `{"result":"fail","msg":"用户名不存在","text":"...","enum":"3"}`
  ///   `{"result":"fail","msg":"该用户已注销，请核实后重新输入","enum":"3","status":1136}`
  static KuwoSession _parseSession(Map<String, dynamic> body) {
    final outcome = (body['ret'] ?? body['result'] ?? '').toString();
    if (outcome != 'succ') {
      throw KuwoAuthError(_errorText(body) ?? '酷我登录失败');
    }
    final sid = (body['sid'] ?? '').toString();
    final user = _userOf(body['userInfo']);
    final uid = (user?['uid'] ?? user?['UID'] ?? '').toString();
    if (uid.isEmpty || sid.isEmpty) {
      throw KuwoAuthError('酷我登录响应不完整');
    }
    final nickname =
        (user?['nickName'] ?? user?['nickname'] ?? '').toString();
    return KuwoSession(uid: uid, sid: sid, nickname: nickname);
  }

  /// `userInfo` 可能是对象，也可能是 JSON 字符串（两种都见过）。
  static Map<String, dynamic>? _userOf(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String && raw.isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is Map<String, dynamic>) return d;
      } catch (_) {}
    }
    return null;
  }

  /// 从失败响应里挑一句人能看懂的话。
  static String? _errorText(Map<String, dynamic> body) {
    for (final key in ['msg', 'text', 'message', 'error']) {
      final v = (body[key] ?? '').toString().trim();
      if (v.isNotEmpty && v != 'fail' && v != 'null') return v;
    }
    return null;
  }

  static Future<KuwoSession> _persistAndReturn(KuwoSession s) async {
    await _persist(s);
    return s;
  }

  // ==================== 工具 ====================

  /// 中国大陆手机号形制（1 + 3..9 开头，共 11 位数字）。
  ///
  /// 公开：登录页在发验证码前先本地预检，避免无谓请求。
  static bool isValidPhone(String p) =>
      p.length == 11 &&
      p.startsWith('1') &&
      (p.codeUnitAt(1) >= 0x33 && p.codeUnitAt(1) <= 0x39) &&
      int.tryParse(p) != null;

  /// 短信验证码 secret：`MD5_upper(MD5_upper("imbadboy@!153") + MD5_upper(手机号+"4"+tm))`。
  ///
  /// 公开：协议的一部分，且单测要拿 TuneWeave 的 synthetic 向量逐字节比对。
  static String smsSecret(String phone, String tm) =>
      _md5Upper('${_md5Upper('imbadboy@!153')}${_md5Upper('${phone}4$tm')}');

  static String _md5Upper(String s) =>
      md5.convert(utf8.encode(s)).toString().toUpperCase();
}
