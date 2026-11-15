// 原生解码库打包契约回归测试（v2.5.8-fix4）。
//
// **背景：一次沉默的打包事故**
//
// v2.5.8-fix2/fix3 里，用户反馈「360RA 没有调用内置的解码器」，日志只有一行
//   dlopen failed: library "qm_native_decoder_360ra.so" not found
// 而同设备的 NAC / DTS:X 探测都「可用」。逐个 readelf 后确认：
//
//   - 能加载的库文件名都带 `lib` 前缀：libMNN_dl.so / libDTSPlaybackSDK.so；
//   - 360RA 库文件被命名成裸名 `qm_native_decoder_360ra.so`，dlopen 也用
//     这个裸名；
//   - 但该库自身的 SONAME 其实是 `libqm_native_decoder_360ra.so`（带前缀）；
//   - AGP 只把 `jniLibs/<abi>/lib*.so` 打进 APK 的 `lib/<abi>/`，不带前缀
//     的文件被**静默丢弃** —— 于是 APK 里根本没有这个库，真机 dlopen 恒报
//     not found，`isSupported=false`，360RA 直接降级，从未走内置解码器。
//
// 这类问题 CI 的 Dart 单测/构建都不会报错（文件静静地没进包），只有真机才
// 暴露。这里用**文件系统契约**把它挡在 CI 里：只要有人把文件名改回裸名、
// 或让 dlopen 名与磁盘文件名/SONAME 漂移，测试立即失败。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 定位项目根（flutter test 一般从包根启动，向上兜底几层更稳）。
Directory _projectRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return dir;
    }
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  throw StateError('找不到项目根（pubspec.yaml），测试工作目录不对');
}

String _p(Directory root, List<String> parts) =>
    '${root.path}${Platform.pathSeparator}${parts.join(Platform.pathSeparator)}';

/// 把 ELF 当 latin1 读成字符串，供搜索 .dynstr 里的 ASCII 串（SONAME /
/// NEEDED）。latin1 与字节一一对应，不会因为遇到非 UTF-8 字节就抛错。
String _elfAsLatin1(File f) => latin1.decode(f.readAsBytesSync());

void main() {
  late Directory root;
  late Directory arm64;

  setUp(() {
    root = _projectRoot();
    arm64 = Directory(_p(root, [
      'android',
      'app',
      'src',
      'main',
      'jniLibs',
      'arm64-v8a'
    ]));
  });

  group('360RA 解码库打包契约（v2.5.8-fix4）', () {
    test('jniLibs 下存在带 lib 前缀的 360RA 库，且不再有裸名文件', () {
      final prefixed =
          File(_p(arm64, ['libqm_native_decoder_360ra.so']));
      final bare = File(_p(arm64, ['qm_native_decoder_360ra.so']));
      expect(prefixed.existsSync(), isTrue,
          reason: '官方 360RA 库必须以 lib 前缀命名，否则 AGP 不打包');
      expect(bare.existsSync(), isFalse,
          reason: '裸名文件若还在，说明有人把打包事故又改回来了');
    });

    test('jniLibs 内所有 .so 都以 lib 开头（AGP 只打包 lib*.so）', () {
      final libs = arm64
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.so'))
          .toList();
      expect(libs, isNotEmpty, reason: 'arm64-v8a 应有预编译解码库');
      for (final f in libs) {
        final name = f.uri.pathSegments.last;
        expect(name.startsWith('lib'), isTrue,
            reason: '$name 不带 lib 前缀，AGP 会静默丢弃、真机 dlopen 找不到');
      }
    });

    test('360RA 库的 ELF SONAME 与带前缀的文件名一致', () {
      final f = File(_p(arm64, ['libqm_native_decoder_360ra.so']));
      expect(f.existsSync(), isTrue);
      // .dynstr 里一定有 SONAME 串；这里验证它与文件名（也是 dlopen 名）一致，
      // 三者命名统一，bionic 才能按 SONAME 自动加载 NEEDED 依赖。
      expect(_elfAsLatin1(f).contains('libqm_native_decoder_360ra.so'), isTrue,
          reason: 'SONAME 应为 libqm_native_decoder_360ra.so');
    });

    test('360RA 库的 NEEDED 依赖也都以 lib 前缀存在于 jniLibs', () {
      final f = File(_p(arm64, ['libqm_native_decoder_360ra.so']));
      final elf = _elfAsLatin1(f);
      // 官方库的两个自研依赖（非系统库），bionic 会按 SONAME 在
      // nativeLibraryDir 里找，文件必须同样带 lib 前缀被打包。
      for (final dep in ['libaudio_common.so', 'libextra_mp4_parser.so']) {
        expect(elf.contains(dep), isTrue, reason: 'NEEDED 应包含 $dep');
        expect(File(_p(arm64, [dep])).existsSync(), isTrue,
            reason: '$dep 必须随包提供，否则 dlopen 360RA 会因缺依赖失败');
      }
    });

    test('ra360_glue.cpp 的 dlopen 首选名与磁盘文件名一致', () {
      final glue = File(_p(root, [
        'android',
        'app',
        'src',
        'main',
        'cpp',
        'ra360_glue.cpp'
      ]));
      final src = glue.readAsStringSync();
      // helper 的候选名里，第一个（首选/dlopen 用）必须是带前缀的正式名，
      // 与磁盘文件名、SONAME 三者一致。
      expect(src.contains('"libqm_native_decoder_360ra.so"'), isTrue,
          reason: 'dlopen 首选名必须是带 lib 前缀的正式名');
      expect(src.indexOf('"libqm_native_decoder_360ra.so"'),
          lessThan(src.indexOf('"qm_native_decoder_360ra.so"')),
          reason: '带前缀的正式名必须排在裸名兜底之前');
    });
  });
}
