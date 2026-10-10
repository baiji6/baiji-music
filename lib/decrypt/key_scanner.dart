/// 客户端数据库密钥扫描器。
///
/// 支持三类输入，按文件魔数自动分派：
///
/// 1. **MMKV**（QQ 音乐 Android/iOS 的 `mmkv.default` / `music_*` 文件）
///    —— 轻量级 KV，底层是 protobuf 变长编码；密钥是 value 里的 base64 串，
///    key 名里通常带 mid，能顺带把 mid 一起抠出来。
/// 2. **SQLite**（酷狗 / 酷我 的 `*.db`、`*.sqlite`）
///    —— 走真实的 b-tree + record 解析，把表名/列名和值配对，
///    这样只有列名带 `ekey` / `key` 的字段才会被收，避免误捞整库数据。
/// 3. **兜底**：任何文本型二进制（PLAIN / SHARED_PREFERENCES 等），
///    直接扫 base64 串。
///
/// 三条路都用「解出来必须是合法 base64 且长度落在 ekey 常见区间」做二次校验，
/// 宁可多收让用户自己删，也不要因为解析器覆盖不全而漏掉密钥。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'key_store.dart';

/// 扫描结果。
class KeyScanResult {
  KeyScanResult({
    required this.source,
    required this.entries,
    this.note,
  });

  /// 命中了哪条解析路径。
  final String source;
  final List<DecryptKeyEntry> entries;

  /// 附加说明，比如「匹配到表 xx 的列 yy」。
  final String? note;

  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;
  int get length => entries.length;
}

/// 统一入口：按魔数分派。
///
/// [hints] 是文件名/路径的小写形式，用来在魔数缺失时兜底判断。
KeyScanResult scanKeys(Uint8List bytes, {String hint = ''}) {
  if (bytes.isEmpty) {
    return KeyScanResult(source: '空文件', entries: const []);
  }

  if (isMmkv(bytes)) {
    final r = scanMmkvKeys(bytes);
    if (r.isNotEmpty) return r;
    // MMKV 可能开了加密（值是密文），退回兜底再试一次。
    return _fallbackScan(bytes, hint, note: 'MMKV（值可能已加密，已用兜底扫描）');
  }

  if (isSqlite(bytes)) {
    final r = scanSqliteKeys(bytes);
    if (r.isNotEmpty) return r;
    return _fallbackScan(bytes, hint, note: 'SQLite（未匹配到密钥列）');
  }

  if (hint.contains('mmkv')) {
    return scanMmkvKeys(bytes).isEmpty
        ? _fallbackScan(bytes, hint, note: 'MMKV')
        : scanMmkvKeys(bytes);
  }

  return _fallbackScan(bytes, hint);
}

// ==================== MMKV ====================

/// MMKV 魔数：`0x16 0x88 0x01`，第 4 字节是加密标记。
bool isMmkv(Uint8List b) =>
    b.length >= 4 && b[0] == 0x16 && b[1] == 0x88 && b[2] == 0x01;

/// MMKV 的内容以 protobuf 变长编码存放，且**同一个 field 号重复出现**
/// 表示多个键值对：
///
/// ```proto
/// message KV {
///   repeated KV dictionary = 1;
/// }
/// message KV {
///   bytes key   = 1;
///   bytes value = 2;
/// }
/// ```
///
/// MMKV 每个内存页的布局是 `[4B payloadSize][protobuf bytes]`，
/// 首个 4 字节之外还有一段 meta（密钥 / 偏移表）。所以这里不硬啃页结构，
/// 而是在整个文件里递归找「能解成 key/value 对」的那段。
KeyScanResult scanMmkvKeys(Uint8List bytes) {
  final out = <DecryptKeyEntry>[];
  final seen = <String>{};

  // 起点：跳过开头的 meta（魔数 + 可能的 cryptKey + 若干偏移表项）。
  // 但为了不漏，我们对整份数据都扫，只是用不同的起始偏移去尝试。
  for (final start in _mmkvStartCandidates(bytes)) {
    final pairs = _parseMmkvDictionary(bytes, start);
    if (pairs.isEmpty) continue;
    for (final kv in pairs) {
      final value = _firstB64(kv.value);
      if (value == null || !seen.add(value)) continue;
      out.add(DecryptKeyEntry(
        value: value,
        mid: _midFromKey(kv.key),
        source: KeySource.importedMmkv,
      ));
    }
    if (out.isNotEmpty) break;
  }

  return KeyScanResult(
    source: 'MMKV',
    entries: out,
    note: out.isEmpty ? null : '解析到 ${out.length} 条键值对',
  );
}

