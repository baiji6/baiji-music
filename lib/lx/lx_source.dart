import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 单个洛雪音源（用户自行导入的 JS 插件）的元数据。
///
/// 脚本正文不放在这里，也不进 SharedPreferences：存到应用 support 目录下的
/// `lx_sources/<scriptFile>`，元数据（含更新地址/开关/版本）存同目录的
/// `sources.json`。这样网关密钥（ikun 的 `API_KEY`、baimusic 的硬编码 IP）
/// 只落在应用私有文件，不塞进明文键值库的长串里。
///
/// **App 不内置任何音源**：用户提供的测试源仅作本地/集成测试夹具。
class LxSource {
  const LxSource({
    required this.id,
    required this.name,
    required this.version,
    this.author = '',
    this.homepage = '',
    this.description = '',
    required this.scriptFile,
    this.sourceUrl = '',
    this.updateUrl = '',
    this.enabled = true,
    this.autoUpdate = false,
    this.importedAt = 0,
    this.lastCheckedAt = 0,
    this.latestVersion = '',
  });

  final String id;
  final String name;
  final String version;

  /// 头信息里的 `@author` / `@homepage` / `@description`。
  final String author;
  final String homepage;
  final String description;

  /// 脚本文件名（相对 `lx_sources/` 目录）。
  final String scriptFile;

  /// 导入来源 URL（从链接导入时非空）。
  final String sourceUrl;

  /// 检测更新地址。URL 导入时默认等于 [sourceUrl]；文件导入时为空，
  /// 用户可在管理页手动填写（如 github/gitee raw 链接）。
  final String updateUrl;

  final bool enabled;

  /// 单源「自动更新」开关（全局开关在 `LxSourceRepo`）。
  final bool autoUpdate;

  final int importedAt;
  final int lastCheckedAt;

  /// 最近一次检测到的远端版本（有更新时用于 UI 角标「vX → vY」）。
  final String latestVersion;

  bool get canCheckUpdate => updateUrl.trim().isNotEmpty;

  /// 从脚本正文导入：解析 `==UserScript==` 风格头信息并生成稳定 id。
  factory LxSource.fromScript(
    String script, {
    String? sourceUrl,
    String? updateUrl,
    String? id,
  }) {
    final meta = parseHeader(script);
    final now = DateTime.now().millisecondsSinceEpoch;
    final sid = id ??
        'src_${now.toRadixString(36)}_${script.hashCode.toUnsigned(32).toRadixString(16)}';
    final fromUrl = (sourceUrl ?? '').trim();
    return LxSource(
      id: sid,
      name: (meta['name'] ?? '').isEmpty ? '未命名音源' : meta['name']!,
      version: meta['version'] ?? '',
      author: meta['author'] ?? '',
      homepage: meta['homepage'] ?? '',
      description: meta['description'] ?? '',
      scriptFile: '$sid.js',
      sourceUrl: fromUrl,
      // URL 导入即可检测/自动更新；文件导入优先用头信息里的 @updateURL，
      // 没有则留空由用户在管理页补。
      updateUrl: (updateUrl ??
              (fromUrl.isNotEmpty ? fromUrl : (meta['updateurl'] ?? '')))
          .trim(),
      importedAt: now,
    );
  }

  /// 解析脚本头部注释里的 `@name/@version/@author/@homepage/@description/
  /// @updateURL` 等字段（大小写不敏感，兼容 `// @name`、`* @name`、
  /// `/* @name */` 三种写法）。
  ///
  /// 逐行剥离注释符后再取值，避免字符类把 `@homepage https://…` 里的
  /// `/` 误当成注释结束符而截断 URL。
  static Map<String, String> parseHeader(String script) {
    // 头信息一定在文件开头；只扫前 12KB，避免混淆大文件全量正则开销。
    final head = script.length > 12000 ? script.substring(0, 12000) : script;
    final re = RegExp(
      r'@(name|version|author|homepage|description|updateURL)\s+(.+)\s*$',
      caseSensitive: false,
    );
    final out = <String, String>{};
    for (final rawLine in const LineSplitter().convert(head)) {
      var line = rawLine.trim();
      if (line.startsWith('//')) line = line.substring(2).trim();
      if (line.startsWith('/*')) line = line.substring(2).trim();
      if (line.startsWith('*')) line = line.substring(1).trim();
      if (line.endsWith('*/')) {
        line = line.substring(0, line.length - 2).trim();
      }
      final m = re.firstMatch(line);
      if (m == null) continue;
      final key = (m.group(1) ?? '').toLowerCase();
      final value = (m.group(2) ?? '').trim();
      if (value.isEmpty || out.containsKey(key)) continue;
      out[key] = value;
    }
    return out;
  }

