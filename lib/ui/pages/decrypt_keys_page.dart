/// 解密密钥管理页。
///
/// 支持三条录入路径：
/// 1. **手动填写**——直接粘贴 ekey / fileKey（最常用）；
/// 2. **导入文本**——从别的工具导出的 `mid,ekey` CSV 或逐行 ekey；
/// 3. **导入客户端数据库**——把QQ 音乐的 MMKV 文件、酷狗 / 酷我的数据库丢进来，
///    本机扫描一遍把 ekey 抠出来。
///
/// 密钥只存在本机 shared_preferences，不联网、不写日志。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../decrypt/key_scanner.dart';
import '../../decrypt/key_store.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// 供解密页复用的加载入口。
Future<List<String>> loadDecryptKeys() async {
  final keys = await DecryptKeys.load();
  return keys.entries.map((e) => e.value).toList();
}

class DecryptKeysPage extends StatefulWidget {
  const DecryptKeysPage({super.key});

  @override
  State<DecryptKeysPage> createState() => _DecryptKeysPageState();
}

class _DecryptKeysPageState extends State<DecryptKeysPage> {
  DecryptKeys? _keys;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final k = await DecryptKeys.load();
    if (!mounted) return;
    setState(() {
      _keys = k;
      _loading = false;
    });
  }

  // ==================== 手动填写 ====================

  Future<void> _manualInput() async {
    final controller = TextEditingController();
    String? mid;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ManualKeyDialog(controller: controller, onMid: (v) => mid = v),
    );
    if (ok != true || controller.text.trim().isEmpty) {
      controller.dispose();
      return;
    }
    final value = controller.text.trim();
    controller.dispose();

    await _keys!.add(DecryptKeyEntry(value: value, mid: mid));
    await _reload();
    _toast('已添加');
  }

  // ==================== 导入文本 ====================

  Future<void> _importText() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入密钥文本'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '每行一条，支持三种写法：\n'
                '• ekey\n'
                '• mid,ekey\n'
                '• mid,文件名,ekey\n'
                '# 开头的行会被忽略',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 8,
                minLines: 5,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '001y7CaR29k6YP,UVFNdXNpYyBFbmNWMixLZXk6...',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) {
      controller.dispose();
      return;
    }
    final count = _keys!.importText(controller.text);
    controller.dispose();
    await _reload();
    _toast('已导入 $count 条');
  }

  // ==================== 导入数据库 ====================

  Future<void> _importDatabase() async {
    try {
      final res = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (res == null || res.files.isEmpty || !mounted) return;

      final found = <DecryptKeyEntry>[];
      final notes = <String>[];
      var failed = 0;

      for (final f in res.files) {
        final p = f.path;
        if (p == null) continue;
        final name = p.split(Platform.pathSeparator).last.toLowerCase();
        try {
          final bytes = await File(p).readAsBytes();
          // 大文件限 64 MiB，避免一次读进几百 MB 把内存打爆。
          if (bytes.length > 64 * 1024 * 1024) {
            failed++;
            notes.add('$name 超过 64MB，已跳过');
            continue;
          }
          final r = scanKeys(bytes, hint: name);
          found.addAll(r.entries);
          final n = r.entries.length;
          notes.add('$name：${r.source} 命中 $n 条'
              '${r.note != null ? '（${r.note!}）' : ''}');
        } catch (e) {
          failed++;
          notes.add('$name 读取失败');
        }
      }

      if (!mounted) return;
      if (found.isEmpty) {
        _showScanReport(notes, failed);
        return;
      }
      final n = await _keys!.importEntries(found);
      await _reload();
      _showScanReport(notes, failed, imported: n);
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  /// 扫描报告：让用户看清每个文件命中了什么、为什么某个文件没中。
  void _showScanReport(List<String> notes, int failed, {int imported = 0}) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(imported > 0 ? '已导入 $imported 条密钥' : '未找到密钥'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (failed > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('$failed 个文件读取失败',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFFF6B6B))),
                  ),
                for (final n in notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('· $n',
                        style: const TextStyle(fontSize: 11.5, height: 1.5)),
                  ),
                const SizedBox(height: 8),
                const Text(
                  '提示：QQ 音乐请选择 app_data 目录下的 mmkv 文件；'
                  '部分客户端会把 ekey 加密存储，遇到这种情况请改用「手动填写」。',
                  style: TextStyle(
                      fontSize: 11, height: 1.5, color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  Future<void> _delete(String value) async {
    await _keys!.remove(value);
    await _reload();
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部密钥？'),
        content: const Text('清空后需要重新导入或填写，否则无法解密。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B6B)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _keys!.clear();
    await _reload();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final keys = _keys;
    return Scaffold(
      appBar: AppBar(
        title: const Text('密钥管理'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (keys != null && keys.isNotEmpty)
            TextButton(
              onPressed: _clearAll,
              child: const Text('清空',
                  style: TextStyle(color: Color(0xFFFF6B6B))),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _MiniAction(
                        icon: Icons.edit_outlined,
                        label: '手动填写',
                        onTap: _manualInput,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MiniAction(
                        icon: Icons.paste_rounded,
                        label: '导入文本',
                        onTap: _importText,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MiniAction(
                        icon: Icons.storage_rounded,
                        label: '导入数据库',
                        onTap: _importDatabase,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                if (keys == null || keys.isEmpty)
                  GlassCard(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 30),
                        child: Column(
                          children: const [
                            Icon(Icons.key_off_rounded,
                                size: 34, color: AppColors.textTertiary),
                            SizedBox(height: 10),
                            Text('还没有密钥',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: AppColors.textTertiary)),
                            SizedBox(height: 6),
                            Text(
                              'QQ 音乐、酷狗 v5、酷我 v2 需要密钥',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.textTertiary),
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
                        for (final e in keys.entries)
                          _KeyTile(entry: e, onDelete: () => _delete(e.value)),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _ManualKeyDialog extends StatefulWidget {
  const _ManualKeyDialog({required this.controller, required this.onMid});

  final TextEditingController controller;
  final ValueChanged<String?> onMid;

  @override
  State<_ManualKeyDialog> createState() => _ManualKeyDialogState();
}

class _ManualKeyDialogState extends State<_ManualKeyDialog> {
  final TextEditingController _mid = TextEditingController();

  @override
  void dispose() {
    _mid.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('手动填写密钥'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: widget.controller,
              maxLines: 3,
              minLines: 2,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                labelText: 'ekey / fileKey',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _mid,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                labelText: 'mid（可选，用于精确匹配）',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => widget.onMid(v.trim().isEmpty ? null : v.trim()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('添加'),
        ),
      ],
    );
  }
}

class _KeyTile extends StatelessWidget {
  const _KeyTile({required this.entry, required this.onDelete});

  final DecryptKeyEntry entry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final v = entry.value;
    final preview = v.length <= 48
        ? v
        //密钥很长，只展示头尾，中间省略——头尾足够判断是不是同一条
        : '${v.substring(0, 32)}…${v.substring(v.length - 12)}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          const Icon(Icons.vpn_key_outlined,
              size: 17, color: AppColors.cyan),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    if (entry.mid != null) 'mid: ${entry.mid}',
                    if (entry.qualityId != null) '音质: ${entry.qualityId}',
                    '来源: ${_sourceLabel(entry.source)}',
                  ].join(' · '),
                  style: const TextStyle(
                      fontSize: 10.5, color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            color: AppColors.textTertiary,
            tooltip: '删除',
          ),
        ],
      ),
    );
  }

  static String _sourceLabel(KeySource s) => switch (s) {
        KeySource.manual => '手动填写',
        KeySource.importedMmkv => 'MMKV 导入',
        KeySource.importedDatabase => '数据库导入',
        KeySource.importedText => '文本导入',
      };
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      onTap: onTap,
      radius: 16,
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Column(
        children: [
          Icon(icon, size: 19, color: AppColors.cyan),
          const SizedBox(height: 7),
          Text(
            label,
            style: const TextStyle(
                fontSize: 11.5, color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}
