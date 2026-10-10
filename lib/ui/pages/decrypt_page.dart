/// 本地音乐解密页。
///
/// 三块功能：选文件 → 选/填密钥 → 批量解密。
///
/// 密钥来源的优先级（在 [decryptor.dart] 里实现）：
/// 1. 文件尾部自带的 ekey（QQ 音乐 QTag / PC v1）——什么都不用填；
/// 2. 密钥库里按 mid / 文件名匹配到的 ekey；
/// 3. 用户在密钥管理里手动填的那条。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../decrypt/decryptor.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'decrypt_keys_page.dart';

/// 单个任务的进度。
class _Task {
  _Task(this.name, this.inputPath);
  final String inputPath;
  final String name;
  DecryptPlatform? platform;
  bool running = false;
  bool done = false;
  String? error;
  String? outputPath;
}

class DecryptPage extends StatefulWidget {
  const DecryptPage({super.key});

  @override
  State<DecryptPage> createState() => _DecryptPageState();
}

class _DecryptPageState extends State<DecryptPage> {
  final List<_Task> _tasks = [];

  /// 已勾选的密钥条目（值为 ekey / fileKey）。
  final List<String> _selectedKeys = [];

  String? _outputDir;
  bool _busy = false;
  bool _cancelled = false;
  int _finished = 0;

  @override
  void initState() {
    super.initState();
    _loadDefaultOutputDir();
    _loadKeys();
  }

