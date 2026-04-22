import Flutter
import UIKit
import Photos

/// Flutter 插件入口 — MethodChannel 桥接
/// Channel: com.newtrip.yingYbirds/live_photo
public class LivePhotoGalleryPlugin: NSObject, FlutterPlugin {

    // MARK: - Registration

    /// 存储 channel 引用，供 previewAssets 的 downloadCallback 闭包捕获，
    /// 以便在保存图片完成后 invokeMethod 回调 Flutter 侧（native → Flutter 主动推送）
    private var channel: FlutterMethodChannel?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.newtrip.yingYbirds/live_photo",
            binaryMessenger: registrar.messenger()
        )
        let instance = LivePhotoGalleryPlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // MARK: - MethodCall Handler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {

        // ─── pickAssets ──────────────────────────────────────────────────────
        // args: PickerConfig 字段 (isDarkMode, maxCount, enableVideo, ...)
        // returns: { items: [[String:Any]], isOriginalPhoto: Bool }
        case "pickAssets":
            guard let rootVC = topViewController() else {
                result(FlutterError(code: "NO_VIEW_CONTROLLER",
                                    message: "无法获取顶层 ViewController",
                                    details: nil))
                return
            }
            let weakChannel = channel
            LivePhotoGalleryCore.shared.pickAssets(
                args: args,
                from: rootVC,
                maxCountReachedCallback: { maxCount in
                    DispatchQueue.main.async {
                        weakChannel?.invokeMethod("onMaxCountReached", arguments: ["maxCount": maxCount])
                    }
                }
            ) { [weak self] outcome in
                self?.flutterResult(outcome, result: result)
            }

        // ─── previewAssets ───────────────────────────────────────────────────
        // args: assets, initialIndex, sourceFrame, selectedAssetIds, showDownloadButton + PickerConfig 字段
        // returns: { items: [[String:Any]], isOriginalPhoto: Bool }
        case "previewAssets":
            guard let rootVC = topViewController() else {
                result(FlutterError(code: "NO_VIEW_CONTROLLER",
                                    message: "无法获取顶层 ViewController",
                                    details: nil))
                return
            }
            let showDownload = args["showDownloadButton"] as? Bool ?? false
            // 弱引用捕获 channel，避免循环引用；在 invokeMethod 前 guard 非 nil
            let weakChannel = channel
            let downloadCallback: (([String: Any]) -> Void)? = showDownload ? { payload in
                DispatchQueue.main.async {
                    weakChannel?.invokeMethod("onDownloadResult", arguments: payload)
                }
            } : nil
            let downloadProgressCallback: (([String: Any]) -> Void)? = showDownload ? { payload in
                DispatchQueue.main.async {
                    weakChannel?.invokeMethod("onDownloadProgress", arguments: payload)
                }
            } : nil
            LivePhotoGalleryCore.shared.previewAssets(
                args: args,
                from: rootVC,
                downloadCallback: downloadCallback,
                downloadProgressCallback: downloadProgressCallback,
                maxCountReachedCallback: { maxCount in
                    DispatchQueue.main.async {
                        weakChannel?.invokeMethod("onMaxCountReached", arguments: ["maxCount": maxCount])
                    }
                }
            ) { [weak self] outcome in
                self?.flutterResult(outcome, result: result)
            }

        // ─── getThumbnail ────────────────────────────────────────────────────
        // args: assetId, width, height
        // returns: { thumbnailPath: String }
        case "getThumbnail":
            LivePhotoGalleryCore.shared.getThumbnail(args: args) { [weak self] outcome in
                self?.flutterResult(outcome, result: result)
            }

        // ─── exportAsset ─────────────────────────────────────────────────────
        // args: assetId, format ("image" | "video" | "livePhotoVideo")
        // returns: { filePath: String }
        case "exportAsset":
            LivePhotoGalleryCore.shared.exportAsset(args: args) { [weak self] outcome in
                self?.flutterResult(outcome, result: result)
            }

        // ─── requestPermission ───────────────────────────────────────────────
        // returns: "authorized" | "limited" | "denied" | "notDetermined"
        case "requestPermission":
            requestPhotoPermission(result: result)

        // ─── cleanupTempFiles ────────────────────────────────────────────────
        // 清理插件产生的临时缓存文件，建议上传完成后或 App 启动时调用
        case "cleanupTempFiles":
            ExportManager.shared.cleanupTempFiles()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Private: Result Bridge

    /// Swift Result<Any?,Error> → FlutterResult
    /// 不同错误类型映射到不同 code，Flutter 侧可精确捕获
    private func flutterResult(_ outcome: Result<Any?, Error>, result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            switch outcome {
            case .success(let value):
                result(value)
            case .failure(let error):
                let (code, message) = Self.flutterErrorInfo(from: error)
                result(FlutterError(code: code, message: message, details: nil))
            }
        }
    }

    /// 将 Swift 错误映射为结构化的 (code, message) 供 FlutterError 使用
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

    // MARK: - Private: Permission

    private func requestPhotoPermission(result: @escaping FlutterResult) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized:
            result("authorized")
        case .limited:
            result("limited")
        case .denied, .restricted:
            result("denied")
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    switch newStatus {
                    case .authorized: result("authorized")
                    case .limited:    result("limited")
                    default:          result("denied")
                    }
                }
            }
        @unknown default:
            result("denied")
        }
    }
}
