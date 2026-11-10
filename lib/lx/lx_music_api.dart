import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/kugou/kugou_api.dart';
import 'package:baiji_music/network/kuwo/qmc_stream.dart';

import 'lx_host_bridge.dart';
import 'lx_runtime.dart';
import 'lx_source.dart';

/// 洛雪音源声明的音质档位（与 LX 官方 `qualitys` 对齐，低 → 高）。
///
/// 各子源实际支持的档位是 `inited.sources[sub].qualitys` 的子集，
/// 取流前用 [pick] 把 App 请求的档位裁剪/降级到插件支持的档位。
class LxQuality {
  LxQuality._();

  static const List<String> all = [
    '128k',
    '320k',
    'flac',
    'flac24bit',
    'hires',
    'atmos',
    'atmos_plus',
    'master',
  ];

  /// 把 App 各平台的音质对象（或洛雪档位字符串）映射到洛雪档位名。
  ///
  /// 判定同时看 code / level / id / label / ext，覆盖 QQ、网易云、酷我、
  /// 酷狗四套枚举；无法识别时保守回退 `128k`（几乎所有源都支持）。
  static String from(dynamic q) {
    if (q == null) return '128k';
    if (q is String) {
      final lower = q.toLowerCase();
      return all.contains(lower) ? lower : _fromText(lower);
    }
    String s;
    if (q is Quality) {
      s = '${q.code} ${q.label} ${q.ext}';
    } else if (q is NeteaseQuality) {
      s = '${q.level} ${q.label} ${q.ext}';
    } else if (q is KuwoQuality) {
      s = '${q.id} ${q.label} ${q.format}';
    } else if (q is KugouQuality) {
      s = '${q.id} ${q.label} ${q.ext}';
    } else {
      s = q.toString();
    }
    return _fromText(s.toLowerCase());
  }

  static String _fromText(String s) {
    // 母带 / 全景声在前，避免它们的 `.flac` 扩展名被当成普通无损。
    if (s.contains('master') || s.contains('母带') || s.contains('jymaster')) {
      return 'master';
    }
    if (s.contains('atmos_plus') || s.contains('全景声 815')) {
      return 'atmos_plus';
    }
    if (s.contains('atmos') ||
        s.contains('全景') ||
        s.contains('dolby') ||
        s.contains('vivid') ||
        s.contains('环绕') ||
        s.contains('d00') ||
        s.contains('q00')) {
      return 'atmos';
    }
    if (s.contains('hires') ||
        s.contains('hi-res') ||
        s.contains('24bit') ||
        s.contains('flac24bit') ||
        s.contains('rs01') ||
        s.contains('臻品音质')) {
      return 'hires';
    }
    if (s.contains('flac') ||
        s.contains('无损') ||
        s.contains('lossless') ||
        s.contains('sq ') ||
        s.contains('f000')) {
      return 'flac';
    }
    if (s.contains('320') ||
        s.contains('exhigh') ||
        s.contains('极高') ||
        s.contains('m800') ||
        s.contains('o800')) {
      return '320k';
    }
    return '128k';
  }

  /// 把期望档位 [want] 裁剪到 [available]：支持则用之，否则向下找最近
  /// 可用档；插件未声明音质时原样返回（由插件自行决定）。
  static String pick(String want, List<String> available) {
    if (available.isEmpty) return want;
    if (available.contains(want)) return want;
    final rank = all.indexOf(want);
    if (rank < 0) return available.first;
    for (var i = rank - 1; i >= 0; i--) {
      if (available.contains(all[i])) return all[i];
    }
    return available.first;
  }
}

/// 洛雪子源 id（对应 `inited.sources` 的 key）。
class LxSubSource {
  LxSubSource._();

  static const String kw = 'kw';
  static const String kg = 'kg';
  static const String tx = 'tx';
  static const String wy = 'wy';
  static const String mg = 'mg';
  static const String git = 'git';

  static const List<String> all = [kw, kg, tx, wy, mg, git];

