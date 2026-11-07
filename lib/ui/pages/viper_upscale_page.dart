/// 本地升频（蝰蛇母带）工具页（v2.5.2）。
///
/// 把本地任意音频离线升频成 96k/192k 24-bit WAV。与播放链路共用
/// [ViperUpscaler]：ffmpeg 解码 → 纯 Dart STFT/SBR 升频 → 24bit WAV。
/// 页面如实标注算法来源与「高频为感知重建」的边界，不冒充官方母带。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../theme/app_theme.dart';
import '../../viper/viper_super_resolution.dart';
import '../../viper/viper_upscaler.dart';
import '../widgets/app_widgets.dart';

class ViperUpscalePage extends StatefulWidget {
  const ViperUpscalePage({super.key});

  @override
  State<ViperUpscalePage> createState() => _ViperUpscalePageState();
}

class _ViperUpscalePageState extends State<ViperUpscalePage> {
  String _inputPath = '';
  String _outputDir = '';
  ViperUpscaleRate _rate = ViperUpscaleRate.khz192;
  bool _tapeEnhance = true;
  bool _busy = false;
  bool _cancelled = false;
  bool _probing = true;
  double _percent = 0;
  String? _ffmpegPath;
  ViperUpscaleResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final exe = await ViperUpscaler.resolveFfmpeg();
    Directory dir;
    try {
      final base = await getApplicationDocumentsDirectory();
      dir = Directory('${base.path}${Platform.pathSeparator}viper_upscale');
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (_) {
      dir = Directory.systemTemp;
    }
    if (!mounted) return;
    setState(() {
      _ffmpegPath = exe;
      _outputDir = dir.path;
      _probing = false;
    });
  }