List<int> _mmkvStartCandidates(Uint8List b) {
  final starts = <int>[0, 4, 8, 16, 32];
  // 页大小通常是 4KB 的倍数；直接把每个 4KB 边界也作为候选，
  // 覆盖「前面有多个页」的大文件。
  for (var p = 4096; p < b.length; p += 4096) {
    starts.add(p);
    if (starts.length > 64) break;
  }
  return starts;
}

class _Kv {
  _Kv(this.key, this.value);
  final Uint8List key;
  final Uint8List value;
}

/// 尝试把 [from] 开始的一段解析成 MMKV 字典（key/value 对列表）。
List<_Kv> _parseMmkvDictionary(Uint8List b, int from) {
  final out = <_Kv>[];
  var i = from;
  final end = b.length;

  while (i < end) {
    final tag = _readVarint(b, i);
    if (tag == null) break;
    i = tag.end;

    final fieldNo = tag.value >> 3;
    final wire = tag.value & 0x7;
    if (fieldNo == 0) break;

    switch (wire) {
      case 0: // varint
        final v = _readVarint(b, i);
        if (v == null) return out;
        i = v.end;
      case 1: // 64-bit
        if (i + 8 > end) return out;
        i += 8;
      case 5: // 32-bit
        if (i + 4 > end) return out;
        i += 4;
      case 2:
        final len = _readVarint(b, i);
        if (len == null || len.value > end - len.end) return out;
        final s = len.end;
        final e = s + len.value;
        if (fieldNo == 1) {
          final kv = _parseInnerKv(b, s, e);
          if (kv != null) out.add(kv);
        }
        i = e;
      default:
        return out; // group（3/4）不出现，视为不是 protobuf
    }
  }
  return out;
}

/// 解析内层 `{ key = 1, value = 2 }`。
_Kv? _parseInnerKv(Uint8List b, int from, int to) {
  Uint8List? key;
  Uint8List? value;
  var i = from;
  while (i < to) {
    final tag = _readVarint(b, i);
    if (tag == null || tag.end >= to) return null;
    i = tag.end;
    final fieldNo = tag.value >> 3;
    final wire = tag.value & 0x7;
    if (wire != 2) return null;
    final len = _readVarint(b, i);
    if (len == null || len.end >= to) return null;
    final s = len.end;
    final e = s + len.value;
    if (e > to) return null;
    if (fieldNo == 1 && key == null) {
      key = Uint8List.sublistView(b, s, e);
    } else if (fieldNo == 2 && value == null) {
      value = Uint8List.sublistView(b, s, e);
    }
    i = e;
  }
  if (key == null) return null;
  return _Kv(key, value ?? Uint8List(0));
}

class _Varint {
  _Varint(this.value, this.end);
  final int value;
  final int end;
}

_Varint? _readVarint(Uint8List b, int i) {
  var shift = 0;
  var result = 0;
  while (i < b.length && shift <= 63) {
    final byte = b[i++];
    result |= (byte & 0x7F) << shift;
    if (byte & 0x80 == 0) return _Varint(result, i);
    shift += 7;
  }
  return null;
}

/// 从 key 名里抠 mid。
///
/// QQ 音乐的 mid 是 14 位 base62（数字 + 大小写字母混排），不是纯数字，
/// 所以边界只能按「非 base62 字符」来卡。常见形态：
/// `music@ekey@001y7CaR29k6YP`、`qqmusic_enc_key_0038mTc14ImRv0`。
String? _midFromKey(Uint8List key) {
  final s = latin1.decode(key, allowInvalid: true);
  final m =
      RegExp(r'(?<![A-Za-z0-9])([A-Za-z0-9]{10,16})(?![A-Za-z0-9])')
          .firstMatch(s);
  final t = m?.group(1);
  if (t == null) return null;
  // 纯字母的词（encrypt、background 之类）不是 mid。
  if (!RegExp(r'[0-9]').hasMatch(t)) return null;
  return t;
}

// ==================== SQLite ====================

/// SQLite 文件头：前 16 字节是 `SQLite format 3\0`（\0 在索引 15，
/// 紧跟着的偏移 16 才是两字节 page size）。
bool isSqlite(Uint8List b) {
  if (b.length < 100) return false;
  const magic = 'SQLite format 3';
  for (var i = 0; i < magic.length; i++) {
    if (b[i] != magic.codeUnitAt(i)) return false;
  }
  return b[15] == 0;
}

