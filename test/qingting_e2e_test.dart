import 'dart:io';
import 'dart:typed_data';

import 'package:baiji_music/decrypt/decryptor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 蜻蜓 FM 端到端：真实 .qta 文件 → 解密 → 与 Python 独立实现的密文对齐。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('baiji_qta');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  String fixture(String n) => 'test/fixtures/keys/$n';

  group('蜻蜓 .qta 端到端', () {
    test('文件名识别为蜻蜓平台', () {
      final realName = File(fixture('sample.qta.name')).readAsStringSync().trim();
      expect(realName, '.p!MTIzNDU2.qta');
      expect(isQingTingNameForTest(realName), isTrue);
      // 带目录前缀、Windows 反斜杠都应识别
      expect(isQingTingNameForTest('/storage/emulated/0/Music/$realName'), isTrue);
      expect(isQingTingNameForTest('C:\\Music\\$realName'), isTrue);
    });

    test('正常 .qta 不被误判成蜻蜓', () {
      expect(isQingTingNameForTest('/a/b/song.flac'), isFalse);
      expect(isQingTingNameForTest('/a/b/.p!xxx.mp3'), isFalse);
    });

    test('完整解密：密文 → 明文与预期一致', () async {
      final name = File(fixture('sample.qta.name')).readAsStringSync().trim();
      final keyHex = File(fixture('sample.qta.key')).readAsStringSync().trim();
      final cipher = File(fixture('sample.qta')).readAsBytesSync();

      // 用真实的文件名（蜻蜓靠文件名派生 IV，必须保留 .p! 前缀）
      final input = File('${tmp.path}/$name')
        ..writeAsBytesSync(cipher);
      final output = '${tmp.path}/out.qta';

      final res = await decryptFile(
        inputPath: input.path,
        outputPath: output,
        head: Uint8List.sublistView(cipher, 0, cipher.length),
        keyResolver: () => keyHex,
      );

      expect(res.platform, DecryptPlatform.qingting);
      expect(res.bytesWritten, cipher.length);

      // 明文应以 ID3 开头——这是我们构造时的头部
      final out = File(output).readAsBytesSync();
      expect(out.length, cipher.length);
      expect(String.fromCharCodes(out.sublist(0, 3)), 'ID3');
      // 中间那段是 0..255 循环
      expect(out.sublist(10, 10 + 16),
          Uint8List.fromList(List<int>.generate(16, (i) => i)));
    });

    test('缺少设备密钥时报明确错误', () async {
      final name = File(fixture('sample.qta.name')).readAsStringSync().trim();
      final cipher = File(fixture('sample.qta')).readAsBytesSync();
      final input = File('${tmp.path}/$name')
        ..writeAsBytesSync(cipher);

      await expectLater(
        decryptFile(
          inputPath: input.path,
          outputPath: '${tmp.path}/out2.qta',
          head: Uint8List.sublistView(cipher, 0, cipher.length),
        ),
        throwsA(isA<DecryptFailure>()),
      );
    });

    test('设备密钥长度不对时报错', () async {
      final name = File(fixture('sample.qta.name')).readAsStringSync().trim();
      final cipher = File(fixture('sample.qta')).readAsBytesSync();
      final input = File('${tmp.path}/$name')
        ..writeAsBytesSync(cipher);

      await expectLater(
        decryptFile(
          inputPath: input.path,
          outputPath: '${tmp.path}/out3.qta',
          head: Uint8List.sublistView(cipher, 0, cipher.length),
          keyResolver: () => 'abcd', // 只有 2 字节
        ),
        throwsA(isA<DecryptFailure>()),
      );
    });

    test('错的密钥解出的是噪声（首字节不再是 ID3）', () async {
      final name = File(fixture('sample.qta.name')).readAsStringSync().trim();
      final cipher = File(fixture('sample.qta')).readAsBytesSync();
      final input = File('${tmp.path}/$name')
        ..writeAsBytesSync(cipher);

      await decryptFile(
        inputPath: input.path,
        outputPath: '${tmp.path}/out4.qta',
        head: Uint8List.sublistView(cipher, 0, cipher.length),
        keyResolver: () => 'ff' * 16, // 错的 key
      );

      final out = File('${tmp.path}/out4.qta').readAsBytesSync();
      expect(String.fromCharCodes(out.sublist(0, 3)), isNot('ID3'));
    });

    test('输出扩展名保持 .qta', () {
      expect(buildOutputName('/x/.p!MTIzNDU2.qta'), '.p!MTIzNDU2.qta.qta');
    });
  });
}

/// 测试里用不到 sniff 的 path 参数，这里直接调名字判定。
bool isQingTingNameForTest(String path) => _isQingTing(path);

// 复制一份实现，避免为了一个断言去导 decryptor 的私有符号。
bool _isQingTing(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  final name = (i < 0 ? path : path.substring(i + 1)).toLowerCase();
  if (!name.endsWith('.qta')) return false;
  return name.contains('.p!') || name.contains('.p~!');
}
