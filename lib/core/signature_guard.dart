import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_logger.dart';

/// 签名校验结果。
class SignatureCheckResult {
  const SignatureCheckResult({
    required this.enforced,
    required this.ok,
    required this.detail,
  });

  /// 是否执行了强校验（有锚定指纹 / 有完整性清单）。
  final bool enforced;

  /// 校验是否通过。enforced=false 时恒为 true（本地构建放行）。
  final bool ok;

  /// 人类可读的说明（拦截页 / 日志用）。
  final String detail;

  /// 应用被篡改：有锚定指纹但比对失败。
  bool get tampered => enforced && !ok;

  static const skipped = SignatureCheckResult(
      enforced: false, ok: true, detail: '当前平台不适用签名校验');
}

/// 全平台签名校验（#78）。
///
/// 分平台策略：
/// - **Android**（重打包重灾区）：构建期 gradle 把实际签名证书 SHA-256
///   锚进 BuildConfig（编进 dex），原生层读取当前 APK 证书比对，
///   重签名 / 二次打包必然失败 → 拦截；
/// - **Windows / macOS / Linux**：CI 构建末尾对产物**全部文件**做
///   SHA-256 清单并用 ed25519 私钥签名（`tools/integrity_sign.py`，
///   私钥走 CI secret，公钥锚在 [_publicKeyHex]）。启动时验签清单 +
///   逐文件比对，改任何文件 / 换清单都会被抓住 → 拦截；
/// - **iOS**：分发的是未签名 ipa，最终证书由用户侧载时各不相同，
///   证书锚定会误伤所有正常安装，明确跳过（文档说明）；
/// - debug / profile 构建一律跳过（热重载 / 修改产物是开发常态）。
///
/// 拦截动作由 [main] 决定：tampered 时不进正常 UI，直接渲染防篡改拦截页。
class SignatureGuard {
  SignatureGuard._();

  static const MethodChannel _channel = MethodChannel('baiji/integrity');

  /// 完整性清单文件名（放在应用目录 / .app Contents 根下）。
  static const String manifestName = 'integrity.manifest';

  /// 清单 magic 头（第 1 行）。
  static const String manifestMagic = 'baiji-integrity-v1';

  /// ed25519 公钥（对应 CI secret 里的私钥，见 tools/integrity_sign.py）。
  static const String _publicKeyHex =
      'afbdb91aa7192390540501e0b920c6ff112cca1f7057d7249c04ae7749903f';

  /// CI 构建标记（build.yml 注入）：官方构建**必须**带完整性清单，
  /// 缺清单即视为被篡改（堵住「删掉清单绕过校验」的口子）。
  /// 本地 release 构建没有该标记，缺清单照常放行。
  static const bool _ciBuild = bool.fromEnvironment('BAIJI_CI_BUILD');

