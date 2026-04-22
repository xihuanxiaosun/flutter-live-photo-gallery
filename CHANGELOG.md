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
