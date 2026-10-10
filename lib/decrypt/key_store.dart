/// 解密密钥库。
///
/// 密钥有两个来源：
/// - **导入**：用户把客户端数据库（QQ 的 MMKV / 酷狗的 `music.db` / 酷我的
///   配置库）或导出的 ekey 文本丢进来，本类负责扫出来；
/// - **手动填写**：用户直接粘贴 ekey / fileKey。
///
/// **每条密钥必须归属一个平台。** 五个平台的加密规则完全不同：
/// QQ 用tc-tea 派生的 ekey、酷狗 v5 复用 QMC v2、酷我用自己的非标准 DES、
/// 网易云是 AES-128-ECB + RC4、咪咕是 MD5 派生 fileKey。把QQ 的 ekey
/// 喂给酷我解，轻则报错、重则解出一堆噪声音频，所以查找时**必须**带平台。
///
/// 持久化用 shared_preferences，不进日志、不上传。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'decryptor.dart' show DecryptPlatform;

/// 密钥条目。**[value] 才是真正能喂给算法的密钥**，其余字段只用于检索。
class DecryptKeyEntry {
  const DecryptKeyEntry({
    required this.value,
    required this.platform,
    this.mid,
    this.mediaFilename,
    this.qualityId,
    this.source = KeySource.manual,
  });

  /// ekey（QMC / KGM v5 / KWM v2）或 fileKey（咪咕）。
  final String value;

  /// 这条密钥属于哪个平台。**必填**——跨平台混用密钥只会解出噪声。
  final DecryptPlatform platform;

  /// `file.media_mid`，QMC STag / MusicEx 用它检索。
  final String? mid;

  /// `file.media_mid` + 扩展名，MusicEx 用。
  final String? mediaFilename;

  /// 音质 id，酷我用（`Header::get_quality_id`）。
  final int? qualityId;

  final KeySource source;

  Map<String, dynamic> toJson() => {
        'v': value,
        'p': platform.name,
        if (mid != null) 'mid': mid,
        if (mediaFilename != null) 'file': mediaFilename,
        if (qualityId != null) 'q': qualityId,
        's': source.name,
      };

  static DecryptKeyEntry fromJson(Map<String, dynamic> j) {
    // 老版本（v1）没有平台字段，一律归到 QQ 音乐——那时密钥只可能来自
    // QQ 音乐的 footer/MMKV，其它平台的密钥是靠文件头自带的。
    final pName = j['p'] as String?;
    final platform = pName == null
        ? DecryptPlatform.qqMusic
        : DecryptPlatform.values.firstWhere(
            (p) => p.name == pName,
            orElse: () => DecryptPlatform.qqMusic,
          );
    return DecryptKeyEntry(
      value: (j['v'] as String?) ?? '',
      platform: platform,
      mid: j['mid'] as String?,
      mediaFilename: j['file'] as String?,
      qualityId: j['q'] as int?,
      source: KeySource.values.firstWhere(
        (s) => s.name == j['s'],
        orElse: () => KeySource.manual,
      ),
    );
  }
}

/// 密钥来源。
enum KeySource { manual, importedMmkv, importedDatabase, importedText }

/// 密钥仓库。所有查找方法都要求指定 [DecryptPlatform]。
class DecryptKeys {
  DecryptKeys._(this._list);

  /// 仅供单元测试：不落盘，直接在内存里造一个仓库。
  factory DecryptKeys.fromEntriesForTest(List<DecryptKeyEntry> entries) {
    final k = DecryptKeys._(List.of(entries));
    k._dedup();
    return k;
  }

  final List<DecryptKeyEntry> _list;

  static const String _prefsKey = 'baiji.decrypt.keys.v2';

  /// v1 的存储 key，只用于一次性迁移。
  static const String _legacyPrefsKey = 'baiji.decrypt.keys.v1';

