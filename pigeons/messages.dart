// ─────────────────────────────────────────────────────────────────────────────
// live_photo_gallery 跨端契约（单一真源）
//
// 这里是 Dart / Kotlin / Swift 三端唯一的接口定义。修改本文件后必须重新生成：
//
//     dart run pigeon --input pigeons/messages.dart
//
// 生成产物（**请勿手工编辑**）：
//   - lib/src/messages.g.dart
//   - android/src/main/kotlin/com/newtrip/live_photo_gallery/Messages.g.kt
//   - ios/Classes/Messages.g.swift
//
// 约定：所有生成类型均以 `Pg` 前缀命名，属于「内部传输类型」。
// 插件的公开 Dart API（LivePhotoGallery / PickerConfig / MediaItem / ...）
// 是手写的门面，位于 lib/live_photo_gallery.dart，在边界处与这些类型互转。
// 公开 API 的形状由 test/contract_test.dart 钉死，不随本文件变化。
// ─────────────────────────────────────────────────────────────────────────────

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/src/main/kotlin/com/newtrip/live_photo_gallery/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.newtrip.live_photo_gallery'),
    swiftOut: 'ios/Classes/Messages.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'live_photo_gallery',
  ),
)

// ─────────────────────────────────────────────────────────────────────────────
// 枚举（此前是两端手工对齐的字符串字面量，最容易漂移的部分）
// ─────────────────────────────────────────────────────────────────────────────

/// 相册权限状态。门面层映射为公开的
/// `"authorized" | "limited" | "denied" | "notDetermined"` 字符串。
enum PgPermissionStatus { authorized, limited, denied, notDetermined }

/// 媒体类型过滤（对应公开的 [MediaFilter]）
enum PgMediaFilter { all, imageOnly, videoOnly, livePhotoOnly }

/// 单个媒体条目的类型（对应公开 API 的 `"image" | "video" | "livePhoto"`）
enum PgMediaType { image, video, livePhoto }

/// 预览资源来源（对应公开 API 的 `"local" | "network"`）
enum PgAssetSource { local, network }

/// 导出格式（对应公开 API 的 `"image" | "video" | "livePhotoVideo"`）
enum PgExportFormat { image, video, livePhotoVideo }

/// 保存网络图片失败的原因（对应公开的 [DownloadErrorCode]）。
/// 此前 Android 发 `"NETWORK_ERROR"` 字符串、iOS 发另一套、Dart 侧再 fromString，
/// 三处任意一处笔误都会静默退化成 `unknown`——改为枚举后是编译期错误。
enum PgDownloadErrorCode { permissionDenied, networkError, saveFailed, unknown }

// ─────────────────────────────────────────────────────────────────────────────
// 数据类
// ─────────────────────────────────────────────────────────────────────────────

/// 裁剪配置（对应公开的 [CropConfig]）
class PgCropConfig {
  PgCropConfig({required this.aspectRatioX, required this.aspectRatioY});

  double aspectRatioX;
  double aspectRatioY;
}

/// 选择器配置（对应公开的 [PickerConfig]）
class PgPickerConfig {
  PgPickerConfig({
    required this.isDarkMode,
    required this.maxCount,
    required this.enableVideo,
    required this.enableLivePhoto,
    required this.showRadio,
    required this.autoPlayVideo,
    required this.maxVideoCount,
    required this.videoMaxDuration,
    required this.filterConfig,
    this.cropConfig,
  });

  bool isDarkMode;
  int maxCount;
  bool enableVideo;
  bool enableLivePhoto;
  bool showRadio;

  /// 视频进入预览页时是否自动播放（默认 false）
  bool autoPlayVideo;

  /// -1 = 无限制
  int maxVideoCount;

  /// 秒，0 = 无限制
  double videoMaxDuration;

  PgMediaFilter filterConfig;
  PgCropConfig? cropConfig;
}

/// 缩略图在屏幕中的位置（逻辑像素），用于飞入/飞回转场
class PgRect {
  PgRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  double x;
  double y;
  double width;
  double height;
}

