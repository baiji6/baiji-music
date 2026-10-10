/// 解密密钥库。
///
/// 密钥有两个来源：
/// - **导入**：用户把客户端数据库（QQ 的 MMKV /酷狗的 `music.db` / 酷我的
///   配置库）或导出的 ekey 文本丢进来，本类负责扫出来；
/// - **手动填写**：用户直接粘贴 ekey / fileKey。
///
/// 密钥以 JSON 存在 shared_preferences 里，不进日志、不上传。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 密钥条目。**[value] 才是真正能喂给算法的密钥**，其余字段只用于检索。
class DecryptKeyEntry {
  const DecryptKeyEntry({
    required this.value,
    this.mid,
    this.mediaFilename,
    this.qualityId,
    this.source = KeySource.manual,
  });

  /// ekey（QMC / KGM v5 / KWM v2）或 fileKey（咪咕）。
  final String value;

  /// `file.media_mid`，QMC STag / MusicEx 用它检索。
  final String? mid;

  /// `file.media_mid` + 扩展名，MusicEx 用。
  final String? mediaFilename;

  /// 音质 id，酷我用（`Header::get_quality_id`）。
  final int? qualityId;

  final KeySource source;

  Map<String, dynamic> toJson() => {
        'v': value,
        if (mid != null) 'mid': mid,
        if (mediaFilename != null) 'file': mediaFilename,
        if (qualityId != null) 'q': qualityId,
        's': source.name,
      };

  static DecryptKeyEntry fromJson(Map<String, dynamic> j) => DecryptKeyEntry(
        value: (j['v'] as String?) ?? '',
        mid: j['mid'] as String?,
        mediaFilename: j['file'] as String?,
        qualityId: j['q'] as int?,
        source: KeySource.values.firstWhere(
          (s) => s.name == j['s'],
          orElse: () => KeySource.manual,
        ),
      );
}

/// 密钥来源。
enum KeySource { manual, importedMmkv, importedDatabase, importedText }

/// 密钥仓库。
class DecryptKeys {
  DecryptKeys._(this._list);

  final List<DecryptKeyEntry> _list;

  static const String _prefsKey = 'baiji.decrypt.keys.v1';

  /// 读出全部密钥。
  static Future<DecryptKeys> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return DecryptKeys._([]);
    try {
      final list = (json.decode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(DecryptKeyEntry.fromJson)
          .where((e) => e.value.isNotEmpty)
          .toList();
      return DecryptKeys._(list);
    } catch (_) {
      // 数据结构损坏时宁可返回空库，也不要让用户进不去页面
      return DecryptKeys._([]);
    }
  }

  /// 写回存储。
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode(_list.map((e) => e.toJson()).toList()));
  }

  List<DecryptKeyEntry> get entries => List.unmodifiable(_list);
  int get length => _list.length;
  bool get isEmpty => _list.isEmpty;
  bool get isNotEmpty => _list.isNotEmpty;

  /// 按 mid 精确查找。
  String? lookupByMid(String mid) {
    for (final e in _list) {
      if (e.mid == mid) return e.value;
    }
    return null;
  }

  /// 按原始文件名查找。
  String? lookupByMediaFilename(String name) {
    for (final e in _list) {
      if (e.mediaFilename == name) return e.value;
    }
    return null;
  }

  /// 按音质 id 查找（酷我 v2 用）。
  String? lookupByQualityId(int q) {
    for (final e in _list) {
      if (e.qualityId == q) return e.value;
    }
    return null;
  }

  /// 兜底：返回库里第一个可用密钥。
  ///
  /// 仅在「同平台、只下了这一首歌」这类场景有效，所以调用方应优先用
  /// mid / filename 精确查。
  String? get anyEkey => _list.isEmpty ? null : _list.first.value;

  /// 添加一条，value 相同则覆盖。
  Future<void> add(DecryptKeyEntry entry) async {
    _list.removeWhere((e) => e.value == entry.value);
    _list.add(entry);
    await save();
  }

  Future<void> remove(String value) async {
    _list.removeWhere((e) => e.value == value);
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
  int importText(String text, {KeySource source = KeySource.importedText}) {
    var count = 0;
    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final parts = line.split(',').map((s) => s.trim()).toList();
      if (parts.length >= 3) {
        _list.add(DecryptKeyEntry(
          value: parts.sublist(2).join(','),
          mid: parts[0],
          mediaFilename: parts[1],
          source: source,
        ));
      } else if (parts.length == 2) {
        _list.add(DecryptKeyEntry(
          value: parts[1],
          mid: parts[0],
          source: source,
        ));
      } else {
        _list.add(DecryptKeyEntry(value: parts[0], source: source));
      }
      count++;
    }
    _dedup();
    return count;
  }

  /// 从客户端数据库的字节流里扫密钥。
  ///
  /// [scan] 由各平台的扫描器提供（QQ/酷狗/酷我各自的存储格式不同），
  /// 这里只负责去重与落盘。
  Future<int> importEntries(List<DecryptKeyEntry> found) async {
    _list.addAll(found);
    _dedup();
    await save();
    return found.length;
  }

  void _dedup() {
    final seen = <String>{};
    _list.removeWhere((e) => !seen.add(e.value));
  }
}
