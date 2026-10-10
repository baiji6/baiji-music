/// QQ 音乐文件尾footer 解析。
///
/// 移植自 `um_crypto/qmc/src/footer/`。QQ 音乐在音频文件**末尾**追加了一段
/// 元数据，里面带 ekey（真正的音频密钥）或 media mid，用于向服务器换密钥。
///
/// 四种变体（对应上游 `Data` 枚举），按顺序尝试匹配：
/// | 变体 | 客户端 | 尾部 magic | 是否含 ekey |
/// |---|---|---|---|
/// | STag | Android | `STag` | 否（只有 mid，需自行查库换 ekey） |
/// | QTag | Android | `QTag` | 是 |
/// | MusicEx | PC v2 | `musicex\0` | 否（同上） |
/// | Legacy | PC v1 | 无 magic，长度前缀 | 是 |
library;

import 'dart:convert';
import 'dart:typed_data';

/// PC v1 footer 里ekey 载荷的合理上限，超过就认为不是 v1 footer。
const int _maxAllowedEkeyLen = 0x500;

/// 初始探测长度。
const int initialDetectionLen = 1024;

/// footer 类型。
enum QmcFooterType {
  /// PC v1（Legacy），自带 ekey。
  pcV1Legacy,

  /// PC v2（MusicEx），只有 mid 与原始文件名。
  pcV2MusicEx,

  /// Android QTag，自带 ekey + 数字 resource id。
  androidQTag,

  /// Android STag，只有 mid + 数字 resource id。
  androidSTag,
}

/// footer 解析结果。
class QmcFooter {
  const QmcFooter({
    required this.type,
    required this.size,
    this.ekey,
    this.resourceId,
    this.mediaMid,
    this.mediaFilename,
  });

  final QmcFooterType type;

  /// 需要从文件末尾裁掉的字节数。
  final int size;

  /// 内嵌的 ekey（**未解密**，需 [qmcEkeyDecrypt]）。
  final String? ekey;

  /// 数字资源 id（QTag / STag）。
  final int? resourceId;

  /// `file.media_mid`（STag / MusicEx）。
  final String? mediaMid;

  /// 实际文件名，如 `F0M000112233445566.mflac`（MusicEx），换 ekey 时用。
  final String? mediaFilename;

  @override
  String toString() => 'QmcFooter(${type.name}, size: $size, ekey: ${ekey != null}, '
      'mid: $mediaMid, file: $mediaFilename)';
}