  static const Map<String, String> labels = {
    kw: '酷我',
    kg: '酷狗',
    tx: 'QQ 音乐',
    wy: '网易云',
    mg: '咪咕',
    git: 'Git 源',
  };

  /// 由 App 原生平台映射到洛雪子源（洛雪音源是取流插件，歌曲仍来自
  /// 原生搜索结果，这里决定用哪个子源去取它的直链）。
  static String fromApp(String source) {
    switch (source) {
      case Source.netease:
        return wy;
      case Source.kuwo:
        return kw;
      case Source.kugou:
        return kg;
      case Source.qq:
      default:
        return tx;
    }
  }
}

/// 洛雪取链失败原因（v2.5.7-pre2）。
///
/// pre1 返回 `LxPlayResult.empty` 时不带任何原因，用户只能看到「无法获取播放
/// 链接」，无从判断是没导入音源、子源不支持还是插件报错。
enum LxFailReason {
  none,
  pluginsNotLoaded,
  subSourceUnsupported,
  qualityUnsupported,
  pluginError,
  timeout,
  emptyUrl,
}

/// 洛雪取流结果。
class LxPlayResult {
  const LxPlayResult({
    this.url = '',
    this.ekey = '',
    this.format = '',
    this.quality = '',
    this.pluginName = '',
    this.subSource = '',
    this.reason = LxFailReason.none,
    this.error = '',
  });

  static const empty = LxPlayResult();

  /// 构造一个带原因的失败结果。
  factory LxPlayResult.failed(
    LxFailReason reason, {
    String error = '',
    String pluginName = '',
    String quality = '',
    String subSource = '',
  }) =>
      LxPlayResult(
        reason: reason,
        error: error,
        pluginName: pluginName,
        quality: quality,
        subSource: subSource,
      );

  final String url;

  /// 插件返回的 QMC ekey（非空且 url 为 mflac/mgg 时需走本地解密中继）。
  final String ekey;

  /// 插件声明的容器格式（mflac / mgg / flac / mp3 …）。
  final String format;

  /// 实际请求的洛雪档位。
  final String quality;

  /// 命中的插件名（用于 UI「已从 X 源补充」提示）。
  final String pluginName;

  /// 本次请求的洛雪子源（tx / wy / kw / kg …）。
  final String subSource;

  /// 失败原因；成功时为 [LxFailReason.none]。
  final LxFailReason reason;

  /// 插件/运行时返回的原始错误（多条时用「；」拼接）。
  final String error;

  bool get ok => url.isNotEmpty;

  /// 是否需要走 QMC 流式解密中继。
  bool get needsRelay => ekey.isNotEmpty;

  /// 给用户看的中文原因。
  String get reasonText => switch (reason) {
        LxFailReason.none => '',
        LxFailReason.pluginsNotLoaded => '未加载任何洛雪音源',
        LxFailReason.subSourceUnsupported => '没有音源声明支持该平台子源',
        LxFailReason.qualityUnsupported => '没有音源支持该音质档位',
        LxFailReason.pluginError => '音源脚本取链失败',
        LxFailReason.timeout => '音源取链超时',
        LxFailReason.emptyUrl => '音源返回了空链接',
      };
}

/// 单个已加载插件（一个 [LxRuntime] 对应一个音源脚本）。
class _LoadedPlugin {
  _LoadedPlugin(this.source, this.runtime);

  final LxSource source;
  final LxRuntime runtime;

  Map<String, dynamic> get declared {
    final m = runtime.inited?['sources'];
    return m is Map ? Map<String, dynamic>.from(m) : <String, dynamic>{};
  }

  bool supports(String subSource) {
    final entry = declared[subSource];
    if (entry is! Map) return false;
    final actions = entry['actions'];
    return actions is List && actions.contains('musicUrl');
  }

  List<String> qualitysOf(String subSource) {
    final entry = declared[subSource];
    if (entry is! Map) return const <String>[];
    final q = entry['qualitys'];
    return q is List
        ? q.map((e) => e.toString()).toList()
        : const <String>[];
  }
}

