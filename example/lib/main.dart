import 'package:flutter/material.dart';
import 'package:live_photo_gallery/live_photo_gallery.dart';
import 'pages/edit_post_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Live Photo Gallery Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          elevation: 0.5,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _permissionStatus = '未请求';

  Future<void> _requestPermission() async {
    try {
      final status = await LivePhotoGallery.requestPermission();
      setState(() => _permissionStatus = status);
    } on LivePhotoException catch (e) {
      setState(() => _permissionStatus = '失败：${e.code}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(title: const Text('Live Photo Gallery 测试')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── 权限区 ────────────────────────────────────
          _SectionCard(
            icon: Icons.lock_open_outlined,
            title: '相册权限',
            subtitle: '状态：$_permissionStatus',
            children: [
              _ActionButton(
                label: '请求相册权限',
                icon: Icons.photo_library_outlined,
                onTap: _requestPermission,
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── 发帖测试区 ────────────────────────────────
          _SectionCard(
            icon: Icons.edit_note_outlined,
            title: '发帖（编辑 + 展示）',
            subtitle: '测试选图、裁剪、预览及回显全链路',
            children: [
              _ActionButton(
                label: '进入「编辑帖子」页',
                icon: Icons.add_photo_alternate_outlined,
                color: Colors.blue,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const EditPostPage()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── 快速选图测试 ──────────────────────────────
          _SectionCard(
            icon: Icons.tune_outlined,
            title: '快速功能测试',
            subtitle: '不同配置快速验证各端行为',
            children: [
              _ActionButton(
                label: '仅图片（不含视频）',
                icon: Icons.image_outlined,
                onTap: () => _quickPick(const PickerConfig(
                  filterConfig: MediaFilter.imageOnly,
                  maxCount: 9,
                )),
              ),
              _ActionButton(
                label: '仅视频',
                icon: Icons.videocam_outlined,
                onTap: () => _quickPick(const PickerConfig(
                  filterConfig: MediaFilter.videoOnly,
                  maxCount: 3,
                )),
              ),
              _ActionButton(
                label: '纯预览模式（无选择框）',
                icon: Icons.preview_outlined,
                onTap: () => _quickPick(const PickerConfig(showRadio: false)),
              ),
              _ActionButton(
                label: '最多 1 张（头像场景）',
                icon: Icons.person_outline,
                onTap: () => _quickPick(const PickerConfig(maxCount: 1)),
              ),
              _ActionButton(
                label: '深色模式',
                icon: Icons.dark_mode_outlined,
                onTap: () => _quickPick(const PickerConfig(isDarkMode: true)),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── 清理 ──────────────────────────────────────
          _SectionCard(
            icon: Icons.cleaning_services_outlined,
            title: '维护',
            children: [
              _ActionButton(
                label: '清理临时文件',
                icon: Icons.delete_sweep_outlined,
                color: Colors.orange,
                onTap: _cleanup,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _quickPick(PickerConfig config) async {
    try {
      final result = await LivePhotoGallery.pickAssets(config: config);
      if (!mounted) return;
      if (result == null) {
        _toast('用户取消');
      } else {
        _toast('选了 ${result.items.length} 项，原图=${result.isOriginalPhoto}');
      }
    } on LivePhotoException catch (e) {
      if (!mounted) return;
      _toast('失败：${e.code} ${e.message}');
    }
  }

  Future<void> _cleanup() async {
    try {
      await LivePhotoGallery.cleanupTempFiles();
      if (!mounted) return;
      _toast('临时文件已清理');
    } on LivePhotoException catch (e) {
      if (!mounted) return;
      _toast('清理失败：${e.code}');
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }
}

// ── 复用组件 ──────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  const _SectionCard({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8)],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: Colors.blue),
              const SizedBox(width: 6),
              Text(title,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!,
                style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          ],
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color? color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.grey[700]!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            border: Border.all(color: c.withOpacity(0.3)),
            borderRadius: BorderRadius.circular(8),
            color: c.withOpacity(0.05),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: c),
              const SizedBox(width: 10),
              Text(label, style: TextStyle(fontSize: 14, color: c)),
              const Spacer(),
              Icon(Icons.chevron_right, size: 18, color: c.withOpacity(0.5)),
            ],
          ),
        ),
      ),
    );
  }
}
