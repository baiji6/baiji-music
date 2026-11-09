import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart' as pc;

/// 洛雪音源宿主引导脚本（[lxBootstrapJs]）的**同步加密桥**处理器。
///
/// 由 `LxRuntime` 注册到 `onMessage('lx_crypto', ...)`。flutter_js 的
/// `sendMessage` 在 QuickJS（native 回调把 `func.invoke(...)` 结果经
/// `_dartToJs` 返回）与 JSCore（`json.encode(result)` → `makeFromJSONString`）
/// 下都会把本函数的返回值**同步**转成 JS 值回传，因此源脚本里同步调用
/// `lx.utils.crypto.*` 能立即拿到结果（用于拼签名 URL 等），无需异步桥。
///
/// 之所以不手写纯 JS 哈希：QuickJS 内置的 JS 引擎对 BigInt 字面量支持不全，
/// 且手写 MD5/SHA/HMAC 易错；改为复用 Dart 的 `crypto` / `pointycastle`
/// 保证与洛雪官方实现一致。
///
/// 入参为 bootstrap 发来的 spec（`jsonDecode` 后的 Map）：
///  - `algo`：`md5` / `sha1` / `sha256` / `hmacsha1` / `hmacsha256` /
///    `random` / `aesenc` / `aesdec`
///  - `d` / `k`：base64 编码的输入数据 / 密钥（哈希、HMAC）
///  - `n`：随机字节数（random）
///  - `data` / `key` / `mode` / `iv`：AES 输入、密钥、模式（`ecb`/`cbc`）、
///    IV（除 `mode` 外均为 base64）
///
/// 返回：
///  - 哈希 / HMAC → **hex 字符串**（洛雪契约，直接拼进签名 URL / 请求体）
///  - `random` → base64（bootstrap 侧再解成 BufferLike）
///  - AES → base64 密文 / 明文（bootstrap 侧解成 BufferLike）
dynamic handleLxCrypto(dynamic args) {
  try {
    final spec = Map<String, dynamic>.from(args as Map);
    final algo = (spec['algo'] as String? ?? '').toLowerCase();
    switch (algo) {
      case 'md5':
        return crypto.md5.convert(_b64(spec['d'])).toString();
      case 'sha1':
        return crypto.sha1.convert(_b64(spec['d'])).toString();
      case 'sha256':
        return crypto.sha256.convert(_b64(spec['d'])).toString();
      case 'hmacsha1':
        return crypto.Hmac(crypto.sha1, _b64(spec['k']))
            .convert(_b64(spec['d']))
            .toString();
      case 'hmacsha256':
        return crypto.Hmac(crypto.sha256, _b64(spec['k']))
            .convert(_b64(spec['d']))
            .toString();
      case 'random':
        final n = (spec['n'] as num?)?.toInt() ?? 0;
        if (n <= 0) return '';
        final rnd = Random.secure();
        return base64.encode(
            List<int>.generate(n, (_) => rnd.nextInt(256), growable: false));
      case 'aesenc':
        return base64.encode(_aes(spec, forEncryption: true));
      case 'aesdec':
        return base64.encode(_aes(spec, forEncryption: false));
      default:
        return '';
    }
  } catch (_) {
    // 同步桥不宜把 Dart 异常抛进 JS 栈（会中断源脚本加载）；返回空串，
    // 由源脚本自行兜底。真实错误可在此按需接入日志。
    return '';
  }
}

List<int> _b64(dynamic v) =>
    v is String && v.isNotEmpty ? base64.decode(v) : const <int>[];

/// AES（ECB / CBC）+ PKCS7 填充，输入输出均为原始字节。
///
/// 逐块调用 `processBlock`（与项目内 `netease_crypto.dart` 的风格一致），
/// 自行处理 PKCS7，避免依赖 `PaddedBlockCipherParameters` 的泛型推断。
List<int> _aes(Map<String, dynamic> spec, {required bool forEncryption}) {
  final key = Uint8List.fromList(_b64(spec['key']));
  final ivBytes = _b64(spec['iv']);
  final mode = (spec['mode'] as String? ?? 'ecb').toLowerCase();
  final useCbc = mode == 'cbc' && ivBytes.length == 16;

  final pc.BlockCipher cipher = useCbc
      ? pc.CBCBlockCipher(pc.AESEngine())
      : pc.ECBBlockCipher(pc.AESEngine());
  if (useCbc) {
    cipher.init(forEncryption,
        pc.ParametersWithIV(pc.KeyParameter(key), Uint8List.fromList(ivBytes)));
  } else {
    cipher.init(forEncryption, pc.KeyParameter(key));
  }

  final bs = cipher.blockSize;
  Uint8List input = Uint8List.fromList(_b64(spec['data']));

  if (forEncryption) {
    final padLen = bs - (input.length % bs);
    final padded = Uint8List(input.length + padLen)..setAll(0, input);
    for (var i = input.length; i < padded.length; i++) {
      padded[i] = padLen;
    }
    input = padded;
  } else {
    if (input.isEmpty || input.length % bs != 0) {
      throw ArgumentError('AES 密文长度必须是块大小的整数倍');
    }
  }

  final out = Uint8List(input.length);
  var off = 0;
  while (off < input.length) {
    cipher.processBlock(input, off, out, off);
    off += bs;
  }

  if (!forEncryption) {
    final padLen = out.last;
    if (padLen < 1 || padLen > bs) {
      throw ArgumentError('非法 PKCS7 填充');
    }
    for (var i = out.length - padLen; i < out.length; i++) {
      if (out[i] != padLen) throw ArgumentError('非法 PKCS7 填充');
    }
    return out.sublist(0, out.length - padLen);
  }
  return out;
}