  /// 安全护栏：仅作**提示**，不阻断导入。宿主只提供 `lx` 契约，
  /// Node / 浏览器专有 API 在 QuickJS 里本就跑不起来。
  static List<String> validateScript(String script) {
    final warnings = <String>[];
    if (!script.contains('globalThis.lx') && !script.contains('lx.')) {
      warnings.add('未发现 globalThis.lx 契约引用，可能不是洛雪音源脚本');
    }
    for (final bad in [
      'require("child_process")',
      "require('child_process')",
      'child_process',
      'process.exit',
    ]) {
      if (script.contains(bad)) warnings.add('包含可疑调用：$bad');
    }
    return warnings;
  }

  LxSource copyWith({
    String? name,
    String? version,
    String? author,
    String? homepage,
    String? description,
    String? sourceUrl,
    String? updateUrl,
    bool? enabled,
    bool? autoUpdate,
    int? importedAt,
    int? lastCheckedAt,
    String? latestVersion,
  }) =>
      LxSource(
        id: id,
        name: name ?? this.name,
        version: version ?? this.version,
        author: author ?? this.author,
        homepage: homepage ?? this.homepage,
        description: description ?? this.description,
        scriptFile: scriptFile,
        sourceUrl: sourceUrl ?? this.sourceUrl,
        updateUrl: updateUrl ?? this.updateUrl,
        enabled: enabled ?? this.enabled,
        autoUpdate: autoUpdate ?? this.autoUpdate,
        importedAt: importedAt ?? this.importedAt,
        lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
        latestVersion: latestVersion ?? this.latestVersion,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'author': author,
        'homepage': homepage,
        'description': description,
        'scriptFile': scriptFile,
        'sourceUrl': sourceUrl,
        'updateUrl': updateUrl,
        'enabled': enabled,
        'autoUpdate': autoUpdate,
        'importedAt': importedAt,
        'lastCheckedAt': lastCheckedAt,
        'latestVersion': latestVersion,
      };

  factory LxSource.fromJson(Map<String, dynamic> map) => LxSource(
        id: map['id'] as String? ?? '',
        name: map['name'] as String? ?? '未命名音源',
        version: map['version'] as String? ?? '',
        author: map['author'] as String? ?? '',
        homepage: map['homepage'] as String? ?? '',
        description: map['description'] as String? ?? '',
        scriptFile: map['scriptFile'] as String? ?? '${map['id'] ?? 'src'}.js',
        sourceUrl: map['sourceUrl'] as String? ?? '',
        updateUrl: map['updateUrl'] as String? ?? '',
        enabled: map['enabled'] as bool? ?? true,
        autoUpdate: map['autoUpdate'] as bool? ?? false,
        importedAt: (map['importedAt'] as num?)?.toInt() ?? 0,
        lastCheckedAt: (map['lastCheckedAt'] as num?)?.toInt() ?? 0,
        latestVersion: map['latestVersion'] as String? ?? '',
      );

  @override
  String toString() => 'LxSource($name $version, $id)';
}

/// 洛雪音源仓库：文件系统（脚本 + `sources.json` 元数据 + `config.json`）。
///
/// 目录可通过 [directory] 注入，便于纯 Dart 单测用临时目录，不必依赖
/// `path_provider` 的平台通道。默认落在应用 support 目录的 `lx_sources/`。
class LxSourceRepo {
  LxSourceRepo({Future<Directory> Function()? directory})
      : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;

