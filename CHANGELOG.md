## Unreleased

迁移到 Pigeon 生成跨端契约。**公开 Dart API（类型与方法签名）完全不变**，
`pickAssets` / `previewAssets` / `getThumbnail` / `exportAsset` /
`cleanupTempFiles` / `onDownloadResult` / `onDownloadProgress` /
`onMaxCountReached` 的用法与 1.0.0 一致，调用方无需改动代码。

### 新增

**`exportAsset` 新增 `original` 选项（默认 `false`，向后兼容）**
- `exportAsset(assetId:, format:, original: false)` 默认行为不变：iOS 返回 web 友好的
  再编码版本（静态图下采样 1600×1600 / JPEG 85%，视频转码 ≤1080p mp4），Android 返回原始字节
- 传 `original: true` 时在**两端**都返回未经再编码/转码的**真原图/原视频**：
  iOS 图片走 `requestImageDataAndOrientation` 的原始字节（保留原始 UTI/扩展名），
  视频用 `AVAssetExportPresetPassthrough` 原样拷贝轨道（不支持 passthrough 时回退到 1080p 转码）；
  Android 本就逐字节拷贝 MediaStore 原文件，该标记为 no-op
- 修复：此前 iOS 的 `exportAsset(format: "image")` 会静默下采样并转 JPEG，与 Android 返回原图的
  行为不一致；上传后端做归档/校验的调用方应传 `original: true`
- `format == "livePhotoVideo"` 时 `original` 被忽略（Live Photo 视频提取本身即无损）

**`PickerConfig.autoPlayVideo`（默认 `false`，向后兼容）**
- 传 `true` 时，`previewAssets` 进入视频页会自动播放当前页视频（仅当前页；相邻页/相册 Live Photo 不会自动播）
- 默认 `false`，不传或旧调用行为完全不变

**预览页 UX 增强（微博式图文混排，纯原生，不改契约）**
- 飞入 hero：从被点缩略图放大飞入，与下拉飞回对称；翻页后关闭改为干净淡出（不飞回过期格子）
- 加载淡入：iOS `.opportunistic` / Android 低清缩略 + 交叉淡入，消除「空白闪一下」
- 底部页码圆点（2–8 张，随页高亮；>8 张与视频页隐藏），双端一致
- 手势：iOS 双击放大到点击点；Android 下滑 fling 关闭、缩放橡皮筋回弹、平移惯性
- Android 修复：初始页即视频时也能自动播放；翻走上一个视频立即暂停

### 变更

**跨端契约改由 Pigeon 生成**
- 新增 `pigeons/messages.dart` 作为 Dart / Kotlin / Swift 三端的单一真源，
  生成 `lib/src/messages.g.dart`、`android/.../Messages.g.kt`、`ios/Classes/Messages.g.swift`
- 原先手工对齐的 MethodChannel 方法名、arg key、字符串枚举全部由生成代码收口；
  此前「三端任意一处笔误 → 静默退化」的一整类问题变成编译期错误
- 生成类型统一 `Pg` 前缀，仅在门面层边界互转，不外泄到公开 API
- 退役 MethodChannel 通道名 `com.newtrip.yingYbirds/live_photo`

**SDK 下限抬高（不兼容变更）**
- `environment.sdk` 由 `>=3.0.0` 抬到 `>=3.4.0`，`flutter` 由 `>=3.3.0` 抬到 `>=3.22.0`
- 原因：dev_dependencies 引入的 `pigeon ^22.7.0` 要求 Dart `^3.4.0`。
  继续声明 3.0.0 的话，任何在下限环境执行 `flutter pub get` 的人都会直接遇到版本求解失败
- 低于该下限的工程需先升级 Flutter 再接入本插件

**越界入参的归一化行为（仅对不符合文档约定的输入可观察）**

以下三处是本次迁移刻意统一的行为。传入符合文档约定的参数时行为与 1.0.0 完全一致，
只有传入契约外的值时才会看到差异：

- `AssetInput.type`：除 `"network"` 外的任意值（含拼写错误、空串）一律按 `"local"` 处理。
  此前 iOS 侧会静默丢弃这类条目，导致预览列表条目数与传入数量不一致
