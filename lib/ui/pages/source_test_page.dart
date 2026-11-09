import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../lx/lx_music_api.dart';
import '../../models/models.dart';
import '../../network/music_api.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

enum _ProbeState { idle, running, ok, fail }

class _Probe {
  _Probe({
    required this.name,
    required this.detail,
    required this.run,
  });

  final String name;
  final String detail;
  final Future<String> Function(Song? song) run;

  _ProbeState state = _ProbeState.idle;
  int ms = 0;
  String result = '';
}

/// 音源测试（v2.5.7，仿 LX Music 的 SourceTest）。
///
/// 对每个原生平台跑「搜索 + 取流」探针，对每个已启用洛雪插件声明的
/// 子源跑「取流」探针，展示耗时 / 成功失败 / 示例直链。真实网络结果
/// 如实展示，不做任何伪装——某个子源取不到链就是失败，便于用户判断
/// 该音源是否可用、是否需要换源。
class SourceTestPage extends StatefulWidget {
  const SourceTestPage({super.key});

  @override
  State<SourceTestPage> createState() => _SourceTestPageState();
}

class _SourceTestPageState extends State<SourceTestPage> {
  List<_Probe> _probes = <_Probe>[];
  bool _ready = false;
  bool _running = false;
  String _probeSongLabel = '准备中…';

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    await LxMusicApi.instance.ensureLoaded();
    final subs = LxMusicApi.instance.availableSubSources().toList()..sort();
    final probes = <_Probe>[];

    const native = <(String, String)>[
      (Source.qq, 'QQ 音乐'),
      (Source.netease, '网易云'),
      (Source.kuwo, '酷我'),
      (Source.kugou, '酷狗'),
    ];
    for (final (id, label) in native) {
      probes.add(_Probe(
        name: '$label · 搜索 + 取流',
        detail: '原生平台（未登录时高档位可能取不到链）',
        run: (song) async {
          final list = await MusicApi.search(id, '周杰伦', num: 1);
          if (list.isEmpty) throw '搜索无结果';
          final r = await MusicApi.playUrlInfo(
              list.first, Quality.mp3_128, NeteaseQuality.standard);
          if (r.isEmpty) throw '取链为空（未登录 / 无版权 / 需会员）';
          return r.url;
        },
      ));
    }

    for (final sub in subs) {
      final label = LxSubSource.labels[sub] ?? sub;
      probes.add(_Probe(
        name: '洛雪 · $label（$sub）',
        detail: 'JS 音源插件取流（128k 探针）',
        run: (song) async {
          final info = song != null
              ? LxMusicApi.musicInfoOf(song, sub)
              : <String, dynamic>{
                  'songmid': '003OUlHO1y2JzP',
                  'hash': '003OUlHO1y2JzP',
                  'name': '测试曲目',
                };
          final r = await LxMusicApi.instance.musicUrl(
            subSource: sub,
            quality: '128k',
            musicInfo: info,
          );
          if (!r.ok) throw '未取到直链（插件返回空或该子源不可用）';
          return '${r.pluginName} · ${r.quality} · ${r.url}';
        },
      ));
    }

    if (!mounted) return;
    setState(() {
      _probes = probes;
      _ready = true;
    });
  }

  Future<void> _runAll() async {
    if (_running) return;
    setState(() {
      _running = true;
      _probeSongLabel = '准备测试曲目…';
      for (final p in _probes) {
        p.state = _ProbeState.idle;
        p.ms = 0;
        p.result = '';
      }
    });

    // 用一次真实搜索拿到测试曲目，供各取流探针复用（失败则用固定 mid）。
    Song? song;
    try {
      final list = await MusicApi.search(Source.qq, '周杰伦', num: 1);
      if (list.isNotEmpty) song = list.first;
    } catch (_) {/* 探针各自会如实报失败 */}
    if (!mounted) return;
    setState(() => _probeSongLabel =
        song != null ? '${song.name} · ${song.singer}' : '默认测试 mid（搜索不可用）');

    for (final p in _probes) {
      if (!mounted) return;
      setState(() => p.state = _ProbeState.running);
      final sw = Stopwatch()..start();
      try {
        final r = await p.run(song).timeout(const Duration(seconds: 20));
        sw.stop();
        if (!mounted) return;
        setState(() {
          p.state = _ProbeState.ok;
          p.ms = sw.elapsedMilliseconds;
          p.result = r;
        });
      } catch (e) {
        sw.stop();
        if (!mounted) return;
        setState(() {
          p.state = _ProbeState.fail;
          p.ms = sw.elapsedMilliseconds;
          p.result = e.toString();
        });
      }
    }
    if (!mounted) return;
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '音源测试',
      actions: [
        MiuixTextButton(
          _running ? '测试中…' : '运行全部',
          onPressed: (_running || !_ready) ? null : _runAll,
        ),
      ],
      child: !_ready
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.zero,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    '逐个音源跑真实「搜索 / 取流」探针，展示延迟与结果。'
                    '测试曲目：$_probeSongLabel。'
                    '洛雪子源只有被已启用插件声明时才会出现；'
                    '失败会如实显示原因，可据此增删或切换音源。',
                    style: TextStyle(
                        fontSize: 11.5,
                        height: 1.6,
                        color: AppColors.textTertiary),
                  ),
                ),
                const SizedBox(height: 12),
                if (_probes.isEmpty)
                  GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '没有可测试的音源。请先在「洛雪音源」页导入并启用音源。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13, color: AppColors.textTertiary),
                      ),
                    ),
                  )
                else
                  for (final p in _probes) _buildProbeCard(p),
                const SizedBox(height: 20),
              ],
            ),
    );
  }

  Widget _buildProbeCard(_Probe p) {
    final (icon, color, status) = switch (p.state) {
      _ProbeState.idle => (Icons.radio_button_unchecked_rounded,
          AppColors.textTertiary, '未测试'),
      _ProbeState.running => (Icons.sync_rounded, AppColors.cyan, '测试中…'),
      _ProbeState.ok => (Icons.check_circle_rounded, AppColors.accent, '成功'),
      _ProbeState.fail => (Icons.error_rounded, AppColors.danger, '失败'),
    };
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
                  p.name,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary),
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
          if (p.result.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.bg2,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                p.result,
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
