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
/// 四个筛选维度是笛卡尔积，「全部音源 × 全部音质 × 全部子源 × 全部平台」
/// 会一次跑出上百条请求打爆音源网关（部分音源如 ikun 有 429 限流），
/// 因此超限截断并提示用户缩小筛选范围。
const int _kMaxProbes = 60;

/// 子源下拉里「全部子源」的哨兵值（与空串「自动」区分）。
const String _kAllSubSources = '__all__';

/// 搜索不可用 / mg、git 子源无对应原生平台时使用的固定测试 mid。
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

/// 洛雪子源 ↔ 曲目来源平台的匹配关系（用于「自动」联动与不匹配提示）。
/// mg / git 没有对应平台，故不在表内，用固定 mid。
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

  /// 样本曲目来源平台；空串表示用固定 mid。
  final String samplePlatform;
  final String detail;
  final Future<LxPlayResult> Function() run;

  _ProbeState state = _ProbeState.idle;
  int ms = 0;
  LxPlayResult? result;

  /// 运行时异常（非音源脚本返回的失败原因）。
  String error = '';
}

/// 洛雪音源测试（v2.5.7-pre2 重写，仿 LX Music 的 SourceTest）。
///
/// **只测试用户导入的洛雪 JS 音源**，不再对 QQ / 网易云 / 酷我 / 酷狗跑
/// 原生「搜索 + 取流」探针。[MusicApi.search] 仅用于按平台准备一条样本
/// mid，**不算测试原生取链**。
///
/// 四个筛选维度：单个音源 / 洛雪音质 / 洛雪子源 / 曲目来源平台；每张卡片
/// 支持单独测试，顶部保留「运行全部」。结果如实展示延迟、命中的插件、
/// 子源、档位与直链，或 [LxPlayResult.reasonText] 的失败原因。
class SourceTestPage extends StatefulWidget {
  const SourceTestPage({super.key});

  @override
  State<SourceTestPage> createState() => _SourceTestPageState();
}

class _SourceTestPageState extends State<SourceTestPage> {
  List<_Probe> _probes = <_Probe>[];
  List<LxPluginInfo> _pluginInfos = <LxPluginInfo>[];

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

  /// 按平台缓存样本曲目（null = 搜索失败，回退固定 mid）。
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
    try {
      infos = LxMusicApi.instance.pluginInfos;
    } catch (e) {
      AppLog.w('SourceTestPage', '读取音源声明失败: $e');
      infos = <LxPluginInfo>[];
    }
    if (!mounted) return;
    setState(() {
      _pluginInfos = infos;
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

  /// 计算音质并集时参考的子源集合。
  List<String> _declaredSubsForFilter() {
    if (_subSource == _kAllSubSources) return LxSubSource.all;
    if (_subSource.isNotEmpty) return <String>[_subSource];
    final platforms = _samplePlatform.isEmpty
        ? _kSamplePlatforms
        : <String>[_samplePlatform];
    return platforms.map(LxSubSource.fromApp).toSet().toList();
  }

  /// 当前「音源 × 子源」下所有插件声明的音质并集，按 [LxQuality.all] 排序。
  /// 不硬编码全部档位：某些音源只声明 4 档，硬编码会造出必假失败探针。
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

  /// (子源, 样本平台) 组合。
  ///
  /// - 「自动」：子源跟随曲目平台；
  /// - 指定子源 / 全部子源：每个子源配它匹配的样本平台（mg/git 用固定
  ///   mid）；若用户**明确**选了某个曲目平台，则一律用该平台，卡片
  ///   detail 会标注「不匹配」，如实提示失败可能来自组合不当。
  ///
  /// 这样「曲目平台 = 全部」不会与 6 个子源做无意义的笛卡尔积。
  List<({String sub, String platform})> _probeCombos() {
    final out = <({String sub, String platform})>[];
    final explicitPlatform = _samplePlatform.isNotEmpty;

    if (_subSource == _kAllSubSources) {
      for (final sub in LxSubSource.all) {
        final matched = _kSubPlatform[sub];
        out.add((
          sub: sub,
          platform: matched == null
              ? ''
              : (explicitPlatform ? _samplePlatform : matched),
        ));
      }
    } else if (_subSource.isNotEmpty) {
      final matched = _kSubPlatform[_subSource];
      if (matched == null) {
        out.add((sub: _subSource, platform: ''));
      } else {
        out.add((
          sub: _subSource,
          platform: explicitPlatform ? _samplePlatform : matched,
        ));
      }
    } else {
      final platforms =
          explicitPlatform ? <String>[_samplePlatform] : _kSamplePlatforms;
      for (final platform in platforms) {
        out.add((sub: LxSubSource.fromApp(platform), platform: platform));
      }
    }
    return out;
  }

  void _rebuildProbes() {
    var probes = <_Probe>[];
    final plugins = _selectedPlugins();
    final qualities = _quality.isEmpty ? _qualities : <String>[_quality];
    final combos = _probeCombos();

    for (final plugin in plugins) {
      for (final quality in qualities) {
        for (final combo in combos) {
          final sub = combo.sub;
          final platform = combo.platform;
          final matchedPlatform = _kSubPlatform[sub];
          final mismatch = matchedPlatform != null &&
              platform.isNotEmpty &&
              matchedPlatform != platform;
          final subLabel = LxSubSource.labels[sub] ?? sub;
          final platformLabel = platform.isEmpty
              ? '固定 mid'
              : (_kPlatformLabels[platform] ?? platform);
          final detail = '音源 ${plugin.display} · 子源 $subLabel($sub)'
              ' · 档位 $quality · 样本 $platformLabel'
              '${mismatch ? '（子源与样本平台不匹配，失败可能源于此）' : ''}';

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
                info = song != null
                    ? LxMusicApi.musicInfoOf(song, sub)
                    : _fixedMusicInfo(sub);
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

  static Map<String, dynamic> _fixedMusicInfo(String sub) =>
      <String, dynamic>{
        'songmid': _kFallbackMid,
        'hash': _kFallbackMid,
        'name': '测试曲目',
        'source': sub,
      };

  // ===== 样本曲目（按平台搜索并缓存，仅用于准备 mid） =====

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
          ? '固定测试 mid（按平台搜索不可用）'
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
          '只测试已导入的洛雪 JS 音源：按「音源 / 音质 / 子源 / 曲目平台」筛选后'
          '逐个取流，展示延迟与真实结果。曲目平台仅用于按平台搜索一条样本 mid'
          '（不算测试原生取链）；样本：$_probeSongLabel。'
          '失败会如实显示原因，可据此增删或切换音源。',
          style: TextStyle(
              fontSize: 11.5, height: 1.6, color: AppColors.textTertiary),
        ),
      );

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
