import 'package:flutter/material.dart';
import 'package:live_photo_gallery/live_photo_gallery.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _status = '点击按钮开始测试插件';

  Future<void> _requestPermission() async {
    try {
      final status = await LivePhotoGallery.requestPermission();
      if (!mounted) return;
      setState(() {
        _status = '相册权限状态：$status';
      });
    } on LivePhotoException catch (e) {
      if (!mounted) return;
      setState(() {
        _status = '请求权限失败：${e.code} ${e.message}';
      });
    }
  }

  Future<void> _cleanupTempFiles() async {
    try {
      await LivePhotoGallery.cleanupTempFiles();
      if (!mounted) return;
      setState(() {
        _status = '已清理插件临时文件';
      });
    } on LivePhotoException catch (e) {
      if (!mounted) return;
      setState(() {
        _status = '清理失败：${e.code} ${e.message}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Live Photo Gallery Example')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ElevatedButton(
                onPressed: _requestPermission,
                child: const Text('请求相册权限'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _cleanupTempFiles,
                child: const Text('清理临时文件'),
              ),
              const SizedBox(height: 24),
              Text(_status),
            ],
          ),
        ),
      ),
    );
  }
}