/// 传给 previewAssets 的单个资源（对应公开的 [AssetInput]）
class PgAssetInput {
  PgAssetInput({
    required this.type,
    this.assetId,
    this.url,
    this.mediaType,
    this.videoUrl,
    this.duration,
  });

  PgAssetSource type;
  String? assetId;
  String? url;
  PgMediaType? mediaType;
  String? videoUrl;

  /// 视频时长（秒）
  double? duration;
}

/// previewAssets 的完整入参
class PgPreviewRequest {
  PgPreviewRequest({
    required this.assets,
    required this.initialIndex,
    required this.sourceFrame,
    required this.selectedAssetIds,
    required this.config,
    required this.showDownloadButton,
    required this.saveAlbumName,
  });

  List<PgAssetInput> assets;
  int initialIndex;
  PgRect sourceFrame;
  List<String> selectedAssetIds;
  PgPickerConfig config;
  bool showDownloadButton;

  /// 空串 = 不额外建相册（iOS）/ 用 App 名（Android）
  String saveAlbumName;
}

/// 返回的单个媒体条目（对应公开的 [MediaItem]）
class PgMediaItem {
  PgMediaItem({
    required this.assetId,
    required this.mediaType,
    required this.thumbnailPath,
    this.duration,
    required this.width,
    required this.height,
  });

  String assetId;
  PgMediaType mediaType;
  String thumbnailPath;

  /// 秒，仅 video 有值
  double? duration;
  int width;
  int height;
}

/// pickAssets / previewAssets 的返回（对应公开的 [PickResult]）
class PgPickResult {
  PgPickResult({required this.items, required this.isOriginalPhoto});

  List<PgMediaItem> items;
  bool isOriginalPhoto;
}

/// 保存网络图片的结果事件（对应公开的 [DownloadResult] sealed 家族）
class PgDownloadResultEvent {
  PgDownloadResultEvent({
    required this.url,
    required this.success,
    this.assetId,
    this.errorCode,
    this.errorMessage,
  });

  String url;
  bool success;

  /// 成功时的 assetId（Android: MediaStore URI；iOS: PHAsset localIdentifier）
  String? assetId;

  /// 失败时的错误码
  PgDownloadErrorCode? errorCode;

  /// 失败时的可读描述
  String? errorMessage;
}

// ─────────────────────────────────────────────────────────────────────────────
// Flutter → Native
//
// pickAssets / previewAssets 会拉起原生 UI，用户操作完才回调，故必须 @async。
// 其余方法在两端也都是异步（权限弹框 / IO 线程导出），一并 @async 以保持原有语义。
// ─────────────────────────────────────────────────────────────────────────────

@HostApi()
abstract class LivePhotoGalleryHostApi {
  /// 查询/申请相册权限
  @async
  PgPermissionStatus requestPermission();

  /// 打开相册选择器；返回 null 表示用户取消
  @async
  PgPickResult? pickAssets(PgPickerConfig config);

  /// 预览资源列表（本地 & 网络混合）；返回 null 表示用户取消
  @async
  PgPickResult? previewAssets(PgPreviewRequest request);

  /// 返回本地缩略图路径
  @async
  String? getThumbnail(String assetId, double width, double height);

  /// 导出资源原文件到临时目录，返回本地路径
  @async
  String? exportAsset(String assetId, PgExportFormat format);

  /// 清理插件产生的临时文件
  @async
  void cleanupTempFiles();
}

// ─────────────────────────────────────────────────────────────────────────────
// Native → Flutter（原生主动推送的三个事件）
// ─────────────────────────────────────────────────────────────────────────────

@FlutterApi()
abstract class LivePhotoGalleryFlutterApi {
  /// 预览页保存网络图片完成（成功或失败）
  void onDownloadResult(PgDownloadResultEvent event);

  /// 预览页下载进度（0.0 ~ 1.0）
  void onDownloadProgress(String url, double progress);

  /// 用户尝试超出最大选择数量
  void onMaxCountReached(int maxCount);
}
