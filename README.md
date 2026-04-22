# live_photo_gallery

iOS & Android 相册选择 & 预览插件，支持图片、视频、Live Photo / Motion Photo 混合场景。

- iOS 最低版本：iOS 15
- Android 最低版本：API 21（Android 5.0）

---

## 目录

- [功能概览](#功能概览)
- [安装](#安装)
- [权限配置](#权限配置)
  - [iOS](#ios)
  - [Android](#android)
- [快速开始](#快速开始)
- [API 参考](#api-参考)
  - [requestPermission](#requestpermission)
  - [pickAssets](#pickassets)
  - [previewAssets](#previewassets)
  - [onDownloadResult](#ondownloadresult)
  - [getThumbnail](#getthumbnail)
  - [exportAsset](#exportasset)
  - [cleanupTempFiles](#cleanuptempfiles)
- [数据模型](#数据模型)
  - [PickerConfig](#pickerconfig)
  - [AssetInput](#assetinput)
  - [MediaItem](#mediaitem)
  - [PickResult](#pickresult)
  - [DownloadResult](#downloadresult)
  - [DownloadErrorCode](#downloaderrorcode)
- [错误处理](#错误处理)
- [使用场景示例](#使用场景示例)
  - [发帖选图](#发帖选图)
  - [预览混合来源媒体](#预览混合来源媒体)
  - [社交场景：网络图片预览 + 保存到相册](#社交场景网络图片预览--保存到相册)
  - [上传前导出文件](#上传前导出文件)
- [纯预览模式](#纯预览模式)
- [关闭动画飞回缩略图](#关闭动画飞回缩略图)
- [临时文件管理](#临时文件管理)

---

## 功能概览

| 功能 | iOS | Android |
|------|:---:|:-------:|
| 多选图片 | ✅ | ✅ |
| 多选视频 | ✅ | ✅ |
| Live Photo / Motion Photo 选择与预览 | ✅ | ✅ |
| 网络图片 + 本地资源混合预览 | ✅ | ✅ |
| 预览页下载按钮（网络图片保存到相册） | ✅ | ✅ |
| 保存结果 native → Flutter 回执 | ✅ | ✅ |
| 相册分组 | ✅ | ✅ |
| 原图导出（HEIC / JPEG / PNG） | ✅ | ✅ |
| 关闭动画飞回缩略图位置 | ✅ | ✅ |
| 纯预览模式（隐藏选择 UI） | ✅ | ✅ |
| 结构化错误码，Flutter 侧精确捕获 | ✅ | ✅ |

---

## 安装

### pubspec.yaml（本地路径，适用于私有插件）

```yaml
dependencies:
  live_photo_gallery:
    path: /your/path/to/live_photo_gallery
```

### pubspec.yaml（pub.dev 发布后）

```yaml
dependencies:
  live_photo_gallery: ^1.0.0
```

```bash
flutter pub get
```

---

## 权限配置

### iOS

在 `ios/Runner/Info.plist` 中添加：

```xml
<!-- 相册读取权限（iOS 14+ 支持 Limited 模式） -->
<key>NSPhotoLibraryUsageDescription</key>
<string>需要访问相册来选择照片和视频</string>

<!-- 相册写入权限（previewAssets 开启 showDownloadButton 时保存网络图片需要） -->
<key>NSPhotoLibraryAddUsageDescription</key>
<string>需要保存图片到您的相册</string>
```

> **Limited Access**：插件使用 `.readWrite` 权限级别，iOS 14 以上用户可选择「选中的照片」模式，插件会正常工作，仅展示用户已授权的照片。

### Android

在 `android/app/src/main/AndroidManifest.xml` 中添加：

```xml
<!-- Android 13+（API 33+） -->
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />

<!-- Android 12 及以下（API ≤ 32） -->
<uses-permission
    android:name="android.permission.READ_EXTERNAL_STORAGE"
    android:maxSdkVersion="32" />
```

> **运行时权限**：调用 `requestPermission()` 会弹出系统权限申请弹窗，在 Android 10 及以下还会申请 `WRITE_EXTERNAL_STORAGE`。

---

## 快速开始

```dart
import 'package:live_photo_gallery/live_photo_gallery.dart';

// 1. 请求权限
final status = await LivePhotoGallery.requestPermission();
if (status != 'authorized' && status != 'limited') return;

// 2. 打开相册选择器
final result = await LivePhotoGallery.pickAssets(
  config: const PickerConfig(maxCount: 9),
);

if (result == null) return; // 用户取消

for (final item in result.items) {
  print('${item.mediaType}: ${item.thumbnailPath}');
}
```

---

## API 参考

### requestPermission

请求相册访问权限。

```dart
static Future<String> requestPermission()
```

**返回值**

| 值 | 含义 |
|----|------|
| `"authorized"` | 完整权限 |
| `"limited"` | 有限权限（iOS 14+ 选中部分照片；Android 14+ 在系统授予“选中的照片/视频”时也可能返回该状态） |
| `"denied"` | 已拒绝（需引导用户到设置页手动开启） |
| `"notDetermined"` | 首次询问前（调用后系统会自动弹授权弹窗） |

**示例**

```dart
final status = await LivePhotoGallery.requestPermission();
switch (status) {
  case 'authorized':
  case 'limited':
    openPicker();
  case 'denied':
    openAppSettings(); // 引导到设置
  default:
    break;
}
```

---

### pickAssets

打开相册选择器，用户选完后返回所选媒体列表。

```dart
static Future<PickResult?> pickAssets({
  PickerConfig config = const PickerConfig(),
})
```

**参数**：见 [PickerConfig](#pickerconfig)

**返回值**：[PickResult](#pickresult)，用户取消时返回 `null`

**说明**

- 返回的 `MediaItem.thumbnailPath` 是本地缓存路径（200×200 JPEG），可直接用 `Image.file` 展示
- 缩略图为确定性文件名，同一资源重复调用不重复生成
- 原图勾选状态通过 `result.isOriginalPhoto` 读取

**示例**

```dart
final result = await LivePhotoGallery.pickAssets(
  config: const PickerConfig(
    maxCount: 9,
    enableVideo: true,
    enableLivePhoto: true,
    isDarkMode: false,
  ),
);

if (result == null || result.items.isEmpty) return;

print('原图：${result.isOriginalPhoto}');
for (final item in result.items) {
  // item.assetId    — 本地资源 ID（iOS: PHAsset localIdentifier；Android: MediaStore URI）
  // item.mediaType  — "image" | "video" | "livePhoto"
  // item.thumbnailPath — 本地缩略图路径
  // item.duration   — 视频时长（秒），图片为 null
  // item.width / item.height
}
```

---

### previewAssets

预览资源列表，支持本地资源与网络资源混合。
可选：传入 `sourceFrame` 实现关闭时飞回缩略图的动画效果；传入 `showDownloadButton: true` 在预览页显示保存按钮。

```dart
static Future<PickResult?> previewAssets({
  required List<AssetInput> assets,
  int initialIndex = 0,
  Rect sourceFrame = Rect.zero,
  List<String> selectedAssetIds = const [],
  PickerConfig config = const PickerConfig(),
  bool showDownloadButton = false,
})
```

**参数**

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `assets` | `List<AssetInput>` | — | 要预览的资源列表（本地 + 网络混合） |
| `initialIndex` | `int` | `0` | 初始显示的索引 |
| `sourceFrame` | `Rect` | `Rect.zero` | 缩略图在屏幕中的位置，用于飞回动画（传 `Rect.zero` 降级为淡出） |
| `selectedAssetIds` | `List<String>` | `[]` | 预选中的资源 ID，预览界面展示勾选状态 |
| `config` | `PickerConfig` | `PickerConfig()` | 选择器配置（`showRadio: false` 为纯预览模式） |
| `showDownloadButton` | `bool` | `false` | 是否在预览页显示保存到相册按钮（**仅对网络图片生效**） |
| `saveAlbumName` | `String` | `''` | 保存图片的目标相册名。Android：`Pictures/<name>/`；iOS：同时加入同名自定义相册。空串 = Android 用 App 名，iOS 仅存到「最近项目」 |

**关于 `showDownloadButton`**

- 按钮仅在当前页为**网络图片**时显示，本地资源页不显示
- 开启后必须监听 [onDownloadResult](#ondownloadresult) 流以获取保存结果，并在 Flutter 侧展示成功/失败提示
- 保存成功后回调包含写入相册的 `assetId`（iOS: PHAsset localIdentifier；Android: MediaStore content URI）

**关于“选择预览页裁剪”**

- 裁剪入口仅在 `config.showRadio == true` 的预览页显示（纯预览模式不显示）
- 仅当前页为 `mediaType == "image"` 时显示「裁剪」按钮；视频 / Live Photo 不支持
- 裁剪完成后，返回结果中的 `assetId` 会替换为裁剪后的本地文件路径（对业务侧可直接上传）
- 原系统相册资源不会被物理修改；插件以“裁剪后的结果图”作为后续流程的最终图
- 裁剪结果默认不写入系统相册，由业务侧决定是否持久化

**返回值**：[PickResult](#pickresult)，用户直接关闭时返回 `null`

> **纯预览模式**：传入 `config: const PickerConfig(showRadio: false)` 时，底部「原图 + 完成」栏和右上角选择按钮全部隐藏，仅保留关闭按钮，适合「已选内容预览」场景。

---

### onDownloadResult

监听预览页保存网络图片到相册的结果事件（native → Flutter 主动推送）。

```dart
static Stream<DownloadResult> get onDownloadResult
```

> 此流为 `broadcast` 类型，可同时被多处订阅。

**用法**

```dart
late StreamSubscription<DownloadResult> _downloadSub;

@override
void initState() {
  super.initState();
  _downloadSub = LivePhotoGallery.onDownloadResult.listen((result) {
    switch (result) {
      case DownloadSuccess(:final url, :final assetId):
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存到相册')),
        );
      case DownloadFailure(:final errorCode, :final errorMessage):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage)),
        );
    }
  });
}

@override
void dispose() {
  _downloadSub.cancel();
  super.dispose();
}
```

---

### getThumbnail

按需获取指定资源的缩略图本地路径。

```dart
static Future<String?> getThumbnail({
  required String assetId,
  double width = 200,
  double height = 200,
})
```

**返回值**：本地临时文件路径，失败返回 `null`

**示例**

```dart
final path = await LivePhotoGallery.getThumbnail(
  assetId: item.assetId,
  width: 400,
  height: 400,
);
if (path != null) {
  Image.file(File(path));
}
```

---

### exportAsset

将本地资源导出为实体文件到临时目录，用于后续上传。

```dart
static Future<String?> exportAsset({
  required String assetId,
  required String format,
})
```

**`format` 可选值**

| 值 | 导出内容 | 典型文件 |
|----|---------|---------|
| `"image"` | 图片（含 Live Photo 静态帧） | `.jpg` / `.heic` / `.png` |
| `"video"` | 视频原文件 | `.mp4` |
| `"livePhotoVideo"` | Live Photo / Motion Photo 的视频部分 | `.mov`（iOS，HDR 自动转 SDR）/ `.mp4`（Android） |

**返回值**：本地临时文件绝对路径，失败返回 `null`

**示例**

```dart
// 导出图片
final imagePath = await LivePhotoGallery.exportAsset(
  assetId: item.assetId,
  format: 'image',
);

// 导出 Live Photo / Motion Photo 视频部分
final videoPath = await LivePhotoGallery.exportAsset(
  assetId: item.assetId,
  format: 'livePhotoVideo',
);
```

> **注意**：导出文件存放在系统临时目录，App 重启或手动清理后会删除，**上传完成后请调用 `cleanupTempFiles()`**。

---

### cleanupTempFiles

清理插件产生的所有临时文件（以 `lpg_` 为前缀）。

```dart
static Future<void> cleanupTempFiles()
```

建议在以下时机调用：

- 上传完成后
- App 启动时（清理上次遗留）
- 用户取消发布时

```dart
// 上传成功后清理
await uploadFiles(filePaths);
await LivePhotoGallery.cleanupTempFiles();
```

---

## 数据模型

### PickerConfig

相册选择器配置项。

```dart
class PickerConfig {
  final bool isDarkMode;       // 暗色模式，默认 false
  final int maxCount;          // 最多可选数量，默认 9
  final bool enableVideo;      // 是否显示视频，默认 true
  final bool enableLivePhoto;  // 是否显示 Live Photo / Motion Photo，默认 true
  final bool showRadio;        // 是否显示选择圆圈，false = 纯预览模式，默认 true
  final CropConfig? cropConfig; // 裁剪配置（用于选择预览页）
}
```

---

### CropConfig

选择预览页中的图片裁剪配置。

```dart
class CropConfig {
  final double aspectRatioX; // 0 = 不锁定比例
  final double aspectRatioY; // 0 = 不锁定比例
}
```

当前版本行为：

- iOS：使用原生交互裁剪 UI，支持自由裁剪
- Android：使用原生交互裁剪 UI（uCrop），支持自由裁剪

---

### AssetInput

传给 `previewAssets` 的资源描述，支持本地资源和网络两种来源。

```dart
class AssetInput {
  final String type;       // "local" | "network"
  final String? assetId;   // type="local" 时必填，本地资源 ID
  final String? url;       // type="network" 时必填，图片封面 URL
  final String? mediaType; // "image" | "video" | "livePhoto"
  final String? videoUrl;  // 视频 URL（type="network" 且 mediaType="video"/"livePhoto" 时填写）
  final double? duration;  // 视频时长（秒）
}
```

**构造示例**

```dart
// 本地资源
AssetInput(type: 'local', assetId: item.assetId, mediaType: item.mediaType)

// 网络图片
AssetInput(type: 'network', url: 'https://cdn.example.com/img.jpg', mediaType: 'image')

// 网络视频（url 为封面图，videoUrl 为视频文件地址）
AssetInput(
  type: 'network',
  url: 'https://cdn.example.com/thumb.jpg',
  mediaType: 'video',
  videoUrl: 'https://cdn.example.com/video.mp4',
  duration: 15.0,
)

// 网络 Live Photo
AssetInput(
  type: 'network',
  url: 'https://cdn.example.com/photo.jpg',
  mediaType: 'livePhoto',
  videoUrl: 'https://cdn.example.com/live.mov',
)
```

---

### MediaItem

`pickAssets` 返回的单个媒体条目，包含展示所需的全部信息。

```dart
class MediaItem {
  final String assetId;       // 默认为本地资源 ID；若执行了裁剪，返回裁剪后的本地文件路径
  final String mediaType;     // "image" | "video" | "livePhoto"
  final String thumbnailPath; // 200×200 本地缩略图路径，可直接 Image.file() 展示
  final double? duration;     // 视频时长（秒），图片为 null
  final int width;            // 原始宽度（px）
  final int height;           // 原始高度（px）
}
```

---

### PickResult

`pickAssets` / `previewAssets` 的返回结果。

```dart
class PickResult {
  final List<MediaItem> items;   // 已选媒体列表
  final bool isOriginalPhoto;    // 用户是否勾选了「原图」
}
```

---

### DownloadResult

预览页保存网络图片到相册的结果，通过 `onDownloadResult` 流推送。`DownloadResult` 是 sealed class，有两个子类：

```dart
// 保存成功
class DownloadSuccess extends DownloadResult {
  final String url;      // 触发下载的图片 URL
  final String? assetId; // 写入相册后的资源 ID（iOS: PHAsset localIdentifier；Android: MediaStore content URI）
}

// 保存失败
class DownloadFailure extends DownloadResult {
  final String url;                  // 触发下载的图片 URL
  final DownloadErrorCode errorCode; // 结构化错误码
  final String errorMessage;         // 可读错误描述，可直接展示给用户
}
```

**模式匹配示例（Dart 3+）**

```dart
LivePhotoGallery.onDownloadResult.listen((result) {
  switch (result) {
    case DownloadSuccess(:final url):
      print('保存成功: $url');
    case DownloadFailure(:final errorCode, :final errorMessage):
      if (errorCode == DownloadErrorCode.permissionDenied) {
        openAppSettings();
      } else {
        showToast(errorMessage);
      }
  }
});
```

---

### DownloadErrorCode

保存失败时的错误原因枚举。

```dart
enum DownloadErrorCode {
  permissionDenied, // 没有相册写入权限
  networkError,     // 网络下载失败（HTTP 错误、超时等）
  saveFailed,       // 写入相册失败（磁盘空间不足等）
  unknown,          // 其他未知错误
}
```

---

## 错误处理

所有方法都可能抛出 `LivePhotoException`，建议统一捕获：

```dart
try {
  final result = await LivePhotoGallery.pickAssets();
} on LivePhotoException catch (e) {
  print('错误码: ${e.code}');
  print('错误信息: ${e.message}');
}
```

**错误码一览**

| code | 触发场景 | 建议处理 |
|------|---------|---------|
| `PERMISSION_DENIED` | 用户拒绝了相册权限 | 引导到系统设置开启 |
| `ASSET_NOT_FOUND` | assetId 找不到对应资源（资源被删除等） | 提示用户资源已不存在 |
| `ASSET_LOAD_FAILED` | 资源加载失败（格式异常、解码错误等） | 提示格式不支持 |
| `EXPORT_FAILED` | 导出/转码失败（磁盘空间不足等） | 提示稍后重试 |
| `SAVE_FAILED` | 写文件失败 | 检查存储空间 |
| `LIVE_PHOTO_ERROR` | Live Photo / Motion Photo 提取或转码失败 | 提示格式不支持 |
| `INVALID_ARGS` | 参数无效（format 不合法等） | 检查调用参数 |
| `NO_VIEW_CONTROLLER` | 无法获取顶层 ViewController（iOS，极少见） | 检查页面栈状态 |
| `UNKNOWN_ERROR` | 未分类错误 | 上报日志 |

---

## 使用场景示例

### 发帖选图

```dart
final result = await LivePhotoGallery.pickAssets(
  config: PickerConfig(
    maxCount: 9 - _currentCount, // 根据已有数量计算剩余可选数
    enableVideo: true,
    enableLivePhoto: true,
  ),
);

if (result == null || result.items.isEmpty) return;

setState(() {
  isOriginalPhoto = result.isOriginalPhoto;
  mediaList.addAll(result.items);
});
```

---

### 预览混合来源媒体

帖子已有服务端图片，追加了本地选图，点击缩略图混合预览：

```dart
Future<void> previewAt(int index, Rect sourceFrame) async {
  final inputs = mediaList.map((m) {
    if (m.assetId != null) {
      // 本地资源
      return AssetInput(type: 'local', assetId: m.assetId!, mediaType: m.mediaType);
    } else {
      // 服务端网络资源
      return AssetInput(
        type: 'network',
        url: m.imageUrl,
        mediaType: m.mediaType,
        videoUrl: m.videoUrl,
        duration: m.duration,
      );
    }
  }).toList();

  await LivePhotoGallery.previewAssets(
    assets: inputs,
    initialIndex: index,
    sourceFrame: sourceFrame,
    config: const PickerConfig(showRadio: false), // 纯预览，不显示选择 UI
  );
}
```

**在 Widget 中获取 sourceFrame**：

```dart
GestureDetector(
  onTap: () {
    final box = context.findRenderObject() as RenderBox?;
    final frame = box != null
        ? (box.localToGlobal(Offset.zero) & box.size)
        : Rect.zero;
    previewAt(index, frame);
  },
  child: ThumbnailCell(...),
)
```

---

### 社交场景：网络图片预览 + 保存到相册

适用于查看他人帖子、动态、广场等场景——预览页右上角出现下载按钮，点击后将当前网络图片保存到系统相册，保存结果通过 `onDownloadResult` 流推送到 Flutter 侧展示。

```dart
class PostDetailPage extends ConsumerStatefulWidget {
  const PostDetailPage({super.key, required this.post});
  final Post post;

  @override
  ConsumerState<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends ConsumerState<PostDetailPage> {
  StreamSubscription<DownloadResult>? _downloadSub;

  @override
  void initState() {
    super.initState();
    // 提前注册监听，避免保存回调丢失
    _downloadSub = LivePhotoGallery.onDownloadResult.listen(_onDownloadResult);
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    super.dispose();
  }

  void _onDownloadResult(DownloadResult result) {
    final msg = switch (result) {
      DownloadSuccess() => '已保存到相册',
      DownloadFailure(:final errorCode, :final errorMessage) =>
        errorCode == .permissionDenied ? '请在设置中开启相册权限' : errorMessage,
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _previewImage(int index, Rect frame) async {
    final assets = widget.post.images.map((url) =>
      AssetInput(type: 'network', url: url, mediaType: 'image'),
    ).toList();

    await LivePhotoGallery.previewAssets(
      assets: assets,
      initialIndex: index,
      sourceFrame: frame,
      config: const PickerConfig(showRadio: false),
      showDownloadButton: true,  // 开启下载按钮
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3),
        itemCount: widget.post.images.length,
        itemBuilder: (context, index) {
          return GestureDetector(
            onTap: () {
              final box = context.findRenderObject() as RenderBox?;
              final frame = box != null
                  ? box.localToGlobal(Offset.zero) & box.size
                  : Rect.zero;
              _previewImage(index, frame);
            },
            child: CachedNetworkImage(
              imageUrl: widget.post.images[index],
              fit: BoxFit.cover,
            ),
          );
        },
      ),
    );
  }
}
```

---

### 上传前导出文件

```dart
Future<void> uploadSelected(List<MediaItem> items, bool isOriginal) async {
  for (final item in items) {
    switch (item.mediaType) {
      case 'image':
        final path = await LivePhotoGallery.exportAsset(
          assetId: item.assetId,
          format: 'image',
        );
        if (path != null) await uploadFile(path);

      case 'video':
        final path = await LivePhotoGallery.exportAsset(
          assetId: item.assetId,
          format: 'video',
        );
        if (path != null) await uploadFile(path);

      case 'livePhoto':
        // Live Photo 需要分别上传静态图和视频
        final imgPath = await LivePhotoGallery.exportAsset(
          assetId: item.assetId, format: 'image');
        final videoPath = await LivePhotoGallery.exportAsset(
          assetId: item.assetId, format: 'livePhotoVideo');
        if (imgPath != null && videoPath != null) {
          await uploadLivePhoto(imgPath, videoPath);
        }
    }
  }

  // 上传完成后清理临时文件
  await LivePhotoGallery.cleanupTempFiles();
}
```

---

## 纯预览模式

当 `PickerConfig(showRadio: false)` 时：

- ✅ 隐藏右上角选择圆圈
- ✅ 隐藏底部「原图」按钮和「完成」按钮
- ✅ 仍支持下滑手势关闭、飞回动画
- ✅ 仍支持长按播放 Live Photo / Motion Photo
- ✅ 仍支持视频播放
- ✅ 仍支持 `showDownloadButton`（下载按钮独立于选择 UI）

适用场景：帖子详情查看、他人动态浏览、个人相册预览。

---

## 关闭动画飞回缩略图

预览关闭时，图片会以动画飞回缩略图位置，需要 Flutter 侧传入缩略图的屏幕坐标：

```dart
// 在 GestureDetector.onTap 中获取当前 Widget 的屏幕 Rect
final box = context.findRenderObject() as RenderBox?;
final frame = box != null
    ? (box.localToGlobal(Offset.zero) & box.size)
    : Rect.zero;

await LivePhotoGallery.previewAssets(
  assets: assets,
  initialIndex: index,
  sourceFrame: frame,   // ← 关键
  config: const PickerConfig(showRadio: false),
);
```

传 `Rect.zero` 时降级为淡出缩小动画。

---

## 临时文件管理

插件导出的所有文件统一以 `lpg_` 为前缀存放在系统临时目录：
- iOS：`NSTemporaryDirectory()`
- Android：`Context.getCacheDir()`

| 行为 | 文件名 |
|------|-------|
| 缩略图 | `lpg_{sanitizedId}_{w}x{h}.jpg`（确定性，命中即复用） |
| 导出图片 | `lpg_{uuid}.jpg` / `.heic` / `.png`（每次新建） |
| 导出视频 | `lpg_{uuid}.mp4` |
| Live Photo 视频 | `lpg_{uuid}.mov`（iOS）/ `lpg_{uuid}.mp4`（Android） |

**推荐清理时机**

```dart
// App 启动时（清理上次遗留）
await LivePhotoGallery.cleanupTempFiles();

// 上传完成后
await uploadAll(filePaths);
await LivePhotoGallery.cleanupTempFiles();

// 用户取消发布
onCancel: () async {
  await LivePhotoGallery.cleanupTempFiles();
  Navigator.pop(context);
};
```
