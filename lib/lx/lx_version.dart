/// 洛雪音源版本号比较。
///
/// 版本串来源各异：`v27`（ikun）、`261107`（HelloWorld）、`2.3.6`（墨澜）、
/// `1.1.0`（baimusic），也可能带 `-fixN` / `+build` 后缀。解析与比较规则
/// 与 App 自身的 `UpdateChecker` 保持一致：只取开头数字段、逐位比较（位数
/// 补 0）、数字相同再比后缀 rank。
///
/// 注意：比较只在**同一个音源**的「当前版本」与「远端版本」之间进行，
/// 不同音源之间（`261107` vs `2.3.6`）不做横向比较，故数字段量级不同无碍。
class SourceVersion {
  SourceVersion._();

  /// 解析出数字段列表；无法解析返回 null。
  static List<int>? parse(String v) {
    var clean = v.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final m = RegExp(r'^\d+(?:\.\d+)*').firstMatch(clean);
    if (m == null) return null;
    clean = m.group(0)!;
    if (clean.isEmpty) return null;
    final parts = clean.split('.');
    if (parts.any((p) => p.isEmpty)) return null;
    final parsed = parts.map(int.tryParse).toList();
    if (parsed.any((p) => p == null)) return null;
    return parsed.cast<int>();
  }

  /// 三态比较：`a` 比 `b` 新 → 1；`b` 新 → -1；相等或无法比较 → 0。
  static int compare(String a, String b) {
    final va = parse(a);
    final vb = parse(b);
    if (va == null || vb == null) {
      // 两边都没有数字段时退化为字典序，避免恒判「相等」；
      // 只有一边可解析时，可解析的一方视为更新（便于首次导入后补上版本号）。
      if (va == null && vb == null) {
        return a.trim().compareTo(b.trim()).sign;
      }
      return va == null ? -1 : 1;
    }
    final n = va.length > vb.length ? va.length : vb.length;
    for (var i = 0; i < n; i++) {
      final x = i < va.length ? va[i] : 0;
      final y = i < vb.length ? vb[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    final ra = _suffixRank(a);
    final rb = _suffixRank(b);
    if (ra != rb) return ra > rb ? 1 : -1;
    if (ra >= 1000) {
      return _suffixOf(a).compareTo(_suffixOf(b)).sign;
    }
    return 0;
  }

  /// [latest] 是否严格新于 [current]。
  static bool isNewer(String latest, String current) =>
      compare(latest, current) > 0;

  static String _strip(String v) =>
      v.trim().replaceFirst(RegExp(r'^[vV]'), '');

  static String _suffixOf(String v) {
    final m = RegExp(r'^\d+(?:\.\d+)*(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$')
        .firstMatch(_strip(v));
    return m?.group(1) ?? '';
  }

  /// 后缀排序权重，与 `UpdateChecker._suffixRank` 同规则：
  /// 无后缀 / `+build` = 0；`-fixN` = 1+N；其它未知后缀 = 1000。
  static int _suffixRank(String v) {
    final m = RegExp(r'^\d+(?:\.\d+)*([-+])([0-9A-Za-z.-]+)')
        .firstMatch(_strip(v));
    if (m == null) return 0;
    if (m.group(1) == '+') return 0; // build metadata 不参与排序
    final fix = RegExp(r'^fix(\d+)$').firstMatch(m.group(2)!);
    if (fix != null) return 1 + int.parse(fix.group(1)!);
    return 1000;
  }
}
