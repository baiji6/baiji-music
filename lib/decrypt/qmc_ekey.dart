/// QQ 音乐 ekey（Encoded Key）解密。
///
/// 移植自 `um_crypto/qmc/src/ekey.rs`。ekey 是 QQ 音乐把真正的音频密钥
/// 再包一层 TEA 加密后的产物，**不是**音频密钥本身——必须先解开才能喂给
/// [QmcV2Cipher]。
///
/// 两种形态由 base64 前缀区分：
/// - `UVFNdXNpYyBFbmNWMixLZXk6`（即 `QQMusic EncV2,Key:`）→ v2，两次 TEA；
/// - 无前缀 → v1，一次 TEA。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'tc_tea.dart';

/// base64 编码后的 v2 前缀 `QQMusic EncV2,Key:`。
const String ekeyV2Prefix = 'UVFNdXNpYyBFbmNWMixLZXk6';

const List<int> _ekeyV2Key1 = [
  0x33, 0x38, 0x36, 0x5A, 0x4A, 0x59, 0x21, 0x40, //
  0x23, 0x2A, 0x24, 0x25, 0x5E, 0x26, 0x29, 0x28,
];

const List<int> _ekeyV2Key2 = [
  0x2A, 0x2A, 0x23, 0x21, 0x28, 0x23, 0x24, 0x25, //
  0x26, 0x5E, 0x61, 0x31, 0x63, 0x5A, 0x2C, 0x54,
];

/// 由 `tan` 曲线派生的 8 字节常量（对应 `make_simple_key::<8>`）。
///
/// 上游用 f32 运算再截断为 u8；这里用 double 计算，i范围很小（0..7）
/// 结果与f32 完全一致。
final List<int> ekeySimpleKey = List<int>.generate(8, (i) {
  final v = 106.0 + i * 0.1;
  return (math.tan(v).abs() * 100.0).toInt() & 0xFF;
});

/// ekey v1 解密。输入是 base64 字符串（允许含首尾空白）。
///
/// 布局：`base64 解码 →前 8 字节是 header，其余是 tc_tea 密文`。
/// TEA 密钥由`simpleKey[i]` 与 `header[i]` 交错拼成 16 字节。
/// 返回值 = header + 明文（即完整的音频密钥）。
Uint8List qmcEkeyDecryptV1(String ekey) {
  final cleaned = ekey.trim();
  if (cleaned.length < 12) {
    throw const FormatException('ekey 太短，无法解密');
  }
  final raw = base64.decode(_stripBase64Padding(cleaned));
  if (raw.length < 16) {
    throw const FormatException('ekey base64 解码后长度不足');
  }

  final header = raw.sublist(0, 8);
  final cipher = raw.sublist(8);

  final teaKey = Uint8List(16);
  for (var i = 0; i < 8; i++) {
    teaKey[i * 2] = ekeySimpleKey[i];
    teaKey[i * 2 + 1] = header[i];
  }

  final plain = tcTeaDecrypt(cipher, teaKey);
  return Uint8List.fromList([...header, ...plain]);
}

/// ekey v2 解密：剥前缀 → 两次 TEA → 截断到第一个 0 字节 → 走 v1。
Uint8List qmcEkeyDecryptV2(String ekeyBody) {
  var raw = base64.decode(_stripBase64Padding(ekeyBody.trim()));
  raw = tcTeaDecrypt(raw, _ekeyV2Key1);
  raw = tcTeaDecrypt(raw, _ekeyV2Key2);

  final zero = raw.indexOf(0);
  final stripped = zero >= 0 ? raw.sublist(0, zero) : raw;
  return qmcEkeyDecryptV1(base64.encode(stripped));
}

/// 统一入口：自动按前缀分派v1/v2。
Uint8List qmcEkeyDecrypt(String ekey) {
  final trimmed = ekey.trim();
  if (trimmed.startsWith(ekeyV2Prefix)) {
    return qmcEkeyDecryptV2(trimmed.substring(ekeyV2Prefix.length));
  }
  return qmcEkeyDecryptV1(trimmed);
}

/// 去掉 base64 里的空白字符，并补齐padding。
///
/// 用户从 QQ 音乐客户端数据库 / MMKV 里拷出来的 ekey 常带换行或空格，
/// `base64.decode` 对这些是直接抛异常的。
String _stripBase64Padding(String s) {
  final cleaned = s.replaceAll(RegExp(r'\s'), '');
  final rest = cleaned.length % 4;
  if (rest == 0) return cleaned;
  return cleaned +'=' * (4 - rest);
}