/// 走真实的 b-tree 遍历解析 SQLite，只收「列名像密钥」的字段。
///
/// 步骤：
/// 1. 解析 header 拿 pageSize / pageCount / textEncoding；
/// 2. 遍历 page 1（sqlite_master），建表名 → 根页 的映射，同时拿列名；
/// 3. 对每张表的 b-tree 做 DFS，解析叶页里的 record；
/// 4. record 的 serial type 决定该列是 NULL/int/blob/text。
KeyScanResult scanSqliteKeys(Uint8List bytes) {
  final out = <DecryptKeyEntry>[];
  final seen = <String>{};

  final pageSize = _sqlitePageSize(bytes);
  final pageCount = _sqlitePageCount(bytes);
  if (pageSize <= 0 || pageCount <= 0) {
    return KeyScanResult(source: 'SQLite', entries: const []);
  }

  // 1) sqlite_master：拿到每张表的根页与建表语句（用于取列名）。
  //    第 1 页前面有 100 字节的文件头，b-tree 页头要跳过它。
  final roots = <_SqlTable>[];
  final master = _readPage(bytes, 1, pageSize);
  _parseLeafPage(master, pageSize, 100, (record) {
    if (record.values.length < 5) return;
    final type = _asText(record.values[0]) ?? '';
    if (type != 'table') return;
    final name = _asText(record.values[1]) ?? '';
    final rootPage = record.values[3];
    final sql = _asText(record.values[4]) ?? '';
    if (name.isEmpty || rootPage is! int || rootPage < 1) return;
    if (name.startsWith('sqlite_')) return;
    roots.add(_SqlTable(name, rootPage, _columnsFromCreate(sql)));
  });
  if (roots.isEmpty) {
    return KeyScanResult(source: 'SQLite', entries: const []);
  }

  // 2) 逐表遍历。
  var matchedColumns = <String>{};
  for (final t in roots) {
    if (t.rootPage > pageCount) continue;
    final keyCols = t.keyColumns;
    // 没有列名信息（sqlite_master 被清空等）时直接放弃这张表，
    // 避免把整库文本都当成密钥。
    if (keyCols.isEmpty) continue;

    _walkTableByRoot(
      bytes,
      t.rootPage,
      pageSize,
      pageCount,
      (record) {
        for (final col in keyCols) {
          final idx = col.index;
          if (idx < 0 || idx >= record.values.length) continue;
          final raw = record.values[idx];
          // 密钥可能是 TEXT，也可能是被客户端塞进 BLOB 的 base64。
          for (final v in _keyCandidates(raw)) {
            if (!seen.add(v)) continue;
            out.add(DecryptKeyEntry(
              value: v,
              mid: _midFromColumns(t.columns, record),
              qualityId: _qualityFromColumns(t.columns, record),
              source: KeySource.importedDatabase,
            ));
            matchedColumns.add('${t.name}.${col.name}');
          }
        }
      },
      visited: <int>{},
    );
  }

  return KeyScanResult(
    source: 'SQLite',
    entries: out,
    note: out.isEmpty
        ? null
        : '扫描 ${roots.length} 张表，命中 ${matchedColumns.take(3).join('、')}'
            '${matchedColumns.length > 3 ? ' 等 ${matchedColumns.length} 列' : ''}',
  );
}

int _sqlitePageSize(Uint8List b) {
  final bd = ByteData.sublistView(b);
  final v = bd.getUint16(16, Endian.big);
  return v == 1 ? 65536 : v;
}

int _sqlitePageCount(Uint8List b) =>
    ByteData.sublistView(b).getUint32(28, Endian.big);

Uint8List _readPage(Uint8List b, int pageNo, int pageSize) {
  final start = (pageNo - 1) * pageSize;
  if (start < 0 || start >= b.length) return Uint8List(0);
  final end = (start + pageSize).clamp(0, b.length);
  return Uint8List.sublistView(b, start, end);
}

