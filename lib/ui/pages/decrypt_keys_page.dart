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

import '../../decrypt/decryptor.dart' show DecryptPlatform;
import '../../decrypt/key_scanner.dart';
import '../../decrypt/key_store.dart';
import '../../decrypt/qingting.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// 供解密页复用的加载入口：把密钥摊平成一个可跨 isolate 传递的字符串 map。
///
/// 两类 key：
/// - `qqMusic` / `kugou` ……该平台的**通用**密钥（第一条）；
/// - `qqMusic <mid>` / `qqMusic@文件名.mp3` ……**精确**条目，解密时优先命中
///   （同一首歌不同音质可能是不同的 ekey，不能只取第一条）。
///
/// 刻意不返回扁平 List——六个平台的密钥规则互不相同，
/// 解密时必须按嗅探出的平台精确取，不能混用。
Future<Map<String, String>> loadDecryptKeySnapshot() async {
  final keys = await DecryptKeys.load();
  final out = <String, String>{};
  for (final p in DecryptPlatform.values) {
    for (final e in keys.entriesOf(p)) {
      if (e.value.isEmpty) continue;
      // 平台级通用条目：只放第一条，作为没有精确匹配时的兜底。
      out.putIfAbsent(p.name, () => e.value);
      final mid = e.mid;
      if (mid != null && mid.isNotEmpty) out['$p.name $mid'] = e.value;
      final fname = e.mediaFilename;
      if (fname != null && fname.isNotEmpty) out['$p.name@$fname'] = e.value;
    }
  }
  return out;
}

class DecryptKeysPage extends StatefulWidget {
  const DecryptKeysPage({super.key});

  @override
  State<DecryptKeysPage> createState() => _DecryptKeysPageState();
}

class _DecryptKeysPageState extends State<DecryptKeysPage> {
  DecryptKeys? _keys;
  bool _loading = true;

  /// 当前选中的平台Tab。所有录入动作都只作用于这个平台。
  DecryptPlatform _platform = DecryptPlatform.qqMusic;

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

  /// 当前平台已录的条目。
  List<DecryptKeyEntry> _entriesOf(DecryptPlatform p) =>
      _keys?.entriesOf(p) ?? const [];

  // ==================== 手动填写 ====================

  Future<void> _manualInput() async {
    final platform = _platform;
    final controller = TextEditingController();
    String? mid;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ManualKeyDialog(
        platform: platform,
        controller: controller,
        onMid: (v) => mid = v,
      ),
    );
    final value = controller.text.trim();
    controller.dispose();
    if (ok != true || value.isEmpty) return;

    // 蜻蜓要的是 16 字节 hex，先本地校验，别把垃圾存进去。
    if (platform.keyIsHex) {
      try {
        parseHexOrThrow(value, '设备密钥');
      } on QingTingFailure catch (e) {
        _toast(e.message);
        return;
      }
    }

