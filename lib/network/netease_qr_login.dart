// 网易云音乐扫码登录（unikey + HTTPS 轮询）。
//
// 对应倾听（NeteaseCloudMusicApi）`login.py` 的 qrcode_unikey /
// login_qr_check 链路，与白姬原有「粘贴 Cookie」登录并存：
//
// 1. unikey：EAPI POST `https://interface3.music.163.com/eapi/login/qrcode/unikey`
//    body `{"type":1}` → unikey（沙箱实测 code:200 + unikey）；
// 2. 二维码内容：`https://music.163.com/login?codekey={unikey}`（本地渲染，
//    不依赖网易云的二维码图片接口）；
// 3. 轮询 GET `https://music.163.com/api/login/qrcode/client/login?key={unikey}&type=1`：
//    - 800 二维码过期
//    - 801 等待扫码
//    - 802 已扫码，待确认
//    - 803 登录成功，凭据在响应的 **Set-Cookie（MUSIC_U）** 里
//
// 轮询而非长连：网易云没有为这个接口提供推送通道，倾听同样是轮询。
import 'dart:async';
import 'dart:convert';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:baiji_music/network/netease/netease_client.dart';

/// 轮询返回码（沙箱实测：新 key 返回 801）。
abstract final class NeteaseQrCode {
  static const int expired = 800; // 二维码过期
  static const int waiting = 801; // 等待扫码
  static const int scanned = 802; // 已扫码，待确认
  static const int success = 803; // 登录成功（Set-Cookie MUSIC_U）
}

/// 扫码状态。
enum NeteaseQrEvent {
  /// 二维码已就绪，等待扫码。
  waiting,

  /// 已扫码，等待用户在手机上确认。
  scanned,

  /// 二维码过期，需要重新获取。
  expired,

  /// 登录成功，[NeteaseQrStatus.cookie] 可用。
  done,
}

class NeteaseQrStatus {
  const NeteaseQrStatus(this.event, {this.cookie});

  final NeteaseQrEvent event;

  /// 仅 [NeteaseQrEvent.done] 时非空：可直接写入 `NeteaseClient.cookie`。
  final String? cookie;
}

/// 扫码二维码：unikey（轮询用）+ 二维码内容（qr_flutter 渲染用）。
class NeteaseQr {
  const NeteaseQr(this.unikey, this.content);

  final String unikey;
  final String content;
}

/// 网易云扫码登录。
abstract final class NeteaseQrLogin {
  // ================= 纯函数（可单测） =================

  /// 二维码内容（网易云 H5 登录页，codekey 即 unikey）。
  static String qrContent(String unikey) =>
      'https://music.163.com/login?codekey=$unikey';

  /// 解析 unikey 响应，取出 unikey。
  static String parseUnikey(Map<String, dynamic> resp) {
    final code = resp['code'] as int? ?? -1;
    if (code != 200) {
      throw Exception('获取 unikey 失败 code=$code');
    }
    final unikey = resp['unikey']?.toString() ?? '';
    if (unikey.isEmpty) {
      throw Exception('获取 unikey 失败: 响应缺少 unikey');
    }
    return unikey;
  }

  /// 轮询返回码 → 事件；未知码按 [NeteaseQrEvent.waiting] 处理（继续等）。
  static NeteaseQrEvent mapPollCode(int code) {
    switch (code) {
      case NeteaseQrCode.expired:
        return NeteaseQrEvent.expired;
      case NeteaseQrCode.scanned:
        return NeteaseQrEvent.scanned;
      case NeteaseQrCode.success:
        return NeteaseQrEvent.done;
      case NeteaseQrCode.waiting:
      default:
        return NeteaseQrEvent.waiting;
    }
  }