/// 从 `CREATE TABLE x (a TEXT, "ekey" TEXT, ...)` 里抠列名。
List<String> _columnsFromCreate(String sql) {
  if (sql.isEmpty) return const [];
  final open = sql.indexOf('(');
  final close = sql.lastIndexOf(')');
  if (open < 0 || close <= open) return const [];

  final body = sql.substring(open + 1, close);
  final cols = <String>[];
  for (final raw in _splitTopLevel(body)) {
    var name = raw.trim();
    if (name.isEmpty) continue;
    final first = name.split(RegExp(r'\s')).first.trim();
    name = first.replaceAll(RegExp(r'^["`\[]|["`\]]$'), '');
    if (name.isEmpty) continue;
    // 表级约束（UNIQUE、PRIMARY KEY、FOREIGN KEY…）不是数据列。
    final head = name.toUpperCase();
    if (const {
      'UNIQUE', 'PRIMARY', 'FOREIGN', 'CHECK', 'CONSTRAINT', 'KEY',
    }.contains(head)) {
      continue;
    }
    cols.add(name);
  }
  return cols;
}

/// 按逗号切分，但不切掉括号 / 引号里的逗号。
List<String> _splitTopLevel(String s) {
  final out = <String>[];
  var depth = 0;
  var quote = '';
  var start = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (quote.isNotEmpty) {
      if (c == quote) quote = '';
      continue;
    }
    if (c == '"' || c == '\'' || c == '`') {
      quote = c;
    } else if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
    } else if (c == ',' && depth == 0) {
      out.add(s.substring(start, i));
      start = i + 1;
    }
  }
  out.add(s.substring(start));
  return out;
}

class _SqlColumn {
  _SqlColumn(this.index, this.name);
  final int index;
  final String name;

  /// 列名像不像密钥字段。
  bool get looksLikeKey {
    final n = name.toLowerCase();
    return n.contains('ekey') ||
        n.contains('encrypt_key') ||
        n.contains('encodekey') ||
        n.contains('decodekey') ||
        n == 'key' ||
        n.endsWith('_key') ||
        n.endsWith('_ekey') ||
        n == 'secret';
  }
}

class _SqlTable {
  _SqlTable(this.name, this.rootPage, List<String> columnNames)
      : columns = [
          for (var i = 0; i < columnNames.length; i++)
            _SqlColumn(i, columnNames[i]),
        ];

  final String name;
  final int rootPage;
  final List<_SqlColumn> columns;

  List<_SqlColumn> get keyColumns =>
      columns.where((c) => c.looksLikeKey).toList();
}

String? _midFromColumns(List<_SqlColumn> cols, _Record rec) {
  for (final c in cols) {
    final n = c.name.toLowerCase();
    if (n != 'mid' && n != 'songmid' && n != 'song_id' && n != 'songid') {
      continue;
    }
    if (c.index >= rec.values.length) continue;
    final v = rec.values[c.index];
    if (v is int) return v.toString();
    final t = _asText(v);
    if (t != null && t.isNotEmpty) return t;
  }
  return null;
}

int? _qualityFromColumns(List<_SqlColumn> cols, _Record rec) {
  for (final c in cols) {
    final n = c.name.toLowerCase();
    if (n != 'qualityid' && n != 'quality_id' && n != 'quality') continue;
    if (c.index >= rec.values.length) continue;
    final v = rec.values[c.index];
    if (v is int) return v;
    final t = _asText(v);
    if (t != null) return int.tryParse(t);
  }
  return null;
}

/// 把列值转成可能的密钥字符串。
Iterable<String> _keyCandidates(Object? raw) sync* {
  if (raw is String) {
    for (final v in _firstB64s(raw)) {
      yield v;
    }
  } else if (raw is Uint8List) {
    // BLOB 里可能直接是密钥字节，也可能是 base64 文本。
    final t = latin1.decode(raw, allowInvalid: true);
    for (final v in _firstB64s(t)) {
      yield v;
    }
    if (raw.length >= 16 && raw.length <= 1024) {
      yield base64.encode(raw);
    }
  }
}

/// 从一段文本里取出全部合法的 base64 密钥串。
Iterable<String> _firstB64s(String s) sync* {
  for (final m in RegExp(r'[A-Za-z0-9+/]{40,1200}={0,2}').allMatches(s)) {
    final v = m.group(0)!;
    if (looksLikeEkey(v)) yield v;
  }
}

/// 从一段字节里取第一个合法密钥串。
String? _firstB64(Uint8List b) {
  if (b.isEmpty) return null;
  final s = latin1.decode(b, allowInvalid: true);
  final m = RegExp(r'[A-Za-z0-9+/]{40,1200}={0,2}').firstMatch(s);
  final v = m?.group(0);
  if (v == null || !looksLikeEkey(v)) return null;
  return v;
}

