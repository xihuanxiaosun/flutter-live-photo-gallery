# live_photo_gallery 集成使用文档

Flutter 插件：iOS + Android **纯原生**相册选择 / 全屏预览 / 导出。支持图片、视频、Live Photo（iOS）、Motion Photo（Android），以及**本地 + 网络资源混排预览**（微博式图文视频信息流）。公共 API 全部收口在 `LivePhotoGallery` 一个类。

> 本文档面向**接入方**。照抄即可跑通；末尾有「常见配方」和「注意事项」。参考实现见仓库 `example/lib/pages/`（`edit_post_page.dart` = 选图+裁剪+回显；`post_feed_page.dart` = 网络资源信息流预览）。

---

## 1. 安装

### 方式 A —— Git 依赖（推荐，已推送到 `main`）
在你项目的 `pubspec.yaml`：
```yaml
dependencies:
  live_photo_gallery:
    git:
      url: https://github.com/xihuanxiaosun/flutter-live-photo-gallery.git
      ref: main
```
> 用 SSH 就把 url 换成 `git@github.com:xihuanxiaosun/flutter-live-photo-gallery.git`。
> 想锁版本可把 `ref` 指向某个 commit 或 tag。

### 方式 B —— 本地 path 依赖（同机联调最快）
```yaml
dependencies:
  live_photo_gallery:
    path: /Volumes/saber/dev/projects/live_photo_gallery
```

然后：
```bash
flutter pub get
```

---

## 2. 环境要求（硬性）

| 项 | 要求 |
|---|---|
| Flutter / Dart | **Flutter ≥ 3.22**，Dart **≥ 3.4**（`>=3.4.0 <4.0.0`） |
| iOS | **最低 iOS 15.0** |
| Android | **minSdk 21**，**compileSdk 34** |

---

## 3. 平台配置

### iOS（在你的 App 里）
1. `ios/Podfile` 顶部：
   ```ruby
   platform :ios, '15.0'
   ```
2. `ios/Runner/Info.plist` 加权限说明（**必须**，否则相册 API 会崩）：
   ```xml
   <key>NSPhotoLibraryUsageDescription</key>
   <string>需要访问相册以选择照片</string>
   <key>NSPhotoLibraryAddUsageDescription</key>
   <string>需要保存照片到相册</string>
   ```
3. 安装 Pods：
   ```bash
   cd ios && export LANG=en_US.UTF-8 && pod install
   ```

### Android（在你的 App 里）
- **权限插件已在自己的 manifest 声明**（`READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` / `READ_MEDIA_VISUAL_USER_SELECTED` / `READ_EXTERNAL_STORAGE` / `WRITE_EXTERNAL_STORAGE`），会自动合并进你的 App，**你无需再写**。
- 确保 `android/app/build.gradle` 里 `minSdk ≥ 21`、`compileSdk ≥ 34`。
- 运行时权限由插件自动申请（调 `pickAssets` / `previewAssets` 时弹框，或你主动调 `requestPermission()`）。

---

## 4. API 参考（全部在 `LivePhotoGallery`）

所有方法都是 `static`，失败时抛 `LivePhotoException`（含 `code` / `message`），建议 try/catch。

```dart
import 'package:live_photo_gallery/live_photo_gallery.dart';
```

### 4.1 requestPermission
```dart
static Future<String> requestPermission()
// 返回 'authorized' | 'limited' | 'denied' | 'notDetermined'
```
一般无需手动调——`pickAssets`/`previewAssets` 会在无权限时自动弹框。想提前查/引导去设置时用它。

### 4.2 pickAssets —— 打开原生宫格选图
```dart
static Future<PickResult?> pickAssets({ PickerConfig config = const PickerConfig() })
// 用户取消 → 返回 null（不是异常、不是空列表）
```

### 4.3 previewAssets —— 全屏预览（本地 + 网络混排）
```dart
static Future<PickResult?> previewAssets({
  required List<AssetInput> assets,
  int initialIndex = 0,
  Rect sourceFrame = Rect.zero,        // 被点缩略图在屏幕中的位置，用于飞入/飞回动画
  List<String> selectedAssetIds = const [],
  PickerConfig config = const PickerConfig(),
  bool showDownloadButton = false,     // 预览页右上「保存到相册」，仅对网络图片生效
  String saveAlbumName = '',           // 保存目标相册/目录名
})
```

### 4.4 getThumbnail —— 生成缩略图本地路径
```dart
static Future<String?> getThumbnail({
  required String assetId, double width = 200, double height = 200,
})
```

