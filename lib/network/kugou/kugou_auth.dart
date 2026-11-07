// 酷狗音乐登录 —— 二维码扫码 + 手动 userid/token + 设备身份持久化。
//
// 协议抄自 HotDownloader `kugou/login.rs`（并与倾听 5.6.14 反编译出的
// `KugouLoginService` / `login-user.kugou.com/v2/qrcode` 交叉核对）。沙箱内
// 已逐条实测打通（2026-11）：
//
//   创建二维码 GET  https://login-user.kugou.com/v2/qrcode
//       params: appid=1001, type=1, plat=4, srcappid=2919,
//               qrcode_txt=... , + 设备三件套(mid/dfid/dev) + 公共参数
//       → data.qrcode（轮询 key）、data.qrcode_img（data:image/png;base64）
//   轮询状态   GET  https://login-user.kugou.com/v2/get_userinfo_qrcode
//       params: appid=1005, srcappid=2919, plat=4, qrcode=<key>, + 设备/公共
//       → data.status: 1=等待扫码 2=已扫码待确认 4=已确认（含 userid/token）
//
// 登录接口与 gateway 的关键差异：签名盐值是 **kugouLoginSalt**
// （NVPh5oo…），不是 gateway 的 OIlwieks…；二者其余公共参数一致
// （见 HotDownloader client.rs 的 request_with）。
//
// 登录的意义在音质：未登录取 /v5/url 高音质会返回 status:2（版权/会员
// 限制）。登录后的 userid/token 必须随设备 mid/dfid/dev 一起注入取链参数
// 才能解锁 flac / Hi-Res，见 [requestParams] 与 kugou_api._fetchUrl。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../core/app_logger.dart';
import '../../core/kv_store.dart';
import 'kugou_cipher.dart';

/// 酷狗登录接口常量。
abstract final class KugouAuthConst {
  static const String loginHost = 'https://login-user.kugou.com';
  static const String qrCreatePath = '/v2/qrcode';
  static const String qrCheckPath = '/v2/get_userinfo_qrcode';

  /// 二维码 H5 落地页（qrcode_img 未下发时用 qr_flutter 本地渲染此 URL）。
  static const String qrLanding =
      'https://h5.kugou.com/apps/loginQRCode/html/index.html';

  /// qrcode_txt：官方客户端创建二维码时携带的前缀。
  static const String qrcodeTxt =
      'https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=1005&';

  static const String ua =
      'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';
}

/// 二维码轮询状态。
enum KugouQrEvent { waiting, scanned, confirmed, expired }

/// 一次轮询的结果；[KugouQrEvent.confirmed] 时 [userid]/[token] 非空。
class KugouQrStatus {
  const KugouQrStatus(this.event, {this.userid = '', this.token = ''});

  final KugouQrEvent event;
  final String userid;
  final String token;

  bool get isDone => event == KugouQrEvent.confirmed;
}

/// 一张待扫的二维码：轮询 key + 服务端下发的 PNG + 兜底 URL。
class KugouQr {
  const KugouQr({
    required this.key,
    required this.url,
    this.imageBytes,
  });

  /// /v2/get_userinfo_qrcode 的 qrcode 参数。
  final String key;

  /// H5 落地页 URL（qrcode_img 缺失时供 qr_flutter 渲染）。
  final String url;

  /// 服务端直接返回的二维码 PNG（data:image/png;base64 解出的字节）。
  final Uint8List? imageBytes;

  bool get hasImage => imageBytes != null && imageBytes!.isNotEmpty;
}

/// 已登录的酷狗会话。
class KugouSession {
  const KugouSession({required this.userid, required this.token});

  final String userid;
  final String token;

  bool get isValid =>
      userid.isNotEmpty && token.isNotEmpty && int.tryParse(userid) != null;

  Map<String, String> toJson() => {'userid': userid, 'token': token};

  static KugouSession? fromJson(Map<String, dynamic> json) {
    final s = KugouSession(
      userid: (json['userid'] ?? '').toString(),
      token: (json['token'] ?? '').toString(),
    );
    return s.isValid ? s : null;
  }
}

