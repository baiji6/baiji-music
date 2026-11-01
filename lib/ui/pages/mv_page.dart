// MV 播放页 —— WebView + HTML5 `<video>` + 本地防盗链代理。
//
// 为什么用 WebView 而不是 media_kit：
//   media_kit 当前依赖 `media_kit_libs_audio`（纯音频库），且 Android 侧
//   换成 `media_kit_libs_video` 会顶掉自编译的 AC-4 补丁库（杜比全景声
//   音质档依赖它，见 pubspec dependency_overrides），不能为 MV 牺牲。
//   WebView 的 `<video>` 原生支持 mp4（Android 内置播放器 / iOS
//   WKWebView），webview_flutter 本就是现有依赖；桌面端（Windows/Linux）
//   无实现，通过 [mvSupportedPlatform] 隐藏入口。
//
// 加载链路（v2.4.3）：
//   点 MV 按钮 → （mvId 为空时兜底查详情）→ MvApi.fetch 取源
//   → MvProxyServer.register 得到 127.0.0.1 代理地址（注入 Referer/UA，
//   Range 透传支持拖动）→ WebView 加载内嵌 HTML 自动播放。
//
// 打开页面时暂停音乐（音频视频抢焦点会互相打断，先停更干净）；
// 返回时不自动恢复，由用户继续。
library;

import 'dart:convert';
import 'dart:io';

import 'package:baiji_music/core/app_logger.dart';
import 'package:baiji_music/models/models.dart';
import 'package:baiji_music/network/mv/mv_api.dart';
import 'package:baiji_music/network/mv/mv_proxy.dart';
import 'package:baiji_music/network/mv/mv_source.dart';
import 'package:baiji_music/network/music_api.dart';
import 'package:baiji_music/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
// AndroidWebViewController（自动播放手势开关是 Android 专属 API）
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// 当前平台能否播 MV（webview_flutter 覆盖 Android / iOS / macOS）。
bool get mvSupportedPlatform =>
    Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

class MvPage extends StatefulWidget {
  const MvPage({
    super.key,
    required this.song,
    required this.onPauseMusic,
    this.mvIdOverride,
  });

  final Song song;

  /// 打开页面时暂停音乐（由播放页传入，通常是有条件地 toggle）。
  final VoidCallback onPauseMusic;

  /// 播放页兜底查询出的 mvId（可为空，为空时本页再查）。
  final String? mvIdOverride;

  @override
  State<MvPage> createState() => _MvPageState();
}

class _MvPageState extends State<MvPage> {
  WebViewController? _controller;
  bool _htmlLoaded = false;

  _MvPhase _phase = _MvPhase.loading;
  String _statusText = '正在获取 MV 播放源…';

  String _qualityKey = '';
  List<MvQuality> _qualities = const [];
  MvQuality _requested = MvApi.defaultQuality;
  bool _reloading = false;

  /// 当前会话已知的 mvId（兜底查询后回填，切画质复用）。
  String _resolvedMvId = '';

  @override
  void initState() {
    super.initState();
    widget.onPauseMusic();
    _open(widget.mvIdOverride ?? widget.song.mvId, _requested);
  }

  Future<void> _open(String mvId, MvQuality quality) async {
    if (mounted) {
      setState(() {
        _phase = _MvPhase.loading;
        _statusText = '正在获取 MV 播放源…';
      });
    }
    try {
      final song = widget.song;
      final result = await MvApi.fetch(
        song,
        qq: AppServices.instance.qq,
        netease: AppServices.instance.netease,
        quality: quality,
        mvId: mvId,
      );
      _resolvedMvId = result.mvId;
      final proxyUrl = await MvProxyServer.instance.register(result.source);
      if (!mounted) return;
      setState(() {
        _qualityKey = result.source.videoQuality;
        _requested = quality;
        _phase = _MvPhase.ready;
      });
      _loadVideo(proxyUrl);
    } on MvUnavailable catch (e) {
      if (mounted) {
        setState(() {
          _phase = _MvPhase.error;
          _statusText = e.reason;
        });
      }
    } catch (e) {
      AppLog.w('MvPage', '打开失败: $e');
      if (mounted) {
        setState(() {
          _phase = _MvPhase.error;
          _statusText = 'MV 播放源获取失败，请检查网络后重试';
        });
      }
    }
  }

