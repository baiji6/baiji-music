/// 蜻蜓FM（.qta）解密。
///
/// 对齐 um-react `src/decrypt-worker/decipher/QingTingFM.ts`：
///
/// ```ts
/// const key = unhex(opts.qingTingAndroidKey || '');      // 32 个 hex 字符 = 16 字节
/// const iv  = QingTingFM.getFileIV(opts.fileName);        // 从文件名派生
/// const qtfm = new QingTingFM(key, iv);                   // AES-128-CTR
/// for (const [block, i] of chunkBuffer(audioBuffer)) qtfm.decrypt(block, i);
/// ```
///
/// 与其它平台最大的不同：**没有文件头**，整个文件（含文件名派生的 IV 语义）
/// 都是密文，而且**必须要有 device key**——它不藏在文件里，而是由 Android
/// 设备信息（product/device/manufacturer/brand/board/model）派生出来的。
///
/// 两种密钥来源：
/// - 用户在「密钥管理」里填 [makeDeviceSecret] 的十六进制结果；
/// - 填了那6 个设备字段，我们本地算一遍（[makeDeviceSecret]）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'aes_ctr.dart';

/// 设备密钥盐值（对齐 `secret.rs` 的 `DEVICE_KEY_SALT`）。
const List<int> _deviceKeySalt = [
  0x26, 0x2b, 0x2b, 0x12, 0x11, 0x12, 0x14, 0x0a, //
  0x08, 0x00, 0x08, 0x0a, 0x14, 0x12, 0x11, 0x12,
];

/// 蜻蜓FM 专有异常。
class QingTingFailure implements Exception {
  const QingTingFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 解密器。
///
/// AES-128-CTR，计数器 64 位大端 + 64 位块偏移。
class QingTingDecipher {
  QingTingDecipher(this.deviceKey, this.iv) {
    if (deviceKey.length != 16) {
      throw const QingTingFailure('蜻蜓设备密钥必须是 16 字节（32 位十六进制）');
    }
    if (iv.length != 16) {
      throw const QingTingFailure('蜻蜓 IV 长度非法');
    }
  }

  final Uint8List deviceKey;
  final Uint8List iv;

  /// 原地解密 [buffer]，其中首字节对应文件偏移 [offset]。
  void decrypt(Uint8List buffer, int offset) {
    if (buffer.isEmpty) return;
    _ctrStream(offset).processBytes(buffer, 0, buffer.length, buffer, 0);
  }

  /// 从 [offset] 处的块序号开始生成连续密钥流。
  ///
  /// CTR 模式下 seek 只改计数器，密钥流与「从头连续加密」完全一致，
  /// 所以分块并行解密和整体解密结果相同。
  AesCtr64BeStream _ctrStream(int offset) {
    // 只喂KeyParameter：CTR 的计数器由AesCtr64BeStream 自己维护，
    // 不走 pointycastle 的 CTRMode（那个是 128 位小端计数器，语义不对）。
    final cipher = AESEngine()..init(true, KeyParameter(deviceKey));
    final stream = AesCtr64BeStream(cipher, iv)..seek(offset ~/ 16);

    final inBlock = offset % 16;
    if (inBlock != 0) {
      // 对齐到块边界后，空跑 inBlock 字节让内部字节指针追上。
      final skip = Uint8List(inBlock);
      stream.processBytes(skip, 0, inBlock, skip, 0);
    }
    return stream;
  }

