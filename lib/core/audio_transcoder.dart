/// 音频转码核心（v2.4.9）。
///
/// 把本地音频文件转成目标格式，并支持自定义声道数、位深、采样率、码率。
///
/// ## 引擎说明（重要）
/// App 播放链路用的 media_kit / libmpv 内嵌 ffmpeg 是**白名单纯解码构建**
/// （`--disable-muxers --disable-encoders --disable-programs`），能解几乎所有
/// 音质，但**不含编码器 / muxer / ffmpeg 命令行**，无法用来产出文件。
///
/// Android 随 APK 打包一份「裁剪版 ffmpeg CLI」（`libffmpeg_exec.so`，放在
/// `nativeLibraryDir`），由 UI 层通过 `FfmpegLocator.extraCandidates` 注入候选
/// 路径，因此移动端开箱即用。v2.4.9 起该二进制改为**动态 PIE**
/// （ET_DYN + `PT_INTERP=/system/bin/linker64`，仅依赖系统 libc/libm）——
/// v2.4.8 的 static-PIE 没有 INTERP，真机上 execve 会被 SELinux/seccomp 拒绝。
/// 页面探测到引擎后会跑一次 `ffmpeg -version` 自检，失败原因直接可见。
/// 探测顺序：
///   1. 页面手动指定 / 环境变量 `BAIJI_FFMPEG`；
///   2. `extraCandidates`（Android 内置引擎）；
///   3. 随包内置目录（可执行文件同目录的 `bin/ffmpeg[.exe]`）；
///   4. 系统 PATH（`which ffmpeg` / `where ffmpeg`）。
/// 注意 [AudioTranscoder.ffmpegPath] 可为空：DTS/360RA/NAC 直出 WAV
/// 走自研解码器，不需要 ffmpeg，只有真正需要编码/封装时才要求引擎可用。
///
/// ## 特殊格式
/// DTS:X / 360RA / NAC / AV3A 这四个格式的上游解码器不在通用 ffmpeg 里，
/// 转码输出按产品约束**锁定为 WAV**：
/// - DTS / 360RA / NAC：优先走 App 自研原生解码器（[SpecialDecoder]），产物即 PCM WAV；
/// - AV3A：交给 ffmpeg 解码成 PCM WAV，若当前 ffmpeg 无 av3a 解码器则给出明确提示。
library;

import 'dart:convert';
import 'dart:io';

import 'app_logger.dart';

/// 可输出的容器/编码格式。
enum TranscodeFormat {
  wav('WAV', 'wav', 'pcm_s16le'),
  flac('FLAC', 'flac', 'flac'),
  m4a('M4A (AAC)', 'm4a', 'aac'),
  mp4('MP4 (AAC 音轨)', 'mp4', 'aac'),
  wma('WMA', 'wma', 'wmav2'),
  aac('AAC', 'aac', 'aac'),
  ac3('AC-3', 'ac3', 'ac3'),
  eac3('E-AC-3', 'eac3', 'eac3'),
  mp3('MP3', 'mp3', 'libmp3lame'),
  ogg('OGG (Vorbis)', 'ogg', 'libvorbis');

  const TranscodeFormat(this.label, this.extension, this.defaultCodec);

  final String label;
  final String extension;
  final String defaultCodec;

  /// 位深只对 PCM / FLAC 有意义；有损编码器由码率决定质量。
  bool get supportsBitDepth => this == TranscodeFormat.wav || this == TranscodeFormat.flac;

  /// 无损格式不需要码率。
  bool get isLossless => this == TranscodeFormat.wav || this == TranscodeFormat.flac;

  /// AC-3 / E-AC-3 编码器只接受有限采样率（32 / 44.1 / 48 kHz）与最多 6 声道，
  /// 用于 UI 提示；实际越界仍由 ffmpeg 明确报错。
  bool get isAc3Family => this == TranscodeFormat.ac3 || this == TranscodeFormat.eac3;

  static TranscodeFormat? fromExtension(String ext) {
    var e = ext.toLowerCase();
    if (e.startsWith('.')) e = e.substring(1);
    for (final f in TranscodeFormat.values) {
      if (f.extension == e) return f;
    }
    return null;
  }
}