int _u32le(Uint8List b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

int _u32be(Uint8List b, int off) =>
    (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];

bool _isBase64(String s) {
  for (final c in s.codeUnits) {
    final ok = (c >= 0x30 && c <= 0x39) || //0-9
        (c >= 0x41 && c <= 0x5A) || // A-Z
        (c >= 0x61 && c <= 0x7A) || // a-z
        c == 0x2B || // +
        c == 0x2F || // /
        c == 0x3D; // =
    if (!ok) return false;
  }
  return true;
}

/// 把 ASCII 范围内的 UTF-16LE 转成UTF-8 字符串。
String _fromAsciiUtf16(Uint8List data, int off, int byteLen) {
  final out = StringBuffer();
  for (var i = 0; i + 1 < byteLen; i += 2) {
    final lo = data[off + i];
    final hi = data[off + i + 1];
    if (lo == 0 || hi != 0 || lo > 0x7F) break;
    out.writeCharCode(lo);
  }
  return out.toString();
}

/// 解析 footer。返回 null 表示不是任何一种已知变体。
///
/// 解析顺序与上游一致（STag → QTag → MusicEx → Legacy）：
/// 带magic 的变体必须严格匹配尾部 magic，Legacy 没有 magic，靠
/// 「尾部 4 字节长度 + 载荷全是 base64 字符」来识别，所以放在最后试。
QmcFooter? parseQmcFooter(Uint8List buffer) {
  return _parseSTag(buffer) ??
      _parseQTag(buffer) ??
      _parseMusicEx(buffer) ??
      _parseLegacy(buffer);
}

bool _hasSuffix(Uint8List b, List<int> suffix) {
  if (b.length < suffix.length) return false;
  final start = b.length - suffix.length;
  for (var i = 0; i < suffix.length; i++) {
    if (b[start + i] != suffix[i]) return false;
  }
  return true;
}

const List<int> _suffixSTag = [0x53, 0x54, 0x61, 0x67]; // "STag"
const List<int> _suffixQTag = [0x51, 0x54, 0x61, 0x67]; // "QTag"
const List<int> _suffixMusicex = [
  0x6D, 0x75, 0x73, 0x69, 0x63, 0x65, 0x78, 0x00, //
];

/// 尾部 `STag`：CSV 为 `id,version,media_mid`，长度前缀是**大端** u32。
///
/// 布局：`... CSV | len(BE u32) | "STag"`——长度字段在 magic **之前** 4 字节。
QmcFooter? _parseSTag(Uint8List buffer) {
  if (buffer.length < 8 || !_hasSuffix(buffer, _suffixSTag)) return null;
  final lenOff = buffer.length - 8;
  final payloadLen = _u32be(buffer, lenOff);
  if (payloadLen > buffer.length - 8) {
    throw const FormatException('STag: 载荷长度超出文件范围');
  }
  final payload = utf8.decode(buffer.sublist(lenOff - payloadLen, lenOff),
      allowMalformed: true);
  final parts = payload.split(',');
  if (parts.length != 3) {
    throw FormatException('STag: CSV 字段数异常 -> $payload');
  }
  if (parts[1] != '2') {
    throw FormatException('STag: 版本不支持 -> ${parts[1]}');
  }
  final id = int.tryParse(parts[0]);
  if (id == null) {
    throw FormatException('STag: 非法 id -> ${parts[0]}');
  }
  return QmcFooter(
    type: QmcFooterType.androidSTag,
    size: payloadLen + 8,
    resourceId: id,
    mediaMid: parts[2],
  );
}

/// 尾部 `QTag`：CSV 为 `ekey,resource_id,version`，长度前缀是**大端** u32。
QmcFooter? _parseQTag(Uint8List buffer) {
  if (buffer.length < 8 || !_hasSuffix(buffer, _suffixQTag)) return null;
  final lenOff = buffer.length - 8;
  final payloadLen = _u32be(buffer, lenOff);
  if (payloadLen > buffer.length - 8) {
    throw const FormatException('QTag: 载荷长度超出文件范围');
  }
  final payload = utf8.decode(buffer.sublist(lenOff - payloadLen, lenOff),
      allowMalformed: true);
  final parts = payload.split(',');
  if (parts.length != 3) {
    throw FormatException('QTag: CSV 字段数异常 -> $payload');
  }
  if (parts[2] != '2') {
    throw FormatException('QTag: 版本不支持 -> ${parts[2]}');
  }
  final id = int.tryParse(parts[1]);
  if (id == null) {
    throw FormatException('QTag: 非法 id -> ${parts[1]}');
  }
  if (!_isBase64(parts[0])) {
    throw FormatException('QTag: 非法 ekey -> ${parts[0]}');
  }
  return QmcFooter(
    type: QmcFooterType.androidQTag,
    size: payloadLen + 8,
    ekey: parts[0],
    resourceId: id,
  );
}

/// 尾部 `musicex\0`，再往里依次是版本号与长度（均为小端 u32）。
///
/// 布局：`... body | 0xC0 | version=1 | "musicex\0"`
QmcFooter? _parseMusicEx(Uint8List buffer) {
  if (buffer.length < 16 || !_hasSuffix(buffer, _suffixMusicex)) return null;
  final verOff = buffer.length - 12; // magic(8) 之前的 4 字节
  final version = _u32le(buffer, verOff);
  if (version != 1) {
    throw FormatException('MusicEx: 不支持的版本 $version');
  }
  final lenOff = verOff - 4;
  final payloadLen = _u32le(buffer, lenOff);
  if (payloadLen != 0xC0) {
    throw FormatException('MusicEx: 不支持的载荷长度 $payloadLen');
  }
  // 载荷本体从 lenOff往前 0xC0 - 0x10 字节（末尾 0x10 是上面两个 u32 + magic）
  final bodyStart = lenOff - (payloadLen - 0x10);
  if (bodyStart < 0) {
    throw const FormatException('MusicEx: 载荷越界');
  }
  // body 布局: u32 x3 | mid[60] | filename[100] | u32
  final mid = _fromAsciiUtf16(buffer, bodyStart + 12, 60);
  final filename = _fromAsciiUtf16(buffer, bodyStart + 12 + 60, 100);
  return QmcFooter(
    type: QmcFooterType.pcV2MusicEx,
    size: payloadLen,
    mediaMid: mid,
    mediaFilename: filename,
  );
}

/// PC v1（Legacy）：尾部 4 字节小端长度 + 以 0 结尾的 base64 ekey。
QmcFooter? _parseLegacy(Uint8List buffer) {
  if (buffer.length < 8) return null;
  final payloadLen = _u32le(buffer, buffer.length - 4);
  if (payloadLen > _maxAllowedEkeyLen) return null;
  if (buffer.length - 4 < payloadLen) return null;

  final raw = buffer.sublist(buffer.length - 4 - payloadLen, buffer.length - 4);
  final zero = raw.indexOf(0);
  final ekeyBytes = zero >= 0 ? raw.sublist(0, zero) : raw;
  String ekey;
  try {
    ekey = utf8.decode(ekeyBytes);
  } catch (_) {
    return null;
  }
  if (ekey.isEmpty || !_isBase64(ekey)) return null;

  return QmcFooter(
    type: QmcFooterType.pcV1Legacy,
    size: payloadLen + 4,
    ekey: ekey,
  );
}
