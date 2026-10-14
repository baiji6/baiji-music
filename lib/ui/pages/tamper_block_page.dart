import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/signature_guard.dart';

/// 防篡改拦截页（#78）：签名校验失败时替代正常 UI 的唯一出口。
///
/// 独立 MaterialApp，不依赖任何业务组件——走到这里时不能信任应用
/// 自身代码是否被替换，越少执行越多余代码越安全。只做三件事：
/// 明确告知校验失败、展示指纹差异（便于用户/开发者排查）、提供退出。
class TamperBlockApp extends StatelessWidget {
  const TamperBlockApp({super.key, required this.result});

  final SignatureCheckResult result;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '白姬音乐',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF160B0D),
        colorScheme: const ColorScheme.dark(
            surface: Color(0xFF160B0D), error: Color(0xFFFF5470)),
      ),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.gpp_bad_rounded,
                        color: Color(0xFFFF5470), size: 64),
                    const SizedBox(height: 20),
                    const Text(
                      '应用完整性校验失败',
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFFFFD9DE)),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '检测到当前安装包的签名与发布版本不一致，应用可能被'
                      '二次打包或篡改。为保护你的账号与数据，本应用拒绝运行。\n\n'
                      '请从官方渠道重新下载安装。',
                      style: TextStyle(
                          fontSize: 14,
                          height: 1.6,
                          color: Colors.red.shade100),
                    ),
                    const SizedBox(height: 18),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A1114),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF5A2128)),
                      ),
                      child: Text(
                        result.detail,
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.red.shade200,
                            fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFFF5470),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: _exit,
                        icon: const Icon(Icons.exit_to_app_rounded, size: 18),
                        label: const Text('退出应用',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _exit() {
    // Android 先走系统返回栈移除任务，再兜底杀进程；桌面直接退出。
    if (Platform.isAndroid) {
      SystemNavigator.pop();
    }
    exit(0);
  }
}