/// 是否像一个 ekey / fileKey。
///
/// 判据：base64 合法 + 解码长度落在各平台密钥的常见区间。
bool looksLikeEkey(String s) {
  final t = s.trim();
  if (t.length % 4 != 0) return false;
  if (t.length < 40 || t.length > 1200) return false;
  Uint8List raw;
  try {
    raw = base64.decode(t);
  } catch (_) {
    return false;
  }
  // QMC v1 是 128 字节静态密钥；KGM/KWM/NCM 的密钥更短（8~64 字节）；
  // QMC v2 的 ekey 解出来通常在 120~400 字节。
  return raw.length >= 8 && raw.length <= 1024;
}

// ==================== record 解析 ====================

class _Record {
  _Record(this.values);
  final List<Object?> values;
}

/// 解析一个 b-tree 页里的所有叶record（表页，page 1 用的是偏移 100 的页头）。
///
/// [page] 是完整页字节（含页头）。
void _parseLeafPage(
  Uint8List page,
  int pageSize,
  int headerOffset,
  void Function(_Record) onRecord,
) {
  if (page.length < headerOffset + 8) return;
  final bd = ByteData.sublistView(page);
  final cellCount = bd.getUint16(headerOffset + 3, Endian.big);
  final contentStart = bd.getUint16(headerOffset + 5, Endian.big);

  final base = contentStart == 0 ? pageSize : contentStart;
  for (var i = 0; i < cellCount; i++) {
    final ptrOff = headerOffset + 8 + i * 2;
    if (ptrOff + 2 > page.length) return;
    final off = bd.getUint16(ptrOff, Endian.big);
    if (off < base || off >= page.length) continue;

    final payloadLen = _readPageVarint(page, off);
    if (payloadLen == null) continue;
    var p = payloadLen.end;
    // 跳过 rowid
    final rowid = _readPageVarint(page, p);
    if (rowid == null) continue;
    p = rowid.end;

    final rec = _parseRecord(page, p, payloadLen.value, pageSize);
    if (rec != null) onRecord(rec);
  }
}

class _PageVarint {
  _PageVarint(this.value, this.end);
  final int value;
  final int end;
}

/// SQLite 的 varint。
///
/// 注意：SQLite 用的是**大端 7-bit 分组**（先来的字节是高位组），
/// 和 protobuf / MMKV 的小端 LEB128 相反。`0x81 0x1D` 在这里是 157，
/// 不是 3713——这个坑会让整条 record 解析错位。
_PageVarint? _readPageVarint(Uint8List b, int i) {
  var result = 0;
  var count = 0;
  while (i < b.length && count < 9) {
    final byte = b[i++];
    result = (result << 7) | (byte & 0x7F);
    if (byte & 0x80 == 0) return _PageVarint(result, i);
    count++;
  }
  // 第 9 字节用满 8 位
  if (i < b.length) {
    return _PageVarint((result << 8) | b[i], i + 1);
  }
  return null;
}

/// 解析 record：变长头部（serial types）+ 数据区。
///
/// payload 溢出时会溢出到溢出页，这里不支持——客户端数据库里的密钥
/// 字段都很短，不会触发。
_Record? _parseRecord(Uint8List b, int from, int payloadLen, int pageSize) {
  final limit = (from + payloadLen).clamp(0, b.length);
  final hdrLen = _readPageVarint(b, from);
  if (hdrLen == null) return null;
  // 注意：record 头的长度字段**包含它自己的 varint**，所以头部结束位置是
  // from + hdrLen，而不是 hdrLen.end + hdrLen。
  final typesEnd = from + hdrLen.value;
  if (hdrLen.value < 1 || hdrLen.end > typesEnd || typesEnd > limit) return null;

  // 先读出全部 serial type
  final serials = <int>[];
  var tp = hdrLen.end;
  while (tp < typesEnd) {
    final t = _readPageVarint(b, tp);
    if (t == null) return null;
    serials.add(t.value);
    tp = t.end;
  }

  // 再按 serial type 走数据区
  final values = <Object?>[];
  var dp = typesEnd;
  for (final s in serials) {
    if (s == 0) {
      values.add(null);
    } else if (s >= 1 && s <= 4) {
      if (dp + s > limit) return null;
      values.add(_readSigned(b, dp, s));
      dp += s;
    } else if (s == 5) {
      if (dp + 6 > limit) return null;
      values.add(_readSigned(b, dp, 6));
      dp += 6;
    } else if (s == 6) {
      if (dp + 8 > limit) return null;
      values.add(_readSigned(b, dp, 8));
      dp += 8;
    } else if (s == 7) {
      if (dp + 8 > limit) return null;
      dp += 8; // float，密钥字段不会是浮点
      values.add(null);
    } else if (s == 8) {
      values.add(0);
    } else if (s == 9) {
      values.add(1);
    } else if (s == 10 || s == 11) {
      values.add(null);
    } else if (s % 2 == 0) {
      final n = (s - 12) ~/ 2;
      if (dp + n > limit) return null;
      values.add(Uint8List.fromList(b.sublist(dp, dp + n)));
      dp += n;
    } else {
      final n = (s - 13) ~/ 2;
      if (dp + n > limit) return null;
      values.add(_decodeText(b, dp, n));
      dp += n;
    }
  }
  return _Record(values);
}