/// 需要特殊处理的输入格式。
enum SpecialFormat {
  dts('DTS:X', true),
  ra360('索尼 360RA', true),
  nac('NAC 神经音频', true),
  av3a('臻音全景声 AV3A', true),
  mp4('MP4 容器', false),
  ac3('AC-3', false),
  eac3('E-AC-3', false);

  const SpecialFormat(this.label, this.wavOnly);

  final String label;

  /// 是否只允许输出 WAV。
  final bool wavOnly;

  static const List<SpecialFormat> wavOnlyFormats = [
    SpecialFormat.dts,
    SpecialFormat.ra360,
    SpecialFormat.nac,
    SpecialFormat.av3a,
  ];
}

/// 转码参数。`0` / `null` 表示「保持源文件」。
class TranscodeOptions {
  const TranscodeOptions({
    this.format = TranscodeFormat.wav,
    this.channels = 0,
    this.sampleRate = 0,
    this.bitDepth = 16,
    this.bitrateKbps = 0,
  });

  final TranscodeFormat format;

  /// 目标声道数（1/2/6/8…）；0 = 保持源。
  final int channels;

  /// 目标采样率 Hz（如 44100 / 48000 / 96000）；0 = 保持源。
  final int sampleRate;

  /// PCM/FLAC 位深：16 / 24 / 32。
  final int bitDepth;

  /// 有损格式码率 kbps；0 = 用编码器默认值。
  final int bitrateKbps;

  TranscodeOptions copyWith({
    TranscodeFormat? format,
    int? channels,
    int? sampleRate,
    int? bitDepth,
    int? bitrateKbps,
  }) {
    return TranscodeOptions(
      format: format ?? this.format,
      channels: channels ?? this.channels,
      sampleRate: sampleRate ?? this.sampleRate,
      bitDepth: bitDepth ?? this.bitDepth,
      bitrateKbps: bitrateKbps ?? this.bitrateKbps,
    );
  }

  /// 参数合法性校验，返回错误文案；合法返回 null。
  String? validate() {
    if (channels != 0 && (channels < 1 || channels > 8)) {
      return '声道数需在 1–8 之间（0 表示保持源）';
    }
    if (sampleRate != 0 && (sampleRate < 8000 || sampleRate > 384000)) {
      return '采样率需在 8000–384000 Hz 之间（0 表示保持源）';
    }
    if (format.supportsBitDepth && ![16, 24, 32].contains(bitDepth)) {
      return '位深只支持 16 / 24 / 32 bit';
    }
    if (bitrateKbps != 0 && (bitrateKbps < 32 || bitrateKbps > 1411)) {
      return '码率需在 32–1411 kbps 之间（0 表示默认）';
    }
    return null;
  }
}