  Future<void> _loadDefaultOutputDir() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      setState(() => _outputDir = '${dir.path}${Platform.pathSeparator}解密音乐');
    } catch (_) {/* 取不到就让用户手动选 */}
  }

  Future<void> _loadKeys() async {
    final keys = await loadDecryptKeys();
    if (!mounted) return;
    setState(() {
      _selectedKeys
        ..clear()
        ..addAll(keys);
    });
  }

  // ==================== 选文件 ====================

  Future<void> _pickFiles() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );
      if (res == null || res.files.isEmpty) return;

      final paths = <String>[];
      for (final f in res.files) {
        final p = f.path;
        if (p == null) continue;
        // file_picker 在部分平台给的是临时缓存路径，移动端要自己落到持久目录
        if (Platform.isAndroid || Platform.isIOS) {
          final cacheDir = (await getTemporaryDirectory()).path;
          final real = '$cacheDir/${f.name}';
          if (!await File(real).exists()) {
            await File(p).copy(real);
          }
          paths.add(real);
        } else {
          paths.add(p);
        }
      }
      if (paths.isEmpty) return;

      setState(() {
        for (final p in paths) {
          if (_tasks.any((t) => t.inputPath == p)) continue;
          _tasks.add(_Task(p.split(Platform.pathSeparator).last, p));
        }
      });
    } catch (e) {
      _toast('选择文件失败：$e');
    }
  }

  Future<void> _pickFolder() async {
    try {
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null || !mounted) return;
      setState(() {
        _tasks.clear();
        final list = Directory(dir)
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .map((f) => f.path)
            .where(_looksEncrypted)
            .toList();
        for (final p in list) {
          _tasks.add(_Task(p.split(Platform.pathSeparator).last, p));
        }
      });
      if (_tasks.isEmpty) _toast('该文件夹里没有找到已加密的音频文件');
    } catch (e) {
      _toast('选择文件夹失败：$e');
    }
  }

  /// 粗筛：按扩展名挑出可能加密的文件。
  bool _looksEncrypted(String path) {
    final p = path.toLowerCase();
    const exts = [
      '.qmcflac', '.mflac', '.kgm', '.vpr', '.kwm', '.ncm', '.3d', '.3da',
    ];
    return exts.any(p.endsWith);
  }

  // ==================== 输出目录 ====================

  Future<void> _chooseOutputDir() async {
    try {
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null || !mounted) return;
      setState(() => _outputDir = dir);
    } catch (e) {
      _toast('选择目录失败：$e');
    }
  }

  // ==================== 解密 ====================

  /// 同时跑几个解密任务。
  ///
  /// 解密是 CPU + 磁盘双瓶颈：纯 CPU 的 AES/RC4 段靠多核并行，
  /// 大文件 I/O 段则会被磁盘带宽卡住。所以并发数取「核数」和「任务数」
  /// 的较小值，最多4个——再多只会让进度条乱跳。
  int get _concurrency {
    final cores = Platform.numberOfProcessors;
    final n = cores <= 2 ? 1 : (cores >= 8 ? 4 : cores - 1);
    return n.clamp(1, _tasks.length);
  }

  Future<void> _start() async {
    if (_tasks.isEmpty) {
      _toast('请先添加要解密的文件');
      return;
    }
    final dir = _outputDir;
    if (dir == null || dir.isEmpty) {
      _toast('请先选择保存位置');
      return;
    }
    if (_busy) return;

    // 目标目录不存在要先建，否则第一个任务会直接失败。
    try {
      final d = Directory(dir);
      if (!await d.exists()) await d.create(recursive: true);
    } catch (e) {
      _toast('无法创建保存目录：$e');
      return;
    }

    setState(() {
      _busy = true;
      _finished = 0;
      _cancelled = false;
      for (final t in _tasks) {
        t
          ..running = false
          ..done = false
          ..error = null
          ..outputPath = null;
      }
    });

    // 密钥在主 isolate 读一次，序列化成纯字符串列表传给 worker，
    // 避免 Isolate 之间传可变对象。
    final keys = _selectedKeys.toList(growable: false);

    // 同名输出会互相覆盖，这里给重名的加上序号。
    final used = <String>{};
    final plans = <_Task, String>{};
    for (final t in _tasks) {
      var name = buildOutputName(t.inputPath);
      if (!used.add(name)) {
        final dot = name.lastIndexOf('.');
        final stem = dot > 0 ? name.substring(0, dot) : name;
        final ext = dot > 0 ? name.substring(dot) : '';
        var i = 2;
        while (!used.add('$stem($i)$ext')) {
          i++;
        }
        name = '$stem($i)$ext';
      }
      plans[t] = '$dir${Platform.pathSeparator}$name';
    }

    // 固定 worker 数量的任务池：每个 worker 串行跑自己那份，
    // worker 之间真并行（各自独立 Isolate）。
    final queue = List<_Task>.from(_tasks);
    final workers = List<Future<void>>.generate(
      _concurrency,
      (w) async {
        while (true) {
          if (!mounted || _cancelled) return;
          if (queue.isEmpty) return;
          final task = queue.removeAt(0);
          setState(() => task.running = true);

          try {
            final res = await Isolate.run(() => _decryptOne(
                  inputPath: task.inputPath,
                  outputPath: plans[task]!,
                  keys: keys,
                ));
            task
              ..platform = res.platform
              ..outputPath = res.outputPath
              ..done = true;
          } catch (e) {
            task.error = e is DecryptFailure ? e.message : '$e';
          } finally {
            task.running = false;
            _finished++;
          }
          if (mounted) setState(() {});
        }
      },
    );

    await Future.wait(workers);

    if (!mounted) return;
    final ok = _finished - _tasks.where((t) => t.error != null).length;
    setState(() => _busy = false);
    _toast(_cancelled
        ? '已取消，完成 $ok / ${_tasks.length}'
        : '完成 $ok / ${_tasks.length}');
  }

  /// 中断当前批次（已解出的文件保留）。
  void _cancel() {
    if (!_busy) return;
    setState(() => _cancelled = true);
  }

  void _clear() {
    setState(() {
      _tasks.clear();
      _finished = 0;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final total = _tasks.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地音乐解密'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
        children: [
          // 说明
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Row(
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 16, color: AppColors.cyan),
                    SizedBox(width: 8),
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
                SizedBox(height: 8),
                Text(
                  '• QQ 音乐、酷狗 v5、酷我 v2 需要密钥才能解；'
                  '其余格式无需密钥。\n'
                  '• 密钥可在「密钥管理」里从客户端数据库导入，或直接手动填写。\n'
                  '• 支持整文件夹批量导入，会自动并发解密。\n'
                  '• 解密只处理你自己合法拥有的文件，请遵守各平台的使用条款。',
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

          // 密钥
          SectionHeader(
            title: '密钥',
            trailing: TextButton.icon(
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const DecryptKeysPage(),
                ));
                await _loadKeys();
              },
              icon: const Icon(Icons.key_rounded, size: 16),
              label: const Text('密钥管理'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.cyan,
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(
                  _selectedKeys.isEmpty
                      ? Icons.key_off_rounded
                      : Icons.key_rounded,
                  size: 18,
                  color: _selectedKeys.isEmpty
                      ? AppColors.textTertiary
                      : AppColors.cyan,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _selectedKeys.isEmpty
                        ? '未设置密钥（部分格式无法解密）'
                        : '已加载 ${_selectedKeys.length} 条密钥',
                    style: TextStyle(
                      fontSize: 13,
                      color: _selectedKeys.isEmpty
                          ? AppColors.textTertiary
                          : AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // 文件
          SectionHeader(
            title: '待解密文件',
            trailing: total == 0
                ? null
                : TextButton(
                    onPressed: _busy ? null : _clear,
                    child: const Text('清空',
                        style: TextStyle(fontSize: 12)),
                  ),
          ),
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  icon: Icons.note_add_outlined,
                  label: '选择文件',
                  onTap: _busy ? null : _pickFiles,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionButton(
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
                    children: const [
                      Icon(Icons.queue_music_outlined,
                          size: 34, color: AppColors.textTertiary),
                      SizedBox(height: 10),
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
                children: [
                  for (final t in _tasks) _TaskTile(task: t),
                ],
              ),
            ),
          const SizedBox(height: 18),

          // 输出位置
          const SectionHeader(title: '保存位置'),
          GlassCard(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.save_alt_rounded,
                  size: 20, color: AppColors.cyan),
              title: Text(
                _outputDir ?? '未选择',
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary),
              ),
              trailing: const Icon(Icons.edit_outlined, size: 17),
              onTap: _busy ? null : _chooseOutputDir,
            ),
          ),
        ],
      ),
      floatingActionButton: _busy
          ? FloatingActionButton.extended(
              onPressed: _cancel,
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.stop_rounded),
              label: Text('停止 $_finished/$total'),
            )
          : FloatingActionButton.extended(
              onPressed: _start,
              backgroundColor: AppColors.cyan,
              foregroundColor: Colors.black,
              icon: const Icon(Icons.lock_open_rounded),
              label: const Text('开始解密'),
            ),
    );
  }
}

