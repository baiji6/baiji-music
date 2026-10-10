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
/// 三类 key：
/// - `qqMusic` / `kugou` ……该平台的**通用**密钥（第一条）；
/// - `qqMusic@原始文件名` / `kugou@audioHash` / `kuwo@rid-quality` ……**精确**条目，
///   解密时按各平台真实的匹配键优先命中（严格对齐 um-react 的
///   `selectQMCv2KeyByFileName` / `selectKugouKey` / `selectKWMv2Key`）；
/// - `qqMusic mid` ……QQ footer 带mid 时的兼容条目。
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
      // 匹配键条目：`平台@匹配键`，各平台匹配键定义见
      // [DecryptKeyEntry.matchKey]（QQ 文件名 / 酷狗 audioHash / 酷我 rid-quality）。
      final mk = e.matchKey;
      if (mk != null && mk.isNotEmpty) out['$p.name@$mk'] = e.value;
      final mid = e.mid;
      if (mid != null && mid.isNotEmpty) out['$p.name $mid'] = e.value;
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

    final entry = await showDialog<DecryptKeyEntry>(
      context: context,
      builder: (ctx) => _ManualKeyDialog(platform: platform),
    );
    if (entry == null) return;

    // 网易云的密钥在文件头里、咪咕能自己猜，填了也没用——
    // 提前说清楚，免得用户以为自己填对了却解不出。
    if (!platform.needsKey && mounted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${platform.label}通常不需要密钥'),
          content: Text(
            '${platform.label}的密钥已经内置在文件里或可由文件头推导。'
            '你仍然可以保存它，但通常不会影响解密结果。\n\n'
            '确定要保存吗？',
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('不保存')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('仍然保存')),
          ],
        ),
      );
      if (go != true) return;
    }

    await _keys!.add(entry);
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
                _importHint(platform),
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
                  hintText: switch (platform) {
                    DecryptPlatform.qingting => '000102030405060708090a0b0c0d0e0f',
                    DecryptPlatform.kuwo => '12345678-128,UVFNdXNpYyBFbmNWMixLZXk6...',
                    DecryptPlatform.kugou =>
                      '8fd2a1c0e3b95d7f4a6b8c2d1e0f3a5b,UVFNdXNpYyBFbmNWMixLZXk6...',
                    _ => '歌曲名.mp3,UVFNdXNpYyBFbmNWMixLZXk6...',
                  },
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

  /// 导入文本的格式说明。**每种平台的分隔符含义都不同**——
  /// 逗号左边是那个平台的匹配键，不是通用的 mid。
  static String _importHint(DecryptPlatform p) => switch (p) {
        DecryptPlatform.qqMusic =>
          '每行一条，格式为 `原始文件名,ekey`（文件名也可只写 ekey）。\n'
              '文件名要与 MusicEx footer 里的 mediaName 一致，否则匹配不上。\n'
              '# 开头的行会被忽略',
        DecryptPlatform.kugou =>
          '每行一条，格式为 `audioHash,ekey`（也可只写 ekey）。\n'
              'audioHash 是 KGM 文件头里的音频指纹。\n'
              '# 开头的行会被忽略',
        DecryptPlatform.kuwo =>
          '每行一条，格式为 `资源ID-音质,ekey`（也可只写 ekey）。\n'
              '例：12345678-128,UVFNdXNpYyBFbmNWMixLZXk6...\n'
              '# 开头的行会被忽略',
        DecryptPlatform.qingting =>
          '每行一条 16 字节设备密钥（32 位十六进制）。蜻蜓 FM 用 AES-128-CTR，'
              '长度必须正好 32 个字符，且所有 .qta 共用同一把。',
        DecryptPlatform.netease || DecryptPlatform.migu =>
          '这两个平台的密钥在文件头里，通常不需要导入。\n'
              '每行一条 ekey，仅作备用记录。',
      };

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