  /// 读出全部密钥；顺带把 v1 的老数据升级到 v2。
  static Future<DecryptKeys> load() async {
    final prefs = await SharedPreferences.getInstance();

    var raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) {
      // 迁移：v1 的条目没有平台字段，fromJson 会默认归到 QQ 音乐。
      final legacy = prefs.getString(_legacyPrefsKey);
      if (legacy != null && legacy.isNotEmpty) {
        final migrated = DecryptKeys._(_decode(legacy));
        await migrated.save();
        await prefs.remove(_legacyPrefsKey);
        return migrated;
      }
      return DecryptKeys._([]);
    }
    return DecryptKeys._(_decode(raw));
  }

  static List<DecryptKeyEntry> _decode(String raw) {
    try {
      return (json.decode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(DecryptKeyEntry.fromJson)
          .where((e) => e.value.isNotEmpty)
          .toList();
    } catch (_) {
      // 数据结构损坏时宁可返回空库，也不要让用户进不去页面
      return [];
    }
  }

  /// 写回存储。
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode(_list.map((e) => e.toJson()).toList()));
  }

  /// 全部条目（跨平台，仅用于展示）。
  List<DecryptKeyEntry> get entries => List.unmodifiable(_list);
  int get length => _list.length;
  bool get isEmpty => _list.isEmpty;
  bool get isNotEmpty => _list.isNotEmpty;

  /// 某个平台下的条目。
  List<DecryptKeyEntry> entriesOf(DecryptPlatform p) =>
      List.unmodifiable(_list.where((e) => e.platform == p));

  /// 某个平台下的密钥条数。
  int countOf(DecryptPlatform p) =>
      _list.where((e) => e.platform == p).length;

  /// 某平台是否有密钥。
  bool hasKeysFor(DecryptPlatform p) => countOf(p) > 0;

  /// 按 mid 精确查找（限平台）。
  String? lookupByMid(String mid, DecryptPlatform platform) {
    for (final e in _list) {
      if (e.platform == platform && e.mid == mid) return e.value;
    }
    return null;
  }

  /// 按原始文件名查找（限平台）。
  String? lookupByMediaFilename(String name, DecryptPlatform platform) {
    for (final e in _list) {
      if (e.platform == platform && e.mediaFilename == name) return e.value;
    }
    return null;
  }

  /// 按音质 id 查找（限平台，酷我 v2 用）。
  String? lookupByQualityId(int q, DecryptPlatform platform) {
    for (final e in _list) {
      if (e.platform == platform && e.qualityId == q) return e.value;
    }
    return null;
  }

  /// 兜底：返回该平台下第一条可用密钥。
  ///
  /// 仅在「同平台、只下了这一首歌」这类场景有效，所以调用方应优先用
  /// mid / filename 精确查。**注意绝不会跨平台返回**。
  String? anyEkeyOf(DecryptPlatform platform) {
    for (final e in _list) {
      if (e.platform == platform) return e.value;
    }
    return null;
  }

  /// 添加一条，**同平台**下value 相同则覆盖。
  ///
  /// 跨平台不做覆盖——QQ 的 ekey 和酷狗的 fileKey 规则不同，即使字面相同
  /// 也是两条独立记录。
  Future<void> add(DecryptKeyEntry entry) async {
    _list.removeWhere(
        (e) => e.value == entry.value && e.platform == entry.platform);
    _list.add(entry);
    await save();
  }

  Future<void> remove(String value, DecryptPlatform platform) async {
    _list.removeWhere((e) => e.value == value && e.platform == platform);
    await save();
  }

  /// 只清空某一个平台的密钥，其他平台不受影响。
  Future<void> clearPlatform(DecryptPlatform platform) async {
    _list.removeWhere((e) => e.platform == platform);
    await save();
  }

  Future<void> clear() async {
    _list.clear();
    await save();
  }

  /// 从纯文本里导入密钥。
  ///
  /// 支持逐行 `ekey`，以及 `mid,ekey` / `mid,filename,ekey` 两种 CSV 形式，
  /// 自动跳过空行与以 `#` 开头的注释。
  ///
  /// [platform] 由调用方指定——同一段文本对不同平台的含义完全不同，
  /// 不做自动猜测（密钥串本身看不出属于哪个平台）。
  int importText(
    String text, {
    required DecryptPlatform platform,
    KeySource source = KeySource.importedText,
  }) {
    var count = 0;
    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final parts = line.split(',').map((s) => s.trim()).toList();
      if (parts.length >= 3) {
        _list.add(DecryptKeyEntry(
          value: parts.sublist(2).join(','),
          platform: platform,
          mid: parts[0],
          mediaFilename: parts[1],
          source: source,
        ));
      } else if (parts.length == 2) {
        _list.add(DecryptKeyEntry(
          value: parts[1],
          platform: platform,
          mid: parts[0],
          source: source,
        ));
      } else {
        _list.add(DecryptKeyEntry(
            value: parts[0], platform: platform, source: source));
      }
      count++;
    }
    _dedup();
    return count;
  }

  /// 从客户端数据库的字节流里扫密钥。
  ///
  /// [found] 里的每条都必须已带platform（扫描器按魔数判定）。
  Future<int> importEntries(List<DecryptKeyEntry> found) async {
    _list.addAll(found);
    _dedup();
    await save();
    return found.length;
  }

  /// 去重：同一条密钥只留一个（**跨平台不合并**——
  /// 不同平台的密钥串即使字面相同也是两条独立记录）。
  void _dedup() {
    final seen = <String>{};
    _list.removeWhere((e) => !seen.add('${e.platform.name}\u0000${e.value}'));
  }
}
