import 'dart:io';

import 'package:flutter/material.dart';

import '../../download/download_manager.dart';
import '../../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// 下载管理页：显示已下载的歌曲文件列表。
class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  List<File> _files = [];

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    final dir = await DownloadManager.instance.getDownloadDir();
    if (!dir.existsSync()) {
      setState(() => _files = []);
      return;
    }
    final all = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    setState(() => _files = all);
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: const Text('清空下载', style: TextStyle(fontSize: 16)),
        content: const Text('确定删除所有已下载的歌曲文件？', style: TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: AppColors.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      for (final f in _files) {
        try { f.deleteSync(); } catch (_) {}
      }
      await _loadFiles();
    }
  }

  String _fileName(File f) => f.path.split(Platform.pathSeparator).last;

  String _fileSize(File f) {
    final bytes = f.lengthSync();
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('下载管理'),
        actions: [
          if (_files.isNotEmpty)
            IconButton(
              onPressed: _clearAll,
              icon: const Icon(Icons.delete_sweep_rounded, color: AppColors.danger),
            ),
        ],
      ),
      body: _files.isEmpty
          ? const Center(
              child: Text(
                '暂无下载\n搜索歌曲后长按可下载',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _files.length,
              itemBuilder: (ctx, i) => GlassCard(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: AppColors.neonGradient),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 22),
                  ),
                  title: Text(
                    _fileName(_files[i]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    _fileSize(_files[i]),
                    style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
                  ),
                  trailing: IconButton(
                    onPressed: () {
                      try { _files[i].deleteSync(); } catch (_) {}
                      _loadFiles();
                    },
                    icon: const Icon(Icons.delete_outline, color: AppColors.danger, size: 20),
                  ),
                ),
              ),
            ),
    );
  }
}
