# 后端对接指南

本文档描述完整的媒体上传 / 回显链路：
**Flutter 选图 → 导出文件 → 上传接口 → 后端存储 → 返回 URL → 客户端回显**

---

## 目录

- [媒体类型说明](#媒体类型说明)
- [上传阶段：Flutter 端发送什么](#上传阶段flutter-端发送什么)
  - [图片上传](#图片上传)
  - [视频上传](#视频上传)
  - [Live Photo 上传](#live-photo-上传)
- [后端接收格式](#后端接收格式)
- [后端返回格式](#后端返回格式)
- [客户端回显](#客户端回显)
  - [Flutter 回显](#flutter-回显)
  - [iOS 原生回显](#ios-原生回显)
  - [Android 回显](#android-回显)
- [完整数据流图](#完整数据流图)
- [各端 Live Photo 支持对照](#各端-live-photo-支持对照)

---

## 媒体类型说明

本插件涉及三种媒体类型，贯穿上传到回显的全链路：

| mediaType | 含义 | 上传内容 | 回显方式 |
|-----------|------|---------|---------|
| `"image"` | 普通图片 | 1 个图片文件 | 静态图 |
| `"video"` | 视频 | 1 个视频文件 | 视频播放器 |
| `"livePhoto"` | Live Photo（苹果实况照片） | 1 个图片 + 1 个视频 | iOS 上动态播放；Android/Web 上降级为静态图 |

---

## 上传阶段：Flutter 端发送什么

### 第一步：选图后获得 assetId

```dart
final result = await LivePhotoGallery.pickAssets(
  config: const PickerConfig(maxCount: 9),
);
// result.items[0].assetId  → "A1B2C3D4-.../L0/001"（PHAsset localIdentifier）
// result.items[0].mediaType → "image" | "video" | "livePhoto"
// result.isOriginalPhoto    → 用户是否勾选了原图
```

### 第二步：按 mediaType 导出实体文件

```dart
Future<List<UploadItem>> prepareUploadItems(
  List<MediaItem> items,
  bool isOriginalPhoto,
) async {
  final uploads = <UploadItem>[];

  for (final item in items) {
    switch (item.mediaType) {

      case 'image':
        final path = await LivePhotoGallery.exportAsset(
          assetId: item.assetId,
          format: 'image',
          // 非原图：导出 1600px JPEG（85% 压缩）
          // 原图：导出 HEIC/JPEG/PNG 原始字节，由插件内部根据勾选状态决定
        );
        uploads.add(UploadItem(
          filePath: path!,
          mediaType: 'image',
          width: item.width,
          height: item.height,
        ));
        break;

      case 'video':
        final path = await LivePhotoGallery.exportAsset(
          assetId: item.assetId,
          format: 'video',
        );
        uploads.add(UploadItem(
          filePath: path!,
          mediaType: 'video',
          duration: item.duration,
          width: item.width,
          height: item.height,
        ));
        break;

      case 'livePhoto':
        // Live Photo 分两个文件：静态图 + 视频
        final imgPath = await LivePhotoGallery.exportAsset(
          assetId: item.assetId, format: 'image');
        final videoPath = await LivePhotoGallery.exportAsset(
          assetId: item.assetId, format: 'livePhotoVideo');
        uploads.add(UploadItem(
          filePath: imgPath!,
          videoFilePath: videoPath!,   // 额外携带视频文件
          mediaType: 'livePhoto',
          width: item.width,
          height: item.height,
        ));
        break;
    }
  }

  return uploads;
}
```

---

### 图片上传

**文件格式**：`.jpg`（非原图）或 `.heic` / `.jpg` / `.png`（原图，保留设备原始格式）

**HTTP 请求（multipart/form-data）**

```
POST /api/media/upload
Content-Type: multipart/form-data; boundary=----FormBoundary

------FormBoundary
Content-Disposition: form-data; name="file"; filename="photo.jpg"
Content-Type: image/jpeg

<二进制文件内容>
------FormBoundary
Content-Disposition: form-data; name="mediaType"

image
------FormBoundary
Content-Disposition: form-data; name="width"

1920
------FormBoundary
Content-Disposition: form-data; name="height"

1080
------FormBoundary--
```

**Dart 上传代码（使用 dio）**

```dart
Future<String> uploadImage(String filePath, int width, int height) async {
  final file = await MultipartFile.fromFile(
    filePath,
    filename: path.basename(filePath),
  );
  final formData = FormData.fromMap({
    'file': file,
    'mediaType': 'image',
    'width': width,
    'height': height,
  });
  final response = await dio.post('/api/media/upload', data: formData);
  return response.data['data']['url'] as String;
}
```

---

### 视频上传

**文件格式**：`.mp4`（H.264，最高 1920×1080）

**HTTP 请求（multipart/form-data）**

```
POST /api/media/upload
Content-Type: multipart/form-data; boundary=----FormBoundary

------FormBoundary
Content-Disposition: form-data; name="file"; filename="video.mp4"
Content-Type: video/mp4

<二进制文件内容>
------FormBoundary
Content-Disposition: form-data; name="mediaType"

video
------FormBoundary
Content-Disposition: form-data; name="duration"

15.3
------FormBoundary
Content-Disposition: form-data; name="width"

1920
------FormBoundary
Content-Disposition: form-data; name="height"

1080
------FormBoundary--
```

**Dart 上传代码**

```dart
Future<VideoUploadResult> uploadVideo(
  String filePath,
  double? duration,
  int width,
  int height,
) async {
  final formData = FormData.fromMap({
    'file': await MultipartFile.fromFile(filePath, filename: 'video.mp4'),
    'mediaType': 'video',
    'duration': duration ?? 0,
    'width': width,
    'height': height,
  });
  final response = await dio.post('/api/media/upload', data: formData);
  final data = response.data['data'];
  return VideoUploadResult(
    videoUrl: data['url'],
    coverUrl: data['coverUrl'],   // 后端可自动抽帧生成封面
  );
}
```

---

### Live Photo 上传

Live Photo 由**静态图（JPEG/HEIC）+ 视频（MOV/MP4）**两部分组成，通常分两次请求或一次携带两个文件字段。

**推荐方案：单接口双文件字段**

```
POST /api/media/upload/livephoto
Content-Type: multipart/form-data; boundary=----FormBoundary

------FormBoundary
Content-Disposition: form-data; name="image"; filename="photo.jpg"
Content-Type: image/jpeg

<静态图二进制>
------FormBoundary
Content-Disposition: form-data; name="video"; filename="live.mov"
Content-Type: video/quicktime

<视频二进制>
------FormBoundary
Content-Disposition: form-data; name="mediaType"

livePhoto
------FormBoundary
Content-Disposition: form-data; name="width"

4032
------FormBoundary
Content-Disposition: form-data; name="height"

3024
------FormBoundary--
```

**Dart 上传代码**

```dart
Future<LivePhotoUploadResult> uploadLivePhoto(
  String imagePath,
  String videoPath,
  int width,
  int height,
) async {
  final formData = FormData.fromMap({
    'image': await MultipartFile.fromFile(
      imagePath,
      filename: path.basename(imagePath),
    ),
    'video': await MultipartFile.fromFile(
      videoPath,
      filename: path.basename(videoPath),
    ),
    'mediaType': 'livePhoto',
    'width': width,
    'height': height,
  });
  final response = await dio.post('/api/media/upload/livephoto', data: formData);
  final data = response.data['data'];
  return LivePhotoUploadResult(
    imageUrl: data['imageUrl'],
    videoUrl: data['videoUrl'],
  );
}
```

---

## 后端接收格式

### 图片 / 视频接口（Spring Boot 示例）

```java
@RestController
@RequestMapping("/api/media")
public class MediaController {

    @PostMapping("/upload")
    public Result<MediaVO> upload(
        @RequestParam("file") MultipartFile file,
        @RequestParam("mediaType") String mediaType,  // "image" | "video"
        @RequestParam(value = "width",    required = false, defaultValue = "0") int width,
        @RequestParam(value = "height",   required = false, defaultValue = "0") int height,
        @RequestParam(value = "duration", required = false, defaultValue = "0") double duration
    ) {
        // 1. 上传到 OSS / CDN
        String url = ossService.upload(file, mediaType);

        // 2. 视频自动截帧（可选，交给 FFmpeg 或云函数处理）
        String coverUrl = null;
        if ("video".equals(mediaType)) {
            coverUrl = videoService.extractCover(url);
        }

        // 3. 保存到数据库并返回
        MediaVO vo = new MediaVO();
        vo.setUrl(url);
        vo.setCoverUrl(coverUrl);
        vo.setMediaType(mediaType);
        vo.setWidth(width);
        vo.setHeight(height);
        vo.setDuration(duration);
        return Result.success(vo);
    }
}
```

### Live Photo 接口（Spring Boot 示例）

```java
@PostMapping("/upload/livephoto")
public Result<LivePhotoVO> uploadLivePhoto(
    @RequestParam("image") MultipartFile image,
    @RequestParam("video") MultipartFile video,
    @RequestParam(value = "width",  defaultValue = "0") int width,
    @RequestParam(value = "height", defaultValue = "0") int height
) {
    String imageUrl = ossService.upload(image, "image");
    String videoUrl = ossService.upload(video, "video");

    LivePhotoVO vo = new LivePhotoVO();
    vo.setImageUrl(imageUrl);
    vo.setVideoUrl(videoUrl);
    vo.setMediaType("livePhoto");
    vo.setWidth(width);
    vo.setHeight(height);
    return Result.success(vo);
}
```

### Node.js（Fastify + multer）示例

```javascript
// 通用上传
fastify.post('/api/media/upload', { preHandler: upload.single('file') }, async (req, reply) => {
  const { mediaType, width, height, duration } = req.body;
  const url = await ossClient.put(req.file.originalname, req.file.buffer);

  let coverUrl = null;
  if (mediaType === 'video') {
    coverUrl = await extractCoverFrame(url);
  }

  return { code: 0, data: { url, coverUrl, mediaType, width: +width, height: +height, duration: +duration } };
});

// Live Photo 上传
fastify.post('/api/media/upload/livephoto', {
  preHandler: upload.fields([{ name: 'image' }, { name: 'video' }])
}, async (req, reply) => {
  const imageUrl = await ossClient.put('photo.jpg', req.files.image[0].buffer);
  const videoUrl = await ossClient.put('live.mov', req.files.video[0].buffer);

  return {
    code: 0,
    data: { imageUrl, videoUrl, mediaType: 'livePhoto', width: +req.body.width, height: +req.body.height }
  };
});
```

---

## 后端返回格式

所有媒体接口统一返回如下结构，Flutter 侧解析后用于回显：

### 单媒体对象（存储在数据库）

```json
{
  "mediaType": "image",
  "url": "https://cdn.example.com/images/abc123.jpg",
  "coverUrl": null,
  "videoUrl": null,
  "width": 1920,
  "height": 1080,
  "duration": null
}
```

```json
{
  "mediaType": "video",
  "url": "https://cdn.example.com/videos/def456.mp4",
  "coverUrl": "https://cdn.example.com/covers/def456.jpg",
  "videoUrl": "https://cdn.example.com/videos/def456.mp4",
  "width": 1920,
  "height": 1080,
  "duration": 15.3
}
```

```json
{
  "mediaType": "livePhoto",
  "url": "https://cdn.example.com/images/ghi789.jpg",
  "coverUrl": null,
  "videoUrl": "https://cdn.example.com/videos/ghi789.mov",
  "width": 4032,
  "height": 3024,
  "duration": null
}
```

### 帖子详情接口返回（包含媒体列表）

```json
{
  "code": 0,
  "data": {
    "postId": "12345",
    "content": "今天天气真好 ☀️",
    "mediaList": [
      {
        "mediaType": "image",
        "url": "https://cdn.example.com/images/abc.jpg",
        "coverUrl": null,
        "videoUrl": null,
        "width": 1920,
        "height": 1080,
        "duration": null
      },
      {
        "mediaType": "livePhoto",
        "url": "https://cdn.example.com/images/def.jpg",
        "videoUrl": "https://cdn.example.com/videos/def.mov",
        "coverUrl": null,
        "width": 4032,
        "height": 3024,
        "duration": null
      },
      {
        "mediaType": "video",
        "url": "https://cdn.example.com/videos/ghi.mp4",
        "coverUrl": "https://cdn.example.com/covers/ghi.jpg",
        "videoUrl": "https://cdn.example.com/videos/ghi.mp4",
        "width": 1920,
        "height": 1080,
        "duration": 30.5
      }
    ]
  }
}
```

> **字段规范**
> - `url`：始终指向图片（或视频封面图），用于缩略图展示
> - `videoUrl`：视频文件 URL，视频和 Live Photo 均有
> - `coverUrl`：视频封面，由后端截帧生成，可与 `url` 字段复用
> - `mediaType`：固定三种值 `"image"` / `"video"` / `"livePhoto"`

---

## 客户端回显

### Flutter 回显

#### 数据模型（Flutter 侧定义）

```dart
class PostMedia {
  final String mediaType;      // "image" | "video" | "livePhoto"
  final String? url;           // 图片 URL 或视频封面 URL
  final String? videoUrl;      // 视频 URL（video 和 livePhoto 均有）
  final double? duration;
  final int width;
  final int height;

  // 本地选图未上传时的临时数据（上传完成后 url 替换）
  final String? assetId;
  final String? thumbnailPath;

  bool get isLocalAsset => assetId != null;
  bool get isVideo => mediaType == 'video';
  bool get isLivePhoto => mediaType == 'livePhoto';

  /// 转为 previewAssets 所需的 AssetInput
  AssetInput toAssetInput() {
    if (isLocalAsset) {
      return AssetInput(type: 'local', assetId: assetId, mediaType: mediaType);
    }
    return AssetInput(
      type: 'network',
      url: url,
      mediaType: mediaType,
      videoUrl: videoUrl,
      duration: duration,
    );
  }

  factory PostMedia.fromJson(Map<String, dynamic> json) => PostMedia(
    mediaType: json['mediaType'] as String,
    url: json['url'] as String?,
    videoUrl: json['videoUrl'] as String?,
    duration: (json['duration'] as num?)?.toDouble(),
    width: (json['width'] as num?)?.toInt() ?? 0,
    height: (json['height'] as num?)?.toInt() ?? 0,
  );
}
```

#### 缩略图宫格展示

```dart
Widget buildThumb(PostMedia media) {
  // 已上传：显示网络图
  if (media.url != null) {
    return Image.network(
      media.url!,
      fit: BoxFit.cover,
      loadingBuilder: (_, child, progress) =>
          progress == null ? child : const Center(child: CircularProgressIndicator()),
      errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
    );
  }
  // 本地未上传：显示缩略图
  if (media.thumbnailPath != null) {
    return Image.file(File(media.thumbnailPath!), fit: BoxFit.cover);
  }
  return const Icon(Icons.image_not_supported_outlined);
}
```

#### 点击预览（混合来源）

```dart
await LivePhotoGallery.previewAssets(
  assets: mediaList.map((m) => m.toAssetInput()).toList(),
  initialIndex: tappedIndex,
  sourceFrame: cellFrame,                           // 飞回动画
  config: const PickerConfig(showRadio: false),     // 纯预览模式
);
```

---

### iOS 原生回显

如果宿主 App 有纯原生页面也需要展示相同内容（如分享卡片、详情页）：

#### 图片（SDWebImage / Kingfisher）

```swift
// Kingfisher
imageView.kf.setImage(with: URL(string: media.url))

// SDWebImage
imageView.sd_setImage(with: URL(string: media.url))
```

#### 视频（AVPlayer）

```swift
// 视频缩略图（封面图）：用 imageView 展示 coverUrl
imageView.kf.setImage(with: URL(string: media.coverUrl ?? media.url))

// 点击后播放视频
let player = AVPlayer(url: URL(string: media.videoUrl!)!)
let playerVC = AVPlayerViewController()
playerVC.player = player
present(playerVC, animated: true) {
    player.play()
}
```

#### Live Photo（PHLivePhotoView）

Live Photo 需要先将图片和视频下载到本地，再合成 `PHLivePhoto` 对象展示。

```swift
import PhotosUI

// 1. 下载图片和视频到本地临时文件
func displayLivePhoto(imageURL: URL, videoURL: URL, in view: PHLivePhotoView) {
    let group = DispatchGroup()
    var localImageURL: URL?
    var localVideoURL: URL?

    group.enter()
    downloadFile(from: imageURL, ext: "jpg") { url in
        localImageURL = url
        group.leave()
    }

    group.enter()
    downloadFile(from: videoURL, ext: "mov") { url in
        localVideoURL = url
        group.leave()
    }

    group.notify(queue: .main) {
        guard let imgURL = localImageURL, let vidURL = localVideoURL else { return }

        // 2. 合成 PHLivePhoto
        PHLivePhoto.request(
            withResourceFileURLs: [imgURL, vidURL],
            placeholderImage: nil,
            targetSize: view.bounds.size,
            contentMode: .aspectFit
        ) { livePhoto, _ in
            if let livePhoto = livePhoto {
                view.livePhoto = livePhoto
                view.startPlayback(with: .hint)  // 自动播放一次提示动效
            }
        }
    }
}

// 3. 点击长按触发全量播放
let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
livePhotoView.addGestureRecognizer(longPress)

@objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    if gesture.state == .began {
        livePhotoView.startPlayback(with: .full)
    } else if gesture.state == .ended || gesture.state == .cancelled {
        livePhotoView.stopPlayback()
    }
}
```

> **注意**：`PHLivePhoto.request(withResourceFileURLs:)` 要求视频文件必须是 `.mov` 格式，且包含 QuickTime 元数据。插件导出的 `livePhotoVideo` 已确保格式兼容。

---

### Android 回显

Android 系统**不支持 Live Photo**（苹果私有格式），需要做降级处理。

#### 图片（Glide / Coil）

```kotlin
// Glide
Glide.with(context)
    .load(media.url)
    .placeholder(R.drawable.placeholder)
    .into(imageView)

// Coil（Compose）
AsyncImage(
    model = media.url,
    contentDescription = null,
    contentScale = ContentScale.Crop,
)
```

#### 视频（ExoPlayer）

```kotlin
// build.gradle
implementation("androidx.media3:media3-exoplayer:1.x.x")
implementation("androidx.media3:media3-ui:1.x.x")

// 代码
val player = ExoPlayer.Builder(context).build()
val mediaItem = MediaItem.fromUri(media.videoUrl)
player.setMediaItem(mediaItem)
player.prepare()
player.play()

// 绑定到 PlayerView
playerView.player = player
```

#### Live Photo → 降级为静态图

```kotlin
// Android 不支持 Live Photo，直接展示静态图部分
// url 字段是静态图，直接加载
when (media.mediaType) {
    "image"     -> loadImage(media.url)
    "video"     -> loadVideo(media.videoUrl, media.coverUrl)
    "livePhoto" -> loadImage(media.url)  // 降级：展示静态帧
}
```

**Android 宫格 Live Photo 角标建议**

```kotlin
// 可在右下角叠加一个小图标提示用户这是 Live Photo，
// 但点击后仅展示静态大图，不播放视频
if (media.mediaType == "livePhoto") {
    livePhotoBadge.visibility = View.VISIBLE
}
```

---

## 完整数据流图

```
┌─────────────────────────────────────────────────────────────────────┐
│                          发帖 / 编辑帖子                              │
└───────────────────┬─────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Flutter — LivePhotoGallery.pickAssets()                            │
│                                                                     │
│  返回 MediaItem { assetId, mediaType, thumbnailPath, ... }          │
└───────────────────┬─────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Flutter — LivePhotoGallery.exportAsset()                           │
│                                                                     │
│  image     → .jpg / .heic（本地临时路径）                             │
│  video     → .mp4（本地临时路径）                                     │
│  livePhoto → .jpg + .mov（本地临时路径 × 2）                          │
└───────────────────┬─────────────────────────────────────────────────┘
                    │
                    ▼ multipart/form-data
┌─────────────────────────────────────────────────────────────────────┐
│  后端 — POST /api/media/upload                                       │
│                                                                     │
│  1. 保存文件到 OSS / 对象存储                                          │
│  2. 视频自动截帧生成封面（FFmpeg / 云函数）                             │
│  3. 写入数据库（mediaType, url, videoUrl, coverUrl, width, height）   │
└───────────────────┬─────────────────────────────────────────────────┘
                    │
                    ▼ JSON 响应
┌─────────────────────────────────────────────────────────────────────┐
│  后端 — GET /api/post/{id} 帖子详情                                   │
│                                                                     │
│  mediaList: [                                                       │
│    { mediaType: "image",     url: "cdn/xxx.jpg" },                  │
│    { mediaType: "livePhoto", url: "cdn/yyy.jpg",                    │
│                              videoUrl: "cdn/yyy.mov" },             │
│    { mediaType: "video",     url: "cdn/zzz.mp4",                    │
│                              coverUrl: "cdn/zzz_cover.jpg" }        │
│  ]                                                                  │
└────────────┬────────────────────────┬───────────────────────────────┘
             │                        │
             ▼                        ▼
┌────────────────────┐   ┌────────────────────────────────────────────┐
│   Flutter / iOS    │   │              Android                       │
│                    │   │                                            │
│ image    → 网络图   │   │ image     → Glide/Coil                    │
│ video    → AVPlayer│   │ video     → ExoPlayer                      │
│ livePhoto→ 点击预览 │   │ livePhoto → Glide 加载静态图（降级）          │
│           PHLivePhotoView│                                          │
└────────────────────┘   └────────────────────────────────────────────┘
```

---

## 各端 Live Photo 支持对照

| 场景 | iOS（原生 / Flutter） | Android | Web |
|------|----------------------|---------|-----|
| 缩略图展示 | 静态图（带 Live 角标） | 静态图（可加角标） | 静态图 |
| 点击查看 | PHLivePhotoView 动态播放 | 普通图片查看 | 普通图片查看 |
| 长按播放 | ✅ 全量播放 | ❌ | ❌ |
| 上传前预览 | ✅ 本插件支持 | ❌ | ❌ |
| 后端存储 | 图片 + 视频 分别存 | 图片 + 视频 分别存 | 图片 + 视频 分别存 |
| 回显最低要求 | iOS 9.1+ | 仅需图片 URL | 仅需图片 URL |

> **建议**：后端数据库中 `mediaType = "livePhoto"` 的记录，同时存储 `imageUrl` 和 `videoUrl` 两个字段。iOS 端使用 `videoUrl` 合成 `PHLivePhoto` 展示，Android / Web 端忽略 `videoUrl` 只展示 `imageUrl`。
