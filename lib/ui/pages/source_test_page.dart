import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/app_logger.dart';
import '../../lx/lx_music_api.dart';
import '../../models/models.dart';
import '../../network/music_api.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

enum _ProbeState { idle, running, ok, fail }

/// 一次「运行全部」最多生成的探针数。
///
/// 虽然已按插件声明裁剪，但「全部音源 × 全部音质 × 全部子源」仍可能很多，
/// 超限截断并提示用户缩小筛选范围，避免打爆音源网关（部分音源有 429 限流）。
const int _kMaxProbes = 60;

/// 子源下拉里「全部子源」的哨兵值（与空串「自动」区分）。
const String _kAllSubSources = '__all__';

/// mg / git 子源没有对应原生平台，只能用占位标识做连通性参考。
const String _kFallbackMid = '003OUlHO1y2JzP';

/// 可作为样本来源的四个原生平台。
const List<String> _kSamplePlatforms = [
  Source.qq,
  Source.netease,
  Source.kuwo,
  Source.kugou,
];

const Map<String, String> _kPlatformLabels = {
  Source.qq: 'QQ 音乐',
  Source.netease: '网易云',
  Source.kuwo: '酷我',
  Source.kugou: '酷狗',
};

/// 洛雪子源 ↔ 曲目来源平台的匹配关系。
/// 用户规则：网易云/酷我按 `id`、QQ 按 `mid`、酷狗按 `hash` 取流，
/// 所以子源与样本平台必须严格对应，错配的探针没有意义。
const Map<String, String> _kSubPlatform = {
  LxSubSource.tx: Source.qq,
  LxSubSource.wy: Source.netease,
  LxSubSource.kw: Source.kuwo,
  LxSubSource.kg: Source.kugou,
};

/// 一条洛雪取流探针。
class _Probe {
  _Probe({
    required this.pluginId,
    required this.pluginName,
    required this.subSource,
    required this.quality,
    required this.samplePlatform,
    required this.detail,
    required this.run,
  });

  /// 锁定的插件 id。**始终非空**：即使「全部音源」也拆成每个插件一条探针，
  /// 避免测 A 时被 B 静默补链导致误判 A 可用。
  final String pluginId;
  final String pluginName;
  final String subSource;
  final String quality;

  /// 样本曲目来源平台；空串表示 mg/git 用占位标识。
  final String samplePlatform;
  final String detail;
  final Future<LxPlayResult> Function() run;

  _ProbeState state = _ProbeState.idle;
  int ms = 0;
  LxPlayResult? result;

  /// 运行时异常（非音源脚本返回的失败原因）。
  String error = '';
}

/// 洛雪音源测试（v2.5.7-pre3 重做，仿 LX Music 的 SourceTest）。
///
/// **只测试用户导入的洛雪 JS 音源**。[MusicApi.search] 仅用于按平台准备
/// 一条真实样本曲目，不算测试原生取链。
///
/// v2.5.7-pre2 的问题：按「所有子源 × 所有平台」做笛卡尔积、用固定假 mid
/// 打真实网关、样本搜索失败也照跑，导致整页必然全红。现在：
/// - 只生成插件 `inited.sources` 声明支持 `musicUrl` 的子源与音质；
/// - 子源与样本平台强制匹配（tx↔QQ、wy↔网易、kw↔酷我、kg↔酷狗）；
/// - 用 [LxMusicApi.musicInfoOf] 构造洛雪标准 `musicInfo`（酷狗真 hash、
///   网易/酷我 id、QQ songmid），样本搜索失败如实报错而非用假 mid 冒充；
/// - 顶部展示加载失败的音源，不再静默跳过。
class SourceTestPage extends StatefulWidget {
  const SourceTestPage({super.key});

  @override
  State<SourceTestPage> createState() => _SourceTestPageState();
}

class _SourceTestPageState extends State<SourceTestPage> {
  List<_Probe> _probes = <_Probe>[];
  List<LxPluginInfo> _pluginInfos = <LxPluginInfo>[];

  /// 加载失败的音源（v2.5.7-pre3）：不再静默吞掉。
  Map<String, String> _loadErrors = <String, String>{};

  /// 当前筛选下所有插件声明的音质并集（动态，不硬编码全部档位）。
  List<String> _qualities = <String>['128k'];

  bool _ready = false;
  bool _running = false;
  bool _truncated = false;
  String _probeSongLabel = '按平台自动准备';

