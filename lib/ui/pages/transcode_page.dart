/// 音频转码页（v2.4.9）。
///
/// 复用「本地音乐解密」的批量任务范式：选文件 → 设参数 → 开始 / 停止。
///
/// 引擎用**标准 ffmpeg 可执行文件**：App 播放内核内嵌的 ffmpeg 是纯解码
/// 构建（`--disable-encoders --disable-muxers --disable-programs`），能解几乎
/// 所有音质但没有编码器 / 复用器 / 命令行，无法产出文件。
/// v2.4.9 起 Android 随 APK 内置裁剪版**动态 PIE** ffmpeg
/// （`applicationInfo.nativeLibraryDir/libffmpeg_exec.so`）——v2.4.8 的
/// static-PIE 无 INTERP 在真机 execve 会被系统拒绝，已换成带
/// `/system/bin/linker64` 的标准形态。通过 `baiji/native` 通道取目录后
/// 自动探测，并在页面上跑一次 `ffmpeg -version` 自检。
/// 保存位置支持「应用目录 / 公共音乐 / 自定义」切换并持久化，切换前做写入预检。
/// DTS/360RA/NAC 直出 WAV 走自研解码器，不依赖 ffmpeg。
/// 详见 `lib/core/audio_transcoder.dart` 顶部说明。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/app_logger.dart';
import '../../core/audio_transcoder.dart';
import '../../core/cache_manager.dart';
import '../../core/kv_store.dart';
import '../../dts/dts_decoder.dart';
import '../../nac/nac_decoder.dart';
import '../../ra360/ra360_decoder.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';

/// 单个转码任务。
class _Task {
  _Task(this.name, this.inputPath);

  final String inputPath;
  final String name;

  /// 选文件时预读的文件头 + 尾部字节，供 [detectSpecialFormat] 嗅探魔数。
  Uint8List? head;

  /// 识别出的特殊输入格式（DTS / 360RA / NAC / AV3A / mp4 / ac3 / eac3）。
  SpecialFormat? special;

  bool running = false;
  bool done = false;
  String? error;
  String? outputPath;
  double? percent;
  int processedMs = 0;
  int? totalMs;
}

class TranscodePage extends StatefulWidget {
  const TranscodePage({super.key});

  @override
  State<TranscodePage> createState() => _TranscodePageState();
}

class _TranscodePageState extends State<TranscodePage> {
  final List<_Task> _tasks = [];
  final TextEditingController _ffmpegController = TextEditingController();

  String? _outputDir;

  /// 保存位置模式：app（应用私有目录）/ public（公共 Music）/ custom（用户指定）。
  String _outputMode = 'app';
  String? _ffmpegPath;
  bool _probing = true;

  /// 引擎自检结果（跑一次 `ffmpeg -version`），真机上能直接看出能否 execve。
  String? _engineCheck;

  TranscodeFormat _format = TranscodeFormat.wav;
  int _channels = 0;
  int _sampleRate = 0;
  int _bitDepth = 16;
  int _bitrateKbps = 0;

  bool _busy = false;
  bool _cancelled = false;
  int _finished = 0;
  AudioTranscoder? _transcoder;

  static const String _kOutputDir = 'transcode_output_dir';
  static const String _kOutputMode = 'transcode_output_mode';

  @override
  void initState() {
    super.initState();
    _loadOutputDir();
    _probeFfmpeg();
  }

  @override
  void dispose() {
    _ffmpegController.dispose();
    super.dispose();
  }

