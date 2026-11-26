// baka 解码器打包契约与资产完整性回归测试（v2.6.6）。
//
// 防止两类沉默事故：
//  1. so 文件名丢 lib 前缀 → AGP 静默不打包 → 真机 dlopen 恒失败；
//  2. AV3A 模型/LSF 资产缺失或损坏 → baka-av3a 解码不可用。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _projectRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return dir;
    }
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  throw StateError('找不到项目根');
}

String _p(Directory root, List<String> parts) =>
    '${root.path}${Platform.pathSeparator}${parts.join(Platform.pathSeparator)}';

void main() {
  late Directory root;
  setUp(() => root = _projectRoot());

  group('baka 解码器 so 打包契约（v2.6.6）', () {
    for (final abi in ['arm64-v8a', 'armeabi-v7a']) {
      test('$abi 存在 libac4_baka.so / libav3a_baka.so（lib 前缀）', () {
        final dir = Directory(_p(root, [
          'android', 'app', 'src', 'main', 'jniLibs', abi
        ]));
        for (final so in ['libac4_baka.so', 'libav3a_baka.so']) {
          expect(File(_p(dir, [so])).existsSync(), isTrue,
              reason: '$abi/$so 必须存在且带 lib 前缀，否则 AGP 不打包');
        }
      });
    }

    test('so 是合法 ELF（含 magic 0x7fELF）', () {
      final f = File(_p(root, [
        'android', 'app', 'src', 'main', 'jniLibs', 'arm64-v8a', 'libac4_baka.so'
      ]));
      final head = f.readAsBytesSync().sublist(0, 4);
      expect(head, equals([0x7f, 0x45, 0x4c, 0x46]));
    });
  });

  group('AV3A 模型资产完整性（v2.6.6）', () {
    test('model.bin / lsf.bin 存在且大小正确', () {
      final dir = Directory(_p(root, ['assets', 'av3a']));
      final model = File(_p(dir, ['model.bin']));
      final lsf = File(_p(dir, ['lsf.bin']));
      expect(model.existsSync(), isTrue);
      expect(lsf.existsSync(), isTrue);
      expect(model.lengthSync(), 79930, reason: 'baka-av3a 模型大小固定 79930');
      expect(lsf.lengthSync(), 43976, reason: 'baka-av3a LSF 大小固定 43976');
    });

    test('lsf.bin 魔数为 AV3LSF01', () {
      final lsf = File(_p(root, ['assets', 'av3a', 'lsf.bin']));
      final magic = latin1.decode(lsf.readAsBytesSync().sublist(0, 8));
      expect(magic, 'AV3LSF01');
    });

    test('pubspec 已声明 assets/av3a/', () {
      final pubspec = File(_p(root, ['pubspec.yaml'])).readAsStringSync();
      expect(pubspec.contains('- assets/av3a/'), isTrue);
    });
  });
}