/// 酷狗设备身份（三件套，首次生成后持久化，登录态与 mid 绑定）。
class KugouDevice {
  const KugouDevice({required this.mid, required this.dfid, required this.dev});

  /// 32 位小写 hex。
  final String mid;

  /// dfid（官方匿名时为 '-'）。
  final String dfid;

  /// dev，32 位小写 hex。
  final String dev;

  Map<String, String> toParams() => {'mid': mid, 'dfid': dfid, 'dev': dev};
}

/// 酷狗登录。
///
/// 用法：
/// ```dart
/// await KugouAuth.restore();                 // 启动时恢复会话
/// final qr = await KugouAuth.createQr();     // 扫码登录
/// final st = await KugouAuth.checkQr(qr.key);
/// await KugouAuth.saveManual('12345', 'token'); // 或手动凭据
/// await KugouAuth.logout();
/// ```
abstract final class KugouAuth {
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.plain,
  ));

  // ---------- 持久化键 ----------
  static const _kMid = 'kugou_device_mid';
  static const _kDfid = 'kugou_device_dfid';
  static const _kDev = 'kugou_device_dev';
  static const _kSession = 'kugou_session';

  static KugouSession? _session;

  /// 当前会话（未恢复时为 null）。
  static KugouSession? get session => _session;

  static bool get isLoggedIn => _session?.isValid ?? false;

  /// 会话变化监听（设置页据此刷新登录态）。
  static final List<void Function()> _listeners = [];

  static void addListener(void Function() l) => _listeners.add(l);

  static void removeListener(void Function() l) => _listeners.remove(l);

  static void _notify() {
    for (final l in List<void Function()>.of(_listeners)) {
      l();
    }
  }

  // ==================== 设备身份 ====================

  static String _randomHex32() {
    final r = Random.secure();
    return md5
        .convert(utf8.encode(
            '${DateTime.now().microsecondsSinceEpoch}-${r.nextInt(1 << 30)}-${r.nextInt(1 << 30)}'))
        .toString();
  }

  /// 取（必要时生成并持久化）设备三件套。
  ///
  /// 与 HotDownloader `device()` 一致：mid/dev 为两个 32 位小写 hex，
  /// dfid 匿名时为 '-'。登录 token 与 mid 绑定，务必全程复用同一份。
  static Future<KugouDevice> device() async {
    final kv = KvStore.instance;
    var mid = kv.getString(_kMid, def: '') ?? '';
    var dfid = kv.getString(_kDfid, def: '') ?? '';
    var dev = kv.getString(_kDev, def: '') ?? '';
    if (mid.length != 32) {
      mid = _randomHex32();
      await kv.setString(_kMid, mid);
    }
    if (dfid.isEmpty) {
      dfid = '-';
      await kv.setString(_kDfid, dfid);
    }
    if (dev.length != 32) {
      dev = _randomHex32();
      await kv.setString(_kDev, dev);
    }
    return KugouDevice(mid: mid, dfid: dfid, dev: dev);
  }

  // ==================== 会话持久化 ====================

  /// 启动时调用：从本地恢复会话（不发请求）。
  static Future<KugouSession?> restore() async {
    final raw = KvStore.instance.getString(_kSession, def: '') ?? '';
    if (raw.isEmpty) {
      _session = null;
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      _session = decoded is Map<String, dynamic>
          ? KugouSession.fromJson(decoded)
          : null;
    } catch (_) {
      _session = null;
    }
    return _session;
  }

  /// 保存会话（供扫码确认 / 手动登录调用）。
  static Future<void> _persist(KugouSession s) async {
    _session = s;
    await KvStore.instance.setString(_kSession, jsonEncode(s.toJson()));
    _notify();
  }

  /// 手动凭据登录（userid + token，可附带同一次登录的设备信息）。
  ///
  /// 对照 HotDownloader `execute("manual")`：userid 必须是正整数，
  /// token 非空且不含控制字符；mid/dfid 若提供则覆盖设备身份（务必与
  /// 取得 token 时是同一台设备，否则取链鉴权会失败）。
  static Future<KugouSession> saveManual(
    String userid,
    String token, {
    String mid = '',
    String dfid = '',
  }) async {
    final u = userid.trim();
    final t = token.trim();
    final uid = int.tryParse(u);
    if (uid == null || uid <= 0) {
      throw KugouAuthError('请填写有效的酷狗 userid（纯数字）');
    }
    if (t.isEmpty || t.length > 4096 || t.codeUnits.any((c) => c < 32)) {
      throw KugouAuthError('请填写有效的酷狗 token');
    }
    if (mid.isNotEmpty || dfid.isNotEmpty) {
      final kv = KvStore.instance;
      final allowed = RegExp(r'^[A-Za-z0-9\-]+$');
      if (mid.isNotEmpty) {
        if (mid.length > 128 || !allowed.hasMatch(mid)) {
          throw KugouAuthError('MID 只能包含字母、数字或短横线');
        }
        await kv.setString(_kMid, mid);
      }
      if (dfid.isNotEmpty) {
        if (dfid.length > 128 || !allowed.hasMatch(dfid)) {
          throw KugouAuthError('DFID 只能包含字母、数字或短横线');
        }
        await kv.setString(_kDfid, dfid);
      }
    }
    final s = KugouSession(userid: u, token: t);
    await _persist(s);
    AppLog.i('KugouAuth', '酷狗手动登录已保存 userid=$u');
    return s;
  }

  /// 退出登录（清会话，保留设备身份，便于下次扫码沿用同一设备）。
  static Future<void> logout() async {
    _session = null;
    await KvStore.instance.remove(_kSession);
    _notify();
  }

  /// 彻底清除（含设备身份）。
  static Future<void> clearAll() async {
    _session = null;
    final kv = KvStore.instance;
    for (final k in [_kSession, _kMid, _kDfid, _kDev]) {
      await kv.remove(k);
    }
    _notify();
  }

  // ==================== 取链凭据注入 ====================

  /// 供 /v5/url 取链使用的参数（设备 + 登录态）。
  ///
  /// 未登录时 userid=0、token 为空，服务端按匿名处理（只能取 128k）；
  /// 登录后带上真实 userid/token 才能解锁 flac / Hi-Res。mid 恒为持久化
  /// 设备值（不再是每次随机），保证与 token 绑定一致。
  static Future<Map<String, String>> requestParams() async {
    final dev = await device();
    final s = _session;
    return <String, String>{
      ...dev.toParams(),
      'userid': s?.isValid == true ? s!.userid : '0',
      if (s?.isValid == true) 'token': s!.token,
    };
  }

  // ==================== 底层登录请求 ====================

  /// 组装完整查询串并签名（login-user 域名专用 salt）。
  ///
  /// 与 HotDownloader `request_with` 一致：先放公共参数，再用业务参数
  /// 覆盖同名键，最后按 key 排序做 md5(SALT+joined+SALT) 签名。
  static Map<String, String> _signedQuery(
      Map<String, String> business, KugouDevice dev) {
    final now = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final q = <String, String>{
      ...kugouGatewayCommon(mid: dev.mid),
      ...dev.toParams(),
      ...business,
    };
    // 公共参数里的 clientver 是 20489，登录业务沿用；clienttime 每次刷新。
    q['clienttime'] = now;
    q['signature'] = kugouSign(q, kugouLoginSalt);
    return q;
  }

  static Map<String, String> get _headers => const {
        'User-Agent': KugouAuthConst.ua,
        'kg-rc': '1',
        'kg-thash': '5d816a0',
        'kg-rec': '1',
        'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
        'kg-tid': '255',
      };

  static Future<Map<String, dynamic>> _getJson(
      String path, Map<String, String> q) async {
    final url =
        '${KugouAuthConst.loginHost}$path?${kugouBuildQuery(q)}';
    final resp = await _dio.get<String>(url,
        options: Options(responseType: ResponseType.plain, headers: _headers));
    final body = (resp.data ?? '').toString();
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw KugouAuthError('酷狗登录响应格式不正确');
    }
    final m = Map<String, dynamic>.from(decoded);
    final status = (m['status'] as num?)?.toInt() ?? 0;
    final code = (m['error_code'] ?? m['errcode'] ?? 0);
    final codeInt = code is num ? code.toInt() : int.tryParse('$code') ?? 0;
    if ((status != 1 && status != 200) || codeInt != 0) {
      final msg = (m['error_msg'] ?? m['errmsg'] ?? m['msg'] ?? '').toString();
      throw KugouAuthError(
          '酷狗登录请求失败 ($codeInt)${msg.isNotEmpty ? '：$msg' : ''}');
    }
    return m;
  }

  // ==================== 二维码登录 ====================

  /// 创建登录二维码。
  ///
  /// 实测服务端直接下发 `data.qrcode_img`（data:image/png;base64），
  /// 优先用它；同时给出 H5 URL 兜底（qr_flutter 本地渲染）。
  static Future<KugouQr> createQr() async {
    final dev = await device();
    final business = <String, String>{
      'appid': '1001',
      'type': '1',
      'plat': '4',
      'srcappid': '2919',
      'qrcode_txt': KugouAuthConst.qrcodeTxt,
    };
    final data = await _getJson(
        KugouAuthConst.qrCreatePath, _signedQuery(business, dev));
    final d = data['data'] is Map
        ? Map<String, dynamic>.from(data['data'] as Map)
        : <String, dynamic>{};
    final key = (d['qrcode'] ?? '').toString();
    if (key.isEmpty) throw KugouAuthError('酷狗未返回二维码标识');
    final img = decodeQrImage((d['qrcode_img'] ?? '').toString());
    final landing = '$KugouAuthConst.qrLanding?qrcode=${Uri.encodeComponent(key)}';
    AppLog.i('KugouAuth', '酷狗二维码已创建 key=$key');
    return KugouQr(key: key, url: landing, imageBytes: img);
  }

  /// 解码 `data:image/png;base64,...` 为字节；非法或空返回 null。
  /// 抽成纯函数便于单测。
  static Uint8List? decodeQrImage(String dataUrl) {
    if (dataUrl.isEmpty || !dataUrl.contains(',')) return null;
    try {
      return base64.decode(dataUrl.split(',').last.trim());
    } catch (_) {
      return null;
    }
  }

  /// 服务端 data.status → 轮询事件（纯函数，可单测）。
  static KugouQrEvent mapPollStatus(int status) => switch (status) {
        1 => KugouQrEvent.waiting,
        2 => KugouQrEvent.scanned,
        4 => KugouQrEvent.confirmed,
        _ => KugouQrEvent.expired,
      };

  /// 轮询二维码状态；确认后自动持久化会话并返回 userid/token。
  static Future<KugouQrStatus> checkQr(String key) async {
    final dev = await device();
    final business = <String, String>{
      'appid': '1005',
      'srcappid': '2919',
      'plat': '4',
      'qrcode': key,
    };
    final data = await _getJson(
        KugouAuthConst.qrCheckPath, _signedQuery(business, dev));
    final d = data['data'] is Map
        ? Map<String, dynamic>.from(data['data'] as Map)
        : <String, dynamic>{};
    final st = (d['status'] as num?)?.toInt() ?? 0;
    final event = mapPollStatus(st);
    if (event != KugouQrEvent.confirmed) return KugouQrStatus(event);
    final userid = (d['userid'] ?? '').toString();
    final token = (d['token'] ?? '').toString();
    if (int.tryParse(userid) == null || int.parse(userid) <= 0 ||
        token.isEmpty) {
      throw KugouAuthError('酷狗登录响应缺少凭据');
    }
    await _persist(KugouSession(userid: userid, token: token));
    AppLog.i('KugouAuth', '酷狗扫码登录成功 userid=$userid');
    return KugouQrStatus(event, userid: userid, token: token);
  }
}

/// 酷狗登录失败（带服务端原文，可直接展示给用户）。
class KugouAuthError implements Exception {
  KugouAuthError(this.message);
  final String message;

  @override
  String toString() => message;
}
