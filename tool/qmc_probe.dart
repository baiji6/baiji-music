// QMC v2 端到端自检脚本（开发期使用，不参与 App 打包）
//
// 用法:
//   dart run tool/qmc_probe.dart <ekey> <encryptedFile> [outFile]
//
// 校验点:
//   1. ekey -> rawKey -> 最终 key 的派生链能跑通
//   2. 解密后的字节是否是合法音频容器（FLAC "fLaC" / MP3 帧头）
//   3. 随机偏移读取（模拟 seek）结果与整文件解密一致
import 'dart:io';
import 'dart:typed_data';

import 'package:baiji_music/network/kuwo/qmc_cipher.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('用法: dart run tool/qmc_probe.dart <ekey> <encFile> [outFile]');
    exit(2);
  }
  final ekey = args[0];
  final encFile = File(args[1]);
  final bytes = encFile.readAsBytesSync();

  // 1) 派生链
  final rawKey = QmcKeyDerivation.extractRawKeyFromEkey(ekey);
  stdout.writeln('rawKey 长度: ${rawKey.length}');
  final key = QmcKeyDerivation.deriveQmcKey(rawKey);
  stdout.writeln('最终 key 长度: ${key.length}  → ${key.length > 300 ? "Rc4Cipher (QMC v2)" : "MapCipher (QMC v1)"}');

  final cipher = QmcKeyDerivation.createCipherFromEkey(ekey);

  // 2) 解密
  final plain = cipher.decrypt(Uint8List.fromList(bytes), 0);
  stdout.writeln('解密后前 16 字节: ${_hex(plain.sublist(0, 16))}');
  stdout.writeln('是否 fLaC 头: ${_isFlac(plain)}');
  stdout.writeln('是否 MP3 帧: ${_isMp3(plain)}');

  // 3) 随机偏移一致性（seek 校验）
  const off = 4096;
  if (bytes.length > off + 64) {
    final part = cipher.decrypt(Uint8List.fromList(bytes.sublist(off, off + 64)), off);
    final same = _eq(part, plain.sublist(off, off + 64));
    stdout.writeln('偏移 $off 的 64 字节与整文件一致: $same');
    stdout.writeln('  part: ${_hex(part.sublist(0, 16))}');
    stdout.writeln('  full: ${_hex(plain.sublist(off, off + 16))}');
  }

  // 跨分段边界校验（128 首段 / 5120 分段）
  for (final b in [0, 100, 127, 128, 5119, 5120, 5121, 10240]) {
    if (bytes.length <= b + 8) continue;
    final p = cipher.decrypt(Uint8List.fromList(bytes.sublist(b, b + 8)), b);
    final ok = _eq(p, plain.sublist(b, b + 8));
    stdout.writeln('  边界 $b 一致: $ok');
  }

  if (args.length >= 3) {
    File(args[2]).writeAsBytesSync(plain);
    stdout.writeln('已写出明文: ${args[2]} (${plain.length} 字节)');
  }
}

bool _isFlac(Uint8List b) =>
    b.length >= 4 && b[0] == 0x66 && b[1] == 0x4C && b[2] == 0x61 && b[3] == 0x43;

bool _isMp3(Uint8List b) =>
    b.length >= 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0;

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _hex(Uint8List b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