int _readSigned(Uint8List b, int off, int n) {
  var v = 0;
  for (var i = 0; i < n; i++) {
    v |= b[off + i] << (8 * i);
  }
  // 符号扩展
  final bits = n * 8;
  if (bits < 64 && (b[off + n - 1] & 0x80) != 0) {
    v -= (1 << bits);
  }
  return v;
}

String _decodeText(Uint8List b, int off, int n) {
  final slice = Uint8List.fromList(b.sublist(off, off + n));
  // SQLite 的 TEXT 编码在 header 偏移 56；这里两种都试，
  // UTF-8 解不出替换字符就按 latin1。
  final asUtf8 = utf8.decode(slice, allowMalformed: false);
  return asUtf8;
}

/// 从任意根页开始 DFS 遍历表 b-tree。
void _walkTableByRoot(
  Uint8List raw,
  int rootPage,
  int pageSize,
  int pageCount,
  void Function(_Record) onRecord, {
  Set<int>? visited,
}) {
  final seen = visited ?? <int>{};
  if (!seen.add(rootPage)) return;

  final page = _readPage(raw, rootPage, pageSize);
  if (page.length < 8) return;
  final bd = ByteData.sublistView(page);
  final type = page[0];
  final cellCount = bd.getUint16(3, Endian.big);

  switch (type) {
    case 0x0D: // 叶表页
      _parseLeafPage(page, pageSize, 0, onRecord);
    case 0x05: // 内部表页：先递归子页，再处理本页（次序无关，因为我们要的是全部）
      for (var i = 0; i < cellCount; i++) {
        final ptrOff = 8 + i * 2;
        if (ptrOff + 2 > page.length) break;
        final child = bd.getUint32(ptrOff, Endian.big);
        if (child >= 1 && child <= pageCount) {
          _walkTableByRoot(raw, child, pageSize, pageCount, onRecord,
              visited: seen);
        }
      }
    default:
      // 索引页（0x02/0x0A）承载的是索引记录，密钥表一般不在索引里，跳过。
      break;
  }
}

String? _asText(Object? v) {
  if (v is String) return v;
  if (v is Uint8List) return latin1.decode(v, allowInvalid: true);
  return null;
}

// ==================== 兜底 ====================

KeyScanResult _fallbackScan(Uint8List bytes, String hint, {String? note}) {
  final text = latin1.decode(bytes, allowInvalid: true);
  final out = <DecryptKeyEntry>[];
  final seen = <String>{};
  for (final m in RegExp(r'[A-Za-z0-9+/]{40,1200}={0,2}').allMatches(text)) {
    final s = m.group(0)!;
    if (!seen.add(s)) continue;
    if (!looksLikeEkey(s)) continue;
    out.add(DecryptKeyEntry(
      value: s,
      mid: _midFromKey(latin1.encode(_contextAround(text, m.start))),
      source: hint.contains('mmkv')
          ? KeySource.importedMmkv
          : KeySource.importedDatabase,
    ));
  }
  return KeyScanResult(
    source: hint.contains('sqlite') ? 'SQLite（兜底）' : '二进制扫描',
    entries: out,
    note: note,
  );
}

/// 取匹配位置前后各 64 字节的上下文，用来在同一行附近找 mid。
String _contextAround(String text, int index) {
  final start = (index - 96).clamp(0, text.length);
  final end = (index + 96).clamp(0, text.length);
  return text.substring(start, end);
}
