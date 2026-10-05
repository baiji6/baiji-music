/// String 安全截断扩展。
///
/// Dart 的 String 没有 Iterable.take，这里为日志/摘要场景提供等价能力。
extension StringClip on String {
  /// 超过 [n] 时截断到前 n 个字符（不抛异常）。
  String clip(int n) => length <= n ? this : substring(0, n);
}