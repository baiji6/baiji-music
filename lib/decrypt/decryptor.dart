/// 本地音乐解密的总调度层。
///
/// 职责：
/// 1. 嗅探文件格式（QQ QMC /酷狗 KGM / 酷我 KWM / 网易云 NCM / 咪咕 3D）；
/// 2. 补齐所需密钥（用户导入的密钥库里查，查不到就报「需要密钥」）；
/// 3. 流式解密并写出到目标文件，同时把封面等副产品落盘。
///
///## 密钥从哪来
///
/// QMC / KGM v5 / KWM v2 都用 ekey。它们的来源分两类：
/// - 文件尾部自带（QMC 的 QTag / PC v1）—— 直接读；
/// - 文件尾只有 mid（QMC 的 STag / MusicEx）—— 必须查客户端数据库；
/// - 什么都没有（KGM v5 / KWM v2）—— 必须查客户端数据库。
///
/// 所以 [DecryptKeys] 同时支持「按 mid 查」与「按音质查」两种索引，
/// 见 `key_store.dart`。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'kgm.dart';
import 'kwm.dart';
import 'migu.dart';
import 'ncm.dart';
import 'qmc.dart';
import 'qmc_ekey.dart';
import 'audio_detect.dart';
import 'qingting.dart';
import 'qmc_footer.dart';

import 'key_store.dart';

/// 支持的音乐平台。
enum DecryptPlatform {
  /// QQ 音乐（.qmcflac / .mflac / .flac）
  qqMusic('QQ 音乐', ['.qmcflac', '.mflac']),

  /// 酷狗（.kgm / .vpr）
  kugou('酷狗音乐', ['.kgm', '.vpr']),

  /// 酷我（.kwm）
  kuwo('酷我音乐', ['.kwm']),

  /// 网易云（.ncm）
  netease('网易云音乐', ['.ncm']),

  /// 咪咕（.3D / .3DA / .m4a 等）
  migu('咪咕音乐', ['.3d', '.3da', '.m4a', '.mp3', '.mp4', '.aac', '.flac']),

  /// 蜻蜓 FM（.qta），文件名形如 `.p!<base64>.qta`
  qingting('蜻蜓 FM', ['.qta']);

  const DecryptPlatform(this.label, this.extensions);

  final String label;
  final List<String> extensions;

  /// 这个平台的密钥填法是不是「hex device key」而不是 ekey。
  ///
  /// 蜻蜓 FM 要的是 16 字节 device key 的**十六进制**（32 个字符），
  /// 不是 base64 的 ekey。
  bool get keyIsHex => this == DecryptPlatform.qingting;

  /// 这个平台是否必须由用户提供密钥。
  ///
  /// 网易云的密钥在文件头里、咪咕能自己猜，所以不需要。
  bool get needsKey =>
      this == DecryptPlatform.kugou ||
      this == DecryptPlatform.kuwo ||
      this == DecryptPlatform.qingting;
}

/// 嗅探出的文件信息。
class SniffResult {
  const SniffResult({
    required this.platform,
    this.footer,
    this.kgmHeader,
    this.kwmHeader,
    this.ncmHeader,
    this.miguKey,
    this.audioDataOffset = 0,
  });

  final DecryptPlatform platform;

  /// QQ 音乐 footer（含 ekey / mid）。
  final QmcFooter? footer;

  final KgmHeader? kgmHeader;
  final KwmHeader? kwmHeader;
  final NcmHeader? ncmHeader;

  /// 咪咕猜出的 32 字节密钥。
  final Uint8List? miguKey;

  /// 音频数据在文件中的起始偏移。
  final int audioDataOffset;

  /// 是否还需要 ekey / fileKey 才能解。
  bool get needsEkey =>
      platform == DecryptPlatform.kugou
          ? kgmHeader?.cryptoVersion == 5
          : platform == DecryptPlatform.kuwo
              ? kwmHeader?.version == 2
              : platform == DecryptPlatform.qqMusic &&
                  footer?.ekey == null;
}

