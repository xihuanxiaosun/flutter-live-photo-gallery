import 'dart:async';
import 'package:flutter/services.dart';

// ──────────────────────────────────────────────────────────────────────────────
// 异常类型
// ──────────────────────────────────────────────────────────────────────────────

/// 插件统一异常
/// iOS 端会抛出带结构化 [code] 的 FlutterError，Flutter 侧封装为此类型。
///
/// 常见 [code] 值：
///   PERMISSION_DENIED  — 没有相册权限
///   ASSET_NOT_FOUND    — 找不到指定资源
///   EXPORT_FAILED      — 导出/转码失败
///   SAVE_FAILED        — 写文件失败
///   LIVE_PHOTO_ERROR   — Live Photo 相关错误
///   INVALID_ARGS       — 参数无效
///   NO_VIEW_CONTROLLER — 无法获取顶层 ViewController（极少见）
///   UNKNOWN_ERROR      — 未分类错误
class LivePhotoException implements Exception {
  final String code;
  final String message;

  const LivePhotoException({required this.code, required this.message});

  @override
  String toString() => 'LivePhotoException($code): $message';
}

// ──────────────────────────────────────────────────────────────────────────────
// 下载结果回调（预览页保存网络图片时，native 主动推送给 Flutter）
// ──────────────────────────────────────────────────────────────────────────────

/// 媒体类型过滤器（优先于 [PickerConfig.enableVideo] / [PickerConfig.enableLivePhoto]）
enum MediaFilter {
  /// 显示全部（图片 + 视频 + Live Photo）
  all,
  /// 仅图片（不含 Live Photo）
  imageOnly,
  /// 仅视频
  videoOnly,
  /// 仅 Live Photo / Motion Photo
  livePhotoOnly;

  String get _value => switch (this) {
        MediaFilter.all => 'all',
        MediaFilter.imageOnly => 'imageOnly',
        MediaFilter.videoOnly => 'videoOnly',
        MediaFilter.livePhotoOnly => 'livePhotoOnly',
      };
}

/// 裁剪配置（预留字段，当前版本仅传递给 native 侧，实际裁剪 UI 待后续版本实现）
class CropConfig {
  /// 裁剪比例 X（0 = 自由裁剪）
  final double aspectRatioX;

  /// 裁剪比例 Y（0 = 自由裁剪）
  final double aspectRatioY;

  const CropConfig({this.aspectRatioX = 0, this.aspectRatioY = 0});

  Map<String, dynamic> toMap() => {
        'aspectRatioX': aspectRatioX,
        'aspectRatioY': aspectRatioY,
      };
}

/// 下载错误码，对齐 Android / iOS 两端的 errorCode 字符串
enum DownloadErrorCode {
  permissionDenied,
  networkError,
  saveFailed,
  unknown;

  static DownloadErrorCode fromString(String? code) => switch (code) {
        'PERMISSION_DENIED' => DownloadErrorCode.permissionDenied,
        'NETWORK_ERROR' => DownloadErrorCode.networkError,
        'SAVE_FAILED' => DownloadErrorCode.saveFailed,
        _ => DownloadErrorCode.unknown,
      };
}

/// 保存网络图片到系统相册的结果（sealed class，Dart 3+）
sealed class DownloadResult {
  /// 触发下载的图片 URL
  final String url;
  const DownloadResult({required this.url});
}

/// 保存成功
class DownloadSuccess extends DownloadResult {
  /// 写入系统相册后的 assetId（Android: MediaStore URI；iOS: PHAsset localIdentifier）
  final String? assetId;
  const DownloadSuccess({required super.url, this.assetId});
}

/// 保存失败
class DownloadFailure extends DownloadResult {
  final DownloadErrorCode errorCode;

  /// 可读错误描述（中文），可直接展示给用户
  final String errorMessage;
  const DownloadFailure({
    required super.url,
    required this.errorCode,
    required this.errorMessage,
  });
}

// ──────────────────────────────────────────────────────────────────────────────
// 数据模型
// ──────────────────────────────────────────────────────────────────────────────

/// 传给 [LivePhotoGallery.previewAssets] 的单个资源描述
class AssetInput {
  /// `"local"` = 本地 PHAsset；`"network"` = 网络资源
  final String type;
  final String? assetId;
  final String? url;

  /// `"image"` | `"video"` | `"livePhoto"`
  final String? mediaType;