/// 特殊格式识别：扩展名 + 文件头魔数。
///
/// 单独抽成纯函数是为了能离线测试，不依赖真实文件。
SpecialFormat? detectSpecialFormat(String path, {List<int>? head}) {
  final lower = path.toLowerCase();
  final name = lower.split(RegExp(r'[\\/]')).last;

  // 独立容器扩展名：这些格式不经通用 ffmpeg 解码器，需单独分流。
  if (name.endsWith('.nac')) return SpecialFormat.nac;
  if (name.endsWith('.ac3')) return SpecialFormat.ac3;
  if (name.endsWith('.eac3') || name.endsWith('.ec3')) {
    return SpecialFormat.eac3;
  }
  if (name.endsWith('.av3a')) return SpecialFormat.av3a;
  if (name.endsWith('.mha1') || name.endsWith('.mhm1')) {
    return SpecialFormat.ra360;
  }
  if (name.endsWith('.dtsx') || name.endsWith('.dtshd')) {
    return SpecialFormat.dts;
  }

  // MP4 家族：靠 box fourcc 细分（ftyp 之后的兼容品牌 / moov 里的 sample entry）。
  if (name.endsWith('.mp4') || name.endsWith('.m4a') || name.endsWith('.mov')) {
    final fourcc = head == null ? null : _findFourcc(head);
    if (fourcc != null) {
      if (fourcc.contains('dtsx')) return SpecialFormat.dts;
      if (fourcc.contains('mha1') || fourcc.contains('mhm1')) {
        return SpecialFormat.ra360;
      }
      if (fourcc.contains('av3a')) return SpecialFormat.av3a;
      if (fourcc.contains('ac-3')) return SpecialFormat.ac3;
      if (fourcc.contains('ec-3')) return SpecialFormat.eac3;
    }
    // 文件名带音质标记时也能识别（下载文件名通常含 code）。
    if (name.contains('dt03') || name.contains('dtsx')) {
      return SpecialFormat.dts;
    }
    if (name.contains('ra01') ||
        name.contains('ra02') ||
        name.contains('ra03') ||
        name.contains('ra04') ||
        name.contains('360ra')) {
      return SpecialFormat.ra360;
    }
    if (name.contains('av3a') || name.contains('vivid')) {
      return SpecialFormat.av3a;
    }
    return SpecialFormat.mp4;
  }

  // 无扩展名 / 其它：按魔数兜底识别 dts 裸流。
  if (head != null && head.length >= 4) {
    final h = head.sublist(0, 4);
    // DTS 同步字 0x7FFE8001（大端）
    if (h[0] == 0x7F && h[1] == 0xFE && h[2] == 0x80 && h[3] == 0x01) {
      return SpecialFormat.dts;
    }
    // AC-3 / E-AC-3 同步字 0x0B77
    if (h[0] == 0x0B && h[1] == 0x77) return SpecialFormat.ac3;
  }
  return null;
}

/// 在文件头字节里查找关键 fourcc，返回小写命中集合的字符串。
String? _findFourcc(List<int> head) {
  const keys = ['dtsx', 'mha1', 'mhm1', 'av3a', 'ac-3', 'ec-3'];
  // 只在文件头做 ASCII 扫描，避免全文件解码开销。
  final sb = StringBuffer();
  for (final k in keys) {
    final bytes = utf8.encode(k);
    outer:
    for (var i = 0; i + bytes.length <= head.length; i++) {
      for (var j = 0; j < bytes.length; j++) {
        if (head[i + j] != bytes[j]) continue outer;
      }
      sb.write('$k ');
      break;
    }
  }
  return sb.isEmpty ? null : sb.toString().toLowerCase();
}

/// 所有允许作为输入的扩展名（用于文件选择器过滤提示）。
const Set<String> kSupportedInputExtensions = {
  'wav', 'flac', 'm4a', 'wma', 'aac', 'mp3', 'ogg', 'opus', 'mp4',
  'ac3', 'eac3', 'ec3', 'aiff', 'aif', 'ape', 'wv', 'dsf', 'dff',
  'mka', 'mkv', 'webm', 'caf', 'au', 'w64', 'm4b', 'mov', 'm4v',
  // 特殊音质容器：走自研解码器（DTS / 360RA / NAC）或 ffmpeg av3a 解码。
  'nac', 'dts', 'dtshd', 'dtsx', 'mha1', 'mhm1', 'av3a',
};