  /// 恢复上次的保存位置（v2.4.9：选择会持久化，不再每次进页面重置）。
  Future<void> _loadOutputDir() async {
    try {
      final savedMode = KvStore.instance.getString(_kOutputMode);
      final savedDir = KvStore.instance.getString(_kOutputDir);
      if (savedDir != null && savedDir.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _outputMode = savedMode ?? 'custom';
          _outputDir = savedDir;
        });
        return;
      }
    } catch (_) {/* KvStore 未初始化时走默认 */}
    await _applyOutputMode('app', persist: false);
  }

  /// 应用私有目录：无需任何权限即可写，但文件管理器里不易直接看到。
  Future<String> _appOutputDir() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}${Platform.pathSeparator}转码音乐';
  }

  /// Android 公共 Music 目录（白姬音乐/）；其它平台返回 null。
  Future<String?> _publicOutputDir() async {
    if (!Platform.isAndroid) return null;
    try {
      final dir = await _nativeChannel.invokeMethod<String>('publicMusicDir');
      if (dir == null || dir.isEmpty) return null;
      return '$dir${Platform.pathSeparator}白姬音乐';
    } catch (e) {
      AppLog.w('TranscodePage', '公共 Music 目录获取失败: $e');
      return null;
    }
  }

  /// 写入预检：真正创建目录并写一个探针文件，避免转码到一半才发现写不了。
  Future<bool> _checkWritable(String path) async {
    try {
      final d = Directory(path);
      if (!await d.exists()) await d.create(recursive: true);
      final probe =
          File('${d.path}${Platform.pathSeparator}.baiji_write_test');
      await probe.writeAsString('test', flush: true);
      await probe.delete();
      return true;
    } catch (e) {
      AppLog.w('TranscodePage', '保存位置不可写: $path, $e');
      return false;
    }
  }

  Future<bool> _ensureAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      if (await Permission.manageExternalStorage.isGranted) return true;
      return (await Permission.manageExternalStorage.request()).isGranted;
    } catch (e) {
      AppLog.w('TranscodePage', '申请所有文件访问权限失败: $e');
      return false;
    }
  }

  /// 切换保存位置：app / public / custom。公共目录先申请权限，全部做写入预检。
  Future<void> _applyOutputMode(String mode, {bool persist = true}) async {
    String? path;
    if (mode == 'app') {
      path = await _appOutputDir();
    } else if (mode == 'public') {
      path = await _publicOutputDir();
      if (path == null) {
        _toast('当前平台无法定位公共音乐目录，请改用「自定义」');
        return;
      }
      if (!await _ensureAllFilesAccess()) {
        _toast('需要「所有文件访问权限」才能写入公共目录；'
            '可改用「应用目录」，或在系统设置里开启后重试');
        return;
      }
    } else {
      await _chooseOutputDir();
      return;
    }
    if (!await _checkWritable(path)) {
      _toast('保存位置不可写：$path\n请改用「应用目录」或开启存储权限');
      return;
    }
    if (persist) {
      try {
        await KvStore.instance.setString(_kOutputMode, mode);
        await KvStore.instance.setString(_kOutputDir, path);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _outputMode = mode;
      _outputDir = path;
    });
    if (persist) _toast('保存位置已设为：$path');
  }

  // ==================== ffmpeg 探测 ====================

  /// Android 随 APK 内置的 ffmpeg 位于 applicationInfo.nativeLibraryDir，
  /// Dart 侧无法直接拿到，走平台通道取目录后作为额外探测候选注入。
  static const MethodChannel _nativeChannel = MethodChannel('baiji/native');

  Future<List<String>> _androidEngineCandidates() async {
    if (!Platform.isAndroid) return const <String>[];
    try {
      final dir = await _nativeChannel.invokeMethod<String>('nativeLibraryDir');
      if (dir == null || dir.isEmpty) return const <String>[];
      return <String>['$dir${Platform.pathSeparator}libffmpeg_exec.so'];
    } catch (e) {
      AppLog.w('TranscodePage', 'nativeLibraryDir 获取失败: $e');
      return const <String>[];
    }
  }

  /// 统一解析：手动指定 / BAIJI_FFMPEG → Android 内置引擎 → 随包 bin → PATH。
  Future<String?> _resolveFfmpeg() async => FfmpegLocator(
        extraCandidates: await _androidEngineCandidates(),
      ).resolve();

  Future<void> _probeFfmpeg() async {
    String? p;
    try {
      p = await _resolveFfmpeg();
    } catch (e) {
      AppLog.w('TranscodePage', 'ffmpeg 探测失败: $e');
    }
    if (!mounted) return;
    setState(() {
      _probing = false;
      _ffmpegPath = p;
      _engineCheck = null;
    });
    // 用户已手动填过路径时不要覆盖。
    if (p != null && _ffmpegController.text.trim().isEmpty) {
      _ffmpegController.text = p;
    }
    if (p != null) await _verifyEngine(p);
  }

  /// 真机自检：实际 execve 一次 `ffmpeg -version`。
  /// 「文件存在但系统不允许执行」（static-PIE / SELinux / 权限）会在这里
  /// 直接暴露，而不是转码到一半才报一句模糊的失败。
  Future<void> _verifyEngine(String path) async {
    String msg;
    try {
      final r = await Process.run(path, const ['-version']);
      final out = (r.stdout as String).trim();
      final err = (r.stderr as String).trim();
      if (r.exitCode == 0 && out.isNotEmpty) {
        msg = '自检通过 · ${out.split('\n').first.trim()}';
      } else {
        final detail = err.isNotEmpty ? err.split('\n').last : out;
        msg = '自检失败（退出码 ${r.exitCode}）'
            '${detail.isNotEmpty ? '：$detail' : ''}';
      }
    } catch (e) {
      msg = '自检失败（无法执行引擎）：$e';
    }
    AppLog.i('TranscodePage', '引擎自检: $msg');
    if (mounted) setState(() => _engineCheck = msg);
  }

  Future<void> _chooseFfmpeg() async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.any);
      final files = res?.files ?? [];
      if (files.isEmpty) return;
      final p = files.first.path;
      if (p == null || !await File(p).exists()) {
        _toast('所选文件不存在');
        return;
      }
      if (!mounted) return;
      setState(() => _ffmpegPath = p);
      _ffmpegController.text = p;
      _toast('已指定 ffmpeg：$p');
    } catch (e) {
      _toast('选择 ffmpeg 失败：$e');
    }
  }

  /// 返回本次可用的 ffmpeg 路径；找不到返回 null。
  /// 返回 null 不是致命错误：DTS/360RA/NAC 直出 WAV 走自研解码器不需要它。
  Future<String?> _ensureFfmpeg() async {
    final manual = _ffmpegController.text.trim();
    if (manual.isNotEmpty && await File(manual).exists()) return manual;
    final p = await _resolveFfmpeg();
    if (p != null && mounted) {
      setState(() => _ffmpegPath = p);
      _ffmpegController.text = p;
    }
    return p;
  }

  /// 用 ffprobe 取源文件时长，让进度条能显示百分比。
  /// ffprobe 优先取 ffmpeg 同目录，其次回退到 PATH；取不到就只显示已处理时长。
  Future<int?> _probeDurationMs(String file) async {
    final manual = _ffmpegController.text.trim();
    final ff = manual.isNotEmpty ? manual : _ffmpegPath;
    if (ff == null || ff.isEmpty) return null;
    final sep = Platform.pathSeparator;
    final probeName = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
    final beside = '${File(ff).parent.path}$sep$probeName';
    final exe = await File(beside).exists() ? beside : probeName;
    try {
      final r = await Process.run(exe, [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=nw=1:nk=1',
        file,
      ]);
      if (r.exitCode != 0) return null;
      final line = (r.stdout as String).trim().split('\n').first.trim();
      final d = double.tryParse(line);
      return d == null ? null : (d * 1000).round();
    } catch (_) {
      return null;
    }
  }

  /// DTS / 360RA / NAC 走 App 自研原生解码器直接产出 PCM WAV。
  Future<String?> _specialDecoder(
    SpecialFormat fmt,
    String src,
    String wav,
  ) async {
    switch (fmt) {
      case SpecialFormat.dts:
        return DtsMusic.decodeLocalToWav(src, wav);
      case SpecialFormat.ra360:
        return Ra360Music.decodeLocalToWav(src, wav);
      case SpecialFormat.nac:
        return NacMusic.decodeLocalToWav(src, wav);
      default:
        // AV3A / mp4 / ac3 / eac3 交给通用 ffmpeg 处理。
        return null;
    }
  }

  // ==================== 选文件 ====================

  /// 读文件头 32KB（文件较大时再拼尾部 32KB）：MP4 的 moov box 可能落在
  /// 文件尾，只嗅探头部会漏掉 dtsx / mha1 / av3a 这些 fourcc。
  Future<Uint8List> _readSniffBytes(String path) async {
    final f = File(path);
    final len = await f.length();
    const chunk = 32768;
    final headLen = len < chunk ? len : chunk;
    final head = Uint8List(headLen);
    final raf = await f.open();
    try {
      final nHead = await raf.readInto(head, 0, headLen);
      if (len > chunk * 2) {
        await raf.setPosition(len - chunk);
        final tail = Uint8List(chunk);
        final nTail = await raf.readInto(tail, 0, chunk);
        final out = Uint8List(nHead + nTail);
        out.setRange(0, nHead, head);
        out.setRange(nHead, nHead + nTail, tail);
        return out;
      }
      return Uint8List.sublistView(head, 0, nHead);
    } finally {
      await raf.close();
    }
  }

  bool _looksAudio(String path) {
    final l = path.toLowerCase();
    final dot = l.lastIndexOf('.');
    if (dot < 0) return false;
    return kSupportedInputExtensions.contains(l.substring(dot + 1));
  }

  /// 加入任务时顺便嗅探格式，让列表在「等待中」就能提示 wavOnly 锁定。
  Future<void> _addPaths(List<String> paths, {bool clearFirst = false}) async {
    final entries = <_Task>[];
    final existing = clearFirst ? <String>{} : _tasks.map((t) => t.inputPath).toSet();
    for (final p in paths) {
      if (existing.contains(p)) continue;
      Uint8List? head;
      SpecialFormat? sp;
      try {
        head = await _readSniffBytes(p);
        sp = detectSpecialFormat(p, head: head);
      } catch (_) {
        sp = detectSpecialFormat(p);
      }
      entries.add(_Task(p.split(Platform.pathSeparator).last, p)
        ..head = head
        ..special = sp);
    }
    if (!mounted) return;
    setState(() {
      if (clearFirst) _tasks.clear();
      _tasks.addAll(entries);
    });
  }

  Future<void> _pickFiles() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );
      final files = res?.files ?? [];
      if (files.isEmpty) return;
      final paths = <String>[];
      for (final f in files) {
        final p = f.path;
        if (p == null) continue;
        // 移动端 file_picker 给的是系统临时缓存，随时可能被回收，先复制到
        // CacheManager 受管子目录再读（与解密页一致）。
        if (Platform.isAndroid || Platform.isIOS) {
          final dir = await CacheManager.subDir(CacheManager.tempDirName);
          final real = '${dir.path}${Platform.pathSeparator}${f.name}';
          if (!await File(real).exists()) await File(p).copy(real);
          paths.add(real);
        } else {
          paths.add(p);
        }
      }
      if (paths.isEmpty) return;
      await _addPaths(paths);
    } catch (e) {
      _toast('选择文件失败：$e');
    }
  }

  Future<void> _pickFolder() async {
    try {
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null) return;
      final list = Directory(dir)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .map((f) => f.path)
          .where(_looksAudio)
          .toList();
      await _addPaths(list, clearFirst: true);
      if (mounted && _tasks.isEmpty) {
        _toast('该文件夹里没有找到支持的音频文件');
      }
    } catch (e) {
      _toast('选择文件夹失败：$e');
    }
  }

  Future<void> _chooseOutputDir() async {
    try {
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null || !mounted) return;
      if (!await _checkWritable(dir)) {
        _toast('所选目录不可写（Android 11+ 写公共目录需要「所有文件访问权限」）：\n$dir');
        return;
      }
      try {
        await KvStore.instance.setString(_kOutputMode, 'custom');
        await KvStore.instance.setString(_kOutputDir, dir);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _outputMode = 'custom';
        _outputDir = dir;
      });
      _toast('保存位置已设为：$dir');
    } catch (e) {
      _toast('选择目录失败：$e');
    }
  }

  /// 手动输入绝对路径：目录选择器在部分 Android 文件管理器上不可用时兜底。
  Future<void> _inputOutputDir() async {
    final controller = TextEditingController(text: _outputDir ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('输入保存目录'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '/storage/emulated/0/Music/白姬音乐',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty) return;
    if (!await _checkWritable(value)) {
      _toast('该目录不可写：$value');
      return;
    }
    try {
      await KvStore.instance.setString(_kOutputMode, 'custom');
      await KvStore.instance.setString(_kOutputDir, value);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _outputMode = 'custom';
      _outputDir = value;
    });
    _toast('保存位置已设为：$value');
  }

  // ==================== 转码 ====================

  Future<void> _start() async {
    if (_tasks.isEmpty) {
      _toast('请先添加要转码的文件');
      return;
    }
    final dir = _outputDir;
    if (dir == null || dir.isEmpty) {
      _toast('请先选择保存位置');
      return;
    }
    if (_busy) return;

    // ffmpeg 允许为 null：DTS/360RA/NAC 直出 WAV 走自研解码器不需要它；
    // 其余格式由 AudioTranscoder 在缺少引擎时给出精确的操作指引。
    final ffmpeg = await _ensureFfmpeg();

    final options = TranscodeOptions(
      format: _format,
      channels: _channels,
      sampleRate: _sampleRate,
      bitDepth: _bitDepth,
      bitrateKbps: _bitrateKbps,
    );
    final optErr = options.validate();
    if (optErr != null) {
      _toast(optErr);
      return;
    }

    // 写入预检：公共目录在 Android 11+ 未开「所有文件访问权限」时会被拒，
    // 这里提前拦下并给出可操作的指引，避免逐个任务都失败。
    if (!await _checkWritable(dir)) {
      _toast('保存位置不可写：$dir\n请在「保存位置」切换到应用目录，'
          '或开启「所有文件访问权限」后重试');
      return;
    }
    if (!mounted) return;

    final transcoder = AudioTranscoder(
      ffmpegPath: ffmpeg,
      specialDecoder: _specialDecoder,
      probeDurationMs: _probeDurationMs,
    );

    setState(() {
      _busy = true;
      _finished = 0;
      _cancelled = false;
      _transcoder = transcoder;
      for (final t in _tasks) {
        t
          ..running = false
          ..done = false
          ..error = null
          ..outputPath = null
          ..percent = null
          ..processedMs = 0
          ..totalMs = null;
      }
    });

    // 串行执行：ffmpeg 本身已吃满多核，并发只会让进度条乱跳、磁盘抢带宽。
    for (final t in _tasks) {
      if (!mounted || _cancelled) break;
      setState(() => t.running = true);
      try {
        final head = t.head ?? await _readSniffBytes(t.inputPath);
        t.special = detectSpecialFormat(t.inputPath, head: head);
        final res = await transcoder.transcode(
          inputPath: t.inputPath,
          outputDir: dir,
          options: options,
          head: head,
          onProgress: (p) {
            if (!mounted) return;
            setState(() {
              t.processedMs = p.processedMs;
              t.totalMs = p.totalMs;
              t.percent = p.percent;
            });
          },
          isCancelled: () => _cancelled,
        );
        t
          ..done = res.ok
          ..outputPath = res.outputPath
          ..error = res.ok ? null : res.error;
      } catch (e) {
        t.error = '$e';
      } finally {
        t.running = false;
        if (t.done && t.error == null) t.percent = 1.0;
        _finished++;
        if (mounted) setState(() {});
      }
    }

    if (!mounted) return;
    final ok = _tasks.where((t) => t.done && t.error == null).length;
    setState(() {
      _busy = false;
      _transcoder = null;
    });
    _toast(_cancelled
        ? '已取消，完成 $ok / ${_tasks.length}'
        : '完成 $ok / ${_tasks.length}');
  }

  void _cancel() {
    if (!_busy) return;
    setState(() => _cancelled = true);
    _transcoder?.cancel();
  }

  void _clear() {
    setState(() {
      _tasks.clear();
      _finished = 0;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    showAppSnack(msg);
  }

  // ==================== 参数提示 ====================

  String get _paramHint {
    if (_format.isAc3Family) {
      return 'AC-3 / E-AC-3 编码器仅支持 32 / 44.1 / 48 kHz 与最多 6 声道；'
          '越界参数会由 ffmpeg 明确报错，拿不准就用「保持源」。';
    }
    if (_format == TranscodeFormat.wma) {
      return 'WMA（wmav2）对采样率与码率有固定档位限制，'
          '建议使用「保持源」或 44100 Hz / 128 kbps。';
    }
    if (_format.supportsBitDepth) {
      return '位深只对 WAV / FLAC 生效：WAV 用 pcm_s16le / s24le / s32le，'
          'FLAC 用 s16 / s32（24bit 以 s32 + 有效位深标注）。';
    }
    return '有损格式由码率控制质量；设为「编码器默认」时由 ffmpeg 自行选择。';
  }

  @override
  Widget build(BuildContext context) {
    final total = _tasks.length;
    final body = ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
      children: [
        // ---------------- 使用说明 ----------------
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 16, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Text(
                    '使用说明',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '• 依赖完整版 ffmpeg 可执行文件：播放内核内嵌的是纯解码 ffmpeg，'
                '没有编码器 / 复用器，无法产出文件。Android 安装包已内置裁剪版'
                '动态 PIE ffmpeg 引擎（含编码器 / 封装器），开箱即用；「转码引擎」'
                '卡片会显示自检结果。桌面端通常直接命中系统 PATH，也可手动指定'
                '或设置 BAIJI_FFMPEG。\n'
                '• 保存位置可切换「应用目录 / 公共音乐 / 自定义」并记住选择；'
                '公共目录需要「所有文件访问权限」，切换时会做写入预检。'
                '完成后任务项显示完整输出路径，可复制。\n'
                '• DTS:X、360RA、NAC 直出 WAV 走 App 自研解码器，无需转码引擎；'
                '仅在自定义声道 / 采样率 / 位深时才需要 ffmpeg。\n'
                '• 输出支持 WAV / FLAC / M4A / MP4 / WMA / AAC / AC-3 / E-AC-3 / '
                'MP3 / OGG，可自定义声道数、采样率、位深与码率。\n'
                '• DTS:X、360RA、NAC、AV3A 只能输出 WAV：前三者走 App 自研解码器，'
                'AV3A 由 ffmpeg 解码；选择其它格式会自动锁定为 WAV。\n'
                '• mp4、ac3、eac3 等 ffmpeg 可解的格式既可作输入也可作输出；'
                '同名文件自动追加序号，不覆盖已有产物。\n'
                '• 仅处理你自己合法拥有的文件，请遵守各平台使用条款。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // ---------------- 转码引擎 ----------------
        SectionHeader(title: '转码引擎', icon: Icons.memory_rounded),
        GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _ffmpegPath != null
                        ? Icons.check_circle_outline_rounded
                        : Icons.error_outline_rounded,
                    size: 18,
                    color: _ffmpegPath != null
                        ? AppColors.success
                        : AppColors.danger,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _probing
                          ? '正在探测转码引擎…'
                          : (_ffmpegPath != null
                              ? '转码引擎已就绪'
                              : (Platform.isAndroid
                                  ? '未找到转码引擎（可手动指定）；'
                                      'DTS/360RA/NAC 直出 WAV 仍可用'
                                  : '未找到 ffmpeg，请手动指定')),
                      style: TextStyle(
                          fontSize: 13, color: AppColors.textPrimary),
                    ),
                  ),
                  MiuixTextButton(
                    '重新探测',
                    onPressed: () {
                      setState(() => _probing = true);
                      _probeFfmpeg();
                    },
                    textStyle:
                        TextStyle(color: AppColors.accent, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              MiuixTextField(
                controller: _ffmpegController,
                label: 'ffmpeg 可执行文件路径（留空自动探测）',
                useLabelAsPlaceholder: true,
                singleLine: true,
              ),
              const SizedBox(height: 10),
              _MiniButton(
                icon: Icons.file_open_outlined,
                label: '手动选择 ffmpeg',
                onTap: _busy ? null : _chooseFfmpeg,
              ),
              const SizedBox(height: 8),
              Text(
                '探测顺序：输入框 / 环境变量 BAIJI_FFMPEG → Android 内置引擎 → '
                '随包内置 bin → 系统 PATH。',
                style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
              ),
              if (_engineCheck != null) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _engineCheck!.contains('通过')
                          ? Icons.check_circle_outline_rounded
                          : Icons.warning_amber_rounded,
                      size: 14,
                      color: _engineCheck!.contains('通过')
                          ? AppColors.success
                          : AppColors.danger,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _engineCheck!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: _engineCheck!.contains('通过')
                              ? AppColors.textSecondary
                              : AppColors.danger,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),

        // ---------------- 转码参数 ----------------
        SectionHeader(title: '转码参数', icon: Icons.tune_rounded),
        GlassCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              _DropdownRow<TranscodeFormat>(
                title: '输出格式',
                hint: '目标容器 / 编码',
                value: _format,
                items: TranscodeFormat.values,
                labelOf: (v) => v.label,
                onChanged: (v) => setState(() => _format = v),
              ),
              MiuixHorizontalDivider(
                  thickness: 1, color: AppColors.strokeGlass),
              _DropdownRow<int>(
                title: '声道数',
                hint: '0 = 保持源文件',
                value: _channels,
                items: const [0, 1, 2, 4, 6, 8],
                labelOf: _channelLabel,
                onChanged: (v) => setState(() => _channels = v),
              ),
              MiuixHorizontalDivider(
                  thickness: 1, color: AppColors.strokeGlass),
              _DropdownRow<int>(
                title: '采样率',
                hint: '0 = 保持源文件',
                value: _sampleRate,
                items: const [
                  0, 32000, 44100, 48000, 88200, 96000, 176400, 192000,
                  352800, 384000,
                ],
                labelOf: _rateLabel,
                onChanged: (v) => setState(() => _sampleRate = v),
              ),
              MiuixHorizontalDivider(
                  thickness: 1, color: AppColors.strokeGlass),
              _DropdownRow<int>(
                title: '位深',
                hint: _format.supportsBitDepth ? '仅 WAV / FLAC 可设' : '当前格式不适用',
                value: _bitDepth,
                items: const [16, 24, 32],
                labelOf: (v) => '$v bit',
                enabled: _format.supportsBitDepth,
                onChanged: (v) => setState(() => _bitDepth = v),
              ),
              MiuixHorizontalDivider(
                  thickness: 1, color: AppColors.strokeGlass),
              _DropdownRow<int>(
                title: '码率',
                hint: _format.isLossless ? '无损格式无需码率' : '0 = 编码器默认',
                value: _bitrateKbps,
                items: const [0, 96, 128, 192, 256, 320, 512, 640, 960, 1411],
                labelOf: _bitrateLabel,
                enabled: !_format.isLossless,
                onChanged: (v) => setState(() => _bitrateKbps = v),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: Text(
                  _paramHint,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // ---------------- 待转码文件 ----------------
        SectionHeader(
          title: '待转码文件',
          trailing: total == 0
              ? null
              : MiuixTextButton(
                  '清空',
                  onPressed: _busy ? null : _clear,
                  textStyle: const TextStyle(fontSize: 12),
                ),
        ),
        Row(
          children: [
            Expanded(
              child: _MiniButton(
                icon: Icons.note_add_outlined,
                label: '选择文件',
                onTap: _busy ? null : _pickFiles,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _MiniButton(
                icon: Icons.folder_open_outlined,
                label: '选择文件夹',
                onTap: _busy ? null : _pickFolder,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_tasks.isEmpty)
          GlassCard(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 26),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.queue_music_outlined,
                        size: 34, color: AppColors.textTertiary),
                    const SizedBox(height: 10),
                    Text(
                      '还没有添加文件',
                      style: TextStyle(
                          fontSize: 13, color: AppColors.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [for (final t in _tasks) _TaskTile(task: t)],
            ),
          ),
        const SizedBox(height: 18),

        // ---------------- 保存位置 ----------------
        const SectionHeader(title: '保存位置'),
        GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _OutputModeChip(
                      label: '应用目录',
                      selected: _outputMode == 'app',
                      onTap: _busy ? null : () => _applyOutputMode('app'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _OutputModeChip(
                      label: '公共音乐',
                      selected: _outputMode == 'public',
                      onTap: _busy ? null : () => _applyOutputMode('public'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _OutputModeChip(
                      label: '自定义',
                      selected: _outputMode == 'custom',
                      onTap: _busy ? null : () => _applyOutputMode('custom'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.folder_open_outlined,
                      size: 16, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _outputDir ?? '未选择',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5, color: AppColors.textSecondary),
                    ),
                  ),
                  MiuixTextButton(
                    '复制',
                    onPressed: _outputDir == null
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: _outputDir!));
                            _toast('已复制保存位置');
                          },
                    textStyle: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _MiniButton(
                      icon: Icons.folder_open_outlined,
                      label: '选择文件夹',
                      onTap: _busy ? null : _chooseOutputDir,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MiniButton(
                      icon: Icons.edit_outlined,
                      label: '手动输入路径',
                      onTap: _busy ? null : _inputOutputDir,
                    ),
                  ),
                ],
              ),
              if (Platform.isAndroid) ...[
                const SizedBox(height: 8),
                Text(
                  '公共目录需「所有文件访问权限」；应用目录无需权限但不易在文件管理器中看到。'
                  '选择会记住，下次打开自动沿用，转码完成后任务项会显示完整路径。',
                  style: TextStyle(
                      fontSize: 10.5,
                      height: 1.5,
                      color: AppColors.textTertiary),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    return PageScaffold(
      title: '音频转码',
      snackbarHost: appSnackbarHostState,
      contentPadding: EdgeInsets.zero,
      floatingActionButton: _busy
          ? MiuixFloatingActionButton(
              onPressed: _cancel,
              containerColor: AppColors.danger,
              child: MiuixContentColor(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.stop_rounded),
                      const SizedBox(width: 6),
                      Text('停止 $_finished/$total'),
                    ],
                  ),
                ),
              ),
            )
          : MiuixFloatingActionButton(
              onPressed: _start,
              containerColor: AppColors.accent,
              child: MiuixContentColor(
                color: Colors.black,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 18),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.play_arrow_rounded),
                      SizedBox(width: 6),
                      Text('开始转码'),
                    ],
                  ),
                ),
              ),
            ),
      child: body,
    );
  }
}