  /// Live Photo 网络视频 URL 或独立视频 URL
  final String? videoUrl;

  /// 视频时长（秒）
  final double? duration;

  const AssetInput({
    required this.type,
    this.assetId,
    this.url,
    this.mediaType,
    this.videoUrl,
    this.duration,
  });

  Map<String, dynamic> toMap() => {
        'type': type,
        if (assetId != null) 'assetId': assetId,
        if (url != null) 'url': url,
        if (mediaType != null) 'mediaType': mediaType,
        if (videoUrl != null) 'videoUrl': videoUrl,
        if (duration != null) 'duration': duration,
      };
}

/// 插件返回的单个媒体条目
class MediaItem {
  final String assetId;

  /// `"image"` | `"video"` | `"livePhoto"`
  final String mediaType;

  /// 本地缩略图文件路径（200×200）
  final String thumbnailPath;

  /// 视频时长（秒）；图片为 null
  final double? duration;
  final int width;
  final int height;

  const MediaItem({
    required this.assetId,
    required this.mediaType,
    required this.thumbnailPath,
    this.duration,
    required this.width,
    required this.height,
  });

  factory MediaItem.fromMap(Map<dynamic, dynamic> map) => MediaItem(
        assetId: map['assetId'] as String? ?? '',
        mediaType: map['mediaType'] as String? ?? 'image',
        thumbnailPath: map['thumbnailPath'] as String? ?? '',
        duration: (map['duration'] as num?)?.toDouble(),
        width: (map['width'] as num?)?.toInt() ?? 0,
        height: (map['height'] as num?)?.toInt() ?? 0,
      );
}

/// [LivePhotoGallery.pickAssets] / [LivePhotoGallery.previewAssets] 的返回结果
class PickResult {
  final List<MediaItem> items;

  /// 用户是否勾选了「原图」
  final bool isOriginalPhoto;

  const PickResult({required this.items, required this.isOriginalPhoto});
}

/// 相册选择器配置
class PickerConfig {
  final bool isDarkMode;
  final int maxCount;
  final bool enableVideo;
  final bool enableLivePhoto;

  /// 是否显示多选圆圈（`false` = 纯预览模式）
  final bool showRadio;

  /// 最多可选视频 / Live Photo 数量（`-1` = 无限制）。
  /// 超出时 native 侧会触发 [LivePhotoGallery.onMaxCountReached] 并提示用户。
  final int maxVideoCount;

  /// 视频最长时长限制（秒，`0` = 无限制）。
  /// 超出时长的视频不会出现在宫格中。
  final double videoMaxDuration;

  /// 媒体类型过滤（优先级高于 [enableVideo] / [enableLivePhoto]）。
  /// - [MediaFilter.all]：显示全部
  /// - [MediaFilter.imageOnly]：仅图片
  /// - [MediaFilter.videoOnly]：仅视频
  /// - [MediaFilter.livePhotoOnly]：仅 Live Photo / Motion Photo
  final MediaFilter filterConfig;

  /// 裁剪配置（预留字段，当前版本实际裁剪 UI 未实现）。
  final CropConfig? cropConfig;

  const PickerConfig({
    this.isDarkMode = false,
    this.maxCount = 9,
    this.enableVideo = true,
    this.enableLivePhoto = true,
    this.showRadio = true,
    this.maxVideoCount = -1,
    this.videoMaxDuration = 0,
    this.filterConfig = MediaFilter.all,
    this.cropConfig,
  })  : assert(maxCount > 0, 'maxCount must be > 0'),
        assert(
          maxVideoCount == -1 || maxVideoCount > 0,
          'maxVideoCount must be -1 or > 0',
        ),
        assert(videoMaxDuration >= 0, 'videoMaxDuration must be >= 0');

  Map<String, dynamic> toMap() => {
        'isDarkMode': isDarkMode,
        'maxCount': maxCount,
        'enableVideo': enableVideo,
        'enableLivePhoto': enableLivePhoto,
        'showRadio': showRadio,
        'maxVideoCount': maxVideoCount,
        'videoMaxDuration': videoMaxDuration,
        'filterConfig': filterConfig._value,
        if (cropConfig != null) 'cropConfig': cropConfig!.toMap(),
      };
}

// ──────────────────────────────────────────────────────────────────────────────
// 插件主类
// ──────────────────────────────────────────────────────────────────────────────