/// ffmpeg 参数构造（纯函数，可离线测试）。
///
/// 生成形如：
/// `ffmpeg -hide_banner -loglevel error -nostdin -y -i in -vn -map 0:a:0
///  [-ac N] [-ar RATE] -c:a CODEC [-sample_fmt FMT] [-b:a Nk] -f FMT out`
List<String> buildFfmpegArgs({
  required String inputPath,
  required String outputPath,
  required TranscodeOptions options,
}) {
  final fmt = options.format;
  final args = <String>[
    '-hide_banner',
    '-loglevel', 'error',
    '-nostdin',
    '-y', // 覆盖已存在产物（输出名已做去重）
    '-i', inputPath,
    '-vn', // 丢掉视频/封面流，只保留音频
    '-map', '0:a:0',
  ];

  if (options.channels > 0) {
    args.addAll(['-ac', '${options.channels}']);
  }
  if (options.sampleRate > 0) {
    args.addAll(['-ar', '${options.sampleRate}']);
  }

  // 编码器 + 位深
  String codec = fmt.defaultCodec;
  if (fmt == TranscodeFormat.wav) {
    codec = switch (options.bitDepth) {
      24 => 'pcm_s24le',
      32 => 'pcm_s32le',
      _ => 'pcm_s16le',
    };
  }
  args.addAll(['-c:a', codec]);

  if (fmt == TranscodeFormat.flac) {
    // FLAC 只接受 s16 / s32 采样格式，24bit 用 s32 + 有效位深标注。
    args.addAll(['-sample_fmt', options.bitDepth >= 24 ? 's32' : 's16']);
    if (options.bitDepth == 24) {
      args.addAll(['-bits_per_raw_sample', '24']);
    }
  }

  // 有损格式码率
  if (!fmt.isLossless && options.bitrateKbps > 0) {
    args.addAll(['-b:a', '${options.bitrateKbps}k']);
  }

  // 显式指定容器，避免输出扩展名与编码器推断不一致（如 .aac → adts）
  args.addAll(['-f', _muxerFor(fmt)]);

  // 进度走 stdout，便于解析且不污染 stderr 的错误信息。
  args.addAll(['-progress', 'pipe:1', '-nostats']);

  args.add(outputPath);
  return args;
}

String _muxerFor(TranscodeFormat f) => switch (f) {
      TranscodeFormat.wav => 'wav',
      TranscodeFormat.flac => 'flac',
      TranscodeFormat.m4a => 'ipod',
      TranscodeFormat.mp4 => 'mp4',
      TranscodeFormat.wma => 'asf',
      TranscodeFormat.aac => 'adts',
      TranscodeFormat.ac3 => 'ac3',
      TranscodeFormat.eac3 => 'eac3',
      TranscodeFormat.mp3 => 'mp3',
      TranscodeFormat.ogg => 'ogg',
    };

/// 根据输入格式约束实际输出格式：wavOnly 源强制 WAV。
TranscodeOptions effectiveOptions(
  String inputPath,
  TranscodeOptions requested, {
  List<int>? head,
}) {
  final sp = detectSpecialFormat(inputPath, head: head);
  if (sp != null && sp.wavOnly && requested.format != TranscodeFormat.wav) {
    return requested.copyWith(format: TranscodeFormat.wav);
  }
  return requested;
}

/// 生成不覆盖已有文件的输出路径（同名追加 (2)/(3)…）。
String resolveOutputPath(String inputPath, String outputDir, TranscodeFormat fmt) {
  final sep = Platform.pathSeparator;
  final stem = inputPath.split(RegExp(r'[\\/]')).last;
  final dot = stem.lastIndexOf('.');
  final base = dot > 0 ? stem.substring(0, dot) : stem;
  var candidate = '$outputDir$sep$base.${fmt.extension}';
  var i = 2;
  while (File(candidate).existsSync()) {
    candidate = '$outputDir$sep$base($i).${fmt.extension}';
    i++;
  }
  return candidate;
}

/// 转码进度。`totalMs` 为 null 时只显示已处理时长。
class TranscodeProgress {
  const TranscodeProgress({this.processedMs = 0, this.totalMs});
  final int processedMs;
  final int? totalMs;

  double? get percent {
    final t = totalMs;
    if (t == null || t <= 0) return null;
    return (processedMs / t).clamp(0.0, 1.0);
  }
}

class TranscodeResult {
  const TranscodeResult.success(this.outputPath)
      : error = null,
        ok = true;
  const TranscodeResult.failure(this.error)
      : outputPath = null,
        ok = false;

  final bool ok;
  final String? outputPath;
  final String? error;
}

/// ffmpeg 可执行路径探测（可注入，便于离线测试）。
class FfmpegLocator {
  FfmpegLocator({
    this.overridePath,
    this.extraCandidates = const <String>[],
    bool Function(String)? fileExists,
    this.pathProbe,
    Map<String, String>? environment,
  })  : fileExists = fileExists ?? _defaultExists,
        environment = environment ?? Platform.environment;

  /// 手动指定路径（优先于环境变量 BAIJI_FFMPEG）。
  final String? overridePath;