  /// 从十六进制字符串构造（对应 TS 的 `unhex`）。
  ///
  /// 只接受 32 个十六进制字符（16 字节）。
  factory QingTingDecipher.fromHexKey(String hexKey, String fileName) {
    final key = parseHexOrThrow(hexKey, '蜻蜓设备密钥');
    final iv = makeDecipherIv(fileName);
    return QingTingDecipher(key, iv);
  }
}

/// 十六进制解析，失败时抛出可读错误。
Uint8List parseHexOrThrow(String s, String label) {
  final t = s.trim();
  if (t.length.isOdd) {
    throw QingTingFailure('$label 必须是偶数个十六进制字符');
  }
  final out = Uint8List(t.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final hi = _hexVal(t.codeUnitAt(i * 2));
    final lo = _hexVal(t.codeUnitAt(i * 2 + 1));
    if (hi < 0 || lo < 0) {
      throw QingTingFailure('$label 含非十六进制字符');
    }
    out[i] = (hi << 4) | lo;
  }
  return out;
}

int _hexVal(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30; // 0-9
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10; // a-f
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10; // A-F
  return -1;
}

/// `hash_resource_id`（对齐 `nonce.rs`）。
///
/// 注意这个哈希是 **i64 语义**：`sum` 与 `outer_sum` 都是 `i64`，
/// `wrapping_shl` 在 64 位上做位移。**按32 位截断会丢掉高 32 位，
/// 导致前4 字节全错**——实测正是如此。
///
/// 循环里还有一层内层 `fold(0, ...)`，它同样以 i64 累加。
int hashResourceId(List<int> resourceId) {
  var sum = 0; // Dart int 是 64 位有符号，正好对上 Rust 的 i64。
  for (final chr in resourceId) {
    final outerSum = sum ^ chr;

    var acc = 0;
    for (final shl in const [0, 1, 4, 5, 7, 8, 40]) {
      acc = _wrappingAdd(acc, _wrappingShl(outerSum, shl));
    }
    sum = acc;
  }
  return sum;
}

/// 64 位左移（Rust的 `i64::wrapping_shl`）。
int _wrappingShl(int v, int s) {
  if (s >= 64) return 0;
  return _toI64(v << s);
}

/// 64 位加法（Rust 的 `i64::wrapping_add`）。
int _wrappingAdd(int a, int b) => _toI64(a + b);

/// 把值折回 i64。
///
/// Dart 原生平台的 int 就是 **64 位有符号**，加法与左移都会自然回绕
/// （`<<` 也是），与 Rust 的 `wrapping_add` / `wrapping_shl` 语义一致，
/// 所以这里原样返回即可。
int _toI64(int v) => v;

/// 从文件名派生 IV（对齐 `make_decipher_iv`）。
///
/// 规则：
/// 1. 去掉目录部分与 `.qta` 后缀；
/// 2. 必须以 `.p!`（标准 base64）或 `.p~!`（URL-safe base64）开头，
///    否则抛错——这是蜻蜓加密文件的命名约定；
/// 3. base64 解码得到 `resource_id@...`，只取 `@` 之前的部分；
/// 4. `hash_resource_id` 后以**大端 64 位**写进 IV 的前 8 字节，后 8 字节补 0。
Uint8List makeDecipherIv(String filePathOrName) {
  var name = fileNameOf(filePathOrName);
  if (name.toLowerCase().endsWith('.qta')) {
    name = name.substring(0, name.length - 4);
  }

  Uint8List resourceInfo;
  if (name.startsWith('.p!')) {
    resourceInfo = _b64(name.substring(3));
  } else if (name.startsWith('.p~!')) {
    resourceInfo = _b64UrlSafe(name.substring(4));
  } else {
    throw const QingTingFailure(
        '蜻蜓文件名必须以 .p! 或 .p~! 开头（这不是有效的 .qta 文件）');
  }

  // 只取 resource id（`@` 之前）。
  final at = resourceInfo.indexOf(0x40); // '@'
  final resourceId =
      at < 0 ? resourceInfo : Uint8List.sublistView(resourceInfo, 0, at);

  final hash = hashResourceId(resourceId);
  final iv = Uint8List(16);
  // BE::write_i64(&mut iv[..8], hash) —— 取 i64 的低 64 位，大端写入。
  final bd = ByteData.sublistView(iv);
  bd.setUint64(0, hash & 0xFFFFFFFFFFFFFFFF, Endian.big);
  return iv;
}

/// 取文件名部分（去掉目录分隔符）。
String fileNameOf(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i < 0 ? path : path.substring(i + 1);
}

Uint8List _b64(String s) {
  try {
    return base64.decode(_stripPadding(s));
  } catch (_) {
    throw const QingTingFailure('蜻蜓文件名里的 base64 解不开');
  }
}

Uint8List _b64UrlSafe(String s) {
  try {
    return base64Url.decode(_stripPadding(s));
  } catch (_) {
    // 有些客户端会用标准 base64 存URL-safe 变体
    try {
      return base64.decode(_stripPadding(s));
    } catch (_) {
      throw const QingTingFailure('蜻蜓文件名里的 base64 解不开');
    }
  }
}

String _stripPadding(String s) {
  final t = s.trim();
  final m = t.length % 4;
  return m == 0 ? t : t + '=' * (4 - m);
}

/// `java_string_hash_code`（对齐 `secret.rs`）。
int javaStringHashCode(String s) {
  var hash = 0;
  for (final c in utf8.encode(s)) {
    hash = (hash * 31 + c) & 0xFFFFFFFF;
  }
  return hash;
}

/// 由 Android 设备信息派生 16 字节设备密钥（对齐 `make_device_secret`）。
///
/// 步骤：六段字符串各算一次 `javaStringHashCode` 并求和→ 转小写十六进制
/// （**不补零**）→ 截断到 16 字节 → 逐字节加盐。
Uint8List makeDeviceSecret({
  required String product,
  required String device,
  required String manufacturer,
  required String brand,
  required String board,
  required String model,
}) {
  var sum = 0;
  for (final v in [product, device, manufacturer, brand, board, model]) {
    sum = (sum + javaStringHashCode(v)) & 0xFFFFFFFF;
  }

  // Rust 的 format!("{:x}") 是小写、且**没有前导零**。
  var hex = sum.toRadixString(16);
  final hexBytes = utf8.encode(hex);

  final key = Uint8List(16);
  final n = hexBytes.length < 16 ? hexBytes.length : 16;
  key.setRange(0, n, hexBytes);
  // 剩余字节保持 0，与 Rust 的 [0u8; 0x10] 一致。

  for (var i = 0; i < 16; i++) {
    key[i] = (key[i] + _deviceKeySalt[i]) & 0xFF;
  }
  return key;
}

/// 设备密钥的十六进制形式（对应 TS 的 `hex(buffer)`）。
String deviceSecretToHex(Uint8List key) =>
    key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// 判断是不是蜻蜓加密文件：文件名以 `.p!.qta` / `.p~!.qta` 结尾。
///
/// 蜻蜓没有文件头，**唯一**的识别依据就是文件名——所以这个判断依赖文件名，
/// 不能只看内容。
bool isQingTingFileName(String name) {
  final n = fileNameOf(name).toLowerCase();
  if (!n.endsWith('.qta')) return false;
  return n.contains('.p!') || n.contains('.p~!');
}
