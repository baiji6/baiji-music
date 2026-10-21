// 酷我 ID / 单曲链接直达播放（v2.4.0-fix1）
//
// 入口：工具箱 → 音乐工具 →「酷我 ID 直达播放」。
//
// 支持三种输入：
//   1. 纯数字歌曲 ID（rid），例如 7149583
//   2. 酷我网页版单曲链接，例如 https://www.kuwo.cn/play_detail/7149583
//   3. 酷我移动端单曲链接，例如 https://m.kuwo.cn/newh5app/song_detail/7149583
//
// 解析出 rid 后调酷我 `music.pay` 拿元信息 + 音质列表，
// 再交给播放器按降级链取链接（加密音轨走本地 QMC 中继解密）。
library;

import 'package:flutter/material.dart';

import '../../network/kuwo/kuwo_api.dart';
import '../../network/music_api.dart';
import '../../player/player_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_widgets.dart';

/// 酷我 ID 直达播放页。
class KuwoDirectPage extends StatefulWidget {
  const KuwoDirectPage({super.key});

  @override
  State<KuwoDirectPage> createState() => _KuwoDirectPageState();
}

class _KuwoDirectPageState extends State<KuwoDirectPage> {
  final _controller = TextEditingController();

  bool _loading = false;
  String? _error;
  KuwoSong? _song;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 从输入中解析酷我 rid。
  ///
  /// 纯数字直接当 rid；否则从链接里抠出末尾的数字 id。
  static String? parseRid(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;
    if (RegExp(r'^\d+$').hasMatch(s)) return s;
    final m = RegExp(
            r'(?:play_detail|song_detail|music|yinyue|song)/(\d+)')
        .firstMatch(s);
    if (m != null) return m.group(1);
    // 兜底：链接里最后一个连续数字段
    final nums = RegExp(r'(\d{3,})').allMatches(s).toList();
    if (nums.isNotEmpty) return nums.last.group(1);
    return null;
  }

  Future<void> _resolve() async {
    final input = _controller.text.trim();
    if (input.isEmpty) {
      setState(() => _error = '请输入酷我歌曲 ID 或单曲链接');
      return;
    }
    final rid = parseRid(input);
    if (rid == null) {
      setState(() => _error = '无法从输入中解析出酷我歌曲 ID');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final song = await KuwoApi.songInfo(rid);
      if (!mounted) return;
      if (song == null || song.name.isEmpty) {
        setState(() {
          _loading = false;
          _error = '未找到该 ID 对应的歌曲（rid=$rid）';
        });
        return;
      }
      setState(() {
        _song = song;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '查询失败：$e';
      });
    }
  }

  void _play() {
    final s = _song;
    if (s == null) return;
    final song = MusicApi.kuwoSongToSong(s);
    PlayerController.instance.playQueue([song], startIndex: 0);
    showAppSnack('开始播放：${s.name}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg2,
      appBar: AppBar(
        title: const Text('酷我 ID 直达播放'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '输入酷我歌曲 ID（rid）或单曲链接，直接跳到播放。'
            '加密音轨会自动走本地 QMC 解密。',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          AppTextField(
            controller: _controller,
            label: '酷我歌曲 ID / 单曲链接',
            useLabelAsPlaceholder: true,
            singleLine: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _resolve(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: NeonButton(
                  label: _loading ? '查询中…' : '查询歌曲',
                  icon: Icons.search_rounded,
                  onPressed: _loading ? null : _resolve,
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(fontSize: 13, color: AppColors.danger),
            ),
          ],
          if (_song != null) ...[
            const SizedBox(height: 20),
            SectionHeader(title: _song!.name),
            GlassCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoRow(label: '歌曲', value: _song!.name),
                  _InfoRow(label: '歌手', value: _song!.artist),
                  _InfoRow(label: '专辑', value: _song!.album),
                  _InfoRow(label: '时长', value: '${_song!.durationSeconds} 秒'),
                  _InfoRow(label: '歌曲 ID', value: _song!.rid),
                  const SizedBox(height: 8),
                  Text(
                    '可用音质：${_song!.qualities.isEmpty ? '（未知）' : _song!.qualities.map((q) => q.label).join(' · ')}',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textTertiary),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: NeonButton(
                          label: '立即播放',
                          icon: Icons.play_arrow_rounded,
                          onPressed: _play,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一行「标签 : 值」。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