### 4.5 exportAsset —— 导出原文件到本地（传后端用）
```dart
static Future<String?> exportAsset({
  required String assetId,
  required String format,   // 'image' | 'video' | 'livePhotoVideo'（其它值抛 INVALID_ARGS）
  bool original = false,    // ⭐ 见下方「注意事项」
})
// 返回本地文件路径
```

### 4.6 cleanupTempFiles —— 清理插件临时文件
```dart
static Future<void> cleanupTempFiles()
// 建议 App 启动时或上传完成后调用
```

### 4.7 事件流（native → Flutter）
```dart
static Stream<DownloadResult> get onDownloadResult;                 // 网络图保存成功/失败
static Stream<({String url, double progress})> get onDownloadProgress; // 保存进度
static Stream<int> get onMaxCountReached;                           // 选择超出上限
```

---

## 5. 数据模型

### PickerConfig（选择器/预览配置）
| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `isDarkMode` | bool | false | 暗色主题 |
| `maxCount` | int | 9 | 最多可选数（>0） |
| `enableVideo` | bool | true | 允许视频 |
| `enableLivePhoto` | bool | true | 允许 Live/Motion Photo |
| `showRadio` | bool | true | 显示多选圈；`false` = 纯预览模式 |
| `autoPlayVideo` | bool | false | 预览页进入视频页是否自动播放（仅当前页） |
| `maxVideoCount` | int | -1 | 最多视频/Live 数（-1 无限） |
| `videoMaxDuration` | double | 0 | 视频最长秒数（0 无限） |
| `filterConfig` | MediaFilter | all | all / imageOnly / videoOnly / livePhotoOnly（优先级高于 enableVideo/enableLivePhoto） |
| `cropConfig` | CropConfig? | null | 裁剪配置（比例字段当前未生效，为自由裁剪） |

### AssetInput（传给 previewAssets 的单个资源）
| 字段 | 类型 | 说明 |
|---|---|---|
| `type` | String | `'local'`（本地 PHAsset/MediaStore）或 `'network'` |
| `assetId` | String? | 本地资源 id |
| `url` | String? | 网络资源封面/图片 URL |
| `mediaType` | String? | `'image'` / `'video'` / `'livePhoto'` |
| `videoUrl` | String? | 网络视频播放 URL（视频/网络实况用） |
| `duration` | double? | 视频时长（秒），仅元数据 |

- 网络图片：`AssetInput(type:'network', url: 图片URL, mediaType:'image')`
- 网络视频：`AssetInput(type:'network', url: 封面URL, mediaType:'video', videoUrl: 播放URL, duration: 秒)`
- 本地资源：`AssetInput(type:'local', assetId: item.assetId)`

### MediaItem（pickAssets/previewAssets 返回的每一项）
| 字段 | 类型 | 说明 |
|---|---|---|
| `assetId` | String | 资源 id（iOS: PHAsset localIdentifier；Android: MediaStore URI） |
| `mediaType` | String | `'image'` / `'video'` / `'livePhoto'` |
| `thumbnailPath` | String | **本地缩略图文件路径（200×200）**，列表直接用 |
| `duration` | double? | 视频时长（秒），图片为 null |
| `width` / `height` | int | 原始像素尺寸 |

### PickResult
```dart
class PickResult { final List<MediaItem> items; final bool isOriginalPhoto; }
```

### DownloadResult（onDownloadResult）
`sealed class`，子类 `DownloadSuccess(url, assetId?)` / `DownloadFailure(url, errorCode, errorMessage)`；
`errorCode ∈ { permissionDenied, networkError, saveFailed, unknown }`。

---

## 6. 常见配方

### 配方 A —— 选图，拿缩略图列表 + 上传原图到后端
```dart
final result = await LivePhotoGallery.pickAssets(
  config: const PickerConfig(maxCount: 9),
);
if (result == null) return; // 用户取消

for (final item in result.items) {
  // 列表展示直接用本地缩略图（无需额外导出）
  final thumbFile = File(item.thumbnailPath);

  // 上传后端：要原画质就 original: true（iOS 才有区别，见注意事项）
  final path = await LivePhotoGallery.exportAsset(
    assetId: item.assetId,
    format: item.mediaType == 'video' ? 'video' : 'image',
    original: true,
  );
  if (path != null) {
    await myUploader.upload(File(path)); // 你的上传逻辑
  }
}
// 上传完成后清理临时文件
await LivePhotoGallery.cleanupTempFiles();
```