  /// 由 UI 层注入的额外候选（Android 随 APK 内置的 ffmpeg 位于
  /// `applicationInfo.nativeLibraryDir/libffmpeg_exec.so`）。
  /// 放在「手动指定」之后、「随包 bin / PATH」之前探测。
  final List<String> extraCandidates;

  /// 可注入的文件存在性判断，便于离线测试。
  final bool Function(String) fileExists;

  /// 可注入的 PATH 探测，便于离线测试。
  final Future<String?> Function()? pathProbe;

  final Map<String, String> environment;

  static bool _defaultExists(String p) => File(p).existsSync();

  /// 随包内置的候选路径（预留给 CI 打包 ffmpeg 二进制）。
  static List<String> bundledCandidates() {
    final exe = Platform.resolvedExecutable;
    final dir = File(exe).parent.path;
    final sep = Platform.pathSeparator;
    final name = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    return [
      '$dir$sep$name',
      '$dir${sep}bin$sep$name',
      '$dir${sep}data${sep}flutter_assets${sep}assets${sep}bin$sep$name',
    ];
  }

  /// 返回可用的 ffmpeg 路径；找不到返回 null。
  ///
  /// 注意：**手动指定 / 环境变量路径失效时直接返回 null**，不再静默回退到
  /// 内置引擎或 PATH——用户显式指定了路径却悄悄换一个引擎执行，产出结果
  /// 与预期不符，比直接报错更难排查。
  Future<String?> resolve() async {
    // 1) 手动指定 / 环境变量
    final manual = overridePath ?? environment['BAIJI_FFMPEG'];
    if (manual != null && manual.trim().isNotEmpty) {
      final p = manual.trim();
      return fileExists(p) ? p : null;
    }
    // 2) 内置引擎（Android nativeLibraryDir）+ 随包 bin
    for (final c in <String>[...extraCandidates, ...bundledCandidates()]) {
      if (c.isNotEmpty && fileExists(c)) return c;
    }
    // 3) 系统 PATH（拿到局部变量才能做空值提升）
    final probe = pathProbe;
    if (probe != null) return await probe();
    return await _probePath();
  }

  static Future<String?> _probePath() async {
    try {
      final result = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        [Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg'],
      );
      if (result.exitCode != 0) return null;
      final out = (result.stdout as String).trim();
      if (out.isEmpty) return null;
      final first = out.split(RegExp(r'\r?\n')).first.trim();
      return first.isEmpty ? null : first;
    } catch (e) {
      AppLog.w('AudioTranscoder', 'PATH 探测 ffmpeg 失败: $e');
      return null;
    }
  }
}

/// 特殊格式（DTS/360RA/NAC）本地文件解码回调。
///
/// 由 UI 层注入，内部调用三个自研解码器的 `decodeLocalToWav`。
/// 返回生成的 WAV 路径；null 表示当前平台不支持或解码失败。
typedef SpecialDecoder = Future<String?> Function(
  SpecialFormat format,
  String sourcePath,
  String targetWavPath,
);

/// 转码执行器。
class AudioTranscoder {
  AudioTranscoder({
    this.ffmpegPath,
    this.specialDecoder,
    this.probeDurationMs,
  });

  /// ffmpeg 可执行路径；可为 null。
  /// DTS/360RA/NAC 直出 WAV 走自研解码器，不需要它；其余转码路径
  /// 在缺少引擎时会返回带操作指引的明确错误，而不是抛出空指针。
  final String? ffmpegPath;

  /// DTS / 360RA / NAC 本地解码回调；null 表示当前平台不支持这些格式。
  final SpecialDecoder? specialDecoder;

  /// 可选：探测输入时长，用于进度百分比。
  final Future<int?> Function(String file)? probeDurationMs;

  Process? _process;
  bool _cancelled = false;

  /// 取消当前任务（已产出的半成品会被清理）。
  void cancel() {
    _cancelled = true;
    try {
      _process?.kill(ProcessSignal.sigkill);
    } catch (_) {}
  }