  // ===== 四个筛选维度 =====
  String _pluginId = ''; // '' = 全部音源
  String _quality = '128k'; // '' = 全部音质
  String _subSource = ''; // '' = 自动；_kAllSubSources = 全部；否则具体子源
  String _samplePlatform = ''; // '' = 全部平台

  /// 按平台缓存样本曲目（null = 搜索失败）。
  final Map<String, Song?> _samples = <String, Song?>{};

  /// 缓存搜索 Future，避免并发 / 重复请求同一平台。
  final Map<String, Future<Song?>> _sampleFutures = <String, Future<Song?>>{};

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  /// 只做音源加载与筛选初始化；样本搜索延迟到真正跑探针时按需进行，
  /// 页面打开不产生网络请求，widget smoke 测试也不会被网络挂住。
  Future<void> _prepare() async {
    try {
      await LxMusicApi.instance.ensureLoaded();
    } catch (e) {
      AppLog.w('SourceTestPage', '洛雪音源加载失败: $e');
    }
    List<LxPluginInfo> infos;
    Map<String, String> errors;
    try {
      infos = LxMusicApi.instance.pluginInfos;
      errors = LxMusicApi.instance.loadErrors;
    } catch (e) {
      AppLog.w('SourceTestPage', '读取音源声明失败: $e');
      infos = <LxPluginInfo>[];
      errors = <String, String>{};
    }
    if (!mounted) return;
    setState(() {
      _pluginInfos = infos;
      _loadErrors = errors;
      _refreshFilters();
      _ready = true;
    });
  }

  // ===== 筛选与探针生成 =====

  void _onFilterChanged(void Function() apply) {
    setState(() {
      apply();
      _refreshFilters();
    });
  }

  void _refreshFilters() {
    _qualities = _computeQualities();
    // 切换音源 / 子源后，当前选中的档位可能已不在并集里，回落到第一档。
    if (_quality.isNotEmpty && !_qualities.contains(_quality)) {
      _quality = _qualities.isNotEmpty ? _qualities.first : '128k';
    }
    if (_pluginId.isNotEmpty && !_pluginInfos.any((p) => p.id == _pluginId)) {
      _pluginId = '';
    }
    _rebuildProbes();
  }

  List<LxPluginInfo> _selectedPlugins() => _pluginId.isEmpty
      ? _pluginInfos
      : _pluginInfos.where((p) => p.id == _pluginId).toList(growable: false);

  /// 计算音质并集时参考的子源集合：只取选中插件**实际声明**的子源，
  /// 避免造出「该音源根本不支持」的必假失败档位。
  List<String> _declaredSubsForFilter() {
    final declared = <String>{};
    for (final p in _selectedPlugins()) {
      for (final e in p.sources.entries) {
        if (e.value.supportsMusicUrl) declared.add(e.key);
      }
    }
    if (_subSource == _kAllSubSources) return declared.toList();
    if (_subSource.isNotEmpty) {
      return declared.contains(_subSource) ? <String>[_subSource] : <String>[];
    }
    final platforms = _samplePlatform.isEmpty
        ? _kSamplePlatforms
        : <String>[_samplePlatform];
    final wanted = platforms.map(LxSubSource.fromApp).toSet();
    return declared.where(wanted.contains).toList();
  }

  /// 当前「音源 × 子源」下所有插件声明的音质并集，按 [LxQuality.all] 排序。
  List<String> _computeQualities() {
    final set = <String>{};
    final subs = _declaredSubsForFilter();
    for (final plugin in _selectedPlugins()) {
      for (final sub in subs) {
        set.addAll(plugin.qualitysOf(sub));
      }
    }
    final list = set.toList();
    int rank(String s) {
      final i = LxQuality.all.indexOf(s);
      return i < 0 ? LxQuality.all.length : i;
    }

    list.sort((a, b) {
      final c = rank(a).compareTo(rank(b));
      return c != 0 ? c : a.compareTo(b);
    });
    return list.isEmpty ? <String>['128k'] : list;
  }