  Future<void> _pickFile() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>[
        'mp3', 'flac', 'wav', 'm4a', 'aac', 'ogg', 'opus', 'wma', 'ape', 'mp4',
      ],
    );
    final p = picked?.files.single.path;
    if (p == null || p.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _inputPath = p;
      _result = null;
      _error = null;
      _percent = 0;
    });
  }

  String _outputPathFor(String input) {
    final name = File(input).uri.pathSegments.last;
    final stem = name.contains('.')
        ? name.substring(0, name.lastIndexOf('.'))
        : name;
    final tag = _rate == ViperUpscaleRate.khz192 ? '192k' : '96k';
    var out = '$_outputDir${Platform.pathSeparator}${stem}_$tag.wav';
    var i = 1;
    while (File(out).existsSync()) {
      out = '$_outputDir${Platform.pathSeparator}${stem}_${tag}_$i.wav';
      i++;
    }
    return out;
  }

  Future<void> _start() async {
    if (_inputPath.isEmpty) {
      setState(() => _error = '请先选择要升频的音频文件');
      return;
    }
    if (_ffmpegPath == null && !_inputPath.toLowerCase().endsWith('.wav')) {
      setState(() => _error = '未找到 ffmpeg 引擎，无法解码该格式。'
          '桌面端请安装 ffmpeg 或改用 WAV 输入；Android 安装包已内置引擎。');
      return;
    }
    final out = _outputPathFor(_inputPath);
    setState(() {
      _busy = true;
      _cancelled = false;
      _percent = 0;
      _result = null;
      _error = null;
    });
    try {
      final res = await ViperUpscaler.upscaleFile(
        inputPath: _inputPath,
        outputPath: out,
        rate: _rate,
        tapeEnhance: _tapeEnhance,
        ffmpegPath: _ffmpegPath,
        onProgress: (p) {
          if (mounted) setState(() => _percent = p);
        },
        isCancelled: () => _cancelled,
      );
      if (!mounted) return;
      setState(() {
        _result = res;
        _percent = 1;
        _busy = false;
      });
    } on ViperCancelled catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '已取消';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '升频失败：$e';
      });
    }
  }

  void _cancel() => setState(() => _cancelled = true);

  static String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final inputName = _inputPath.isEmpty
        ? '未选择'
        : File(_inputPath).uri.pathSegments.last;
    return PageScaffold(
      title: '本地升频 · 蝰蛇母带',
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      floatingActionButton: MiuixFloatingActionButton(
        onPressed: _busy ? _cancel : _start,
        containerColor: _busy ? AppColors.danger : AppColors.accent,
        child: MiuixContentColor(
          color: _busy ? Colors.white : Colors.black,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_busy ? Icons.stop_rounded : Icons.auto_awesome_rounded),
                const SizedBox(width: 6),
                Text(_busy ? '停止' : '开始升频'),
              ],
            ),
          ),
        ),
      ),
      child: ListView(
        children: [
          SectionHeader(
              title: '这是什么', icon: Icons.info_outline_rounded),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Text(
              '${ViperSuperResolution.algorithmNote}\n\n'
              '酷狗官方「蝰蛇母带 / 至臻母带」带「AI升频」标记：服务端只下发 '
              '320k 源文件，端侧用 STFT + DNN 超分重建到 192kHz/24bit。'
              '本工具按相同骨架用公开算法实现，生成的 24 kHz 以上高频是'
              '**依据低频信号重建的感知近似**，并非原始录音中真实存在的信息；'
              '官方 DNN 模型权重是闭源且绑定天玑 NPU，无法移植。',
              style: TextStyle(
                  fontSize: 12, height: 1.6, color: AppColors.textTertiary),
            ),
          ),
          const SizedBox(height: 20),

          SectionHeader(title: '输入与参数', icon: Icons.tune_rounded),
          GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                MiuixArrowPreference(
                  title: '选择音频文件',
                  summary: inputName,
                  startAction: Icon(Icons.audio_file_rounded,
                      color: AppColors.accent, size: 22),
                  onClick: _busy ? null : _pickFile,
                ),
                const MiuixHorizontalDivider(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.graphic_eq_rounded,
                          color: AppColors.violet, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text('目标规格',
                            style: TextStyle(
                                fontSize: 14,
                                color: AppColors.textPrimary)),
                      ),
                      DropdownButton<ViperUpscaleRate>(
                        value: _rate,
                        underline: const SizedBox.shrink(),
                        items: ViperUpscaleRate.values
                            .map((r) => DropdownMenuItem<ViperUpscaleRate>(
                                  value: r,
                                  child: Text(r.label,
                                      style: const TextStyle(fontSize: 13)),
                                ))
                            .toList(),
                        onChanged: _busy
                            ? null
                            : (v) {
                                if (v != null) setState(() => _rate = v);
                              },
                      ),
                    ],
                  ),
                ),
                const MiuixHorizontalDivider(),
                MiuixSwitchPreference(
                  title: '声音焕新',
                  summary: '轻度频响 tilt + 动态处理（对应官方「声音焕新引擎」思路）',
                  startAction: Icon(Icons.auto_fix_high_rounded,
                      color: AppColors.accentAlt, size: 22),
                  value: _tapeEnhance,
                  onChanged: (v) {
                    if (!_busy) setState(() => _tapeEnhance = v);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '输出到：$_outputDir\n'
              '192 kHz / 24 bit / 立体声 WAV 体积约为 1.15 MB/秒'
              '（4 分钟歌曲约 276 MB），请留意磁盘空间。'
              '播放页选「蝰蛇母带」时会自动走同一引擎并缓存结果。',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
          ),
          const SizedBox(height: 20),

          SectionHeader(title: '引擎状态', icon: Icons.memory_rounded),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(
                  _probing
                      ? Icons.hourglass_top_rounded
                      : (_ffmpegPath != null
                          ? Icons.check_circle_outline_rounded
                          : Icons.warning_amber_rounded),
                  size: 18,
                  color: _probing
                      ? AppColors.textTertiary
                      : (_ffmpegPath != null
                          ? AppColors.success
                          : AppColors.danger),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _probing
                        ? '正在探测 ffmpeg 引擎…'
                        : (_ffmpegPath != null
                            ? 'ffmpeg 已就绪：$_ffmpegPath'
                            : '未找到 ffmpeg：仅 WAV 输入可用（桌面端请安装 ffmpeg）'),
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          if (_busy || _percent > 0)
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _busy
                        ? '升频中… ${(_percent * 100).toStringAsFixed(0)}%'
                        : '完成',
                    style: TextStyle(
                        fontSize: 13, color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(value: _percent),
                  const SizedBox(height: 8),
                  Text(
                    '取消在当前解码/升频阶段结束后生效；一首 4 分钟歌曲'
                    '首次转换通常需数十秒，结果会缓存，重复播放不再转换。',
                    style: TextStyle(
                        fontSize: 11, color: AppColors.textTertiary),
                  ),
                ],
              ),
            ),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(_error!,
                  style: TextStyle(fontSize: 13, color: AppColors.danger)),
            ),

          if (_result != null) _buildResult(_result!),
        ],
      ),
    );
  }

  Widget _buildResult(ViperUpscaleResult r) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
              title: '转换结果', icon: Icons.check_circle_outline_rounded),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${r.sampleRate} Hz / ${r.bitDepth} bit / ${r.channels} 声道 · '
                  '${r.durationSeconds.toStringAsFixed(2)} 秒',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary),
                ),
                const SizedBox(height: 6),
                Text('文件：${r.wavPath}',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textTertiary)),
                Text('体积：${_fmtBytes(r.bytes)} · 用时 ${r.elapsed}',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textTertiary)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                            ClipboardData(text: r.wavPath));
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('路径已复制')),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text('复制路径'),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: () => Share.shareXFiles(
                          <XFile>[XFile(r.wavPath)],
                          subject: '本地升频 192kHz/24bit WAV'),
                      icon: const Icon(Icons.ios_share_rounded, size: 16),
                      label: const Text('分享文件'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