  void _loadVideo(String proxyUrl) async {
    final c = await _ensureController();
    final html = _videoHtml(proxyUrl);
    await c.loadHtmlString(html, baseUrl: 'about:blank');
    if (mounted) setState(() => _htmlLoaded = true);
  }

  String _videoHtml(String src) {
    // jsonEncode 转义：src 即使带引号也安全
    final safeSrc = jsonEncode(src);
    return '''
<!DOCTYPE html>
<html><head>
<meta name="viewport" content="width=device-width, initial-scale=1,
      maximum-scale=1, user-scalable=no">
<style>
  html,body { margin:0; padding:0; height:100%; background:#000;
              overflow:hidden; }
  video { width:100%; height:100%; object-fit:contain;
          background:#000; outline:none; }
  ::-webkit-scrollbar { display:none; }
</style>
</head><body>
<video id="v" src=$safeSrc controls autoplay playsinline preload="auto"
       x5-playsinline webkit-playsinline></video>
</body></html>
''';
  }

  Future<WebViewController> _ensureController() async {
    if (_controller != null) return _controller!;
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..setNavigationDelegate(NavigationDelegate(
        onWebResourceError: (e) {
          AppLog.w('MvPage', 'webview error: ${e.description}');
        },
      ));
    // Android：允许无手势自动播放（进入页面即播）
    if (Platform.isAndroid) {
      final android = c.platform as AndroidWebViewController;
      android.setMediaPlaybackRequiresUserGesture(false);
    }
    _controller = c;
    return c;
  }

  Future<void> _pickQuality() async {
    if (_reloading || _phase != _MvPhase.ready) return;
    if (_qualities.isEmpty) {
      _qualities = await MvApi.availableQualities(
        widget.song,
        mvId: _resolvedMvId,
      );
      if (mounted) setState(() {});
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<MvQuality>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('MV 画质',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final q in _qualities)
              ListTile(
                dense: true,
                title: Text(q.key.toUpperCase()),
                trailing: q.key == _qualityKey
                    ? Icon(Icons.check_rounded,
                        color: AppPalette.dark.accent, size: 20)
                    : (q.key == _requested.key
                        ? Icon(Icons.radio_button_checked_rounded,
                            color: Theme.of(ctx).hintColor, size: 18)
                        : null),
                onTap: () => Navigator.of(ctx).pop(q),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (picked == null || picked.key == _requested.key) return;
    _reloading = true;
    try {
      await _open(_resolvedMvId, picked);
    } finally {
      _reloading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(child: _buildBody()),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    final song = widget.song;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                color: Colors.white70, size: 28),
          ),
          Expanded(
            child: Text(
              '${song.name} - ${song.singer}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          IconButton(
            onPressed: _phase == _MvPhase.ready ? _pickQuality : null,
            icon: const Icon(Icons.tune_rounded,
                color: Colors.white70, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _MvPhase.ready:
        // _loadVideo 完成前先转圈，避免黑屏误导
        if (!_htmlLoaded) {
          return const Center(
              child: CircularProgressIndicator(color: Colors.white24));
        }
        return WebViewWidget(controller: _controller!);
      case _MvPhase.loading:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white24),
              const SizedBox(height: 14),
              Text(_statusText,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        );
      case _MvPhase.error:
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam_off_rounded,
                    color: Colors.white24, size: 44),
                const SizedBox(height: 14),
                Text(_statusText,
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 13)),
                const SizedBox(height: 18),
                OutlinedButton(
                  onPressed: () =>
                      _open(_resolvedMvId.isNotEmpty || widget.mvIdOverride == null
                          ? _resolvedMvId
                          : widget.mvIdOverride!,
                      _requested),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        );
    }
  }

  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        children: [
          const Icon(Icons.movie_outlined, color: Colors.white38, size: 16),
          const SizedBox(width: 6),
          Text(
            _qualityKey.isEmpty ? '—' : _qualityKey.toUpperCase(),
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const Spacer(),
          const Text(
            'MV',
            style: TextStyle(color: Colors.white24, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

enum _MvPhase { loading, ready, error }