  /// 某个插件在当前筛选下真正要测的子源：只取它声明支持 `musicUrl` 的子源。
  List<String> _subsForProbe(LxPluginInfo plugin) {
    final declared = plugin.sources.entries
        .where((e) => e.value.supportsMusicUrl)
        .map((e) => e.key)
        .where((sub) => LxSubSource.all.contains(sub))
        .toList();
    if (_subSource == _kAllSubSources) return declared;
    if (_subSource.isNotEmpty) {
      return declared.contains(_subSource) ? <String>[_subSource] : <String>[];
    }
    // 「自动」：子源跟随曲目平台。
    final platforms = _samplePlatform.isEmpty
        ? _kSamplePlatforms
        : <String>[_samplePlatform];
    final wanted = platforms.map(LxSubSource.fromApp).toSet();
    return declared.where(wanted.contains).toList();
  }

  void _rebuildProbes() {
    var probes = <_Probe>[];
    for (final plugin in _selectedPlugins()) {
      for (final sub in _subsForProbe(plugin)) {
        final platform = _kSubPlatform[sub] ?? '';
        // 明确选了曲目平台却与该子源不匹配 → 直接跳过，不造必假失败项。
        if (_samplePlatform.isNotEmpty &&
            platform.isNotEmpty &&
            _samplePlatform != platform) {
          continue;
        }
        // 只测该插件在这个子源上声明过的音质档位。
        final declaredQ = plugin.qualitysOf(sub);
        final qualities = (_quality.isEmpty ? _qualities : <String>[_quality])
            .where((q) => declaredQ.isEmpty || declaredQ.contains(q))
            .toList();
        for (final quality in qualities) {
          final subLabel = LxSubSource.labels[sub] ?? sub;
          final platformLabel = platform.isEmpty
              ? '占位标识（该子源无对应平台，结果仅供参考）'
              : (_kPlatformLabels[platform] ?? platform);
          final detail = '音源 ${plugin.display} · 子源 $subLabel($sub)'
              ' · 档位 $quality · 样本 $platformLabel';

          probes.add(_Probe(
            pluginId: plugin.id,
            pluginName: plugin.display,
            subSource: sub,
            quality: quality,
            samplePlatform: platform,
            detail: detail,
            run: () async {
              Map<String, dynamic> info;
              if (platform.isEmpty) {
                info = _fixedMusicInfo(sub);
              } else {
                final song = await _sampleFor(platform);
                if (song == null) {
                  // 不再拿假 mid 冒充测试结果：如实说明样本没准备好。
                  return LxPlayResult.failed(
                    LxFailReason.pluginError,
                    error: '${_kPlatformLabels[platform] ?? platform} '
                        '样本搜索失败，无法准备真实曲目',
                    quality: quality,
                    subSource: sub,
                    pluginName: plugin.display,
                  );
                }
                info = LxMusicApi.musicInfoOf(song, sub);
              }
              return LxMusicApi.instance.musicUrl(
                subSource: sub,
                quality: quality,
                musicInfo: info,
                pluginId: plugin.id,
              );
            },
          ));
        }
      }
    }

    _truncated = probes.length > _kMaxProbes;
    if (_truncated) probes = probes.sublist(0, _kMaxProbes);
    _probes = probes;
  }

  /// mg / git 没有对应原生平台，只能给一份洛雪标准结构的占位 musicInfo。
  static Map<String, dynamic> _fixedMusicInfo(String sub) =>
      <String, dynamic>{
        'id': _kFallbackMid,
        'songmid': _kFallbackMid,
        'hash': '',
        'songId': _kFallbackMid,
        'name': '测试曲目',
        'singer': '测试',
        'source': sub,
        'interval': '0:00',
        'albumName': '',
        'types': <Map<String, dynamic>>[
          <String, dynamic>{'type': '128k', 'size': ''}
        ],
        '_types': <String, dynamic>{
          '128k': <String, dynamic>{'size': ''}
        },
        'typeUrl': <String, dynamic>{},
        'meta': <String, dynamic>{
          'songId': _kFallbackMid,
          'albumName': '',
          'qualitys': <dynamic>[],
          '_qualitys': <String, dynamic>{},
          'hash': '',
        },
      };

  // ===== 样本曲目（按平台搜索并缓存） =====

  Future<Song?> _sampleFor(String platform) {
    final cached = _sampleFutures[platform];
    if (cached != null) return cached;
    final future = _fetchSample(platform);
    _sampleFutures[platform] = future;
    return future;
  }

  Future<Song?> _fetchSample(String platform) async {
    try {
      final list = await MusicApi.search(platform, '周杰伦', num: 1)
          .timeout(const Duration(seconds: 8));
      if (list.isNotEmpty) {
        _samples[platform] = list.first;
        _updateSongLabel();
        return list.first;
      }
    } catch (e) {
      AppLog.w('SourceTestPage',
          '准备 ${_kPlatformLabels[platform] ?? platform} 样本失败: $e');
    }
    _samples[platform] = null;
    return null;
  }

