// 酷我 `f=ar` 协议编解码 —— DES 变体 + Base64
//
// 逆向自倾听 5.5.0.2（com.listen.musicapp）所用酷我接口，
// 并与 TuneWeave 的 Rust 实现（crates/tuneweave-provider-kuwo/src/client/
// native/codec.rs）逐表逐式交叉验证：
//
//   q 参数    = base64(DES-ECB(query,  key = "kwks&@69"))   ← sealQuery
//   响应体    = base64(DES-ECB(body,   key = sx))           ← openResponse
//
// 其中 sx 是**请求里自己带的 8 位纯数字响应密钥**（取毫秒时间戳前 8 位），
// 服务端用它加密响应；两边必须一致，否则解出来是乱码。
//
// 这里的 DES 与 QMC ekey 解密用的是同一套表（iperm/fperm/exp/roundP/kpc1/
// kpc2/rot/rotMask/sbox 全部一致），因此直接复用 qmc_cipher.dart 的
// [EkeyCipher]，只是补了 encrypt 方向，没有第二份密码学实现。
//
// 填充规则（酷我官方客户端行为）：
//   - 加密侧：明文补 \0 到 8 的倍数；长度恰为 8 的倍数时**也补满一整块**，
//     因此填充量恒在 1..=8；
//   - 解密侧：按尾部 \0 的数量（1..=8）截断，数量不在该区间视为坏响应。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'qmc_cipher.dart';

/// 酷我 `f=ar` 编解码。
abstract final class KuwoCipher {
  /// q 参数的 DES 密钥（酷我公开常量）。
  static const String queryKey = 'kwks&@69';

  /// 明文上限（酷我官方客户端同款：64 KiB）。
  static const int maxPlain = 64 * 1024;

  /// 密文上限（256 KiB）。
  static const int maxResponse = 256 * 1024;

  static Uint8List _keyOf(String key) {
    final b = utf8.encode(key);
    if (b.length != 8) {
      throw ArgumentError('酷我 DES 密钥必须是 8 字节，实际 ${b.length}');
    }
    return Uint8List.fromList(b);
  }

  /// 生成 8 位纯数字响应密钥 sx（毫秒时间戳前 8 位，酷我官方同款）。
  static String newResponseKey([int? nowMs]) {
    final ms = (nowMs ?? DateTime.now().millisecondsSinceEpoch).toString();
    return ms.substring(0, 8);
  }

  /// 校验 sx 形制：8 位纯数字。
  static bool isValidResponseKey(String sx) =>
      sx.length == 8 && sx.codeUnits.every((c) => c >= 0x30 && c <= 0x39);

  // ==================== q 参数 ====================

  /// 加密查询串：`base64(DES-ECB(plain, "kwks&@69"))`。
  ///
  /// [plain] 是**已经做过 form 编码**的查询串（`k=v&k=v`），
  /// 内层值各自编码，外层 q 直接裸拼（不要对 q 再编码一次，
  /// 否则会改变线上形态）。
  static String sealQuery(String plain) {
    if (plain.length > maxPlain) {
      throw ArgumentError('酷我查询串过长: ${plain.length} > $maxPlain');
    }
    final out = EkeyCipher.encrypt(
      Uint8List.fromList(utf8.encode(plain)),
      _keyOf(queryKey),
    );
    return base64.encode(out);
  }

  // ==================== 响应体 ====================

  /// 解密响应体：`base64 -> DES-ECB(body, sx) -> 去尾部 \0`。
  ///
  /// 返回解密后的明文（通常是 JSON 文本）。
  /// 任何一步不合法（key 不是 8 位数字、base64 坏、长度不是 8 的倍数、
  /// 填充量不在 1..=8、超出大小预算）都抛 [FormatException]。
  static String openResponse(String body, String sx) {
    if (body.length > maxResponse) {
      throw const FormatException('酷我响应体超出大小预算');
    }
    if (!isValidResponseKey(sx)) {
      throw const FormatException('酷我响应密钥 sx 必须是 8 位纯数字');
    }
    final Uint8List cipher;
    try {
      cipher = base64.decode(body.trim());
    } catch (_) {
      throw const FormatException('酷我响应体不是合法 Base64');
    }
    if (cipher.isEmpty || cipher.length % 8 != 0) {
      throw const FormatException('酷我响应体长度不是 8 的倍数');
    }
    final dec = EkeyCipher.decrypt(cipher, _keyOf(sx));
    var end = dec.length;
    while (end > 0 && dec[end - 1] == 0) {
      end--;
    }
    final padding = dec.length - end;
    if (padding < 1 || padding > 8) {
      throw const FormatException('酷我响应体填充量异常');
    }
    return utf8.decode(Uint8List.sublistView(dec, 0, end), allowMalformed: true);
  }
}