/// Live Photo 相册选择 & 预览插件（iOS & Android）
///
/// 所有方法均可能抛出 [LivePhotoException]，建议调用方用 try/catch 包裹：
/// ```dart
/// try {
///   final result = await LivePhotoGallery.pickAssets();
/// } on LivePhotoException catch (e) {
///   // e.code / e.message
/// }
/// ```
class LivePhotoGallery {
  static const _channel = MethodChannel('com.newtrip.yingYbirds/live_photo');

  // ────────────────────────────────────────────────
  // 下载结果事件流（native → Flutter 主动推送）
  //
  // 用法：
  //   final sub = LivePhotoGallery.onDownloadResult.listen((result) {
  //     switch (result) {
  //       case DownloadSuccess(:final url, :final assetId):
  //         ScaffoldMessenger.of(context).showSnackBar(...);
  //       case DownloadFailure(:final errorCode, :final errorMessage):
  //         // 处理失败
  //     }
  //   });
  //   // 页面销毁时 sub.cancel()
  // ────────────────────────────────────────────────
  static final StreamController<DownloadResult> _downloadCtrl =
      StreamController<DownloadResult>.broadcast();

  /// 监听预览页保存图片的结果事件（成功或失败）
  static Stream<DownloadResult> get onDownloadResult => _downloadCtrl.stream;

  // ────────────────────────────────────────────────
  // 下载进度事件流（native → Flutter 实时推送）
  //
  // 用法：
  //   final sub = LivePhotoGallery.onDownloadProgress.listen((e) {
  //     print('${e.url} => ${(e.progress * 100).toStringAsFixed(0)}%');
  //   });
  // ────────────────────────────────────────────────

  static final StreamController<({String url, double progress})>
      _downloadProgressCtrl = StreamController<({String url, double progress})>.broadcast();

  /// 监听预览页下载图片的进度（0.0 ~ 1.0）
  static Stream<({String url, double progress})> get onDownloadProgress =>
      _downloadProgressCtrl.stream;

  // ────────────────────────────────────────────────
  // 超出最大选择数量事件流
  //
  // 用法：
  //   final sub = LivePhotoGallery.onMaxCountReached.listen((maxCount) {
  //     ScaffoldMessenger.of(context).showSnackBar(
  //       SnackBar(content: Text('最多只能选择 $maxCount 张')),
  //     );
  //   });
  // ────────────────────────────────────────────────

  static final StreamController<int> _maxCountCtrl =
      StreamController<int>.broadcast();

  /// 监听用户尝试超出最大选择数量时的事件（参数为 maxCount）
  static Stream<int> get onMaxCountReached => _maxCountCtrl.stream;

