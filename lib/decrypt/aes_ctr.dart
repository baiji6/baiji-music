/// AES-128-CTR，64 位大端计数器 + 64 位块偏移。
///
/// pointycastle 自带的 `CTRMode` 用的是**全 128 位小端递增**计数器，
/// 和蜻蜓FM 用的 `ctr::Ctr64BE<aes::Aes128>` 不一致，所以这里自己实现。
///
/// `ctr::Ctr64BE` 的语义（RustCrypto `ctr` crate）：
///
/// ```text
/// counter_block = iv[0..8]  (nonce，永不递增)
///               || be_u64(block_index)[8..16]   (64 位大端块偏移)
/// keystream_i  = AES-128-Encrypt(key, counter_block)
/// ```
///
/// 即前 8 字节固定为 IV 的 nonce 段，后 8 字节才是递增的块偏移。
/// 每加密一个块，块偏移 +1；块内 16 字节按顺序消耗密钥流。
library;

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 可 seek 的 CTR 字节流。
///
/// [cipher] 必须是已用 `encrypt=true` 初始化的 [AESEngine]，
/// [iv] 必须是 16 字节。
class AesCtr64BeStream {
  AesCtr64BeStream(this._cipher, Uint8List iv)
      : _counterBlock = Uint8List.fromList(iv) {
    if (iv.length != 16) {
      throw ArgumentError('AES-CTR 的 IV 必须是 16 字节，实际 ${iv.length}');
    }
    // 初始块偏移为 0：IV 后 8 字节本就应为 0，这里显式写一次保证一致。
    _writeCounter(0);
  }

  final BlockCipher _cipher;

  /// 计数器块：[0..8] 是 IV 的 nonce 段，[8..16] 是大端块偏移。
  final Uint8List _counterBlock;

  final Uint8List _keystream = Uint8List(16);

  /// [_keystream] 中已消耗的字节数；等于 16 表示需要生成新密钥流。
  int _keystreamUsed = 16;

  /// 下一个要生成的块偏移。
  int _nextBlockIndex = 0;

  void _writeCounter(int blockIndex) {
    ByteData.sublistView(_counterBlock)
        .setUint64(8, blockIndex & 0xFFFFFFFFFFFFFFFF, Endian.big);
  }

  /// 跳到第 [blockIndex] 个块（0 基）。
  ///
  /// 返回 `this` 以便级联：`stream..seek(n)..processBytes(...)`。
  AesCtr64BeStream seek(int blockIndex) {
    _nextBlockIndex = blockIndex;
    _keystreamUsed = 16;
    _writeCounter(blockIndex);
    return this;
  }

  /// 计数器块（仅供测试断言内部状态）。
  Uint8List get counterBlockForTest => _counterBlock;

  /// 原地把 [input] 的 [inOff..inOff+len) 与密钥流异或到
  /// [output] 的 [outOff..outOff+len)。
  ///
  /// [input] 与 [output] 可以是同一个 buffer。
  void processBytes(
    Uint8List input,
    int inOff,
    int len,
    Uint8List output,
    int outOff,
  ) {
    var i = 0;
    while (i < len) {
      if (_keystreamUsed >= 16) {
        // _counterBlock 当前存的就是本块要用的计数器，
        // 先用它生成密钥流，**再**把计数器推进到下一块。
        _cipher.processBlock(_counterBlock, 0, _keystream, 0);
        _nextBlockIndex++;
        _writeCounter(_nextBlockIndex);
        _keystreamUsed = 0;
      }
      final avail = 16 - _keystreamUsed;
      final take = avail < (len - i) ? avail : (len - i);
      for (var j = 0; j < take; j++) {
        output[outOff + i + j] =
            input[inOff + i + j] ^ _keystream[_keystreamUsed + j];
      }
      _keystreamUsed += take;
      i += take;
    }
  }
}
