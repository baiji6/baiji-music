/// 第三方音源设置（v2.6.7）。
///
/// 一个「内置音源」开关 + 一个用户自填的 API Key：
/// - [useBuiltIn] = true（默认）：取流走各平台内置实现，行为与此前一致；
/// - [useBuiltIn] = false：取流走第三方聚合接口
///   `https://source.shiqianjiang.cn/api/music/url`。
///
/// Key 只由设置页写入 KvStore，**代码里没有任何默认值**，发布包不含 key。
/// JOOX / QQ 音乐 2 没有第三方通道，永远走内置（见 ThirdPartyStreamApi）。
library;

import 'package:flutter/foundation.dart';

import 'kv_store.dart';

class ThirdPartySource extends ChangeNotifier {
  ThirdPartySource._();

  static final ThirdPartySource instance = ThirdPartySource._();

  static const String _prefs = 'third_party_source';
  static const String _kUseBuiltIn = 'use_built_in';
  static const String _kApiKey = 'api_key';
  static const String _kProviderId = 'provider_id';

  /// 默认走内置音源（不改变老用户行为；未填 key 时第三方通道也用不了）。
  static const bool defaultUseBuiltIn = true;

  /// 默认 provider：聆澜。未来接入别的第三方 API 时改这里或在设置里切换。
  static const String defaultProviderId = 'linglan';

  bool _useBuiltIn = defaultUseBuiltIn;
  String _apiKey = '';
  String _providerId = defaultProviderId;

  /// true = 取流走内置实现；false = 走第三方聚合 API。
  bool get useBuiltIn => _useBuiltIn;

  /// 用户自填的第三方 API Key（未填时为空串）。
  String get apiKey => _apiKey;

  /// 当前选择的第三方 provider id（默认 `linglan` 聆澜）。
  String get providerId => _providerId;

  bool get hasApiKey => _apiKey.isNotEmpty;

  /// 是否具备走第三方通道的条件：开关关闭（用第三方）且已填 key。
  bool get shouldUseThirdParty => !_useBuiltIn && _apiKey.isNotEmpty;

  /// 启动时恢复（main 里 KvStore 就绪后调用一次）。
  Future<void> load() async {
    _useBuiltIn = KvStore.instance.getBool(
      '$_prefs:$_kUseBuiltIn',
      def: defaultUseBuiltIn,
    );
    _apiKey = KvStore.instance.getString('$_prefs:$_kApiKey')?.trim() ?? '';
    final storedProvider = KvStore.instance.getString('$_prefs:$_kProviderId');
    _providerId = (storedProvider != null && storedProvider.trim().isNotEmpty)
        ? storedProvider.trim()
        : defaultProviderId;
    notifyListeners();
  }

  Future<void> setUseBuiltIn(bool v) async {
    if (v == _useBuiltIn) return;
    _useBuiltIn = v;
    notifyListeners();
    await KvStore.instance.setBool('$_prefs:$_kUseBuiltIn', v);
  }

  /// 切换第三方 provider（未来接入新 API 时用；当前只有 `linglan`）。
  Future<void> setProviderId(String id) async {
    if (id.isEmpty || id == _providerId) return;
    _providerId = id;
    notifyListeners();
    await KvStore.instance.setString('$_prefs:$_kProviderId', id);
  }

  Future<void> setApiKey(String key) async {
    final next = key.trim();
    if (next == _apiKey) return;
    _apiKey = next;
    notifyListeners();
    await KvStore.instance.setString('$_prefs:$_kApiKey', next);
  }
}