/// 单个子源的 `inited.sources[sub]` 声明（v2.5.7-pre2，供音源测试页筛选）。
class LxSubSourceDecl {
  const LxSubSourceDecl({
    required this.sub,
    required this.actions,
    required this.qualitys,
  });

  final String sub;
  final List<String> actions;
  final List<String> qualitys;

  bool get supportsMusicUrl => actions.contains('musicUrl');
}

/// 一个已加载插件的元信息（音源测试页「单独测试一个音源」用）。
class LxPluginInfo {
  const LxPluginInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.sources,
  });

  final String id;
  final String name;
  final String version;
  final String author;
  final Map<String, LxSubSourceDecl> sources;

  bool supports(String sub) => sources[sub]?.supportsMusicUrl ?? false;

  List<String> qualitysOf(String sub) =>
      sources[sub]?.qualitys ?? const <String>[];

  String get display => version.isEmpty ? name : '$name $version';
}

/// 洛雪音源取流入口：管理运行时池、按子源/音质路由、失败自动切下一个插件。
///
/// 所有启用插件各持一个 [LxRuntime]；脚本变更后调 [reload] 重建
/// （音源自动更新通过 `LxUpdateChecker.onSourcesChanged` 触发）。
class LxMusicApi {
  // 允许注入仓库（测试 / App 启动），同时保留可空的懒创建默认值。
  // ignore: prefer_initializing_formals
  LxMusicApi({LxSourceRepo? repo}) : _repo = repo;

  /// 全局单例（播放器 / 路由 / UI 共用）。
  static final LxMusicApi instance = LxMusicApi();

  LxSourceRepo? _repo;
  final Map<String, _LoadedPlugin> _plugins = <String, _LoadedPlugin>{};
  bool _loading = false;

  /// 最近一次加载失败的音源（v2.5.7-pre3）：`音源名 -> 失败原因`。
  ///
  /// 之前 `ensureLoaded()` 只写日志、静默跳过，用户导入了不兼容的音源
  /// （如使用当前 QuickJS 不支持的 ES2022 语法）却完全看不到提示，表现为
  /// 「纯洛雪模式莫名其妙取不了流」。这里把错误暴露给音源管理页。
  final Map<String, String> _loadErrors = <String, String>{};

  /// 加载失败明细（只读）。
  Map<String, String> get loadErrors => Map<String, String>.unmodifiable(_loadErrors);

  LxSourceRepo get repo => _repo ??= LxSourceRepo();

  /// 注入仓库（测试 / App 启动时调用），并清掉旧的运行时。
  void configure(LxSourceRepo repo) {
    if (_repo == repo) return;
    closeAll();
    _repo = repo;
  }

  /// 当前已加载的插件数（音源测试页 / UI 用）。
  int get loadedCount => _plugins.length;

  /// 已启用的插件声明支持的全部子源。
  Set<String> availableSubSources() {
    final out = <String>{};
    for (final p in _plugins.values) {
      out.addAll(p.declared.keys);
    }
    return out;
  }

  /// 已加载插件的元信息（v2.5.7-pre2，音源测试页下拉数据源）。
  ///
  /// 每个插件的 `sources` 直接来自 `runtime.inited.sources`，与取流时
  /// `_LoadedPlugin.supports/qualitysOf` 读的是同一份声明，不会出现
  /// 「测试页显示支持、实际取链却不支持」的偏差。
  List<LxPluginInfo> get pluginInfos => _plugins.values.map((p) {
        final sources = <String, LxSubSourceDecl>{};
        p.declared.forEach((key, value) {
          if (value is! Map) return;
          final sub = key.toString();
          final m = Map<String, dynamic>.from(value);
          final actions = m['actions'] is List
              ? (m['actions'] as List).map((e) => e.toString()).toList()
              : const <String>[];
          sources[sub] = LxSubSourceDecl(
            sub: sub,
            actions: actions,
            qualitys: p.qualitysOf(sub),
          );
        });
        return LxPluginInfo(
          id: p.source.id,
          name: p.source.name,
          version: p.source.version,
          author: p.source.author,
          sources: sources,
        );
      }).toList(growable: false);

