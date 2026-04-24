import 'dart:io';
import 'package:flutter/material.dart';
import 'package:live_photo_gallery/live_photo_gallery.dart';
import 'post_display_page.dart';

class EditPostPage extends StatefulWidget {
  const EditPostPage({super.key});

  @override
  State<EditPostPage> createState() => _EditPostPageState();
}

class _EditPostPageState extends State<EditPostPage> {
  final _titleController = TextEditingController(text: '今天天气真好 🌤');
  List<MediaItem> _selectedItems = [];
  bool _isOriginalPhoto = false;
  bool _loading = false;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  // ── 打开相册选图 ──────────────────────────────────
  Future<void> _pickMedia() async {
    setState(() => _loading = true);
    try {
      final result = await LivePhotoGallery.pickAssets(
        config: const PickerConfig(
          maxCount: 9,
          showRadio: true,
          enableVideo: true,
          enableLivePhoto: true,
          isDarkMode: false,
        ),
      );
      if (result != null && mounted) {
        setState(() {
          _selectedItems = result.items;
          _isOriginalPhoto = result.isOriginalPhoto;
        });
      }
    } on LivePhotoException catch (e) {
      if (!mounted) return;
      _showSnack('选图失败：${e.code} ${e.message}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── 点击缩略图预览 ────────────────────────────────
  Future<void> _previewAt(int index, Rect sourceFrame) async {
    final assets = _selectedItems
        .map((item) => AssetInput(type: 'local', assetId: item.assetId))
        .toList();

    try {
      final result = await LivePhotoGallery.previewAssets(
        assets: assets,
        initialIndex: index,
        sourceFrame: sourceFrame,
        selectedAssetIds: _selectedItems.map((e) => e.assetId).toList(),
        config: const PickerConfig(showRadio: true, maxCount: 9),
      );
      if (result != null && mounted) {
        setState(() {
          _selectedItems = result.items;
          _isOriginalPhoto = result.isOriginalPhoto;
        });
      }
    } on LivePhotoException catch (e) {
      if (!mounted) return;
      _showSnack('预览失败：${e.code}');
    }
  }

  // ── 移除某张 ──────────────────────────────────────
  void _removeAt(int index) {
    setState(() => _selectedItems.removeAt(index));
  }

  // ── 发布（跳转展示页） ─────────────────────────────
  void _publish() {
    if (_selectedItems.isEmpty) {
      _showSnack('请先选择图片');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PostDisplayPage(
          title: _titleController.text.trim().isEmpty
              ? '无标题'
              : _titleController.text.trim(),
          items: List.from(_selectedItems),
          isOriginalPhoto: _isOriginalPhoto,
        ),
      ),
    );
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  // ── UI ───────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('编辑帖子'),
        actions: [
          TextButton(
            onPressed: _publish,
            child: const Text('发布', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: Column(
        children: [
          // 标题输入
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: TextField(
              controller: _titleController,
              maxLines: 3,
              maxLength: 200,
              decoration: const InputDecoration(
                hintText: '说点什么...',
                border: InputBorder.none,
                counterStyle: TextStyle(color: Colors.grey),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 媒体宫格
          Expanded(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: _buildMediaGrid(),
            ),
          ),
          // 底部状态栏
          if (_selectedItems.isNotEmpty)
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.photo_library_outlined, size: 16, color: Colors.grey[600]),
                  const SizedBox(width: 4),
                  Text('已选 ${_selectedItems.length} 项',
                      style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                  if (_isOriginalPhoto) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.blue.shade200),
                      ),
                      child: Text('原图', style: TextStyle(fontSize: 11, color: Colors.blue[700])),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMediaGrid() {
    // 最多 9 张 + 一个"添加"按钮
    final showAdd = _selectedItems.length < 9;
    final total = _selectedItems.length + (showAdd ? 1 : 0);

    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: total,
      itemBuilder: (ctx, i) {
        if (showAdd && i == _selectedItems.length) {
          return _AddCell(loading: _loading, onTap: _pickMedia);
        }
        return _MediaCell(
          item: _selectedItems[i],
          index: i,
          onTap: (frame) => _previewAt(i, frame),
          onRemove: () => _removeAt(i),
        );
      },
    );
  }
}

// ── 添加按钮格子 ────────────────────────────────────
class _AddCell extends StatelessWidget {
  final bool loading;
  final VoidCallback onTap;

  const _AddCell({required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[100],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey[300]!),
        ),
        child: loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_photo_alternate_outlined,
                      size: 32, color: Colors.grey[500]),
                  const SizedBox(height: 4),
                  Text('添加', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                ],
              ),
      ),
    );
  }
}

// ── 已选媒体格子 ────────────────────────────────────
class _MediaCell extends StatelessWidget {
  final MediaItem item;
  final int index;
  final void Function(Rect frame) onTap;
  final VoidCallback onRemove;

  const _MediaCell({
    required this.item,
    required this.index,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 缩略图
        GestureDetector(
          onTap: () {
            final box = context.findRenderObject() as RenderBox?;
            final frame = box != null
                ? box.localToGlobal(Offset.zero) & box.size
                : Rect.zero;
            onTap(frame);
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(item.thumbnailPath),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: Colors.grey[200],
                child: const Icon(Icons.broken_image, color: Colors.grey),
              ),
            ),
          ),
        ),
        // 视频/Live 角标
        if (item.mediaType != 'image')
          Positioned(
            bottom: 4,
            left: 6,
            child: _TypeBadge(type: item.mediaType, duration: item.duration),
          ),
        // 删除按钮
        Positioned(
          top: 2,
          right: 2,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              width: 22,
              height: 22,
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

class _TypeBadge extends StatelessWidget {
  final String type;
  final double? duration;
  const _TypeBadge({required this.type, this.duration});

  @override
  Widget build(BuildContext context) {
    final isVideo = type == 'video';
    final label = isVideo
        ? (duration != null
            ? '${duration!.toInt()}″'
            : '视频')
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