/// 手动填写密钥对话框。
///
/// **字段按平台动态变化**——各平台的解密条件根本不同，揉在一个表单里
/// 只会让人填错：
/// - QQ 音乐 → 原始文件名 + ekey（上游 `selectQMCv2KeyByFileName` 的查表键）
/// - 酷狗→ audioHash + ekey（上游 `selectKugouKey` 的查表键）
/// - 酷我→ 资源 ID + 音质 + ekey（上游 `selectKWMv2Key` 拼成 `rid-quality`）
/// - 蜻蜓 FM → 只要设备密钥，**没有匹配键**（一把通吃）
/// - 网易云 / 咪咕 → 密钥在文件头里，不需要匹配键
///
/// 确认后直接返回构造好的 [DecryptKeyEntry]（未入库）。
class _ManualKeyDialog extends StatefulWidget {
  const _ManualKeyDialog({required this.platform});

  final DecryptPlatform platform;

  @override
  State<_ManualKeyDialog> createState() => _ManualKeyDialogState();
}

class _ManualKeyDialogState extends State<_ManualKeyDialog> {
  final _value = TextEditingController();

  /// QQ 的原始文件名 / 酷狗的 audioHash（两个平台都是单个字符串字段）。
  final _match = TextEditingController();

  /// 酷我：资源 id 与音质要分成两个数字框，因为它们是两个独立字段。
  final _rid = TextEditingController();
  final _quality = TextEditingController();

  String? _error;

  @override
  void dispose() {
    _value.dispose();
    _match.dispose();
    _rid.dispose();
    _quality.dispose();
    super.dispose();
  }

  /// 平台需要的匹配键字段名（用于标题与错误提示）。
  String get _matchLabel => switch (widget.platform) {
        DecryptPlatform.qqMusic => '原始文件名',
        DecryptPlatform.kugou => 'audioHash（音频指纹）',
        DecryptPlatform.kuwo => '资源 ID',
        _ => '',
      };

  void _submit() {
    final p = widget.platform;
    final value = _value.text.trim();
    if (value.isEmpty) {
      setState(() => _error = '密钥不能为空');
      return;
    }

    // 蜻蜓要的是 16 字节 hex，先本地校验，别把垃圾存进去。
    if (p.keyIsHex) {
      try {
        parseHexOrThrow(value, '设备密钥');
      } on QingTingFailure catch (e) {
        setState(() => _error = e.message);
        return;
      }
    }

    // 需要匹配键的平台：匹配键没填就一定查不到，直接拦在提交这一步。
    if (p.needsMatchKey) {
      if (p == DecryptPlatform.kuwo) {
        final rid = int.tryParse(_rid.text.trim());
        final q = int.tryParse(_quality.text.trim());
        if (rid == null || q == null) {
          setState(() => _error = '资源 ID 与音质都要填，且必须是数字');
          return;
        }
        Navigator.pop(
          context,
          DecryptKeyEntry(
            value: value,
            platform: p,
            resourceId: rid,
            qualityId: q,
          ),
        );
        return;
      }
      final mk = _match.text.trim();
      if (mk.isEmpty) {
        setState(() => _error = '$_matchLabel不能为空——'
            '没有它这条密钥永远匹配不上文件');
        return;
      }
      Navigator.pop(
        context,
        _entryWithMatchKey(value, mk, p),
      );
      return;
    }

    // 蜻蜓 / 网易云 / 咪咕：没有匹配键概念。
    Navigator.pop(context, DecryptKeyEntry(value: value, platform: p));
  }

  /// 把「匹配键 + ekey」组装成对应平台的条目。
  static DecryptKeyEntry _entryWithMatchKey(
      String value, String matchKey, DecryptPlatform p) =>
      switch (p) {
        DecryptPlatform.qqMusic => DecryptKeyEntry(
            value: value, platform: p, mediaFilename: matchKey),
        DecryptPlatform.kugou => DecryptKeyEntry(
            value: value, platform: p, audioHash: matchKey),
        _ => DecryptKeyEntry(
            value: value, platform: p, mediaFilename: matchKey),
      };