- `AssetInput.mediaType`：不在 `{image, video, livePhoto}` 内的值一律归一为 `"image"`
  （原 iOS `PluginBridge.parseMediaType` 的 default 分支行为，现三端统一）
- Android 返回结果中缺失的 `mediaType`：现在为 `"image"`，此前为空串 `""`

**修复：`exportAsset` 恢复非法 `format` 的报错契约**
- `format` 不在 `{image, video, livePhotoVideo}` 内时，抛出
  `LivePhotoException(code: 'INVALID_ARGS', message: '不支持的媒体类型')`，且不再发起 native 调用
- 迁移中途这里曾把任意非法值归一为 `image`，导致拼错 format 会静默导出静态图；
  现恢复 1.0.0 中 iOS 侧 `PhotoLibraryError.invalidMediaType` 的原有行为

### 测试

- 新增 `test/pigeon_boundary_test.dart`：在真实 pigeon channel 上挂 mock native，
  逐值钉死门面 ↔ 生成类型的手写转换器（`MediaFilter` / `PickerConfig` / `AssetInput` /
  `MediaItem` / `DownloadErrorCode` / `exportAsset` 的 format）
- 新增 `android/src/test/.../PigeonBoundaryTest.kt`：逐值钉死 Kotlin 侧
  `.wire` 映射、`pgMediaTypeOf` / `pgDownloadErrorCodeOf` 的兜底、
  以及 `PgPickerConfig.toPickerConfig()` 的字段还原与归一化
- `test/contract_test.dart` 的定位收窄为「公开门面形状」——迁移后其覆盖的
  `toMap` / `fromMap` 已不再跨越 channel，wire 契约看上面两个新文件

## 1.0.0

首个正式版本，iOS & Android 双平台完整支持。

### 新增功能

**双平台支持**
- Android 原生实现（API 21+），使用 MediaStore API，性能媲美系统相册
- Android Motion Photo（动态照片）选择、预览与导出

**核心 API**
- `requestPermission()` — 请求相册访问权限，iOS 支持 Limited 模式，Android 适配 API 33 分级权限
- `pickAssets()` — 原生宫格选择器，多选图片 / 视频 / Live Photo / Motion Photo
- `previewAssets()` — 全屏预览，支持本地资源与网络资源混合，关闭时飞回缩略图动画
- `getThumbnail()` — 按需生成指定尺寸缩略图，确定性缓存
- `exportAsset()` — 将本地资源导出为实体文件（image / video / livePhotoVideo）
- `cleanupTempFiles()` — 清理插件产生的所有临时文件

**预览页下载功能**
- `previewAssets()` 新增 `showDownloadButton` 参数，网络图片预览时右上角显示保存按钮
- 保存完成后 native 主动回调 Flutter（双向 MethodChannel），无需 Flutter Widget 在前台
- `LivePhotoGallery.onDownloadResult` — `broadcast` Stream，监听保存成功 / 失败事件
- `DownloadResult` sealed class（Dart 3+），子类 `DownloadSuccess` / `DownloadFailure`
- `DownloadErrorCode` 枚举：`permissionDenied` / `networkError` / `saveFailed` / `unknown`
- iOS：使用 `PHPhotoLibrary.performChanges` 保存，图片与视频分别调用对应 API
- Android：API 29+ 使用 `IS_PENDING` 原子写模式，API < 29 兼容 `insertImage`

**选择器**
- 支持暗色/亮色主题（`isDarkMode`）
- 支持最大选择数限制（`maxCount`）
- 支持纯预览模式（`showRadio: false`，隐藏选择 UI）
- 选中防闪烁：Payload 精准刷新，仅更新选中覆盖层，不重载图片

**错误处理**
- 结构化错误码：`PERMISSION_DENIED` / `ASSET_NOT_FOUND` / `ASSET_LOAD_FAILED` / `EXPORT_FAILED` / `SAVE_FAILED` / `LIVE_PHOTO_ERROR` / `INVALID_ARGS` / `NO_VIEW_CONTROLLER` / `UNKNOWN_ERROR`
- Flutter 侧统一 `LivePhotoException(code, message)` 类型，可精确捕获