  /// 入口：返回当前平台的校验结果；任何异常都视为「跳过」而不是拦截——
  /// 校验器自身故障不能把正常用户锁在门外。
  static Future<SignatureCheckResult> check() async {
    if (kDebugMode || kProfileMode) {
      return const SignatureCheckResult(
          enforced: false, ok: true, detail: 'debug/profile 构建跳过签名校验');
    }
    try {
      if (Platform.isAndroid) return await _checkAndroid();
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        return await _checkDesktop();
      }
      // iOS：侧载自签证书各不相同，锚定会误伤，明确跳过
      return SignatureCheckResult.skipped;
    } catch (e) {
      AppLog.w('SignatureGuard', '签名校验执行异常（放行）: $e');
      return SignatureCheckResult(
          enforced: false, ok: true, detail: '校验异常放行: $e');
    }
  }

  // ==================== Android ====================

  static Future<SignatureCheckResult> _checkAndroid() async {
    final r = await _channel.invokeMethod<Map>('verifySignature');
    if (r == null) {
      return const SignatureCheckResult(
          enforced: false, ok: true, detail: '原生通道无返回');
    }
    final enforced = r['enforced'] == true;
    final ok = r['ok'] == true;
    return SignatureCheckResult(
      enforced: enforced,
      ok: ok,
      detail: enforced
          ? (ok ? '签名指纹一致' : '签名指纹不一致：预期 ${r['expected']}，实际 ${r['current']}')
          : '构建未锚定签名指纹（本地构建），跳过校验',
    );
  }

  // ==================== 桌面（Windows / macOS / Linux） ====================

  /// 清单查找：从可执行文件目录向上最多 4 层——
  /// Windows/Linux 清单与 exe 同目录；macOS 清单放 `.app/Contents/`，
  /// 覆盖整个 bundle（exe 在 `Contents/MacOS/` 下）。
  static Future<SignatureCheckResult> _checkDesktop() async {
    var base = Directory(File(Platform.resolvedExecutable).parent.path);
    File? manifest;
    for (var i = 0; i < 4; i++) {
      final f = File('${base.path}${Platform.pathSeparator}$manifestName');
      if (f.existsSync()) {
        manifest = f;
        break;
      }
      final parent = base.parent;
      if (parent.path == base.path) break;
      base = parent;
    }
    if (manifest == null) {
      if (_ciBuild) {
        // 官方 CI 构建一定带清单；没有 = 被人删掉绕过校验
        return const SignatureCheckResult(
            enforced: true, ok: false, detail: '官方构建缺少完整性清单（被删除）');
      }
      return const SignatureCheckResult(
          enforced: false,
          ok: true,
          detail: '无完整性清单（本地构建或旧产物），跳过校验');
    }
    return verifyManifest(base, manifest, ciBuild: _ciBuild);
  }

  /// 校验 [manifestFile]（签名清单）对其覆盖目录 [appDir] 的完整性。
  /// [publicKeyHex] 默认为生产公钥，测试注入自己的密钥对公钥。
  /// [ciBuild] 仅测试用（生产读编译期常量 [_ciBuild]）。
  /// public 仅为可测试性；生产入口是 [check]。
  static Future<SignatureCheckResult> verifyManifest(
      Directory appDir, File manifestFile,
      {String publicKeyHex = _publicKeyHex, bool ciBuild = false}) async {
    try {
      // 1) 解析 + 验签
      final lines = await manifestFile.readAsLines();
      if (lines.length < 3 || lines[0] != manifestMagic) {
        return const SignatureCheckResult(
            enforced: true, ok: false, detail: '完整性清单格式异常');
      }
      final Uint8List sig;
      final Map<String, dynamic> payload;
      final String jsonText = lines.sublist(2).join('\n');
      try {
        sig = base64Decode(lines[1].trim());
        payload = jsonDecode(jsonText) as Map<String, dynamic>;
      } catch (e) {
        return SignatureCheckResult(
            enforced: true, ok: false, detail: '完整性清单解析失败: $e');
      }
      final jsonBytes = Uint8List.fromList(utf8.encode(jsonText));
      if (!_verifyEd25519(jsonBytes, sig, publicKeyHex)) {
        return const SignatureCheckResult(
            enforced: true,
            ok: false,
            detail: '完整性清单签名无效（被替换或私钥不符）');
      }

      // 2) 逐文件比对
      final files = payload['files'];
      if (files is! Map) {
        return const SignatureCheckResult(
            enforced: true, ok: false, detail: '完整性清单缺少 files 字段');
      }
      var checked = 0;
      for (final entry in files.entries) {
        final rel = entry.key as String;
        final expect = entry.value as String;
        final f =
            File('${appDir.path}${Platform.pathSeparator}'
                '${rel.replaceAll('/', Platform.pathSeparator)}');
        if (!f.existsSync()) {
          return SignatureCheckResult(
              enforced: true, ok: false, detail: '受保护文件缺失: $rel');
        }
        final actual = sha256Hex(await f.readAsBytes());
        if (actual != expect) {
          return SignatureCheckResult(
              enforced: true, ok: false, detail: '受保护文件被篡改: $rel');
        }
        checked++;
      }
      AppLog.i('SignatureGuard', '完整性清单验签通过（$checked 个文件）');
      return SignatureCheckResult(
          enforced: true, ok: true, detail: '完整性清单验签通过（$checked 个文件）');
    } catch (e) {
      // 清单存在却校验崩溃——按被篡改处理（宁可误报不可漏报）
      return SignatureCheckResult(
          enforced: true, ok: false, detail: '完整性校验执行异常: $e');
    }
  }

  // ==================== 密码学原语 ====================

  /// ed25519 验签（RFC 8032，与 CI 端 openssl 签名互通）；
  /// key/sig 任一长度不对或验不过都返回 false。
  static bool _verifyEd25519(Uint8List message, Uint8List signature,
      [String publicKeyHex = _publicKeyHex]) {
    try {
      if (signature.length != ed.SignatureSize) return false;
      return ed.verify(ed.PublicKey(_hexBytes(publicKeyHex)), message,
          signature);
    } catch (e) {
      return false;
    }
  }

  static Uint8List _hexBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// SHA-256 hex（小写）。
  static String sha256Hex(List<int> data) =>
      sha256.convert(data).toString();
}