### 配方 B —— 帖子详情：点缩略图开全屏预览（网络混排 + 视频自动播）
```dart
final assets = post.media.map((m) => m.isVideo
    ? AssetInput(type: 'network', url: m.coverUrl, mediaType: 'video',
                 videoUrl: m.videoUrl, duration: m.duration)
    : AssetInput(type: 'network', url: m.imageUrl, mediaType: 'image')
).toList();

// 用被点格子的 RenderBox 算 sourceFrame（飞入/飞回起点）
final box = cellContext.findRenderObject() as RenderBox?;
final frame = (box != null && box.hasSize)
    ? box.localToGlobal(Offset.zero) & box.size
    : Rect.zero;

await LivePhotoGallery.previewAssets(
  assets: assets,
  initialIndex: tappedIndex,
  sourceFrame: frame,
  config: const PickerConfig(showRadio: false, autoPlayVideo: true),
);
```

### 配方 C —— 预览网络图片并允许保存到相册
```dart
final sub = LivePhotoGallery.onDownloadResult.listen((r) {
  switch (r) {
    case DownloadSuccess():   showToast('已保存');
    case DownloadFailure(:final errorMessage): showToast('保存失败：$errorMessage');
  }
});
await LivePhotoGallery.previewAssets(
  assets: [AssetInput(type: 'network', url: imageUrl, mediaType: 'image')],
  config: const PickerConfig(showRadio: false),
  showDownloadButton: true,
  saveAlbumName: 'MyApp',
);
// 用完记得 sub.cancel();
```

---

## 7. 错误处理

```dart
try {
  final r = await LivePhotoGallery.pickAssets();
} on LivePhotoException catch (e) {
  // e.code / e.message
}
```
常见 `code`：`PERMISSION_DENIED`、`ASSET_NOT_FOUND`、`ASSET_LOAD_FAILED`、`EXPORT_FAILED`、`SAVE_FAILED`、`LIVE_PHOTO_ERROR`、`INVALID_ARGS`、`NO_VIEW_CONTROLLER`、`UNKNOWN_ERROR`。

---

## 8. 注意事项 / 坑（重要）

- **`exportAsset` 的 `original`**：
  - `false`（默认）：iOS 返回 **再编码**版本（静态图 ≤1600×1600 / JPEG 85%，视频转码 ≤1080p mp4）；Android 返回原始字节。适合上传前要压缩或直接展示。
  - `true`：**两端都返回真原图/原视频**。要做后端归档/校验、保原画质，就传 `true`。
- **`原图` 开关（`PickResult.isOriginalPhoto`）只是回传给你的**建议标志**，不改变 `exportAsset` 的行为。是否传 `original: true` 由你按它决定。
- **缩略图白拿**：`MediaItem.thumbnailPath` 就是 200×200 本地缩略图，列表/预览直接用，别再为了缩略图去 `exportAsset`。
- **`sourceFrame`** 用「被点那个格子」自己的 `RenderBox` 计算，不要用整页 context，否则飞入/飞回起点会错。
- **`autoPlayVideo`** 只自动播**当前页**的视频（相邻页/相册 Live Photo 不会），翻走即停；当前默认**带声、播一次、不循环**。
- **纯预览模式（`showRadio: false`，微信式）**：预览页**没有顶栏**（关闭/分享/计数都不显示），**单击图片即关闭**（放大态/视频页除外），状态栏白色，底部圆点常驻。选择模式（`showRadio: true`，来自 `pickAssets`）仍保留顶栏与选择 UI。
- **保存网络图 = 长按**：传 `showDownloadButton: true` 后，预览里**长按网络静图**弹「保存图片 / 取消」底部弹窗（顶栏已隐藏，长按取代了原来的顶部保存按钮）。结果仍走 `onDownloadResult`，记得监听它给用户反馈。相册 Live Photo 的长按仍是播放。
- **信息流里的时长角标**来自你传的 `AssetInput.duration`（或你后端字段），而放大预览的时长是播放器读真实视频得到的——两者对不上是**数据**对不上，不是插件问题。
- **临时文件**：`exportAsset` / 保存会产生临时文件，适时调 `cleanupTempFiles()`。
- **iOS Info.plist 两个权限键必须加**，否则一调相册就崩。

---

## 9. 快速自测

接好后，跑一遍插件自带 example 对照行为：
```bash
cd example && flutter run   # 首页「帖子查看（信息流）」一站式验证四种媒体组合
```
更细的真机验证清单见仓库 `DEVICE_TEST_CHECKLIST.md`。
