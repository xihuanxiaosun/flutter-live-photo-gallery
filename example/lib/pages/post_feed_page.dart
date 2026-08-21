import 'dart:async';
import 'package:flutter/material.dart';
import 'package:live_photo_gallery/live_photo_gallery.dart';

/// 「帖子查看」演示页 —— 模拟微博式信息流，覆盖四种媒体组合，逐一点开验证原生预览：
///   · 单图  · 多图  · 图文+视频混排  · 多视频
/// 另加一条「含坏链」的帖子，用来直观观察「网络资源有误时的兜底」。
///
/// 全部用**网络资源**（大陆可达优先：视频取自 runoob / 阿里云，图片取自 picsum + 百度域）。
/// 如某条 URL 在你的网络下打不开，直接改 [_R] 里的常量即可 —— 顺带也能看坏链兜底表现。
class PostFeedPage extends StatefulWidget {
  const PostFeedPage({super.key});

  @override
  State<PostFeedPage> createState() => _PostFeedPageState();
}

class _PostFeedPageState extends State<PostFeedPage> {
  StreamSubscription<DownloadResult>? _downloadSub;

  @override
  void initState() {
    super.initState();
    // 长按网络图 →「保存图片」后，native 通过 onDownloadResult 回推结果，这里弹提示。
    _downloadSub = LivePhotoGallery.onDownloadResult.listen((r) {
      if (!mounted) return;
      final msg = switch (r) {
        DownloadSuccess() => '已保存到相册',
        DownloadFailure(:final errorMessage) => '保存失败：$errorMessage',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
    });
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        title: const Text('帖子查看（信息流）'),
        elevation: 0.5,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
      ),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 10),
        itemCount: _posts.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _PostCard(post: _posts[i]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 资源池：如某条打不开，改这里即可（大陆可达优先）
// ─────────────────────────────────────────────────────────────────────────────

class _R {
  // 图片：picsum 按 seed 稳定取图（同一 seed 每次同一张）；另含一条百度域内样例。
  static const imgA = 'https://picsum.photos/seed/lpg-a/1000/1200';
  static const imgB = 'https://picsum.photos/seed/lpg-b/1200/900';
  static const imgC = 'https://picsum.photos/seed/lpg-c/1000/1000';
  static const imgD = 'https://picsum.photos/seed/lpg-d/900/1300';
  static const imgE = 'https://picsum.photos/seed/lpg-e/1200/800';
  static const imgF = 'https://picsum.photos/seed/lpg-f/1000/1000';
  static const imgBaidu =
      'https://gips0.baidu.com/it/u=3602773692,1512483864&fm=3028&app=3028&f=JPEG&fmt=auto?w=1024&h=1024';

  // 视频封面（图片）
  static const coverV1 = 'https://picsum.photos/seed/lpg-v1/1000/1000';
  static const coverV2 = 'https://picsum.photos/seed/lpg-v2/1000/1000';
  static const coverV3 = 'https://picsum.photos/seed/lpg-v3/1000/1000';

  // 视频（大陆可达）：runoob 两个小片段 + 阿里云官方 demo（~146MB，用来测大文件/缓冲卡顿）
  static const videoSmall1 = 'https://www.runoob.com/try/demo_source/mov_bbb.mp4';
  static const videoSmall2 = 'https://www.runoob.com/try/demo_source/movie.mp4';
  static const videoBig = 'https://player.alicdn.com/video/aliyunmedia.mp4';

  // 故意的坏链：域名不存在 → 观察「资源有误」时缩略图与原生预览的兜底表现。
  static const brokenImg =
      'https://this-host-does-not-exist.invalid/broken.jpg';
}

// ─────────────────────────────────────────────────────────────────────────────
// 数据模型
// ─────────────────────────────────────────────────────────────────────────────

class _Media {
  final String cover; // 缩略图 / 视频封面 URL
  final String type; // 'image' | 'video'
  final String? videoUrl; // 视频播放 URL
  final double? duration; // 视频时长（秒），仅用于角标展示

  const _Media.image(this.cover)
      : type = 'image',
        videoUrl = null,
        duration = null;

  const _Media.video({
    required this.cover,
    required this.videoUrl,
    this.duration,
  }) : type = 'video';

  /// 转成插件的网络资源描述。
  AssetInput toInput() => type == 'video'
      ? AssetInput(
          type: 'network',
          url: cover,
          mediaType: 'video',
          videoUrl: videoUrl,
          duration: duration,
        )
      : AssetInput(type: 'network', url: cover, mediaType: 'image');
}

class _Post {
  final String author;
  final String text;
  final List<_Media> media;
  const _Post({required this.author, required this.text, required this.media});

  bool get hasVideo => media.any((m) => m.type == 'video');
}

// ─────────────────────────────────────────────────────────────────────────────
// 示例帖子（覆盖你要逐一测的四种组合 + 一条坏链）
// ─────────────────────────────────────────────────────────────────────────────

final List<_Post> _posts = [
  const _Post(
    author: '单图帖',
    text: '① 单图：点开是单张全屏预览，双击可放大到点击点，下拉关闭飞回缩略图。',
    media: [_Media.image(_R.imgA)],
  ),
  const _Post(
    author: '多图帖',
    text: '② 多图（6 张）：左右滑翻页，底部有小圆点指示当前页（≤8 张才显示圆点）。',
    media: [
      _Media.image(_R.imgB),
      _Media.image(_R.imgC),
      _Media.image(_R.imgD),
      _Media.image(_R.imgE),
      _Media.image(_R.imgF),
      _Media.image(_R.imgBaidu),
    ],
  ),
  _Post(
    author: '图文+视频 混排帖',
    text: '③ 图片和视频混排：翻到视频页会自动播放（当前页才播），翻走即停。',
    media: [
      const _Media.image(_R.imgC),
      _Media.video(
          cover: _R.coverV1, videoUrl: _R.videoSmall1, duration: 10),
      const _Media.image(_R.imgE),
      _Media.video(
          cover: _R.coverV2, videoUrl: _R.videoSmall2, duration: 13),
    ],
  ),
  _Post(
    author: '多视频帖',
    text: '④ 多个视频：逐页自动播放（含一个 ~146MB 大文件，用来看缓冲/卡顿时的表现）。',
    media: [
      _Media.video(
          cover: _R.coverV1, videoUrl: _R.videoSmall1, duration: 10),
      _Media.video(
          cover: _R.coverV2, videoUrl: _R.videoSmall2, duration: 13),
      _Media.video(cover: _R.coverV3, videoUrl: _R.videoBig, duration: 262),
    ],
  ),
  const _Post(
    author: '坏链兜底帖',
    text: '⑤ 故意放了一张打不开的图：看缩略图占位图标 + 原生预览的兜底表现。',
    media: [
      _Media.image(_R.brokenImg),
      _Media.image(_R.imgA),
    ],
  ),
];

// ─────────────────────────────────────────────────────────────────────────────
// 单条帖子卡片
// ─────────────────────────────────────────────────────────────────────────────

class _PostCard extends StatelessWidget {
  final _Post post;
  const _PostCard({required this.post});

  /// 点击第 [index] 个媒体 → 打开原生全屏预览。
  /// [cellContext] 是被点格子自身的 context，用来算 sourceFrame（飞入/飞回起点）。
  Future<void> _openPreview(
      BuildContext pageContext, int index, BuildContext cellContext) async {
    final box = cellContext.findRenderObject() as RenderBox?;
    final frame = (box != null && box.hasSize)
        ? box.localToGlobal(Offset.zero) & box.size
        : Rect.zero;

    try {
      await LivePhotoGallery.previewAssets(
        assets: post.media.map((m) => m.toInput()).toList(),
        initialIndex: index,
        sourceFrame: frame,
        // 纯预览（无选择框）；含视频的帖子开启「进入视频页自动播放」。
        config: PickerConfig(
          showRadio: false,
          autoPlayVideo: post.hasVideo,
        ),
        // 允许保存网络图：预览里长按网络图会弹「保存图片 / 取消」。
        showDownloadButton: true,
      );
    } on LivePhotoException catch (e) {
      if (!pageContext.mounted) return;
      ScaffoldMessenger.of(pageContext).showSnackBar(
        SnackBar(
          content: Text('预览失败：${e.code} ${e.message}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 作者行
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: Colors.blue.shade100,
                child: const Icon(Icons.person, size: 20, color: Colors.blue),
              ),
              const SizedBox(width: 10),
              Text(post.author,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14)),
              const Spacer(),
              Text('${post.media.length} 项',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            ],
          ),
          const SizedBox(height: 10),
          Text(post.text, style: const TextStyle(fontSize: 14, height: 1.5)),
          const SizedBox(height: 12),
          _MediaGrid(post: post, onTap: _openPreview),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 媒体宫格（网络缩略图：带加载态 loadingBuilder + 坏链兜底 errorBuilder）
// ─────────────────────────────────────────────────────────────────────────────

class _MediaGrid extends StatelessWidget {
  final _Post post;
  final void Function(BuildContext pageContext, int index, BuildContext cell)
      onTap;
  const _MediaGrid({required this.post, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final count = post.media.length;
    if (count == 1) return _cell(context, 0, radius: 10, aspect: 4 / 3);
    if (count == 2) {
      return Row(children: [
        Expanded(child: _cell(context, 0, radius: 8)),
        const SizedBox(width: 4),
        Expanded(child: _cell(context, 1, radius: 8)),
      ]);
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: count,
      itemBuilder: (_, i) => _cell(context, i, radius: 6),
    );
  }

  Widget _cell(BuildContext pageContext, int index,
      {double radius = 6, double aspect = 1}) {
    final media = post.media[index];
    return Builder(builder: (cellCtx) {
      return GestureDetector(
        onTap: () => onTap(pageContext, index, cellCtx),
        child: AspectRatio(
          aspectRatio: aspect,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(
                  media.cover,
                  fit: BoxFit.cover,
                  // 加载态：转圈占位
                  loadingBuilder: (_, child, progress) => progress == null
                      ? child
                      : Container(
                          color: const Color(0xFFEDEDED),
                          child: const Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                  // 坏链兜底：占位图标
                  errorBuilder: (_, __, ___) => Container(
                    color: const Color(0xFFEDEDED),
                    child: const Center(
                      child: Icon(Icons.broken_image_outlined,
                          color: Colors.grey, size: 28),
                    ),
                  ),
                ),
                if (media.type == 'video')
                  Positioned(
                    bottom: 5,
                    left: 6,
                    child: _VideoBadge(duration: media.duration),
                  ),
                if (media.type == 'video')
                  const Center(
                    child: Icon(Icons.play_circle_fill,
                        color: Colors.white70, size: 34),
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _VideoBadge extends StatelessWidget {
  final double? duration;
  const _VideoBadge({this.duration});

  /// 与原生预览进度条一致的 m:ss 格式（例如 0:10 / 4:22），避免角标与放大后对不上。
  static String _fmt(double seconds) {
    final t = seconds.round();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final label = duration != null ? _fmt(duration!) : '视频';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.videocam, size: 11, color: Colors.white),
        const SizedBox(width: 2),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.white)),
      ]),
    );
  }
}
