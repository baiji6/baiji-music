import 'kv_store.dart';

/// 免责声明与使用协议的「已同意」状态。
///
/// 只在本地记一个版本号标记：将来协议内容有重大调整时，
/// 把 [_revision] 加一，老用户就会在下次启动时重新看到弹窗。
class AgreementStore {
  AgreementStore._();

  /// 协议修订号：正文有实质性变更时 +1，用于触发重新确认。
  static const int revision = 1;

  static const String _key = 'agreement:accepted_revision';

  /// 用户是否已经同意过当前版本的协议。
  static bool get accepted =>
      KvStore.instance.getInt(_key, def: 0) >= revision;

  /// 标记用户已同意当前版本的协议。
  static Future<void> accept() =>
      KvStore.instance.setInt(_key, revision);

  /// 仅用于调试：清掉同意记录，让弹窗再次出现。
  static Future<void> reset() => KvStore.instance.remove(_key);
}
