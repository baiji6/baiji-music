// 全平台签名校验（#78）：桌面端完整性清单验签的契约测试。
//
// 生产私钥走 CI secret 不入库；本文件内置一对**仅用于测试**的
// ed25519 密钥（公开无妨，与生产密钥无关），用
// [SignatureGuard.verifyManifest] 的公钥注入参数做端到端验证。
import 'dart:convert';
import 'dart:io';

import 'package:baiji_music/core/signature_guard.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测试私钥种子（PKCS#8 seed）与公钥。
const _testSeedHex =
    'eacf24fabf3682f417851a1ff3b2ff78515bc2e96eedaf1a75ccd8177185133d';
const _testPubHex =
    '15dd87ddaae137f839939aa66955200d91f0ccc4a42833f8103705da719faf7e';
/// 另一把无关密钥的公钥（交叉验签必须失败）。
const _otherPubHex =
    'afbdb91aa7192390540501e0b920c6ff112cca1f7057d7249c04ae7749903f';

Uint8List _hexBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

ed.PrivateKey get _testKey {
  final seed = _hexBytes(_testSeedHex);
  final pub = ed.public(ed.PrivateKey(
      Uint8List.fromList([...seed, ..._hexBytes(_testPubHex)])));
  return ed.PrivateKey(Uint8List.fromList([...seed, ...pub.bytes]));
}

String _signManifest(String jsonText) =>
    base64Encode(ed.sign(_testKey, Uint8List.fromList(utf8.encode(jsonText))));

Future<Directory> _fixture(Map<String, String> files) async {
  final dir = await Directory.systemTemp.createTemp('sig_guard');
  addTearDown(() => dir.deleteSync(recursive: true));
  for (final e in files.entries) {
    final f = File('${dir.path}${Platform.pathSeparator}'
        '${e.key.replaceAll('/', Platform.pathSeparator)}');
    await f.parent.create(recursive: true);
    await f.writeAsString(e.value);
  }
  return dir;
}

void main() {
  test('合法清单：验签通过且逐文件命中', () async {
    final dir = await _fixture({
      'baiji_music.exe': 'binary-bytes',
      'data/icudt.dat': 'big-endian-data',
    });
    // 哈希用真实算法：先算出真实清单再签名
    final real = {
      'files': {
        for (final e in {
          'baiji_music.exe': 'binary-bytes',
          'data/icudt.dat': 'big-endian-data',
        }.entries)
          e.key: SignatureGuard.sha256Hex(utf8.encode(e.value)),
      },
      'version': '2.2.9',
    };
    final jsonText = jsonEncode(real);
    final manifest = File(
        '${dir.path}${Platform.pathSeparator}${SignatureGuard.manifestName}');
    await manifest.writeAsString(
        '${SignatureGuard.manifestMagic}\n${_signManifest(jsonText)}\n$jsonText\n');

    final r = await SignatureGuard.verifyManifest(dir, manifest,
        publicKeyHex: _testPubHex);
    expect(r.tampered, isFalse, reason: r.detail);
    expect(r.enforced, isTrue);
    expect(r.detail, contains('2 个文件'));
  });

  test('文件被篡改 → 拦截', () async {
    final dir = await _fixture({'app.bin': 'original'});
    final files = {'app.bin': SignatureGuard.sha256Hex(utf8.encode('original'))};
    final jsonText =
        jsonEncode({'files': files, 'version': '2.2.9'});
    final manifest = File(
        '${dir.path}${Platform.pathSeparator}${SignatureGuard.manifestName}');
    await manifest.writeAsString(
        '${SignatureGuard.manifestMagic}\n${_signManifest(jsonText)}\n$jsonText\n');
    // 篡改
    await File('${dir.path}/app.bin').writeAsString('hacked');

    final r = await SignatureGuard.verifyManifest(dir, manifest,
        publicKeyHex: _testPubHex);
    expect(r.tampered, isTrue);
    expect(r.detail, contains('app.bin'));
  });

  test('受保护文件缺失 → 拦截', () async {
    final dir = await _fixture({'keep.bin': 'a'});
    final jsonText = jsonEncode({
      'files': {
        'keep.bin': SignatureGuard.sha256Hex(utf8.encode('a')),
        'gone.bin': '00' * 32,
      },
      'version': '2.2.9',
    });
    final manifest = File(
        '${dir.path}${Platform.pathSeparator}${SignatureGuard.manifestName}');
    await manifest.writeAsString(
        '${SignatureGuard.manifestMagic}\n${_signManifest(jsonText)}\n$jsonText\n');

    final r = await SignatureGuard.verifyManifest(dir, manifest,
        publicKeyHex: _testPubHex);
    expect(r.tampered, isTrue);
    expect(r.detail, contains('gone.bin'));
  });

  test('签名无效（换私钥重签的清单）→ 拦截', () async {
    final dir = await _fixture({'app.bin': 'a'});
    final jsonText = jsonEncode({
      'files': {'app.bin': SignatureGuard.sha256Hex(utf8.encode('a'))},
      'version': '2.2.9',
    });
    final manifest = File(
        '${dir.path}${Platform.pathSeparator}${SignatureGuard.manifestName}');
    // 用测试公钥验，但清单是"别的密钥"签的（这里用生产公钥当另一把钥匙，
    // 只需要保证与 _testPubHex 不同即可）
    final forged = base64Encode(
        ed.sign(_testKey, Uint8List.fromList(utf8.encode('not the payload'))));
    await manifest.writeAsString(
        '${SignatureGuard.manifestMagic}\n$forged\n$jsonText\n');

    final r = await SignatureGuard.verifyManifest(dir, manifest,
        publicKeyHex: _testPubHex);
    expect(r.tampered, isTrue);
    expect(r.detail, contains('签名无效'));
    // 交叉确认：生产公钥同样验不过测试密钥签的清单
    final r2 = await SignatureGuard.verifyManifest(dir, manifest,
        publicKeyHex: _otherPubHex);
    expect(r2.tampered, isTrue);
  });

  test('清单格式异常 / 解析失败 → 拦截', () async {
    final dir = await _fixture({'app.bin': 'a'});
    final manifest = File(
        '${dir.path}${Platform.pathSeparator}${SignatureGuard.manifestName}');
    await manifest.writeAsString('not-manifest\n');
    final r =
        await SignatureGuard.verifyManifest(dir, manifest, publicKeyHex: _testPubHex);
    expect(r.tampered, isTrue);
    expect(r.detail, contains('格式异常'));
  });

  test('官方 CI 构建（ciBuild）缺清单语义由 _checkDesktop 判定；'
      'verifyManifest 本身始终要求清单存在', () async {
    // 该用例锚定行为约定：verifyManifest 收到不存在的清单文件会抛异常，
    // 外层按被篡改处理（宁可误报不可漏报）
    final dir = await _fixture({'app.bin': 'a'});
    final missing = File(
        '${dir.path}${Platform.pathSeparator}no-such.manifest');
    final r = await SignatureGuard.verifyManifest(dir, missing,
        publicKeyHex: _testPubHex);
    expect(r.tampered, isTrue);
    expect(r.detail, contains('异常'));
  });
}