  /// 重新加载所有启用音源（导入/删除/启用开关/自动更新后调用）。
  Future<void> reload() async {
    closeAll();
    await ensureLoaded();
  }

  /// 懒加载：首次取流或显式调用时才创建运行时，避免启动即跑大脚本。
  Future<void> ensureLoaded() async {
    if (_plugins.isNotEmpty || _loading) return;
    _loading = true;
    _loadErrors.clear();
    try {
      final sources = await repo.enabled();
      for (final s in sources) {
        LxRuntime? rt;
        try {
          final script = await repo.readScript(s);
          rt = LxRuntime(http: LxDioHttpClient().call);
          rt.loadScript(script, scriptInfo: <String, dynamic>{
            'name': s.name,
            'version': s.version,
            'author': s.author,
            'homepage': s.homepage,
            'description': s.description,
          });
          _plugins[s.id] = _LoadedPlugin(s, rt);
          if (rt.inited == null) {
            _loadErrors[s.name] = '脚本未声明 inited（宿主环境可能不兼容）';
            AppLog.w('LxMusicApi', '音源 ${s.name} 未声明 inited');
          }
          AppLog.d('LxMusicApi',
              '已加载音源 ${s.name} ${s.version}，声明子源 ${rt.inited?['sources']?.toString() ?? '{}'}');
        } catch (e) {
          rt?.close();
          _loadErrors[s.name] = e.toString();
          AppLog.w('LxMusicApi', '音源 ${s.name} 加载失败: $e');
        }
      }
    } finally {
      _loading = false;
    }
  }

  /// 按洛雪子源 + 音质取流。
  ///
  /// 遍历所有声明支持该子源的启用插件，逐个 `dispatch('request', …)`；
  /// 任一返回空/异常即自动切到下一个插件（音源间自动切换）。
  /// [pluginId] 非空时只使用这一个插件（音源测试页「单独测试一个音源」），
  /// 避免被其它插件静默补链导致误判该音源可用。失败结果带 [LxFailReason]
  /// 与汇总错误，供 UI / 日志如实展示。
  Future<LxPlayResult> musicUrl({
    required String subSource,
    required String quality,
    required Map<String, dynamic> musicInfo,
    String? pluginId,
  }) async {
    await ensureLoaded();
    if (_plugins.isEmpty) {
      return LxPlayResult.failed(LxFailReason.pluginsNotLoaded,
          quality: quality, subSource: subSource);
    }
    final pool = pluginId == null
        ? _plugins.values.toList(growable: false)
        : _plugins.entries
            .where((e) => e.key == pluginId)
            .map((e) => e.value)
            .toList(growable: false);
    if (pool.isEmpty) {
      return LxPlayResult.failed(LxFailReason.pluginsNotLoaded,
          error: '未找到音源 $pluginId',
          quality: quality,
          subSource: subSource);
    }
    final candidates =
        pool.where((p) => p.supports(subSource)).toList(growable: false);
    if (candidates.isEmpty) {
      return LxPlayResult.failed(LxFailReason.subSourceUnsupported,
          error: '没有音源声明支持 $subSource',
          quality: quality,
          subSource: subSource);
    }

    final errors = <String>[];
    for (final p in candidates) {
      final declaredQ = p.qualitysOf(subSource);
      final q = LxQuality.pick(quality, declaredQ);
      try {
        final res = await p.runtime.dispatch('request', <String, dynamic>{
          'action': 'musicUrl',
          'source': subSource,
          'info': <String, dynamic>{'musicInfo': musicInfo, 'type': q},
        });
        final url = res.url;
        if (res.isError) {
          final why = res.error ?? '未知错误';
          errors.add('${p.source.name}: $why');
          AppLog.w('LxMusicApi', '${p.source.name} 取链失败: $why');
          continue;
        }
        if (url == null || url.isEmpty) {
          errors.add('${p.source.name}: 空链接');
          AppLog.w('LxMusicApi', '${p.source.name} 取链返回空链接');
          continue;
        }
        return LxPlayResult(
          url: url,
          ekey: res.field('ekey')?.toString() ?? '',
          format: res.field('format')?.toString() ??
              res.field('type')?.toString() ??
              '',
          quality: q,
          pluginName: p.source.name,
          subSource: subSource,
        );
      } catch (e) {
        errors.add('${p.source.name}: $e');
        AppLog.w('LxMusicApi', '${p.source.name} 取链异常: $e');
      }
    }
    final allTimeout = errors.isNotEmpty &&
        errors.every((e) => e.toLowerCase().contains('timeout'));
    final allEmpty = errors.isNotEmpty &&
        errors.every((e) => e.contains('空链接'));
    return LxPlayResult.failed(
      allTimeout
          ? LxFailReason.timeout
          : (allEmpty ? LxFailReason.emptyUrl : LxFailReason.pluginError),
      error: errors.join('；'),
      quality: quality,
      subSource: subSource,
    );
  }

