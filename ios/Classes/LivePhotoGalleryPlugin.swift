import Flutter
import UIKit
import Photos

/// Flutter 插件入口 — Pigeon 桥接
///
/// 跨端契约由 pigeons/messages.dart 生成（Messages.g.swift）：本类实现生成的
/// `LivePhotoGalleryHostApi` 协议，native → Flutter 的三个事件走生成的
/// `LivePhotoGalleryFlutterApi`。
///
/// 生成类型（`Pg*`）只出现在本文件的边界处：`LivePhotoGalleryCore` 及其下游
/// 仍然消费原有的 `[String: Any]` 形状，业务代码不受契约迁移影响。
public class LivePhotoGalleryPlugin: NSObject, FlutterPlugin, LivePhotoGalleryHostApi {

    // MARK: - Registration

    /// Native → Flutter 事件通道，供 previewAssets 的 download / maxCount 回调闭包捕获
    private var flutterApi: LivePhotoGalleryFlutterApi?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = LivePhotoGalleryPlugin()
        instance.flutterApi = LivePhotoGalleryFlutterApi(binaryMessenger: registrar.messenger())
        LivePhotoGalleryHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
        // setUp 的 handler 闭包已强引用 instance；publish 让 registrar 也持有一份，
        // 与迁移前 addMethodCallDelegate 的生命周期语义保持一致。
        registrar.publish(instance)
    }

    // MARK: - LivePhotoGalleryHostApi

    /// returns: authorized | limited | denied | notDetermined
    func requestPermission(completion: @escaping (Result<PgPermissionStatus, Error>) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized:
            completion(.success(.authorized))
        case .limited:
            completion(.success(.limited))
        case .denied, .restricted:
            completion(.success(.denied))
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    switch newStatus {
                    case .authorized: completion(.success(.authorized))
                    case .limited:    completion(.success(.limited))
                    default:          completion(.success(.denied))
                    }
                }
            }
        @unknown default:
            completion(.success(.denied))
        }
    }

    func pickAssets(
        config: PgPickerConfig,
        completion: @escaping (Result<PgPickResult?, Error>) -> Void
    ) {
        guard let rootVC = topViewController() else {
            completion(.failure(PigeonError(code: "NO_VIEW_CONTROLLER",
                                            message: "无法获取顶层 ViewController",
                                            details: nil)))
            return
        }
        let api = flutterApi
        LivePhotoGalleryCore.shared.pickAssets(
            args: Self.args(from: config),
            from: rootVC,
            maxCountReachedCallback: { maxCount in
                DispatchQueue.main.async {
                    api?.onMaxCountReached(maxCount: Int64(maxCount)) { _ in }
                }
            }
        ) { outcome in
            Self.finishPickResult(outcome, completion: completion)
        }
    }

    func previewAssets(
        request: PgPreviewRequest,
        completion: @escaping (Result<PgPickResult?, Error>) -> Void
    ) {
        guard let rootVC = topViewController() else {
            completion(.failure(PigeonError(code: "NO_VIEW_CONTROLLER",
                                            message: "无法获取顶层 ViewController",
                                            details: nil)))
            return
        }
        let showDownload = request.showDownloadButton
        let api = flutterApi
        // 预览页仍以 [String: Any] 形式回传下载事件（保持 UI 层不变），在此翻译成契约类型
        let downloadCallback: (([String: Any]) -> Void)? = showDownload ? { payload in
            let event = Self.downloadEvent(from: payload)
            DispatchQueue.main.async {
                api?.onDownloadResult(event: event) { _ in }
            }
        } : nil
        let downloadProgressCallback: (([String: Any]) -> Void)? = showDownload ? { payload in
            let url = payload["url"] as? String ?? ""
            let progress = payload["progress"] as? Double ?? 0
            DispatchQueue.main.async {
                api?.onDownloadProgress(url: url, progress: progress) { _ in }
            }
        } : nil
        LivePhotoGalleryCore.shared.previewAssets(
            args: Self.args(from: request),
            from: rootVC,
            downloadCallback: downloadCallback,
            downloadProgressCallback: downloadProgressCallback,
            maxCountReachedCallback: { maxCount in
                DispatchQueue.main.async {
                    api?.onMaxCountReached(maxCount: Int64(maxCount)) { _ in }
                }
            }
        ) { outcome in
            Self.finishPickResult(outcome, completion: completion)
        }
    }

    func getThumbnail(
        assetId: String,
        width: Double,
        height: Double,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        LivePhotoGalleryCore.shared.getThumbnail(
            args: ["assetId": assetId, "width": width, "height": height]
        ) { outcome in
            Self.finishPath(outcome, key: "thumbnailPath", completion: completion)
        }
    }

    func exportAsset(
        assetId: String,
        format: PgExportFormat,
        original: Bool,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        LivePhotoGalleryCore.shared.exportAsset(
            args: ["assetId": assetId, "format": format.wire, "original": original]
        ) { outcome in
            Self.finishPath(outcome, key: "filePath", completion: completion)
        }
    }

    func cleanupTempFiles(completion: @escaping (Result<Void, Error>) -> Void) {
        ExportManager.shared.cleanupTempFiles()
        DispatchQueue.main.async { completion(.success(())) }
    }

    // MARK: - Private: Result Bridge

    /// `Result<Any?, Error>`（业务层形状）→ Pigeon 的 `PgPickResult?`
    /// 所有回调统一切回主线程，与迁移前 flutterResult 的行为一致。
    private static func finishPickResult(
        _ outcome: Result<Any?, Error>,
        completion: @escaping (Result<PgPickResult?, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            switch outcome {
            case .success(let value):
                completion(.success(pickResult(from: value)))
            case .failure(let error):
                completion(.failure(pigeonError(from: error)))
            }
        }
    }

    /// `Result<Any?, Error>` → 单个路径字符串（getThumbnail / exportAsset）
    private static func finishPath(
        _ outcome: Result<Any?, Error>,
        key: String,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            switch outcome {
            case .success(let value):
                completion(.success((value as? [String: Any])?[key] as? String))
            case .failure(let error):
                completion(.failure(pigeonError(from: error)))
            }
        }
    }

    private static func pickResult(from value: Any?) -> PgPickResult? {
        guard let dict = value as? [String: Any] else { return nil }
        let rawItems = dict["items"] as? [[String: Any]] ?? []
        let items: [PgMediaItem] = rawItems.map { item in
            PgMediaItem(
                assetId: item["assetId"] as? String ?? "",
                mediaType: mediaType(from: item["mediaType"] as? String),
                thumbnailPath: item["thumbnailPath"] as? String ?? "",
                duration: item["duration"] as? Double,
                width: Int64(item["width"] as? Int ?? 0),
                height: Int64(item["height"] as? Int ?? 0)
            )
        }
        return PgPickResult(items: items, isOriginalPhoto: dict["isOriginalPhoto"] as? Bool ?? false)
    }

    /// 预览页的下载事件字典 → 契约类型
    private static func downloadEvent(from payload: [String: Any]) -> PgDownloadResultEvent {
        let url = payload["url"] as? String ?? ""
        if (payload["status"] as? String) == "success" {
            return PgDownloadResultEvent(url: url, success: true,
                                         assetId: payload["assetId"] as? String)
        }
        return PgDownloadResultEvent(
            url: url,
            success: false,
            errorCode: downloadErrorCode(from: payload["errorCode"] as? String),
            errorMessage: payload["errorMessage"] as? String
        )
    }

    /// Swift 错误 → 结构化 PigeonError（code 与迁移前的 FlutterError code 逐字一致）
    private static func pigeonError(from error: Error) -> PigeonError {
        let (code, message) = flutterErrorInfo(from: error)
        return PigeonError(code: code, message: message, details: nil)
    }

    /// 将 Swift 错误映射为结构化的 (code, message)
    private static func flutterErrorInfo(from error: Error) -> (String, String) {
        if let e = error as? PhotoLibraryError {
            switch e {
            case .permissionDenied:           return ("PERMISSION_DENIED",   e.localizedDescription)
            case .assetNotFound:              return ("ASSET_NOT_FOUND",     e.localizedDescription)
            case .exportFailed:               return ("EXPORT_FAILED",       e.localizedDescription)
            case .saveFailed:                 return ("SAVE_FAILED",         e.localizedDescription)
            case .invalidMediaType:           return ("INVALID_ARGS",        e.localizedDescription)
            case .albumNotFound:              return ("ALBUM_NOT_FOUND",     e.localizedDescription)
            case .assetLoadFailed:            return ("ASSET_LOAD_FAILED",   e.localizedDescription)
            }
        }
        if let e = error as? LivePhotoError {
            return ("LIVE_PHOTO_ERROR", e.localizedDescription)
        }
        return ("UNKNOWN_ERROR", error.localizedDescription)
    }

    // MARK: - Private: 契约类型 → 业务层 args

    private static func args(from config: PgPickerConfig) -> [String: Any] {
        var dict: [String: Any] = [
            "isDarkMode":       config.isDarkMode,
            "maxCount":         Int(config.maxCount),
            "enableVideo":      config.enableVideo,
            "enableLivePhoto":  config.enableLivePhoto,
            "showRadio":        config.showRadio,
            "autoPlayVideo":    config.autoPlayVideo,
            "maxVideoCount":    Int(config.maxVideoCount),
            "videoMaxDuration": config.videoMaxDuration,
            "filterConfig":     config.filterConfig.wire,
        ]
        if let crop = config.cropConfig {
            dict["cropConfig"] = [
                "aspectRatioX": crop.aspectRatioX,
                "aspectRatioY": crop.aspectRatioY,
            ]
        }
        return dict
    }

    private static func args(from request: PgPreviewRequest) -> [String: Any] {
        var dict = args(from: request.config)
        dict["assets"] = request.assets.map { asset -> [String: Any] in
            var a: [String: Any] = ["type": asset.type.wire]
            if let assetId  = asset.assetId  { a["assetId"]  = assetId }
            if let url      = asset.url      { a["url"]      = url }
            if let type     = asset.mediaType { a["mediaType"] = type.wire }
            if let videoUrl = asset.videoUrl { a["videoUrl"] = videoUrl }
            if let duration = asset.duration { a["duration"] = duration }
            return a
        }
        dict["initialIndex"] = Int(request.initialIndex)
        dict["sourceFrame"] = [
            "x":      request.sourceFrame.x,
            "y":      request.sourceFrame.y,
            "width":  request.sourceFrame.width,
            "height": request.sourceFrame.height,
        ]
        dict["selectedAssetIds"]   = request.selectedAssetIds
        dict["showDownloadButton"] = request.showDownloadButton
        dict["saveAlbumName"]      = request.saveAlbumName
        return dict
    }

    private static func mediaType(from raw: String?) -> PgMediaType {
        switch raw {
        case "video":     return .video
        case "livePhoto": return .livePhoto
        default:          return .image
        }
    }

    private static func downloadErrorCode(from raw: String?) -> PgDownloadErrorCode {
        switch raw {
        case "PERMISSION_DENIED": return .permissionDenied
        case "NETWORK_ERROR":     return .networkError
        case "SAVE_FAILED":       return .saveFailed
        default:                  return .unknown
        }
    }

    // MARK: - Private: ViewController Helpers

    /// 获取当前最顶层的 ViewController（支持 Nav / Tab / Modal 嵌套）
    private func topViewController() -> UIViewController? {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
            let window = scene.windows.first(where: { $0.isKeyWindow })
        else { return nil }
        return topVC(from: window.rootViewController)
    }

    private func topVC(from vc: UIViewController?) -> UIViewController? {
        if let nav = vc as? UINavigationController { return topVC(from: nav.visibleViewController) }
        if let tab = vc as? UITabBarController    { return topVC(from: tab.selectedViewController) }
        if let presented = vc?.presentedViewController { return topVC(from: presented) }
        return vc
    }
}

// MARK: - 契约枚举 → 既有业务层消费的字符串

extension PgMediaFilter {
    var wire: String {
        switch self {
        case .all:           return "all"
        case .imageOnly:     return "imageOnly"
        case .videoOnly:     return "videoOnly"
        case .livePhotoOnly: return "livePhotoOnly"
        }
    }
}

extension PgMediaType {
    var wire: String {
        switch self {
        case .image:     return "image"
        case .video:     return "video"
        case .livePhoto: return "livePhoto"
        }
    }
}

extension PgAssetSource {
    var wire: String {
        switch self {
        case .local:   return "local"
        case .network: return "network"
        }
    }
}

extension PgExportFormat {
    var wire: String {
        switch self {
        case .image:          return "image"
        case .video:          return "video"
        case .livePhotoVideo: return "livePhotoVideo"
        }
    }
}