  void _updateSongLabel() {
    if (!mounted) return;
    final found = _samples.entries
        .where((e) => e.value != null)
        .map((e) => '${_kPlatformLabels[e.key] ?? e.key}: ${e.value!.name}')
        .toList();
    setState(() {
      _probeSongLabel = found.isEmpty
          ? '按平台自动准备（尚未搜索）'
          : found.join(' / ');
    });
  }

  // ===== 执行 =====

  /// 单独跑一条探针；[LxPlayResult] 的失败原因如实写回卡片。
  Future<void> _runOne(_Probe p) async {
    if (p.state == _ProbeState.running || !mounted) return;
    setState(() {
      p.state = _ProbeState.running;
      p.ms = 0;
      p.result = null;
      p.error = '';
    });
    final sw = Stopwatch()..start();
    try {
      final r = await p.run().timeout(const Duration(seconds: 30));
      sw.stop();
      if (!mounted) return;
      setState(() {
        p.ms = sw.elapsedMilliseconds;
        p.result = r;
        p.state = r.ok ? _ProbeState.ok : _ProbeState.fail;
      });
    } catch (e) {
      sw.stop();
      if (!mounted) return;
      setState(() {
        p.ms = sw.elapsedMilliseconds;
        p.error = e.toString();
        p.state = _ProbeState.fail;
      });
    }
  }

  Future<void> _runAll() async {
    if (_running || _probes.isEmpty) return;
    setState(() {
      _running = true;
      for (final p in _probes) {
        p.state = _ProbeState.idle;
        p.ms = 0;
        p.result = null;
        p.error = '';
      }
    });
    for (final p in _probes) {
      if (!mounted) return;
      await _runOne(p);
    }
    if (!mounted) return;
    setState(() => _running = false);
  }