  Future<TranscodeResult> transcode({
    required String inputPath,
    required String outputDir,
    required TranscodeOptions options,
    List<int>? head,
    void Function(TranscodeProgress p)? onProgress,
    bool Function()? isCancelled,
  }) async {
    _cancelled = false;
    final err = options.validate();
    if (err != null) return TranscodeResult.failure(err);
    if (!File(inputPath).existsSync()) {
      return const TranscodeResult.failure('源文件不存在');
    }

    final sp = detectSpecialFormat(inputPath, head: head);
    final effective = effectiveOptions(inputPath, options, head: head);

    try {
      await Directory(outputDir).create(recursive: true);
    } catch (e) {
      return TranscodeResult.failure('无法创建输出目录：$e');
    }

    final outputPath =
        resolveOutputPath(inputPath, outputDir, effective.format);

    String ffmpegInput = inputPath;

    // 特殊格式：DTS/360RA/NAC 走自研解码器直接产出 WAV；
    // AV3A 仍交给 ffmpeg 解成 PCM WAV（若 ffmpeg 无 av3a 解码器会明确报错）。
    if (sp != null && sp.wavOnly && sp != SpecialFormat.av3a) {
      final decoder = specialDecoder;
      if (decoder == null) {
        return TranscodeResult.failure(
            '${sp.label} 需要 App 内置解码器，当前平台不可用');
      }
      // 自研解码器直出的是 s16 PCM WAV，无法应用自定义声道/采样率/位深。
      // 这些参数需要 ffmpeg 做二次 PCM 变换，提前判断，避免白解码一遍。
      final exe = ffmpegPath;
      final needResample = effective.channels > 0 ||
          effective.sampleRate > 0 ||
          effective.bitDepth > 16;
      if (needResample && (exe == null || exe.isEmpty)) {
        return const TranscodeResult.failure(
            '自定义声道 / 采样率 / 位深需要 ffmpeg 引擎：请清除自定义参数以直出 WAV，'
            '或在「转码引擎」里指定 ffmpeg');
      }
      final wav = await decoder(sp, inputPath, outputPath);
      if (_cancelled || (isCancelled?.call() ?? false)) {
        _cleanup(outputPath);
        return const TranscodeResult.failure('已取消');
      }
      if (wav == null) {
        return TranscodeResult.failure('${sp.label} 解码失败（内置解码器不可用）');
      }
      // 解码产物即 WAV；若用户额外要求改声道/采样率/位深，再跑一次 ffmpeg 做 PCM 变换。
      if (!needResample) {
        onProgress?.call(const TranscodeProgress(processedMs: 0, totalMs: 1));
        return TranscodeResult.success(outputPath);
      }
      ffmpegInput = wav;
      // 二次处理仍输出到同一路径，用临时文件中转避免自读自写。
      final tmp = '$outputPath.tmp.wav';
      final r = await _runFfmpeg(
        input: ffmpegInput,
        output: tmp,
        options: effective,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      if (!r.ok) {
        _cleanup(tmp);
        _cleanup(outputPath);
        return r;
      }
      try {
        // 解码器已写出 outputPath，部分平台 rename 不允许覆盖已存在文件，
        // 先删再改名，避免 Windows 上二次重采样后写回失败。
        final outFile = File(outputPath);
        if (outFile.existsSync()) outFile.deleteSync();
        File(tmp).renameSync(outputPath);
      } catch (e) {
        _cleanup(tmp);
        return TranscodeResult.failure('写出 WAV 失败：$e');
      }
      return TranscodeResult.success(outputPath);
    }

    final result = await _runFfmpeg(
      input: ffmpegInput,
      output: outputPath,
      options: effective,
      onProgress: onProgress,
      isCancelled: isCancelled,
      cleanupOnFailure: true,
    );
    // AV3A 只能转 WAV，但很多标准 ffmpeg 构建不含 av3a 解码器；
    // 把底层报错翻译成可操作的提示，避免用户只看到一行 demuxer 错误。
    if (!result.ok &&
        sp == SpecialFormat.av3a &&
        !(result.error?.contains('已取消') ?? false)) {
      return TranscodeResult.failure(
        'AV3A 解码失败：当前 ffmpeg 可能不含 av3a 解码器，'
        '请改用带 av3a 支持的构建。原始错误：${result.error ?? ''}',
      );
    }
    return result;
  }

  Future<TranscodeResult> _runFfmpeg({
    required String input,
    required String output,
    required TranscodeOptions options,
    void Function(TranscodeProgress p)? onProgress,
    bool Function()? isCancelled,
    bool cleanupOnFailure = false,
  }) async {
    final args = buildFfmpegArgs(
      inputPath: input,
      outputPath: output,
      options: options,
    );
    AppLog.i('AudioTranscoder', '转码: ${options.format.extension} ← $input');

    int? totalMs;
    final durationProbe = probeDurationMs;
    if (durationProbe != null) {
      try {
        totalMs = await durationProbe(input);
      } catch (_) {}
    }

    final exe = ffmpegPath;
    if (exe == null || exe.isEmpty) {
      return const TranscodeResult.failure(
          '当前平台没有可用的 ffmpeg 转码引擎：请在「转码引擎」里手动指定，'
          '或在 Android 上使用带内置引擎的安装包');
    }
    try {
      _process = await Process.start(exe, args);
    } catch (e) {
      return TranscodeResult.failure('无法启动 ffmpeg（$exe）：$e');
    }

    final stderrBuf = StringBuffer();
    final pending = <String>[];
    var processedMs = 0;

    void handleStdout(String line) {
      // -progress pipe:1 输出 key=value 行，out_time_us 优先（微秒）。
      if (line.startsWith('out_time_us=')) {
        final v = int.tryParse(line.substring('out_time_us='.length));
        if (v != null) processedMs = v ~/ 1000;
      } else if (line.startsWith('out_time_ms=')) {
        final v = int.tryParse(line.substring('out_time_ms='.length));
        if (v != null) processedMs = v;
      } else if (line.startsWith('out_time=') && !line.contains('N/A')) {
        // 形如 00:01:23.45，作为兜底
        final v = _parseClock(line.substring('out_time='.length));
        if (v != null) processedMs = v;
      } else if (line.startsWith('progress=')) {
        onProgress?.call(TranscodeProgress(
          processedMs: processedMs,
          totalMs: totalMs,
        ));
      }
      if (pending.length > 200) pending.removeAt(0);
      pending.add(line);
    }

    final stdoutFut = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(handleStdout, onError: (Object e) {});
    final stderrFut = _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) {
      if (stderrBuf.length < 4000) stderrBuf.writeln(l);
    }, onError: (Object e) {});