  static Future<Directory> _defaultDirectory() async =>
      getApplicationSupportDirectory();

  Future<Directory> get _root async {
    final base = await _directory();
    final d = Directory('${base.path}${Platform.pathSeparator}lx_sources');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> get _metaFile async =>
      File('${(await _root).path}${Platform.pathSeparator}sources.json');

  Future<File> get _configFile async =>
      File('${(await _root).path}${Platform.pathSeparator}config.json');

  Future<File> _scriptFile(LxSource s) async => File(
      '${(await _root).path}${Platform.pathSeparator}${s.scriptFile}');

  /// 全部音源（按导入时间升序）；读取失败返回空列表而非抛错。
  Future<List<LxSource>> all() async {
    try {
      final f = await _metaFile;
      if (!await f.exists()) return <LxSource>[];
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! List) return <LxSource>[];
      final list = decoded
          .whereType<Map>()
          .map((e) => LxSource.fromJson(Map<String, dynamic>.from(e)))
          .where((s) => s.id.isNotEmpty)
          .toList();
      list.sort((a, b) => a.importedAt.compareTo(b.importedAt));
      return list;
    } catch (_) {
      return <LxSource>[];
    }
  }

  /// 仅启用的音源。
  Future<List<LxSource>> enabled() async =>
      (await all()).where((s) => s.enabled).toList();

  Future<void> saveAll(List<LxSource> items) async {
    final f = await _metaFile;
    await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(items.map((e) => e.toJson()).toList()));
  }

  /// 导入一个新音源：写脚本文件 + 追加元数据。
  Future<LxSource> add({
    required String script,
    String? sourceUrl,
    String? updateUrl,
  }) async {
    final src = LxSource.fromScript(script,
        sourceUrl: sourceUrl, updateUrl: updateUrl);
    await writeScript(src, script);
    final list = await all();
    list.removeWhere((e) => e.id == src.id);
    list.add(src);
    await saveAll(list);
    return src;
  }

  /// 按 id 更新（或追加）一条元数据。
  Future<void> update(LxSource s) async {
    final list = await all();
    final i = list.indexWhere((e) => e.id == s.id);
    if (i >= 0) {
      list[i] = s;
    } else {
      list.add(s);
    }
    await saveAll(list);
  }

  /// 删除音源及其脚本文件。
  Future<void> remove(String id) async {
    final list = await all();
    final targets = list.where((e) => e.id == id).toList();
    list.removeWhere((e) => e.id == id);
    await saveAll(list);
    for (final s in targets) {
      try {
        final f = await _scriptFile(s);
        if (await f.exists()) await f.delete();
      } catch (_) {/* 单个文件删除失败不影响元数据 */}
    }
  }

  Future<String> readScript(LxSource s) async =>
      (await _scriptFile(s)).readAsString();

  Future<void> writeScript(LxSource s, String script) async =>
      (await _scriptFile(s)).writeAsString(script);

  // ---------------- 全局配置 ----------------

  Future<Map<String, dynamic>> _config() async {
    try {
      final f = await _configFile;
      if (!await f.exists()) return <String, dynamic>{};
      final decoded = jsonDecode(await f.readAsString());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _saveConfig(Map<String, dynamic> cfg) async {
    await (await _configFile).writeAsString(jsonEncode(cfg));
  }

  /// 全局「自动更新洛雪音源」开关。
  Future<bool> globalAutoUpdate() async =>
      (await _config())['autoUpdate'] as bool? ?? false;

  Future<void> setGlobalAutoUpdate(bool value) async {
    final cfg = await _config();
    cfg['autoUpdate'] = value;
    await _saveConfig(cfg);
  }

  /// 最近一次全局检测时间（毫秒），用于「启动后空闲时静默检测」节流。
  Future<int> lastCheckAt() async =>
      (await _config())['lastCheckAt'] as int? ?? 0;

  Future<void> setLastCheckAt(int ms) async {
    final cfg = await _config();
    cfg['lastCheckAt'] = ms;
    await _saveConfig(cfg);
  }
}
