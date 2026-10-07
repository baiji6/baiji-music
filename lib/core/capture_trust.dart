import 'dart:io';

import 'kv_store.dart';

/// 抓包调试支持（Reqable / Charles / Fiddler / mitmproxy）。
///
/// 背景（这也是只加 `networkSecurityConfig.xml` 抓不到包的原因）：
/// Dart 的 TLS 校验**不走** Android 的网络安全配置——Android 端 `dart:io`
/// 在 `runtime/bin/security_context_android.cc` 里写死只加载
/// `/system/etc/security/cacerts`（系统证书目录），用户证书库里的抓包 CA 一律不认；
/// iOS / macOS / Windows / Linux 同理，只认各自平台内置的根证书。
/// 所以必须在 Dart 侧把 `badCertificateCallback` 放行，抓包工具的中间人证书
/// 才能通过校验。
///
/// 本开关对 **debug / profile / release 全部生效**（用户要求正式版也要能抓包），
/// 默认关闭，在「设置 → 抓包调试」里手动打开。
class CaptureTrust {
  CaptureTrust._();

  static const _keyEnabled = 'capture_trust_enabled';
  static const _keyProxy = 'capture_proxy';

  static bool _enabled = false;
  static String _proxy = '';

  /// 是否放行中间人证书（抓包开关）。
  static bool get enabled => _enabled;

  /// 手动指定的抓包代理 `host:port`；为空时沿用环境变量（HTTP_PROXY / HTTPS_PROXY）。
  static String get proxy => _proxy;

  static bool get proxyEnabled => _proxy.trim().isNotEmpty;

  /// 启动阶段从本地存储恢复开关状态。
  static Future<void> load() async {
    _enabled = KvStore.instance.getBool(_keyEnabled, def: false);
    _proxy = KvStore.instance.getString(_keyProxy, def: '') ?? '';
  }

  static Future<void> setEnabled(bool v) async {
    _enabled = v;
    await KvStore.instance.setBool(_keyEnabled, v);
  }

  /// 设置抓包代理。
  ///
  /// 注意：代理地址在 HttpClient 创建时就固定了，改动后需要**重启应用**才生效；
  /// 而 [setEnabled] 是每次握手实时读取，即时生效。
  static Future<void> setProxy(String v) async {
    _proxy = v.trim();
    await KvStore.instance.setString(_keyProxy, _proxy);
  }
}

/// 全局 [HttpOverrides]：把抓包开关接到所有 `dart:io` HttpClient 上。
///
/// 覆盖 dio（搜索 / 取流 / 歌词 / 下载 / 更新检查）与 Flutter 图片加载等
/// 所有走 `dart:io` 的请求。
class CaptureHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // 基类实现是 `new _HttpClient(context)`，不会再次进入本方法，无递归风险
    final client = super.createHttpClient(context);
    // 证书校验失败时回调；返回 true 表示接受抓包工具的中间人证书。
    // 闭包每次握手都重新读取 [CaptureTrust.enabled]，所以开关即时生效。
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) => CaptureTrust.enabled;
    if (CaptureTrust.proxyEnabled) {
      final proxy = CaptureTrust.proxy;
      client.findProxy = (Uri uri) => 'PROXY $proxy';
    }
    return client;
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    if (CaptureTrust.proxyEnabled) return 'PROXY ${CaptureTrust.proxy}';
    return super.findProxyFromEnvironment(url, environment);
  }
}