  /// 注册 native → Dart 的方法调用处理器（幂等，只注册一次）
  static bool _handlerRegistered = false;
  static void _ensureHandlerRegistered() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onDownloadResult':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final status = args['status'] as String?;
        final url    = args['url']    as String? ?? '';
        if (status == 'success') {
          _downloadCtrl.add(DownloadSuccess(
            url:     url,
            assetId: args['assetId'] as String?,
          ));
        } else {
          _downloadCtrl.add(DownloadFailure(
            url:          url,
            errorCode:    DownloadErrorCode.fromString(args['errorCode'] as String?),
            errorMessage: args['errorMessage'] as String? ?? '保存失败',
          ));
        }
        return null;
      case 'onDownloadProgress':
        final args     = Map<String, dynamic>.from(call.arguments as Map);
        final url      = args['url']      as String? ?? '';
        final progress = (args['progress'] as num?)?.toDouble() ?? 0.0;
        _downloadProgressCtrl.add((url: url, progress: progress));
        return null;
      case 'onMaxCountReached':
        final args     = Map<String, dynamic>.from(call.arguments as Map);
        final maxCount = args['maxCount'] as int? ?? 0;
        _maxCountCtrl.add(maxCount);
        return null;
      default:
        return null;
    }
  }

  // ────────────────────────────────────────────────
  // 请求相册权限
  // 返回: "authorized" | "limited" | "denied" | "notDetermined"
  // ────────────────────────────────────────────────
  static Future<String> requestPermission() async {
    try {
      return await _channel.invokeMethod<String>('requestPermission') ??
          'denied';
    } on PlatformException catch (e) {
      throw LivePhotoException(code: e.code, message: e.message ?? '');
    }
  }

  // ────────────────────────────────────────────────
  // 打开相册选择器
  // 返回 null 表示用户取消
  // ────────────────────────────────────────────────
  static Future<PickResult?> pickAssets({
    PickerConfig config = const PickerConfig(),
  }) async {
    // 注册 handler 以接收 onMaxCountReached 回调
    _ensureHandlerRegistered();
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'pickAssets',
        config.toMap(),
      );
      return _parsePickResult(raw);
    } on PlatformException catch (e) {
      throw LivePhotoException(code: e.code, message: e.message ?? '');
    }
  }

  // ────────────────────────────────────────────────
  // 预览资源列表（支持本地 & 网络混合）
  // [sourceFrame] 为缩略图在屏幕中的位置，用于飞入/飞回转场动画
  // 关闭或完成都会返回当前选择结果；若未选择则 `items` 为空
  // ────────────────────────────────────────────────
  static Future<PickResult?> previewAssets({
    required List<AssetInput> assets,
    int initialIndex = 0,
    Rect sourceFrame = Rect.zero,
    List<String> selectedAssetIds = const [],
    PickerConfig config = const PickerConfig(),

    /// 是否在预览页显示"保存到相册"按钮（仅对网络图片生效）。
    /// 开启后请监听 [onDownloadResult] 获取保存结果，在 Flutter 侧展示成功/失败 UI。
    bool showDownloadButton = false,

    /// 保存图片时写入的相册/目录名称。
    ///
    /// - Android：图片保存到 `Pictures/<saveAlbumName>/`，空串则使用 App 名称。
    /// - iOS：图片同时加入名为 [saveAlbumName] 的自定义相册；
    ///   空串则仅保存到「最近项目」，不额外创建相册。
    String saveAlbumName = '',
  }) async {
    if (showDownloadButton) _ensureHandlerRegistered();
    try {
      final args = <String, dynamic>{
        'assets': assets.map((a) => a.toMap()).toList(),
        'initialIndex': initialIndex,
        'sourceFrame': {
          'x': sourceFrame.left,
          'y': sourceFrame.top,
          'width': sourceFrame.width,
          'height': sourceFrame.height,
        },
        'selectedAssetIds':    selectedAssetIds,
        'showDownloadButton':  showDownloadButton,
        if (saveAlbumName.isNotEmpty) 'saveAlbumName': saveAlbumName,
        ...config.toMap(),
      };
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'previewAssets',
        args,
      );
      return _parsePickResult(raw);
    } on PlatformException catch (e) {
      throw LivePhotoException(code: e.code, message: e.message ?? '');
    }
  }

  // ────────────────────────────────────────────────
  // 获取缩略图本地路径
  // ────────────────────────────────────────────────
  static Future<String?> getThumbnail({
    required String assetId,
    double width = 200,
    double height = 200,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getThumbnail',
        {'assetId': assetId, 'width': width, 'height': height},
      );
      return raw?['thumbnailPath'] as String?;
    } on PlatformException catch (e) {
      throw LivePhotoException(code: e.code, message: e.message ?? '');
    }
  }

  // ────────────────────────────────────────────────
  // 导出资源原文件到本地临时目录
  // [format]: "image" | "video" | "livePhotoVideo"
  // 返回本地文件路径
  // ────────────────────────────────────────────────
  static Future<String?> exportAsset({
    required String assetId,
    required String format,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'exportAsset',
        {'assetId': assetId, 'format': format},
      );
      return raw?['filePath'] as String?;
    } on PlatformException catch (e) {
      throw LivePhotoException(code: e.code, message: e.message ?? '');
    }
  }

  // ────────────────────────────────────────────────
  // 清理插件产生的临时文件
  // 建议在应用启动或上传完成后调用
  // ────────────────────────────────────────────────
  static Future<void> cleanupTempFiles() async {
    try {
      await _channel.invokeMethod<void>('cleanupTempFiles');
    } on PlatformException catch (e) {
      throw LivePhotoException(code: e.code, message: e.message ?? '');
    }
  }

  // ────────────────────────────────────────────────
  // 私有解析
  // ────────────────────────────────────────────────
  static PickResult? _parsePickResult(Map<dynamic, dynamic>? raw) {
    if (raw == null) return null;
    final rawItems = raw['items'] as List<dynamic>? ?? [];
    return PickResult(
      items: rawItems
          .whereType<Map<dynamic, dynamic>>()
          .map(MediaItem.fromMap)
          .toList(),
      isOriginalPhoto: raw['isOriginalPhoto'] as bool? ?? false,
    );
  }
}