  /// 由 [Song] 直接取流：自动映射子源、音质、构造洛雪 `musicInfo`。
  Future<LxPlayResult> musicUrlForSong(
    Song song,
    dynamic quality, {
    String? pluginId,
  }) async {
    final sub = song.lxSource.isNotEmpty
        ? song.lxSource
        : LxSubSource.fromApp(song.source);
    return musicUrl(
      subSource: sub,
      quality: LxQuality.from(quality),
      musicInfo: musicInfoOf(song, sub),
      pluginId: pluginId,
    );
  }

  /// 把 App 的 [Song] 转成洛雪源脚本期望的标准 `musicInfo`。
  ///
  /// 对齐 LX-X `src/types/music.d.ts` 与 `musicSdk/*/musicInfo.js`：顶层含
  /// `id / name / singer / source / interval / meta`，tx 带 `songmid /
  /// strMediaMid / albumMid`，kg 带 `hash`。用户规则：网易云 / 酷我用 `id`，
  /// QQ 用 `mid`（即 `songmid`），酷狗用 `hash`。
  ///
  /// 兼容性要点：不同音源读的字段并不统一（baimusic 读 `songmid`、ikun 读
  /// `hash ?? songmid`），所以**所有候选字段都填上正确值**；且非酷狗平台
  /// `hash` 必须为空，否则 ikun 会优先取到一个错误的 hash 直接取链失败。
  static Map<String, dynamic> musicInfoOf(Song song, String subSource) {
    final isKg = subSource == LxSubSource.kg || song.isKugou;
    final isTx = subSource == LxSubSource.tx;
    final isWy = subSource == LxSubSource.wy || song.isNetease;

    // 网易 mid 形如 `ne$id`，去掉前缀才是真正的数字 song id。
    final numericId = song.songId > 0
        ? song.songId.toString()
        : (isWy && song.mid.startsWith('ne')
            ? song.mid.substring(2)
            : song.mid);
    // 网易 / 酷我以 id 为主键；QQ / 酷狗以 mid / albumAudioId 为主键。
    final primaryId = isWy ? numericId : song.mid;
    final songIdValue = song.songId > 0 ? song.songId : numericId;

    // 酷狗真 hash：优先 Song.hash（搜索/歌单时持久化），否则查进程内缓存。
    var kgHash = song.hash;
    if (kgHash.isEmpty && isKg) {
      kgHash = KugouApi.cachedSong(song.mid)?.hash ?? '';
    }

    // 顶层 songmid 统一填「平台主键」，让只读 songmid 的音源在任何子源
    // 都能拿到有效标识；酷狗另外提供真 hash（ikun 会优先取它）。
    final songmid = isTx ? song.mid : primaryId;

    // types / _types：酷狗按各档位 hash 构造（部分音源会从 _types[q].hash
    // 取对应音质文件），其余平台按 qualityCodes 给档位骨架。
    final types = <Map<String, dynamic>>[];
    final typesMap = <String, dynamic>{};
    final cachedKg = isKg ? KugouApi.cachedSong(song.mid) : null;
    if (cachedKg != null) {
      for (final q in cachedKg.qualities) {
        final name = LxQuality.from(q);
        final entry = <String, dynamic>{
          'type': name,
          'size': '',
          'hash': cachedKg.hashFor(q),
        };
        types.add(entry);
        typesMap[name] = <String, dynamic>{
          'size': '',
          'hash': cachedKg.hashFor(q),
        };
      }
    } else {
      for (final code in song.qualityCodes) {
        final name = LxQuality.from(code);
        types.add(<String, dynamic>{'type': name, 'size': ''});
        typesMap[name] = <String, dynamic>{'size': ''};
      }
    }
    if (types.isEmpty) {
      types.add(<String, dynamic>{'type': '128k', 'size': ''});
      typesMap['128k'] = <String, dynamic>{'size': ''};
    }

    final cover = song.coverUrl;
    final meta = <String, dynamic>{
      'songId': songIdValue,
      'albumName': song.album,
      'albumId': song.albumMid,
      'picUrl': cover,
      'qualitys': types,
      '_qualitys': typesMap,
      'hash': isKg ? kgHash : '',
      'strMediaMid': isTx ? song.mid : '',
      'songmid': songmid,
    };

    return <String, dynamic>{
      'id': primaryId,
      'songmid': songmid,
      'hash': isKg ? kgHash : '',
      'songId': songIdValue,
      'name': song.name,
      'singer': song.singer,
      'source': subSource,
      'interval': _formatInterval(song.duration),
      'duration': song.duration,
      'albumName': song.album,
      'album': song.album, // 部分音源读 album 而非 albumName
      'albumId': song.albumMid,
      'albumMid': song.albumMid,
      'strMediaMid': isTx ? song.mid : '',
      'img': cover,
      'picUrl': cover,
      'types': types,
      '_types': typesMap,
      'typeUrl': <String, dynamic>{},
      'meta': meta,
    };
  }