    final exitCode = await _process!.exitCode;
    await stdoutFut.cancel();
    await stderrFut.cancel();
    _process = null;

    if (_cancelled || (isCancelled?.call() ?? false)) {
      _cleanup(output);
      return const TranscodeResult.failure('已取消');
    }
    if (exitCode != 0) {
      _cleanup(output);
      final raw = stderrBuf.toString().trim();
      final lines = raw.isEmpty
          ? const <String>[]
          : raw.split('\n').where((l) => l.trim().isNotEmpty).toList();
      // 保留末尾数行：ffmpeg 的关键错误（权限 / 编码器 / 输出路径）都在末尾，
      // 只取最后一行常会把「Permission denied」之外的原因一起吞掉。
      final tail = lines.isEmpty
          ? ''
          : (lines.length > 4
              ? lines.sublist(lines.length - 4).join('\n')
              : lines.join('\n'));
      return TranscodeResult.failure(
        'ffmpeg 退出码 $exitCode\n输出：$output'
        '${tail.isNotEmpty ? '\n$tail' : ''}',
      );
    }
    if (!File(output).existsSync() || File(output).lengthSync() == 0) {
      if (cleanupOnFailure) _cleanup(output);
      return TranscodeResult.failure('转码未生成有效文件：$output');
    }
    onProgress?.call(TranscodeProgress(processedMs: processedMs, totalMs: totalMs));
    return TranscodeResult.success(output);
  }

  static void _cleanup(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  static int? _parseClock(String s) {
    final parts = s.trim().split(':');
    if (parts.length != 3) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final sec = double.tryParse(parts[2]);
    if (h == null || m == null || sec == null) return null;
    return ((h * 3600 + m * 60 + sec) * 1000).round();
  }
}