  @override
  Widget build(BuildContext context) {
    final p = widget.platform;
    return AlertDialog(
      title: Text('手动填写密钥 → ${p.label}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
              // ---- 匹配键字段：各平台不同，按平台显示 ----
              if (p == DecryptPlatform.kuwo) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _rid,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          labelText: '资源 ID（rid）',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 130,
                      child: TextField(
                        controller: _quality,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          labelText: '音质（quality）',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '两者会拼成 ${_rid.text.trim().isEmpty ? 'rid-quality' : '${_rid.text.trim()}-${_quality.text.trim()}'} '
                  '作为查表键',
                  style: const TextStyle(
                      fontSize: 10.5, color: AppColors.textTertiary),
                ),
                const SizedBox(height: 12),
              ] else if (p.needsMatchKey) ...[
                TextField(
                  controller: _match,
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    labelText: '$_matchLabel（必填）',
                    hintText: switch (p) {
                      DecryptPlatform.qqMusic => '例如 歌曲名.mp3',
                      DecryptPlatform.kugou =>
                        '32 位十六进制，例如 8fd2a1c0e3b95d7f4a6b8c2d1e0f3a5b',
                      _ => '',
                    },
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
              ],
              // ---- 密钥本体 ----
              TextField(
                controller: _value,
                maxLines: p.keyIsHex ? 1 : 3,
                minLines: p.keyIsHex ? 1 : 2,
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  labelText: p.keyIsHex
                      ? '设备密钥（32 位 hex，16 字节）'
                      : _valueLabel(p),
                  isDense: p.keyIsHex,
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style: const TextStyle(
                        fontSize: 11.5, color: Color(0xFFFF6B6B))),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('添加')),
      ],
    );
  }

  static String _valueLabel(DecryptPlatform p) => switch (p) {
        DecryptPlatform.qqMusic => 'ekey（QMC v2）',
        DecryptPlatform.kugou => 'fileKey（KGM v5）',
        DecryptPlatform.kuwo => 'fileKey（KWM v2）',
        _ => 'ekey / fileKey',
      };

  /// 各平台的**解密条件**与密钥填法。
  ///
  /// 文案直接对着 um-react 的 TS 契约写：密钥填错版本是最常见的失败原因，
  /// 而用户往往分不清"这首歌到底是 v1 还是 v2"。
  static String _keyHint(DecryptPlatform p) => switch (p) {
        DecryptPlatform.qqMusic =>
          'QQ 音乐 QMC v2（.mflac）：按**原始文件名**查 ekey，'
              '文件名对不上就解不出（找不到时会按相近文件名兜底）。\n'
              'QMC v1（.qmcflac）用内置静态密钥，不需要填。',
        DecryptPlatform.kugou =>
          '酷狗 KGM：只有 **v5** 需要 fileKey，按文件头里的 **audioHash** 查表。'
              'v2/v3 是内置密钥，不要填。\n'
              'audioHash 可用工具箱的「读取文件信息」看到。',
        DecryptPlatform.kuwo =>
          '酷我 KWM：只有 **v2** 需要 fileKey，查表键是 `资源ID-音质`'
              '（rid 在文件头 0x18，音质取文件头format_name 的开头数字）。\n'
              '同一首歌不同音质是不同的 key，v1 用内置密钥。',
        DecryptPlatform.netease =>
          '网易云：密钥已内置在 .ncm 文件头的 meta 里，**无需填写**。',
        DecryptPlatform.migu =>
          '咪咕：无需填写——密钥由文件头已知明文反推。'
              '填了反而可能导致解出噪声。',
        DecryptPlatform.qingting =>
          '蜻蜓 FM：只要一把 16 字节设备密钥（32 位十六进制），'
              '不做任何匹配——所有 .qta 文件共用它。\n'
              '它由手机机型信息派生，不在任何客户端数据库里。',
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
              '${platform.keyIsHex ? ' · 密钥为 hex' : ''}'
              '\n查表键：${platform.needsMatchKey ? platform.matchKeyLabel : '无（一把通吃 / 密钥在文件头）'}',
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
                    if (entry.hasMatchKey)
                      '${entry.platform.matchKeyLabel}: ${entry.matchKey}',
                    if (entry.mid != null) 'mid: ${entry.mid}',
                    if (!entry.hasMatchKey && entry.platform.needsMatchKey)
                      '⚠缺${entry.platform.matchKeyLabel}，无法匹配',
                    '来源: ${_sourceLabel(entry.source)}',
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: (!entry.hasMatchKey &&
                            entry.platform.needsMatchKey)
                        ? const Color(0xFFFFB020)
                        : AppColors.textTertiary,
                  ),
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