/// 在 worker isolate 里跑单文件解密。
///
/// 只传可跨 isolate 传输的原始数据（路径、字节、字符串列表）。
Future<DecryptResult> _decryptOne({
  required String inputPath,
  required String outputPath,
  required List<String> keys,
}) async {
  final file = File(inputPath);
  final headLen = await file.length();
  // 头部要够NCM / KGM / KWM / 咪咕 各自解析；咪咕猜密钥需要 0x100。
  final headSize = headLen < 0x2000 ? headLen : 0x2000;
  final head = await _readRange(file, 0, headSize);

  Uint8List? tail;
  // QQ 音乐的 footer 在文件尾，需要单独读 1 KiB。
  if (_looksQmc(inputPath)) {
    final tailSize = headLen < 1024 ? headLen : 1024;
    tail = await _readRange(file, headLen - tailSize, tailSize);
  }

  return decryptFile(
    inputPath: inputPath,
    outputPath: outputPath,
    head: head,
    tail: tail,
    keyResolver: keys.isEmpty ? null : () => keys.first,
  );
}

bool _looksQmc(String p) {
  final l = p.toLowerCase();
  return l.endsWith('.qmcflac') || l.endsWith('.mflac');
}

Future<Uint8List> _readRange(File f, int start, int length) async {
  final raf = await f.open();
  try {
    final buf = Uint8List(length);
    await raf.setPosition(start);
    final read = await raf.readInto(buf, 0, length);
    return Uint8List.sublistView(buf, 0, read);
  } finally {
    await raf.close();
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task});
  final _Task task;

  @override
  Widget build(BuildContext context) {
    final name = task.name;
    final maxLen = 42;
    final shown = name.length <= maxLen
        ? name
        //文件名可能很长，中间省略并保留扩展名——扩展名决定格式，用户必须看得见
        : '${name.substring(0, maxLen - 10)}…${name.substring(name.length - 9)}';

    Color statusColor;
    String statusText;
    if (task.running) {
      statusColor = AppColors.cyan;
      statusText = '解密中';
    } else if (task.error != null) {
      statusColor = const Color(0xFFFF6B6B);
      statusText = task.error!;
    } else if (task.done) {
      statusColor = const Color(0xFF4ADE80);
      statusText = '完成 · ${task.platform?.label ?? ''}';
    } else {
      statusColor = AppColors.textTertiary;
      statusText = '等待中';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: task.running
                ? const CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.cyan)
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
                  style: const TextStyle(
                      fontSize: 12.5, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: statusColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
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
              color: disabled ? AppColors.textTertiary : AppColors.cyan),
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