  // ===== UI =====

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '音源测试',
      actions: [
        MiuixTextButton(
          _running ? '测试中…' : '运行全部',
          onPressed: (_running || !_ready || _probes.isEmpty) ? null : _runAll,
        ),
      ],
      child: !_ready
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.zero,
              children: [
                _buildIntro(),
                const SizedBox(height: 10),
                _buildLoadErrors(),
                _buildFilters(),
                const SizedBox(height: 12),
                if (_truncated) _buildTruncatedHint(),
                if (_pluginInfos.isEmpty)
                  _buildEmpty('没有可测试的音源。请先在「洛雪音源」页导入并启用音源。')
                else if (_probes.isEmpty)
                  _buildEmpty('当前筛选下没有可测试的组合，请调整音源 / 音质 / 子源 / 平台。')
                else
                  for (final p in _probes) _buildProbeCard(p),
                const SizedBox(height: 20),
              ],
            ),
    );
  }

  Widget _buildIntro() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          '只测试已导入的洛雪 JS 音源：按每个音源声明的子源与音质生成探针，'
          '子源与曲目平台强制匹配（QQ / 网易云 / 酷我 / 酷狗），'
          '曲目平台仅用于搜索一条真实样本（不算测试原生取链）。'
          '样本：$_probeSongLabel。样本搜索失败会如实报错，不再用假 mid 冒充结果。',
          style: TextStyle(
              fontSize: 11.5, height: 1.6, color: AppColors.textTertiary),
        ),
      );

  /// 加载失败的音源不再静默跳过（v2.5.7-pre3）。
  Widget _buildLoadErrors() {
    if (_loadErrors.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '有 ${_loadErrors.length} 个音源加载失败（不参与测试）',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.danger),
              ),
              const SizedBox(height: 6),
              for (final e in _loadErrors.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${e.key}：${e.value}',
                    style: TextStyle(
                        fontSize: 11, height: 1.4,
                        color: AppColors.textTertiary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilters() => GlassCard(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        child: Column(
          children: [
            _filterRow(
              label: '音源',
              value: _pluginId,
              items: [
                (value: '', label: '全部音源（逐个单独测试）'),
                for (final p in _pluginInfos) (value: p.id, label: p.display),
              ],
              onChanged: (v) => _onFilterChanged(() => _pluginId = v),
            ),
            const MiuixHorizontalDivider(),
            _filterRow(
              label: '洛雪音质',
              value: _quality,
              items: [
                (value: '', label: '全部音质（${_qualities.length} 档）'),
                for (final q in _qualities) (value: q, label: q),
              ],
              onChanged: (v) => _onFilterChanged(() => _quality = v),
            ),
            const MiuixHorizontalDivider(),
            _filterRow(
              label: '洛雪子源',
              value: _subSource,
              items: [
                (value: '', label: '自动（跟随曲目平台）'),
                (value: _kAllSubSources, label: '全部子源'),
                for (final sub in LxSubSource.all)
                  (value: sub, label: '${LxSubSource.labels[sub] ?? sub} ($sub)'),
              ],
              onChanged: (v) => _onFilterChanged(() => _subSource = v),
            ),
            const MiuixHorizontalDivider(),
            _filterRow(
              label: '曲目平台',
              value: _samplePlatform,
              items: [
                (value: '', label: '全部平台（按子源自动匹配）'),
                for (final platform in _kSamplePlatforms)
                  (value: platform,
                      label: _kPlatformLabels[platform] ?? platform),
              ],
              onChanged: (v) => _onFilterChanged(() => _samplePlatform = v),
            ),
          ],
        ),
      );

  Widget _filterRow({
    required String label,
    required String value,
    required List<({String value, String label})> items,
    required ValueChanged<String> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
              width: 68,
              child: Text(
                label,
                style: TextStyle(
                    fontSize: 12, color: AppColors.textSecondary),
              ),
            ),
            Expanded(
              child: DropdownButton<String>(
                value: items.any((i) => i.value == value) ? value : null,
                isExpanded: true,
                isDense: true,
                dropdownColor: AppColors.bg2,
                underline: const SizedBox.shrink(),
                style: TextStyle(
                    fontSize: 12.5, color: AppColors.textPrimary),
                items: [
                  for (final item in items)
                    DropdownMenuItem<String>(
                      value: item.value,
                      child: Text(
                        item.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5, color: AppColors.textPrimary),
                      ),
                    ),
                ],
                onChanged: _running
                    ? null
                    : (v) {
                        if (v != null) onChanged(v);
                      },
              ),
            ),
          ],
        ),
      );

  Widget _buildTruncatedHint() => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          '组合过多，已按上限 $_kMaxProbes 条探针截断。'
          '请缩小「音源 / 音质 / 子源 / 平台」的筛选范围后再运行全部。',
          style: TextStyle(fontSize: 11.5, color: AppColors.danger),
        ),
      );

  Widget _buildEmpty(String text) => GlassCard(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
          ),
        ),
      );

  Widget _buildProbeCard(_Probe p) {
    final (icon, color, status) = switch (p.state) {
      _ProbeState.idle => (Icons.radio_button_unchecked_rounded,
          AppColors.textTertiary, '未测试'),
      _ProbeState.running =>
        (Icons.sync_rounded, AppColors.cyan, '测试中…'),
      _ProbeState.ok => (Icons.check_circle_rounded, AppColors.accent, '成功'),
      _ProbeState.fail => (Icons.error_rounded, AppColors.danger, '失败'),
    };

    final r = p.result;
    String text = '';
    if (p.state == _ProbeState.ok && r != null) {
      final subLabel = LxSubSource.labels[r.subSource] ?? r.subSource;
      text = '${r.pluginName} · $subLabel(${r.subSource})'
          ' · ${r.quality} · ${r.url}';
    } else if (p.state == _ProbeState.fail) {
      if (r != null) {
        text = [r.reasonText, r.error]
            .where((s) => s.isNotEmpty)
            .join('：');
      } else {
        text = p.error;
      }
      if (text.isEmpty) text = '取链失败';
    }

    return GlassCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${p.pluginName} · ${p.subSource} · ${p.quality}',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary),
                ),
              ),
              if (!_running)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: SizedBox(
                    height: 26,
                    child: TextButton(
                      onPressed: _ready ? () => _runOne(p) : null,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        '测试',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.accent),
                      ),
                    ),
                  ),
                ),
              if (p.ms > 0)
                Text('${p.ms} ms',
                    style: TextStyle(
                        fontSize: 11, color: AppColors.textTertiary)),
              const SizedBox(width: 8),
              TagBadge(status, color: color),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            p.detail,
            style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
          ),
          if (text.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.bg2,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    fontFamily: 'monospace',
                    color: p.state == _ProbeState.fail
                        ? AppColors.danger
                        : AppColors.textSecondary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
