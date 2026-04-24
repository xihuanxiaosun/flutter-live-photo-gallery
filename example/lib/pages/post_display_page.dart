import 'dart:io';
import 'package:flutter/material.dart';
import 'package:live_photo_gallery/live_photo_gallery.dart';

class PostDisplayPage extends StatefulWidget {
  final String title;
  final List<MediaItem> items;
  final bool isOriginalPhoto;

  const PostDisplayPage({
    super.key,
    required this.title,
    required this.items,
    required this.isOriginalPhoto,
  });

  @override
  State<PostDisplayPage> createState() => _PostDisplayPageState();
}

class _PostDisplayPageState extends State<PostDisplayPage> {
  // ── 点击缩略图，跳原生全屏预览 ──────────────────────
  Future<void> _previewAt(int index, Rect sourceFrame) async {
    final assets = widget.items
        .map((item) => AssetInput(type: 'local', assetId: item.assetId))
        .toList();

    try {
      await LivePhotoGallery.previewAssets(
        assets: assets,
        initialIndex: index,
        sourceFrame: sourceFrame,
        // 展示页纯预览，不需要选择功能
        config: const PickerConfig(showRadio: false),
      );
    } on LivePhotoException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('预览失败：${e.code}'),
            duration: const Duration(seconds: 2)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('帖子详情'),
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 发布者头像 + 信息 ───────────────────────
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Colors.blue.shade100,
                  child: const Icon(Icons.person, color: Colors.blue),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('测试用户',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    Text('刚刚',
                        style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                  ],
                ),
                const Spacer(),
                if (widget.isOriginalPhoto)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.blue.shade200),
                    ),
                    child: Text('原图',
                        style: TextStyle(fontSize: 11, color: Colors.blue[700])),
                  ),
              ],
            ),
            const SizedBox(height: 14),

            // ── 正文 ────────────────────────────────────
            Text(
              widget.title,
              style: const TextStyle(fontSize: 16, height: 1.5),
            ),
            const SizedBox(height: 14),

            // ── 媒体宫格 ─────────────────────────────────
            if (widget.items.isNotEmpty) _buildGrid(),

            const SizedBox(height: 24),

            // ── 底部统计信息 ─────────────────────────────
            Row(
              children: [
                Icon(Icons.photo_library_outlined, size: 14, color: Colors.grey[400]),
                const SizedBox(width: 4),
                Text('${widget.items.length} 张媒体',
                    style: TextStyle(fontSize: 12, color: Colors.grey[400])),
                const SizedBox(width: 16),
                Icon(Icons.touch_app_outlined, size: 14, color: Colors.grey[400]),
                const SizedBox(width: 4),
                Text('点击图片可全屏预览',
                    style: TextStyle(fontSize: 12, color: Colors.grey[400])),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid() {
    final count = widget.items.length;

    // 1 张：大图
    if (count == 1) {
      return _buildSingleImage(0);
    }

    // 2 张：左右各半
    if (count == 2) {
      return Row(
        children: [
          Expanded(child: _buildThumbnail(0, aspectRatio: 1.0)),
          const SizedBox(width: 4),
          Expanded(child: _buildThumbnail(1, aspectRatio: 1.0)),
        ],
      );
    }

    // 3~9 张：3列宫格
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: count,
      itemBuilder: (_, i) => _buildThumbnail(i, aspectRatio: 1.0),
    );
  }

  // 单图大展示
  Widget _buildSingleImage(int index) {
    final item = widget.items[index];
    return GestureDetector(
      onTap: () => _tapAt(index),
      child: Builder(builder: (ctx) {
        return AspectRatio(
          aspectRatio: item.width > 0 && item.height > 0
              ? item.width / item.height
              : 4 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(
                  File(item.thumbnailPath),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _placeholder(),
                ),
              ),
              if (item.mediaType != 'image')
                Positioned(
                  bottom: 8,
                  left: 10,
                  child: _TypeBadge(type: item.mediaType, duration: item.duration),
                ),
            ],
          ),
        );
      }),
    );
  }

  // 宫格单格
  Widget _buildThumbnail(int index, {required double aspectRatio}) {
    final item = widget.items[index];
    return GestureDetector(
      onTap: () => _tapAt(index),
      child: Builder(builder: (ctx) {
        return AspectRatio(
          aspectRatio: aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(
                  File(item.thumbnailPath),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _placeholder(),
                ),
              ),
              if (item.mediaType != 'image')
                Positioned(
                  bottom: 4,
                  left: 5,
                  child: _TypeBadge(type: item.mediaType, duration: item.duration),
                ),
            ],
          ),
        );
      }),
    );
  }

  void _tapAt(int index) {
    final ctx = context;
    // 找到点击格子的 RenderBox 计算 sourceFrame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = ctx.findRenderObject() as RenderBox?;
      final frame = box != null
          ? box.localToGlobal(Offset.zero) & box.size
          : Rect.zero;
      _previewAt(index, frame);
    });
    _previewAt(index, Rect.zero);
  }

  Widget _placeholder() => Container(
        color: Colors.grey[200],
        child: const Center(child: Icon(Icons.broken_image, color: Colors.grey)),
      );
}

class _TypeBadge extends StatelessWidget {
  final String type;
  final double? duration;
  const _TypeBadge({required this.type, this.duration});

  @override
  Widget build(BuildContext context) {
    final isVideo = type == 'video';
    final label = isVideo
        ? (duration != null ? '${duration!.toInt()}″' : '视频')
        : 'Live';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isVideo ? Icons.videocam : Icons.motion_photos_on,
              size: 11, color: Colors.white),
          const SizedBox(width: 2),
          Text(label, style: const TextStyle(fontSize: 10, color: Colors.white)),
        ],
      ),
    );
  }
}