/// 解密结果。
class DecryptResult {
  const DecryptResult({
    required this.outputPath,
    required this.platform,
    required this.bytesWritten,
    this.coverPath,
    this.metadata,
    this.audioFormat = 'bin',
  });

  final String outputPath;
  final DecryptPlatform platform;
  final int bytesWritten;

  /// 内嵌封面已保存到此路径。
  final String? coverPath;

  /// 网易云的 metadata JSON。
  final String? metadata;

  /// 实际探测到的产物音频格式（`bin` = 没通过校验）。
  ///
  /// 对应上游 `detectAudioExtension` 的返回值。
  final String audioFormat;

  /// 产物是否通过了「像音频」的校验。
  bool get verified => audioFormat != 'bin';
}

/// 解密异常，携带一个用户可读的 [message]。
class DecryptFailure implements Exception {
  const DecryptFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 嗅探文件格式。需要 [head] 为文件**头部**（QQ 音乐还需尾部，见 [sniffWithFooter]）。
SniffResult sniff(Uint8List head) {
  if (isNcmFile(head)) {
    return SniffResult(
      platform: DecryptPlatform.netease,
      ncmHeader: parseNcmHeader(head),
      audioDataOffset: parseNcmHeader(head).audioDataOffset,
    );
  }

  // 酷狗 / 酷我靠 magic 精确匹配，可以放心直接试
  try {
    final h = parseKgmHeader(head);
    return SniffResult(
      platform: DecryptPlatform.kugou,
      kgmHeader: h,
      audioDataOffset: h.dataOffset,
    );
  } catch (_) {/*不是 KGM */}

  try {
    final h = parseKwmHeader(head);
    return SniffResult(
      platform: DecryptPlatform.kuwo,
      kwmHeader: h,
      audioDataOffset: kwmDataStartOffset,
    );
  } catch (_) {/* 不是 KWM */}

  final miguKey = guessMiguKey(head);
  if (miguKey != null) {
    return SniffResult(
      platform: DecryptPlatform.migu,
      miguKey: miguKey,
      audioDataOffset: miguDataStartOffset,
    );
  }

  return SniffResult(platform: DecryptPlatform.qqMusic);
}

/// 嗅探 QQ 音乐文件（同时看尾部的 footer）。
SniffResult sniffQmc(Uint8List head, Uint8List tail) {
  final footer = parseQmcFooter(tail);
  return SniffResult(
    platform: DecryptPlatform.qqMusic,
    footer: footer,
    audioDataOffset: 0,
  );
}

/// 从密钥库里按 sniff 结果查找所需密钥。
///
/// **所有查找都限定在 [SniffResult.platform] 对应的平台内**——
/// 五个平台的密钥规则互不相通，跨平台取密钥只会解出噪声。
///
/// 优先级：文件自带 ekey → footer 里的 mid → footer 文件名 → 同平台兜底。
String? resolveEkey(SniffResult sniff, DecryptKeys keys) {
  final embedded = sniff.footer?.ekey;
  if (embedded != null && embedded.isNotEmpty) return embedded;

  final p = sniff.platform;

  final mid = sniff.footer?.mediaMid;
  if (mid != null && mid.isNotEmpty) {
    final byMid = keys.lookupByMid(mid, p);
    if (byMid != null) return byMid;
  }

  final fileName = sniff.footer?.mediaFilename;
  if (fileName != null && fileName.isNotEmpty) {
    final byFile = keys.lookupByMediaFilename(fileName, p);
    if (byFile != null) return byFile;
  }

  return keys.anyEkeyOf(p);
}

/// 单个文件的解密入口。**必须在 Isolate 里跑**（CPU 密集）。
///
/// [head] 是文件头部（至少 0x1000 字节），[tail] 是文件尾部
/// （至少 1024 字节；QQ 音乐必需，其余格式可为 null）。
///
/// [keyResolver] 在 Isolate 内被调用，因此必须是纯计算/查表的闭包
/// （不能捕获不可发送的对象）——这里约定它只接收字符串。
Future<DecryptResult> decryptFile({
  required String inputPath,
  required String outputPath,
  required Uint8List head,
  Uint8List? tail,
  DecryptKeys? keys,
  String? Function()? keyResolver,
  Map<String, String>? platformKeys,
}) async {
  final file = File(inputPath);
  final totalLen = await file.length();

  final result = _decryptRange(
    file: file,
    totalLen: totalLen,
    outputPath: outputPath,
    head: head,
    tail: tail,
    keys: keys,
    ekeyOverride: keyResolver?.call(),
    platformKeys: platformKeys,
  );
  return result;
}

DecryptResult _decryptRange({
  required File file,
  required int totalLen,
  required String outputPath,
  required Uint8List head,
  Uint8List? tail,
  required DecryptKeys? keys,
  required String? ekeyOverride,
  Map<String, String>? platformKeys,
}) {
  // 先嗅探出平台，才能按平台挑密钥——**绝不能拿一把钥匙开所有锁**。
  final sniffed = _sniffWithTail(head, tail, keys, ekeyOverride, file.path);

  // 优先级：调用方显式给的密钥 > 按平台+mid 查出来的 > 该平台的任意一把。
  //
  // 跨 isolate 时 [keys] 是 null（Isolate 之间不能传自定义对象），靠
  // [platformKeys] 兜底；主 isolate 里则优先走 [keys] 的精确匹配，
  // 因为 QQ 音乐同一首歌不同音质可能是不同的 ekey。
  final String? ekeyValue;
  if (ekeyOverride != null) {
    ekeyValue = ekeyOverride;
  } else if (keys != null) {
    ekeyValue = resolveEkey(sniffed, keys);
  } else {
    ekeyValue = platformKeys == null
        ? null
        // 先精确（mid / 文件名），再退到该平台的通用密钥。
        : (_matchByMidInMap(sniffed, platformKeys) ??
            _matchByFilenameInMap(sniffed, platformKeys) ??
            platformKeys[sniffed.platform.name]);
  }

  final out = File(outputPath);
  out.parent.createSync(recursive: true);

  final result = switch (sniffed.platform) {
    DecryptPlatform.netease =>
      _decryptNcm(file, totalLen, out, sniffed),
    DecryptPlatform.kugou =>
      _decryptKgm(file, totalLen, out, sniffed, ekeyValue),
    DecryptPlatform.kuwo =>
      _decryptKwm(file, totalLen, out, sniffed, ekeyValue),
    DecryptPlatform.migu =>
      _decryptMigu(file, totalLen, out, sniffed),
    DecryptPlatform.qingting =>
      _decryptQingTing(file, totalLen, out, ekeyValue),
    DecryptPlatform.qqMusic =>
      _decryptQmc(file, totalLen, out, sniffed, ekeyValue, tail),
  };

  // 校验产物确实是音频——对应上游 decrypt.ts 里的
  // `if (!result.overrideExtension && audioExt === 'bin') throw`。
  //
  // 密钥填错 / 版本判断错 / 偏移猜错时，解密本身不会报错，只是产出噪声。
  // 没有这一步，用户会拿到一个"能播放但全是电流声"的文件且不知原因。
  final fmt = _detectOutputFormat(out, result.bytesWritten);
  if (fmt == 'bin') {
    // 产物不是音频：删掉，避免用户以为是成功的。
    try {
      if (out.existsSync()) out.deleteSync();
    } catch (_) {/* 删不掉就算了*/}
    throw DecryptFailure(
      _badKeyHint(sniffed.platform),
    );
  }
  return DecryptResult(
    outputPath: result.outputPath,
    platform: result.platform,
    bytesWritten: result.bytesWritten,
    coverPath: result.coverPath,
    metadata: result.metadata,
    audioFormat: fmt,
  );
}

/// 探测解密产物的音频格式（读文件头 0x100 字节）。
String _detectOutputFormat(File out, int written) {
  if (written <= 0) return 'bin';
  try {
    final raf = out.openSync();
    try {
      final n = written < 0x100 ? written : 0x100;
      final buf = Uint8List(n);
      final read = raf.readIntoSync(buf, 0, n);
      if (read <= 0) return 'bin';
      return detectAudioFormat(Uint8List.sublistView(buf, 0, read)).extension;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return 'bin';
  }
}

/// 产物不像音频时，给出**针对该平台**的排查提示。
String _badKeyHint(DecryptPlatform p) => switch (p) {
      DecryptPlatform.qqMusic =>
        '解密结果不是有效的音频文件。QQ 音乐请确认：QMC v2 需要匹配这首歌的 ekey；'
            'PC v1 格式（footer 为 Legacy）则用内置密钥，不需要填写。',
      DecryptPlatform.kugou =>
        '解密结果不是有效的音频文件。酷狗请确认填的是 **v5 专用**的 fileKey——'
            '酷狗客户端里其他 key（v2/v3）不通用；v2/v3 本身不需要密钥。',
      DecryptPlatform.kuwo =>
        '解密结果不是有效的音频文件。酷我请确认填的是 **kwm v2** 的 fileKey，'
            'v1 无需密钥。',
      DecryptPlatform.netease =>
        '解密结果不是有效的音频文件。这通常说明文件已损坏，'
            '或它并非标准的网易云缓存格式。',
      DecryptPlatform.migu =>
        '解密结果不是有效的音频文件。咪咕通常无需密钥（由文件头推导），'
            '若你填了 fileKey，请确认它来自咪咕客户端配置。',
      DecryptPlatform.qingting =>
        '解密结果不是有效的音频文件。蜻蜓 FM 的设备密钥必须与生成它的'
            '六段机型信息完全一致——请检查 product / device / manufacturer / '
            'brand / board / model 是否与该歌曲播放时的设备一致。',
    };

SniffResult _sniffWithTail(
  Uint8List head,
  Uint8List? tail,
  DecryptKeys? keys,
  String? ekey,
  String inputPath,
) {
  // 蜻蜓 FM 没有文件头——**只能靠文件名**（`.p!<base64>.qta`）识别，
  // 必须放在最前面，否则会被下面几层的魔数嗅探误判成别的格式。
  if (isQingTingFileName(inputPath)) {
    return SniffResult(
      platform: DecryptPlatform.qingting,
      audioDataOffset: 0, // 整个文件都是密文
    );
  }

  if (isNcmFile(head)) {
    final h = parseNcmHeader(head);
    return SniffResult(
      platform: DecryptPlatform.netease,
      ncmHeader: h,
      audioDataOffset: h.audioDataOffset,
    );
  }
  try {
    final h = parseKgmHeader(head);
    return SniffResult(
        platform: DecryptPlatform.kugou,
        kgmHeader: h,
        audioDataOffset: h.dataOffset);
  } catch (_) {/* continue */}
  try {
    final h = parseKwmHeader(head);
    return SniffResult(
        platform: DecryptPlatform.kuwo,
        kwmHeader: h,
        audioDataOffset: kwmDataStartOffset);
  } catch (_) {/* continue */}

  final miguKey = guessMiguKey(head);
  if (miguKey != null) {
    return SniffResult(
        platform: DecryptPlatform.migu,
        miguKey: miguKey,
        audioDataOffset: miguDataStartOffset);
  }

  if (tail != null) {
    return sniffQmc(head, tail);
  }
  return SniffResult(platform: DecryptPlatform.qqMusic);
}

/// 每块4 MiB —— 太大在移动端容易触发内存抖动，太小则文件 IO 开销占比上升。
const int _chunkSize = 4 * 1024 * 1024;

/// 把 [from] 之后的字节流式解密并写出。
int _streamDecrypt({
  required File input,
  required File output,
  required int from,
  required int to,
  required void Function(Uint8List chunk, int offsetInFile) onChunk,
}) {
  final raf = input.openSync();
  try {
    final chunk = Uint8List(_chunkSize);
    final sink = output.openSync(mode: FileMode.writeOnly);
    try {
      var pos = from;
      while (pos < to) {
        final want = (to - pos) < _chunkSize ? (to - pos) : _chunkSize;
        // RandomAccessFile 的读接口只认「buffer 内起止下标」，没有文件偏移
        // 参数，所以每轮都要先 seek。
        raf.setPositionSync(pos);
        final read = raf.readIntoSync(chunk, 0, want);
        if (read <= 0) break;
        final view = Uint8List.sublistView(chunk, 0, read);
        onChunk(view, pos);
        sink.writeFromSync(view);
        pos += read;
      }
      return pos - from;
    } finally {
      sink.closeSync();
    }
  } finally {
    raf.closeSync();
  }
}

String _outExtension(String inputPath) {
  final p = inputPath.toLowerCase();
  if (p.endsWith('.qmcflac')) return '.flac';
  if (p.endsWith('.mflac')) return '.flac';
  if (p.endsWith('.kgm') || p.endsWith('.vpr')) return '.flac';
  if (p.endsWith('.kwm')) return '.flac';
  if (p.endsWith('.ncm')) return '.mp3';
  if (p.endsWith('.3d') || p.endsWith('.3da')) return '.mp4';
  // 蜻蜓的原始名是 `.p!<base64>.qta`，解出来的就是音频，直接还原成 .qta
  if (p.endsWith('.qta')) return '.qta';
  final dot = p.lastIndexOf('.');
  return dot >= 0 ? p.substring(dot) : '';
}

// ==================== 各格式 ====================

DecryptResult _decryptQmc(File file, int totalLen, File out, SniffResult s,
    String? ekey, Uint8List? tail) {
  // footer 里有 ekey 就用 QMC v2（PC v1 除外）；PC v1 用内置静态密钥
  final footer = s.footer;
  var e = ekey ?? footer?.ekey;

  if (footer != null && footer.type == QmcFooterType.pcV1Legacy) {
    // PC v1 尾部只有 ekey，但音频本身是 v1 静态密钥加密的
    final written = _streamDecrypt(
      input: file,
      output: out,
      from: 0,
      to: totalLen - footer.size,
      onChunk: (chunk, off) => qmc1Decrypt(chunk, off),
    );
    return DecryptResult(
      outputPath: out.path,
      platform: DecryptPlatform.qqMusic,
      bytesWritten: written,
    );
  }

  if (e == null || e.isEmpty) {
    throw const DecryptFailure('缺少 ekey，请在「密钥管理」中导入或手动填写后再试');
  }
  final cipher = QmcV2Cipher(qmcEkeyDecrypt(e));
  final end = footer != null ? totalLen - footer.size : totalLen;
  final written = _streamDecrypt(
    input: file,
    output: out,
    from: 0,
    to: end,
    onChunk: (chunk, off) => cipher.decrypt(chunk, off),
  );
  return DecryptResult(
    outputPath: out.path,
    platform: DecryptPlatform.qqMusic,
    bytesWritten: written,
  );
}

DecryptResult _decryptKgm(File file, int totalLen, File out, SniffResult s,
    String? ekey) {
  final header = s.kgmHeader;
  if (header == null) {
    throw const DecryptFailure('KGM 头部解析失败');
  }
  final e = ekey ?? header.let((_) => null);
  final d = createKgmDecipher(header, ekey: e);
  final written = _streamDecrypt(
    input: file,
    output: out,
    from: header.dataOffset,
    to: totalLen,
    onChunk: (chunk, off) => d.decrypt(chunk, off - header.dataOffset),
  );
  return DecryptResult(
    outputPath: out.path,
    platform: DecryptPlatform.kugou,
    bytesWritten: written,
  );
}

DecryptResult _decryptKwm(File file, int totalLen, File out, SniffResult s,
    String? ekey) {
  final header = s.kwmHeader;
  if (header == null) {
    throw const DecryptFailure('KWM 头部解析失败');
  }
  final d = createKwmDecipher(header, ekey: ekey);
  final written = _streamDecrypt(
    input: file,
    output: out,
    from: kwmDataStartOffset,
    to: totalLen,
    onChunk: (chunk, off) =>
        d.decrypt(chunk, off - kwmDataStartOffset),
  );
  return DecryptResult(
    outputPath: out.path,
    platform: DecryptPlatform.kuwo,
    bytesWritten: written,
  );
}

DecryptResult _decryptMigu(File file, int totalLen, File out, SniffResult s) {
  final key = s.miguKey;
  if (key == null) {
    throw const DecryptFailure('无法从文件头推断咪咕密钥，请手动填写 fileKey');
  }
  final d = MiguDecipher.fromKey(key);
  final written = _streamDecrypt(
    input: file,
    output: out,
    from: miguDataStartOffset,
    to: totalLen,
    onChunk: (chunk, off) =>
        d.decrypt(chunk, off - miguDataStartOffset),
  );
  return DecryptResult(
    outputPath: out.path,
    platform: DecryptPlatform.migu,
    bytesWritten: written,
  );
}


DecryptResult _decryptQingTing(
    File file, int totalLen, File out, String? deviceKeyHex) {
  final hex = deviceKeyHex?.trim();
  if (hex == null || hex.isEmpty) {
    throw const DecryptFailure(
        '蜻蜓 FM 需要设备密钥，请在「密钥管理」里填写或由设备信息生成');
  }

  final QingTingDecipher d;
  try {
    d = QingTingDecipher.fromHexKey(hex, file.path);
  } on QingTingFailure catch (e) {
    throw DecryptFailure(e.message);
  }

  // 蜻蜓的文件**没有头**，从第0 字节起整块都是密文。
  final written = _streamDecrypt(
    input: file,
    output: out,
    from: 0,
    to: totalLen,
    onChunk: (chunk, offset) => d.decrypt(chunk, offset),
  );

  return DecryptResult(
    outputPath: out.path,
    platform: DecryptPlatform.qingting,
    bytesWritten: written,
  );
}
DecryptResult _decryptNcm(File file, int totalLen, File out, SniffResult s) {
  final header = s.ncmHeader;
  if (header == null) {
    throw const DecryptFailure('NCM 头部解析失败');
  }
  final written = _streamDecrypt(
    input: file,
    output: out,
    from: header.audioDataOffset,
    to: totalLen,
    onChunk: (chunk, off) =>
        header.decrypt(chunk, off - header.audioDataOffset),
  );

  String? coverPath;
  if (header.image1 != null && header.image1!.isNotEmpty) {
    final f = File('${out.path}.jpg');
    f.writeAsBytesSync(header.image1!);
    coverPath = f.path;
  }

  String? meta;
  try {
    meta = header.readMetadata();
  } catch (_) {
    // metadata 损坏不应该让音频解密整体失败
  }

  return DecryptResult(
    outputPath: out.path,
    platform: DecryptPlatform.netease,
    bytesWritten: written,
    coverPath: coverPath,
    metadata: meta,
  );
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

/// 计算输出文件名（含扩展名推导）。
String buildOutputName(String inputPath) {
  final slash = [inputPath.lastIndexOf('/'), inputPath.lastIndexOf(r'\')]
      .reduce((a, b) => a > b ? a : b);
  final name = inputPath.substring(slash + 1);
  return name + _outExtension(inputPath);
}

/// 工具：把字节序列转成可打印 hex，便于在界面上排查密钥。
String hexPreview(List<int> bytes, {int max = 16}) {
  final take = bytes.length < max ? bytes.length : max;
  final s = bytes.take(take).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  return bytes.length > take ? '$s ...' : s;
}

/// 工具：UTF-8 容错解码。
String safeUtf8(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

/// 跨 isolate 时用的兜底匹配：从扁平 map 里按 mid 找精确匹配。
///
/// [platformKeys] 的 key 形如 `platform` 或 `platform mid`——
/// 后者是带 mid 的精确条目，优先于该平台的第一把通用密钥。
String? _matchByMidInMap(SniffResult sniff, Map<String, String> platformKeys) {
  final mid = sniff.footer?.mediaMid;
  if (mid == null || mid.isEmpty) return null;
  return platformKeys['${sniff.platform.name} $mid'];
}

/// 同[_matchByMidInMap]，但按原始文件名匹配（QQ 的 MusicEx footer 给的是文件名）。
String? _matchByFilenameInMap(SniffResult sniff, Map<String, String> m) {
  final name = sniff.footer?.mediaFilename;
  if (name == null || name.isEmpty) return null;
  return m['${sniff.platform.name}@$name'];
}
