// QQ 音乐「手机 App 扫码登录」（CreateQRCode + MQTT5 over WSS 事件推送）。
//
// 对应倾听（qqmusic-api）`login.py` 的 checking_mobile_qrcode 链路，
// 与 ptlogin2 网页扫码（见 login_api.dart 的 getQrcode/checkQrcode）是
// **两套独立机制**，不要混用：
//
// - ptlogin2：HTTPS 轮询，二维码由腾讯 QQ 开放平台签发，任何扫码人都行；
// - 本文件：二维码由音乐登录服务器签发，**必须用手机上的 QQ 音乐 App
//   扫**，登录事件走 MQTT 长连推送（不轮询）。
//
// 全流程（沙箱内用 Python 参考实现逐字节验证过，见 mqtt_ws.dart 头注）：
//   1. CreateQRCode → qrcodeID + base64 PNG；
//   2. MQTT CONNECT wss://mu.y.qq.com/ws/handshake（CONNACK 可能 0x9D
//      重定向，由 MqttWsClient 内部处理）；
//   3. SUBSCRIBE management.qrcode_login/{qrcodeID}；
//   4. 服务端经 PUBLISH 的 UserProperty `type` 推事件：
//      scanned / canceled / timeout / loginFailed / cookies；
//   5. cookies 事件载荷里取 qqmusic_uin 与 qqmusic_key，换票：
//      music.login.LoginServer.Login（tmeLoginType=6）→ Credential。
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/login_api.dart';
import 'package:baiji_music/network/mqtt_ws.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:baiji_music/network/qq_music_client.dart';

/// MQTT 长连地址（QQ 音乐扫码事件通道）。
const String kQqMobileMqttUrl = 'wss://mu.y.qq.com/ws/handshake';

/// 扫码事件（对应服务端 UserProperty `type` 的取值）。
enum QqMobileQrEvent {
  /// 二维码已就绪且订阅成功，等待扫码。
  waiting,

  /// 用户已扫码，等待在手机上点确认。
  scanned,

  /// 用户在手机上取消 / 拒绝。
  canceled,

  /// 二维码过期（服务端推送）。
  timeout,

  /// 服务端推送登录失败。
  loginFailed,

  /// 登录成功，[QqMobileQrStatus.credential] 可用。
  done,
}

/// 一次扫码的状态。
class QqMobileQrStatus {
  const QqMobileQrStatus(
    this.event, {
    this.credential,
    this.detail,
  });

  final QqMobileQrEvent event;

  /// 仅 [QqMobileQrEvent.done] 时非空。
  final Credential? credential;

  /// 附加说明（loginFailed 的服务端原文等）。
  final String? detail;
}

/// 手机扫码二维码：qrcodeID（订阅主题用）+ PNG 字节（Image.memory 用）。
class QqMobileQr {
  const QqMobileQr(this.qrcodeId, this.image);

  final String qrcodeId;
  final List<int> image;
}

/// QQ 音乐手机 App 扫码登录。
///
/// 用法：
/// ```dart
/// final qr = await QqMobileLogin.createQr();
/// // 展示 qr.image …
/// await for (final s in QqMobileLogin.watchQr(qr.qrcodeId)) {
///   if (s.event == QqMobileQrEvent.done) { /* s.credential */ break; }
/// }
/// ```
abstract final class QqMobileLogin {
  // ================= 纯函数（可单测） =================

  /// 解析 CreateQRCode 响应，取出 qrcodeID 与 PNG 字节。
  ///
  /// 响应形如 `{"code":0,"data":{"qrcodeID":"…","qrcode":"data:image/png;base64,…"}}`。
  /// [data] 传 req_0.data（调用方已解包）。
  static QqMobileQr parseCreateQr(Map<String, dynamic> data) {
    final id = data['qrcodeID']?.toString() ?? '';
    final b64 = data['qrcode']?.toString() ?? '';
    if (id.isEmpty || b64.isEmpty) {
      throw Exception('CreateQRCode 响应缺少 qrcodeID/qrcode');
    }
    // 兼容 "data:image/png;base64," 前缀与裸 base64 两种形态
    final raw = b64.contains(',') ? b64.split(',').last : b64;
    return QqMobileQr(id, base64Decode(raw));
  }

