// V0M0 mflac 全曲解密验证（复用项目解密算法，保证与 App 行为一致）
import 'dart:io';
import 'dart:typed_data';
import 'package:baiji_music/decrypt/qmc_ekey.dart';
import 'package:baiji_music/decrypt/qmc.dart';

Future<void> main(List<String> args) async {
  final ekey = args[0];
  final input = File(args[1]);
  final output = File(args[2]);

  final key = qmcEkeyDecrypt(ekey);
  stdout.writeln('音频密钥长度: ${key.length} → ${key.length <= 300 ? 'Map' : 'RC4'}');

  final cipher = QmcV2Cipher(key);
  final data = Uint8List.fromList(await input.readAsBytes());
  cipher.decrypt(data, 0);
  await output.writeAsBytes(data);
  stdout.writeln('已解密 ${data.length} 字节 → ${output.path}');
}