  /// 毫秒 → LX `interval` 字符串（`m:ss`）。
  static String _formatInterval(int durationMs) {
    if (durationMs <= 0) return '';
    final total = (durationMs / 1000).round();
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // ---------------- mflac / mgg + ekey 流式解密 ----------------

  static QmcRelayServer? _relay;

  static Future<QmcRelayServer> _ensureRelay() async {
    final r = _relay;
    if (r != null) return r;
    final server = QmcRelayServer();
    await server.start();
    return _relay = server;
  }

  /// 把带 ekey 的加密直链换成本地 QMC 解密中继地址。
  ///
  /// 不显式传 cipher：`QmcRelayServer` 会用 `createCipherFromEkey` 自动
  /// 从 ekey 派生密钥（与酷我 mflac/mgg 同一条通道），兼容各家 ekey 封装。
  /// 无 ekey 时原样返回。
  static Future<String> resolveEncrypted(
    String url,
    String ekey,
    String format,
  ) async {
    if (ekey.isEmpty || url.isEmpty) return url;
    try {
      final relay = await _ensureRelay();
      final ext = _extFor(format, url);
      return relay.urlFor(url, ekey, ext: ext);
    } catch (e) {
      AppLog.w('LxMusicApi', 'QMC 中继启动失败，回退直连: $e');
      return url;
    }
  }

  static String _extFor(String format, String url) {
    final f = format.toLowerCase();
    if (f.contains('mflac')) return 'flac';
    if (f.contains('mgg') || f.contains('ogg')) return 'ogg';
    if (f.isNotEmpty && !f.contains('/') && !f.contains('.')) return f;
    final m = RegExp(r'\.([a-zA-Z0-9]+)(?:\?|$)').firstMatch(url);
    return m?.group(1)?.toLowerCase() ?? 'flac';
  }

  void closeAll() {
    for (final p in _plugins.values) {
      p.runtime.close();
    }
    _plugins.clear();
  }
}