  /// 解析 cookies 事件载荷，取出换票需要的 uin 与 key。
  ///
  /// 真实样本（沙箱从 paho 抓包固化）：
  /// `{"cookies":{"qqmusic_uin":{"value":"123456"},"qqmusic_key":{"value":"Q_H_L_…"}}}`。
  static ({String uin, String key}) parseCookiesPayload(String payloadText) {
    final Object? decoded = jsonDecode(payloadText);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('无效的 MQTT 消息格式');
    }
    final cookies = decoded['cookies'];
    if (cookies is! Map<String, dynamic>) {
      throw Exception('获取登录凭据失败: 缺少 cookies');
    }
    final uin = cookies['qqmusic_uin'];
    final key = cookies['qqmusic_key'];
    final uinStr = uin is Map<String, dynamic> ? uin['value']?.toString() : null;
    final keyStr = key is Map<String, dynamic> ? key['value']?.toString() : null;
    if (uinStr == null || uinStr.isEmpty || keyStr == null || keyStr.isEmpty) {
      throw Exception('获取登录凭据失败: 缺少必要参数');
    }
    return (uin: uinStr, key: keyStr);
  }

  /// MQTT 客户端标识（倾听同款：毫秒时间戳 + 4 位随机数）。
  static String clientId() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final r = Random().nextInt(9000) + 1000;
    return '$ms$r';
  }

  // ================= 网络 =================

  /// 获取手机扫码二维码。
  static Future<QqMobileQr> createQr() async {
    final data = await AppServices.instance.qq.executeRaw(
      BizRequest(
        module: 'music.login.LoginServer',
        method: 'CreateQRCode',
        param: const {
          'tmeAppID': 'qqmusic',
          'device': 'android',
          'version': 3,
        },
      ),
      // 倾听对 CreateQRCode 用的就是 ct=23/cv=0（手机端扫码场景）
      extraComm: const {'ct': 23, 'cv': 0},
    );
    final inner = data['data'];
    if (inner is! Map<String, dynamic>) {
      throw Exception('CreateQRCode 响应缺少 data');
    }
    return parseCreateQr(inner);
  }

  /// 换票：cookies 事件里的 uin/key → Credential。
  ///
  /// 对应倾听 `_handle_mobile_message` 里的 Login 调用：
  /// param `{musicid, qrCodeID, token}` + comm `{tmeLoginType: 6}`。
  static Future<Credential> exchangeTicket(
    String qrcodeId,
    String uin,
    String key,
  ) async {
    final musicid = int.tryParse(uin);
    if (musicid == null) {
      throw Exception('无效的 uin: $uin');
    }
    final data = await AppServices.instance.qq.executeRaw(
      BizRequest(
        module: 'music.login.LoginServer',
        method: 'Login',
        param: {
          'musicid': musicid,
          'qrCodeID': qrcodeId,
          'token': key,
        },
        allowErrorCodes: true,
      ),
      extraComm: const {'tmeLoginType': 6},
    );
    return Credential.fromDict(LoginApi.validateResult(data));
  }

  /// 订阅扫码事件流。
  ///
  /// - 返回的流在终态（done/canceled/timeout/loginFailed）、整体超时
  ///   （[timeout]）或监听取消时自动关闭，并断开 MQTT 连接；
  /// - 链路错误（建连/订阅失败）以流错误形式抛出；
  /// - 一张二维码只对应一条流：取消后要重新走 createQr。
  static Stream<QqMobileQrStatus> watchQr(
    String qrcodeId, {
    Duration timeout = const Duration(minutes: 5),
  }) {
    late final StreamController<QqMobileQrStatus> controller;
    MqttWsClient? client;
    StreamSubscription<MqttMessage>? sub;
    Timer? deadline;
    var finished = false;

    Future<void> cleanup() async {
      if (finished) return;
      finished = true;
      deadline?.cancel();
      await sub?.cancel();
      await client?.disconnect();
    }

    controller = StreamController<QqMobileQrStatus>(
      onListen: () async {
        try {
          client = await MqttWsClient.connect(
            url: kQqMobileMqttUrl,
            clientId: clientId(),
            keepAliveSecs: 45,
            userProperties: {
              'tmeAppID': 'qqmusic',
              'business': 'management',
              'hashTag': qrcodeId,
              'clientTag': 'management.user',
              'userID': qrcodeId,
            },
            headers: const {
              'Origin': 'https://y.qq.com',
              'Referer': 'https://y.qq.com/',
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
            },
          );
          if (finished) {
            await client!.disconnect();
            return;
          }
          await client!.subscribe(
            'management.qrcode_login/$qrcodeId',
            userProperties: const {
              'authorization': 'tmelogin',
              'pubsub': 'unicast',
            },
          );
          if (finished) return;
          controller.add(const QqMobileQrStatus(QqMobileQrEvent.waiting));

          // 服务端可能主动断开（如二维码在别处被消费），消息流结束即链路结束
          client!.done.then((_) async {
            if (finished) return;
            finished = true;
            deadline?.cancel();
            controller.add(const QqMobileQrStatus(
              QqMobileQrEvent.timeout,
              detail: '连接已断开',
            ));
            await sub?.cancel();
            await controller.close();
          });

          sub = client!.messages.listen((msg) async {
            if (finished) return;
            final type = msg.userProperties['type'];
            AppLog.d('QqMobileLogin', 'MQTT 事件 type=$type');
            switch (type) {
              case 'scanned':
                controller.add(const QqMobileQrStatus(QqMobileQrEvent.scanned));
                return;
              case 'canceled':
                await _finish(controller, cleanup,
                    const QqMobileQrStatus(QqMobileQrEvent.canceled));
                return;
              case 'timeout':
                await _finish(controller, cleanup,
                    const QqMobileQrStatus(QqMobileQrEvent.timeout));
                return;
              case 'loginFailed':
                await _finish(
                    controller,
                    cleanup,
                    QqMobileQrStatus(QqMobileQrEvent.loginFailed,
                        detail: msg.payloadText));
                return;
              case 'cookies':
                try {
                  final c = parseCookiesPayload(msg.payloadText);
                  final cred = await exchangeTicket(qrcodeId, c.uin, c.key);
                  AppLog.i('QqMobileLogin', '手机扫码登录成功 uid=${cred.musicid}');
                  await _finish(
                      controller,
                      cleanup,
                      QqMobileQrStatus(QqMobileQrEvent.done, credential: cred));
                } catch (e) {
                  await _finish(
                      controller,
                      cleanup,
                      QqMobileQrStatus(QqMobileQrEvent.loginFailed,
                          detail: '$e'));
                }
                return;
              default:
                // 未知事件类型：忽略，继续等
                return;
            }
          });

          deadline = Timer(timeout, () async {
            if (finished) return;
            await _finish(controller, cleanup,
                const QqMobileQrStatus(QqMobileQrEvent.timeout, detail: '等待超时'));
          });
        } catch (e, s) {
          AppLog.e('QqMobileLogin', '扫码链路失败: $e\n$s');
          await cleanup();
          if (!controller.isClosed) {
            controller.addError(Exception('扫码登录连接失败: $e'));
            await controller.close();
          }
        }
      },
      onCancel: cleanup,
    );
    return controller.stream;
  }

  /// 推终态 → 收尾 → 关流。
  static Future<void> _finish(
    StreamController<QqMobileQrStatus> controller,
    Future<void> Function() cleanup,
    QqMobileQrStatus status,
  ) async {
    if (controller.isClosed) return;
    controller.add(status);
    await cleanup();
    await controller.close();
  }
}