  /// 从 Set-Cookie 列表里提取 `name=value` 对并拼成 Cookie 串。
  ///
  /// Set-Cookie 形如 `MUSIC_U=abc; Path=/; Expires=…`，属性段
  /// （Path/Expires/Domain/HttpOnly/Secure/SameSite/Max-Age）要丢掉；
  /// 同名后者覆盖前者。
  static String buildCookieFromSetCookie(List<String> setCookies) {
    final map = <String, String>{};
    for (final entry in setCookies) {
      final first = entry.split(';').first.trim();
      final idx = first.indexOf('=');
      if (idx <= 0) continue;
      final name = first.substring(0, idx).trim();
      final value = first.substring(idx + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      map[name] = value;
    }
    return map.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  // ================= 网络 =================

  /// 获取扫码二维码。
  static Future<NeteaseQr> createQr() async {
    final resp = await AppServices.instance.netease.postEapi(
      '${NeteaseClient.eapiBase}/login/qrcode/unikey',
      const {'type': 1},
    );
    final unikey = parseUnikey(resp);
    return NeteaseQr(unikey, qrContent(unikey));
  }

  /// 轮询扫码状态。
  ///
  /// - 终态（[NeteaseQrEvent.done] / [NeteaseQrEvent.expired]）或整体
  ///   [timeout] 到了自动关流；
  /// - 单次请求失败不中断整体流程（容忍网络抖动），连续失败超过
  ///   [maxFailures] 次才以流错误结束；
  /// - 取消监听即停止轮询。
  static Stream<NeteaseQrStatus> poll(
    String unikey, {
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 5),
    int maxFailures = 5,
  }) {
    late final StreamController<NeteaseQrStatus> controller;
    Timer? ticker;
    Timer? deadline;
    var failures = 0;
    var stopped = false;

    Future<void> stop() async {
      if (stopped) return;
      stopped = true;
      ticker?.cancel();
      deadline?.cancel();
    }

    controller = StreamController<NeteaseQrStatus>(
      onListen: () {
        deadline = Timer(timeout, () async {
          await stop();
          if (!controller.isClosed) {
            controller.add(const NeteaseQrStatus(NeteaseQrEvent.expired));
            await controller.close();
          }
        });

        Future<void> tick() async {
          if (stopped) return;
          try {
            final resp = await AppServices.instance.netease.getRaw(
                '${NeteaseClient.apiBase}/login/qrcode/client/login'
                '?key=$unikey&type=1');
            // Dio 默认 responseType 是 json：body 可能已被解成 Map
            final raw = resp.data;
            Map<String, dynamic> body;
            if (raw is Map<String, dynamic>) {
              body = raw;
            } else {
              final text = raw?.toString() ?? '';
              try {
                final decoded = jsonDecode(text);
                body = decoded is Map<String, dynamic>
                    ? decoded
                    : <String, dynamic>{'code': -1};
              } catch (_) {
                body = <String, dynamic>{'code': -1};
              }
            }
            final code = body['code'] as int? ?? -1;
            final event = mapPollCode(code);
            failures = 0; // 拿到响应就清零

            if (event == NeteaseQrEvent.done) {
              final cookie = buildCookieFromSetCookie(
                  resp.headers.map['set-cookie'] ?? const []);
              if (cookie.isEmpty) {
                throw Exception('登录成功但未取到 Set-Cookie');
              }
              AppLog.i('NeteaseQrLogin', '扫码登录成功');
              await stop();
              controller.add(NeteaseQrStatus(NeteaseQrEvent.done, cookie: cookie));
              await controller.close();
              return;
            }
            controller.add(NeteaseQrStatus(event));
            if (event == NeteaseQrEvent.expired) {
              await stop();
              await controller.close();
            }
          } catch (e) {
            failures++;
            AppLog.w('NeteaseQrLogin', '第 $failures 次轮询异常: $e');
            if (failures >= maxFailures) {
              await stop();
              if (!controller.isClosed) {
                controller.addError(Exception('扫码登录轮询失败: $e'));
                await controller.close();
              }
            }
          }
        }

        ticker = Timer.periodic(interval, (_) => tick());
        // 立即执行第一次，不用等一个间隔
        tick();
      },
      onCancel: stop,
    );
    return controller.stream;
  }
}
