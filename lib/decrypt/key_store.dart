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
    this.audioHash,
    this.resourceId,
    this.source = KeySource.manual,
  });

  /// ekey（QMC / KGM v5 / KWM v2）或设备密钥（蜻蜓）/ fileKey（咪咕）。
  final String value;

  /// 这条密钥属于哪个平台。**必填**——跨平台混用密钥只会解出噪声。
  final DecryptPlatform platform;

  /// `file.media_mid`，QMC STag / MusicEx 用它检索。
  final String? mid;

  /// QQ 音乐 MusicEx footer 里的**原始文件名**（`mediaName`）。
  ///
  /// 这是 QQ 音乐 QMC v2 唯一的匹配依据——上游
  /// `selectQMCv2KeyByFileName` 就是拿它当key 去查表。
  final String? mediaFilename;

  /// 酷狗 v5 的 `audioHash`（文件头里的音频指纹）。
  ///
  /// 上游 `selectKugouKey` 用它做 key 查表，**不命中就没有密钥**，
  /// 不会退化成"随便取一把"。
  final String? audioHash;

  /// 酷我的资源 id（文件头 0x18）。
  final int? resourceId;

  /// 音质 id，酷我用（取 `format_name` 开头连续数字）。
  final int? qualityId;

  final KeySource source;

  /// 这个平台用来查表的**匹配键**；为空表示该平台不需要匹配键。
  ///
  /// 对齐 um-react `features/settings/settingsSelector.ts`：
  /// - QQ 音乐 → 原始文件名（可选模糊匹配，见 [DecryptKeys.lookupByFileName]）
  /// - 酷狗 → `audioHash`
  /// - 酷我 → `rid-quality`（rid 与quality **必须同时**对上）
  /// - 蜻蜓 FM → 无（单把设备密钥通吃）
  /// - 网易云 / 咪咕 → 无（密钥在文件头里）
  String? get matchKey {
    switch (platform) {
      case DecryptPlatform.qqMusic:
        return mediaFilename;
      case DecryptPlatform.kugou:
        return audioHash;
      case DecryptPlatform.kuwo:
        // 上游：`${rid}-${quality.replace(/\D/g, '')}`
        if (resourceId == null || qualityId == null) return null;
        return '$resourceId-$qualityId';
      case DecryptPlatform.qingting:
      case DecryptPlatform.netease:
      case DecryptPlatform.migu:
        return null;
    }
  }

  /// 匹配键是否够用了。填不全的话这条密钥永远查不到，只能靠兜底。
  ///
  /// QQ 音乐放宽成「文件名**或** mid」——因为 MusicEx footer 里两个字段
  /// 可能只有一个存在，而 [resolveEkey] 的 QQ 分支确实是两条都查。
  /// 酷狗/ 酷我则必须严格：上游 `hasOwn` / `rid-quality` 不命中就**没有密钥**。
  bool get hasMatchKey => switch (platform) {
        DecryptPlatform.qqMusic =>
          (mediaFilename != null && mediaFilename!.isNotEmpty) ||
              (mid != null && mid!.isNotEmpty),
        _ => matchKey != null,
      };

  Map<String, dynamic> toJson() => {
        'v': value,
        'p': platform.name,
        if (mid != null) 'mid': mid,
        if (mediaFilename != null) 'file': mediaFilename,
        if (audioHash != null) 'ah': audioHash,
        if (resourceId != null) 'rid': resourceId,
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
      audioHash: j['ah'] as String?,
      resourceId: (j['rid'] as num?)?.toInt(),
      qualityId: (j['q'] as num?)?.toInt(),
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
  /// **只在"该平台下的第一条"确实带有匹配键时才返回**；对需要匹配键的
  /// 平台（QQ / 酷狗 / 酷我），拿不到匹配键的密钥是没法用的，
  /// 返回它只会解出噪声，所以宁可返回 null。
  ///
  /// 上游的行为：酷狗 `hasOwn(keys, audioHash)` 不命中就**没有密钥**，
  /// 绝不会退化成"任意一把"。这里保持一致。
  String? anyEkeyOf(DecryptPlatform platform) {
    final needsKey = platform.needsMatchKey;
    for (final e in _list) {
      if (e.platform != platform) continue;
      if (needsKey && !e.hasMatchKey) continue;
      return e.value;
    }
    return null;
  }

  /// 按匹配键精确查找（限平台）。
  ///
  /// 这是 QQ / 酷狗 / 酷我的**正确用法**：从文件头/ footer 取出匹配键
  /// （文件名 / audioHash / rid-quality）直接查表，命中即用、不命中即无。
  String? lookupByMatchKey(String matchKey, DecryptPlatform platform) {
    if (matchKey.isEmpty) return null;
    for (final e in _list) {
      if (e.platform == platform && e.matchKey == matchKey) return e.value;
    }
    return null;
  }

  /// QQ 音乐专用：文件名精确匹配 → 可选模糊匹配。
  ///
  /// 对齐上游 `selectQMCv2KeyByFileName`：
  /// ```ts
  /// if (hasOwn(keys, normalizedName)) ekey = keys[normalizedName];
  /// else if (allowFuzzyNameSearch) {
  ///   const closestName = closestByLevenshtein(normalizedName, qmc2KeyStoreNames);
  ///   ekey = keys[closestName];
  /// }
  /// ```
  /// 模糊匹配只在**同一平台内**进行，绝不会跨到别的平台。
  String? lookupByFileName(String name, DecryptPlatform platform,
      {bool allowFuzzy = true}) {
    if (name.isEmpty) return null;
    final exact = lookupByMatchKey(name, platform);
    if (exact != null) return exact;
    if (!allowFuzzy) return null;

    String? best;
    var bestDist = 1 << 30;
    for (final e in _list) {
      if (e.platform != platform) continue;
      final k = e.matchKey;
      if (k == null || k.isEmpty) continue;
      final d = _levenshtein(name, k);
      if (d < bestDist) {
        bestDist = d;
        best = e.value;
      }
    }
    // 名字差太远就不猜了——猜错会解出噪声还让人以为密钥不对。
    return bestDist <= 3 ? best : null;
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final la = a.length, lb = b.length;
    var prev = List<int>.generate(lb + 1, (i) => i);
    var cur = List<int>.filled(lb + 1, 0);
    for (var i = 1; i <= la; i++) {
      cur[0] = i;
      final ca = a.codeUnitAt(i - 1);
      for (var j = 1; j <= lb; j++) {
        final cost = ca == b.codeUnitAt(j - 1) ? 0 : 1;
        final d = prev[j] + 1;
        final ins = cur[j - 1] + 1;
        final del = prev[j - 1] + cost;
        cur[j] = d < ins ? (d < del ? d : del) : (ins < del ? ins : del);
      }
      final t = prev;
      prev = cur;
      cur = t;
    }
    return prev[lb];
  }

  /// 添加一条，**同平台 + 同密钥 + 同匹配键**才覆盖。
  ///
  /// 匹配键必须参与判重（fix4）：同批下载的歌常用同一把 ekey，
  /// 只按「平台+密钥」覆盖会把先加入的另一首歌的匹配条目顶掉。
  ///
  /// 跨平台不做覆盖——QQ 的 ekey 和酷狗的 fileKey 规则不同，即使字面相同
  /// 也是两条独立记录。
  Future<void> add(DecryptKeyEntry entry) async {
    _list.removeWhere((e) =>
        e.value == entry.value &&
        e.platform == entry.platform &&
        e.matchKey == entry.matchKey);
    _list.add(entry);
    await save();
  }

  /// 删除一条。匹配键也参与判重，避免误删同密钥的另一首匹配条目。
  Future<void> remove(String value, DecryptPlatform platform,
      {String? matchKey}) async {
    _list.removeWhere((e) =>
        e.value == value &&
        e.platform == platform &&
        (matchKey == null ? true : e.matchKey == matchKey));
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

  /// 从纯文本里导入密钥，每行一条。
  ///
  /// **分隔符与字段含义随平台而变**——因为各平台的匹配键根本不同：
  /// - QQ 音乐：`原始文件名,ekey`（或只有 `ekey`）
  /// - 酷狗：`audioHash,ekey`（或只有 `ekey`）
  /// - 酷我：`资源ID-音质,ekey`（或只有 `ekey`）
  /// - 蜻蜓：只有 `设备密钥hex`，没有匹配键
  ///
  /// 空行与以 `#` 开头的注释会被跳过。
  ///
  /// [platform] 由调用方指定——同一段文本对不同平台的含义完全不同，
  /// 不做自动猜测（密钥串本身看不出属于哪个平台）。
  ///
  /// **导入后立即落盘**（fix4）：此前只改内存不 save，用户从密钥页返回
  /// 或重启 App 后 `load()` 读到旧数据，导入的密钥全部消失——
  /// 即「导入密钥后解密失败」的直接根因。
  Future<int> importText(
    String text, {
    required DecryptPlatform platform,
    KeySource source = KeySource.importedText,
  }) async {
    var count = 0;
    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final parts = line.split(',').map((s) => s.trim()).toList();
      final entry = switch (parts.length) {
        >= 2 => _entryFromMatchKey(parts[0], parts.sublist(1).join(','),
            platform, source),
        _ => DecryptKeyEntry(value: parts[0], platform: platform, source: source),
      };
      _list.add(entry);
      count++;
    }
    _dedup();
    await save();
    return count;
  }

  /// 把「匹配键,ekey」这一行解析成对应平台的条目。
  ///
  /// 不同平台的匹配键写法不一样，不能一律当成 mid：
  /// - 酷我的是 `rid-quality`，要拆成两个数字字段；
  /// - QQ 的是原始文件名，酷狗的是 audioHash，都是整体字符串。
  static DecryptKeyEntry _entryFromMatchKey(
      String matchKey, String ekey, DecryptPlatform platform, KeySource src) {
    if (platform == DecryptPlatform.kuwo) {
      // `12345-128`：拆成资源 id 与音质。拆不开就整体当文件名存，
      // 至少不会丢数据，用户还能在界面上看到。
      final m = RegExp(r'^(\d+)-(\d+)$').firstMatch(matchKey);
      if (m != null) {
        return DecryptKeyEntry(
          value: ekey,
          platform: platform,
          resourceId: int.parse(m.group(1)!),
          qualityId: int.parse(m.group(2)!),
          source: src,
        );
      }
    }
    return switch (platform) {
      DecryptPlatform.qqMusic => DecryptKeyEntry(
          value: ekey, platform: platform, mediaFilename: matchKey, source: src),
      DecryptPlatform.kugou => DecryptKeyEntry(
          value: ekey, platform: platform, audioHash: matchKey, source: src),
      _ => DecryptKeyEntry(
          value: ekey, platform: platform, mediaFilename: matchKey, source: src),
    };
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

  /// 去重：**同平台 + 同密钥 + 同匹配键**只留一个。
  ///
  /// 去重键必须带匹配键（fix4）：两首歌完全可能共用同一把 ekey
  /// （同一个账号下载的同批歌曲），按「平台+密钥」去重会把第二首歌的
  /// 匹配条目悄悄吞掉，之后按文件名查表直接落空。
  /// 跨平台不合并——不同平台的密钥串即使字面相同也是两条独立记录。
  void _dedup() {
    final seen = <String>{};
    _list.removeWhere(
        (e) => !seen.add('${e.platform.name}\u0000${e.value}\u0000${e.matchKey ?? ''}'));
  }
}
