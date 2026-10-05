import 'package:flutter/material.dart';

import 'theme/app_theme.dart';
import 'ui/pages/discover_home.dart';
import 'ui/pages/library_home.dart';
import 'ui/pages/search_home.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BaijiMusicApp());
}

class BaijiMusicApp extends StatelessWidget {
  const BaijiMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '白姬音乐',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: AppShell(
        titles: const ['发现', '搜索', '我的'],
        pages: const [
          DiscoverHome(),
          SearchHome(),
          LibraryHome(),
        ],
      ),
    );
  }
}