    await _keys!.add(DecryptKeyEntry(
      value: value,
      platform: platform,
      mid: mid,
    ));
    await _reload();
    _toast('已添加到${platform.label}');
  }

  // ==================== 导入文本 ====================

  Future<void> _importText() async {
    final platform = _platform;
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('导入密钥文本 → ${platform.label}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                platform.keyIsHex
                    ? '每行一条设备密钥（32 位十六进制）。蜻蜓 FM 用 AES-128-CTR，'
                        '密钥长度必须正好 16 字节。'
                    : '每行一条，支持三种写法：\n'
                        '• ekey\n'
                        '• mid,ekey\n'
                        '• mid,文件名,ekey\n'
                        '# 开头的行会被忽略',
                style: const TextStyle(fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 8,
                minLines: 5,
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: platform.keyIsHex
                      ? '000102030405060708090a0b0c0d0e0f'
                      : '001y7CaR29k6YP,UVFNdXNpYyBFbmNWMixLZXk6...',
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
    final count = _keys!.importText(controller.text, platform: platform);
    controller.dispose();
    await _reload();
    _toast('已向${platform.label}导入 $count 条');
  }

  // ==================== 导入数据库 ====================

  Future<void> _importDatabase() async {
    final platform = _platform;
    // 蜻蜓的密钥是设备派生出来的，不是从客户端库里扫出来的——直接引导去生成。
    if (platform == DecryptPlatform.qingting) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('蜻蜓 FM 密钥无法扫描'),
          content: const Text(
            '蜻蜓 FM 的密钥是由手机机型信息（product / device / manufacturer / '
            'brand / board / model）派生出来的，不存在于任何客户端数据库里。\n\n'
            '请用「由设备信息生成」按钮，按你手机的真实机型信息生成。',
            style: TextStyle(fontSize: 13, height: 1.6),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('关闭')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('去生成')),
          ],
        ),
      );
      if (go == true && mounted) _openQingTingGenerator();
      return;
    }

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
          final r = scanKeys(bytes, platform: platform, hint: name);
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

  // ==================== 蜻蜓设备信息生成 ====================

  void _openQingTingGenerator() {
    showDialog<void>(
      context: context,
      builder: (ctx) => const _QingTingGeneratorDialog(),
    );
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

  Future<void> _delete(DecryptKeyEntry e) async {
    await _keys!.remove(e.value, e.platform);
    await _reload();
  }

  /// 只清空当前 Tab 的平台，不动其他平台的密钥。
  Future<void> _clearAll() async {
    final platform = _platform;
    final n = _entriesOf(platform).length;
    if (n == 0) {
      _toast('${platform.label} 还没有密钥');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('清空${platform.label}的全部密钥？'),
        content: Text(
          '将删除 $n 条。其他平台的密钥不受影响。\n'
          '清空后需要重新导入或填写，否则无法解密。',
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
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
    await _keys!.clearPlatform(platform);
    await _reload();
    _toast('已清空${platform.label}');
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
                // ---- 平台 Tab：每个平台的加密规则不同，必须分开录入 ----
                _PlatformTabs(
                  current: _platform,
                  counts: {
                    for (final p in DecryptPlatform.values)
                      p: _entriesOf(p).length,
                  },
                  onSelect: (p) => setState(() => _platform = p),
                ),
                const SizedBox(height: 16),
                _PlatformBanner(platform: _platform),
                const SizedBox(height: 16),
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
                if (_platform == DecryptPlatform.qingting) ...[
                  const SizedBox(height: 10),
                  _MiniAction(
                    icon: Icons.auto_fix_high_rounded,
                    label: '由设备信息生成密钥',
                    onTap: _openQingTingGenerator,
                  ),
                ],
                const SizedBox(height: 20),
                if (_entriesOf(_platform).isEmpty)
                  GlassCard(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 30),
                        child: Column(
                          children: [
                            const Icon(Icons.key_off_rounded,
                                size: 34, color: AppColors.textTertiary),
                            const SizedBox(height: 10),
                            Text('${_platform.label}还没有密钥',
                                style: const TextStyle(
                                    fontSize: 13,
                                    color: AppColors.textTertiary)),
                            const SizedBox(height: 6),
                            Text(
                              _platform.needsKey
                                  ? '该平台必须填写密钥才能解密'
                                  : '该平台通常无需密钥，文件头里已自带',
                              style: const TextStyle(
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
                        for (final e in _entriesOf(_platform))
                          _KeyTile(entry: e, onDelete: () => _delete(e)),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _ManualKeyDialog extends StatefulWidget {
  const _ManualKeyDialog({
    required this.platform,
    required this.controller,
    required this.onMid,
  });

  final DecryptPlatform platform;
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
    final p = widget.platform;
    return AlertDialog(
      title: Text('手动填写密钥 → ${p.label}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.cyan.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _keyHint(p),
                style: const TextStyle(fontSize: 11.5, height: 1.55),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: widget.controller,
              maxLines: 3,
              minLines: 2,
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                labelText: p.keyIsHex ? '设备密钥（32 位 hex）' : 'ekey / fileKey',
                border: const OutlineInputBorder(),
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

  /// 各平台密钥的形态说明——填错格式是最常见的失败原因。
  static String _keyHint(DecryptPlatform p) => switch (p) {
        DecryptPlatform.qqMusic => 'QQ 音乐：ekey 为 base64 串，通常在文件尾部的 QMG 块里。',
        DecryptPlatform.kugou => '酷狗：v5 需fileKey（hex），与酷狗 App 内其他 key 不是一回事。',
        DecryptPlatform.kuwo => '酷我：kwm 的 fileKey（hex），从酷我客户端缓存目录的数据库里拿。',
        DecryptPlatform.netease => '网易云：密钥已内置在 .ncm 文件头里，通常不需要填写。',
        DecryptPlatform.migu => '咪咕：多数情况下密钥可由文件头推导，通常不需要填写。',
        DecryptPlatform.qingting =>
          '蜻蜓 FM：需要 16 字节设备密钥的十六进制（32 个字符），'
              '由手机机型信息派生，不在任何客户端数据库里。',
      };
}

/// 蜻蜓 FM 设备密钥生成器：填 6 段机型信息 → 派生 device key。
class _QingTingGeneratorDialog extends StatefulWidget {
  const _QingTingGeneratorDialog();

  @override
  State<_QingTingGeneratorDialog> createState() =>
      _QingTingGeneratorDialogState();
}

class _QingTingGeneratorDialogState extends State<_QingTingGeneratorDialog> {
  final _fields = <String, TextEditingController>{
    for (final k in const [
      'product',
      'device',
      'manufacturer',
      'brand',
      'board',
      'model',
    ])
      k: TextEditingController(),
  };

  String? _result;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _generate() {
    if (_fields.values.any((c) => c.text.trim().isEmpty)) {
      setState(() => _result = null);
      _toast('六段机型信息都要填');
      return;
    }
    final hex = deviceSecretToHex(
      makeDeviceSecret(
        product: _fields['product']!.text.trim(),
        device: _fields['device']!.text.trim(),
        manufacturer: _fields['manufacturer']!.text.trim(),
        brand: _fields['brand']!.text.trim(),
        board: _fields['board']!.text.trim(),
        model: _fields['model']!.text.trim(),
      ),
    );
    setState(() => _result = hex);
  }

  void _toast(String m) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('由设备信息生成蜻蜓密钥'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '填你手机「关于手机」里的原始值。构建号等字段不要改写，'
                '差一个字符就解不出正确结果。',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 14),
              for (final entry in _fields.entries) ...[
                TextField(
                  controller: entry.value,
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    labelText: entry.key,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (_result != null) ...[
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.cyan.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(
                    _result!,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '点「保存到蜻蜓」直接入库；若解出来是噪声，多半是某段机型信息写错了。',
                  style: TextStyle(
                      fontSize: 11, height: 1.5, color: AppColors.textTertiary),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        TextButton(onPressed: _generate, child: const Text('生成')),
        if (_result != null)
          FilledButton(
            onPressed: () async {
              final keys = await DecryptKeys.load();
              await keys.add(DecryptKeyEntry(
                value: _result!,
                platform: DecryptPlatform.qingting,
              ));
              if (!context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已保存到蜻蜓 FM')),
              );
            },
            child: const Text('保存到蜻蜓'),
          ),
      ],
    );
  }
}

/// 平台切换 Tab。每格右上角显示该平台已录的条数。
class _PlatformTabs extends StatelessWidget {
  const _PlatformTabs({
    required this.current,
    required this.counts,
    required this.onSelect,
  });

  final DecryptPlatform current;
  final Map<DecryptPlatform, int> counts;
  final ValueChanged<DecryptPlatform> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 74,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: DecryptPlatform.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final p = DecryptPlatform.values[i];
          final n = counts[p] ?? 0;
          final sel = p == current;
          final color = sel ? AppColors.cyan : AppColors.textTertiary;
          return InkWell(
            onTap: () => onSelect(p),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 92,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: sel ? 0.13 : 0.05),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: color.withValues(alpha: sel ? 0.55 : 0.18),
                  width: sel ? 1.4 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    p.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                      color: sel ? AppColors.textPrimary : AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    p.extensions.isEmpty ? '—' : p.extensions.first,
                    style: TextStyle(fontSize: 10, color: color),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    n > 0 ? '$n 条' : '未设置',
                    style: TextStyle(
                      fontSize: 10,
                      color: n > 0 ? AppColors.cyan : AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 当前平台的规则说明条。
class _PlatformBanner extends StatelessWidget {
  const _PlatformBanner({required this.platform});

  final DecryptPlatform platform;

  @override
  Widget build(BuildContext context) {
    final needs = platform.needsKey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: (needs ? const Color(0xFFFFB020) : AppColors.textTertiary)
            .withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            needs ? Icons.lock_outline_rounded : Icons.lock_open_rounded,
            size: 16,
            color: needs ? const Color(0xFFFFB020) : AppColors.textTertiary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${platform.label}｜${platform.extensions.join(' ')}'
              '${needs ? ' · 需要密钥' : ' · 通常无需密钥'}'
              '${platform.keyIsHex ? ' · 密钥为 hex' : ''}',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: needs ? const Color(0xFFFFB020) : AppColors.textTertiary,
              ),
            ),
          ),
        ],
      ),
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