// ==================== 参数标签 ====================

String _channelLabel(int v) => switch (v) {
      0 => '保持源',
      1 => '单声道 (1)',
      2 => '立体声 (2)',
      4 => '4.0 (4)',
      6 => '5.1 (6)',
      8 => '7.1 (8)',
      _ => '$v 声道',
    };

String _rateLabel(int v) => v == 0 ? '保持源' : '$v Hz';

String _bitrateLabel(int v) => v == 0 ? '编码器默认' : '$v kbps';

String _fmtDuration(int ms) {
  final s = ms ~/ 1000;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:'
      '${(s % 60).toString().padLeft(2, '0')}';
}

// ==================== 组件 ====================

/// 参数下拉行：左标题 + 说明，右侧固定宽度的下拉框。
class _DropdownRow<T> extends StatelessWidget {
  const _DropdownRow({
    required this.title,
    required this.hint,
    required this.value,
    required this.items,
    required this.labelOf,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final String hint;
  final T value;
  final List<T> items;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: enabled
                        ? AppColors.textPrimary
                        : AppColors.textTertiary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10.5, color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppColors.bg2.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.strokeGlass),
              ),
              child: DropdownButton<T>(
                value: value,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                dropdownColor: AppColors.bg2,
                icon: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: enabled
                      ? AppColors.accent
                      : AppColors.textTertiary,
                ),
                style: TextStyle(
                  fontSize: 13,
                  color: enabled
                      ? AppColors.textPrimary
                      : AppColors.textTertiary,
                ),
                items: [
                  for (final v in items)
                    DropdownMenuItem<T>(
                      value: v,
                      child: Text(
                        labelOf(v),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: enabled
                    ? (v) {
                        if (v != null) onChanged(v);
                      }
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task});
  final _Task task;

  @override
  Widget build(BuildContext context) {
    final name = task.name;
    const maxLen = 42;
    final shown = name.length <= maxLen
        ? name
        : '${name.substring(0, maxLen - 10)}…${name.substring(name.length - 9)}';

    Color statusColor;
    String statusText;
    if (task.running) {
      statusColor = AppColors.accent;
      final p = task.percent;
      statusText = p != null
          ? '转码中 ${(p * 100).clamp(0, 100).toStringAsFixed(0)}% · '
              '${_fmtDuration(task.processedMs)}'
          : '转码中 · 已处理 ${_fmtDuration(task.processedMs)}';
    } else if (task.error != null) {
      statusColor = AppColors.danger;
      statusText = task.error!;
    } else if (task.done) {
      statusColor = AppColors.success;
      final f = task.outputPath;
      final outName = f == null ? '' : f.split(Platform.pathSeparator).last;
      statusText = outName.isEmpty ? '完成' : '完成 · $outName';
    } else {
      statusColor = AppColors.textTertiary;
      final sp = task.special;
      statusText = (sp != null && sp.wavOnly)
          ? '等待中 · ${sp.label} → 仅 WAV'
          : '等待中';
    }

    final showBar = task.running && task.percent != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: task.running
                    ? const MiuixCircularProgressIndicator(
                        size: 18, strokeWidth: 2)
                    : Icon(
                        task.error != null
                            ? Icons.error_outline_rounded
                            : (task.done
                                ? Icons.check_circle_outline_rounded
                                : Icons.music_note_outlined),
                        size: 17,
                        color: statusColor,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shown,
                      style: TextStyle(
                          fontSize: 12.5, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      statusText,
                      maxLines: task.error != null ? 4 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: statusColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // 完成后给出完整输出路径，可直接复制，避免「转完了找不到文件」。
          if (task.done && task.outputPath != null) ...[
            const SizedBox(height: 5),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    task.outputPath!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10, color: AppColors.textTertiary),
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => Clipboard.setData(
                      ClipboardData(text: task.outputPath!)),
                  child: Icon(Icons.copy_all_outlined,
                      size: 14, color: AppColors.textTertiary),
                ),
              ],
            ),
          ],
          if (showBar) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: task.percent,
                minHeight: 4,
                backgroundColor: AppColors.strokeGlass,
                color: AppColors.accent,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 保存位置模式切换 chip。
class _OutputModeChip extends StatelessWidget {
  const _OutputModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => MiuixPressable(
        onPressed: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accent.withValues(alpha: 0.14)
                : AppColors.strokeGlass,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? AppColors.accent : AppColors.textSecondary,
              ),
            ),
          ),
        ),
      );
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return GlassCard(
      onTap: onTap,
      radius: 16,
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon,
              size: 17,
              color: disabled ? AppColors.textTertiary : AppColors.accent),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: disabled ? AppColors.textTertiary : AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
