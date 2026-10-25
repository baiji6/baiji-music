// 内嵌风控验证页（v2.4.2-pre2，仿倾听的 tcaptcha 方案）。
//
// QQ 音乐的风控场景（发表评论 10009 / 短信登录 20276）会下发一个
// 验证页地址（腾讯滑块 / 验证中心）。之前是跳外部浏览器，验证完还得
// 手动切回 App；倾听的做法是 App 内嵌 WebView 直接完成。本页即同款：
//
// - Android / iOS：内嵌 WebView 加载验证页，完成滑块后点「完成验证」
//   返回，调用方立即重试原操作；
// - 桌面端（macOS / Windows / Linux）：webview_flutter 无平台实现，
//   降级为打开系统浏览器（与旧行为一致），保证五端 CI 构建不受影响。
//
// 为什么不做「自动检测验证完成」：验证页是跨域 iframe（turing.captcha
// .qcloud.com），外层页面拿不到滑块成功的回调事件；倾听是在 WebView
// 里注入 JS 轮询 iframe 形态做的凑近检测，脆弱且依赖具体页面结构。
// 这里用一个明确的「完成验证」按钮收口，行为可预期。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// 打开风控验证页。
///
/// 返回 `true` 表示用户在页面里点过「完成验证」（调用方应立即重试）；
/// 桌面端降级为浏览器打开，返回恒为 `false`。
Future<bool> openCaptchaVerify(BuildContext context, String url,
    {String title = '安全验证'}) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    // 桌面端：webview_flutter 没有平台实现，降级浏览器
    unawaited(launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication));
    return false;
  }
  final done = await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => CaptchaVerifyPage(url: url, title: title)),
  );
  return done ?? false;
}

/// 风控验证页：WebView + 「完成验证」收口按钮。
class CaptchaVerifyPage extends StatefulWidget {
  const CaptchaVerifyPage({super.key, required this.url, required this.title});

  final String url;
  final String title;

  @override
  State<CaptchaVerifyPage> createState() => _CaptchaVerifyPageState();
}

class _CaptchaVerifyPageState extends State<CaptchaVerifyPage> {
  late final WebViewController _controller;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p / 100);
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: widget.title,
      contentPadding: EdgeInsets.zero,
      child: Column(
        children: [
          if (_progress < 1)
            LinearProgressIndicator(value: _progress, minHeight: 2),
          Expanded(child: WebViewWidget(controller: _controller)),
          // 完成收口：滑块成功后验证页没有可依赖的外层回调，
          // 让用户点一下回 App，行为最可控。
          Container(
            padding: EdgeInsets.fromLTRB(20, 10, 20, 10),
            decoration: BoxDecoration(
              color: AppColors.bg2,
              border: Border(
                  top: BorderSide(color: AppColors.strokeGlass, width: 0.5)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '完成滑块/验证后，点击下方按钮返回并继续操作',
                    style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
                  ),
                  const SizedBox(height: 8),
                  NeonButton(
                    label: '完成验证，返回继续',
                    icon: Icons.verified_rounded,
                    gradient: const [AppColors.violet, AppColors.cyan],
                    onPressed: () => Navigator.pop(context, true),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
