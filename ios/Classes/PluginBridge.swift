import Foundation
import UIKit
import Photos

/// 负责 Flutter ↔ iOS 的参数解析与结果封装
/// 所有方法均为纯函数，无副作用
enum PluginBridge {

    // MARK: - 解析入参

    static func parsePickerConfig(from args: [String: Any]) -> PickerConfig {
        PickerConfig(from: args)
    }

    /// 将 Flutter 传入的 assets 数组转换为 PhotoAssetModel 列表
    /// 支持 type: "local"（PHAsset）和 "network"（远程 URL）
    /// 优化：本地资源批量查询 PHAsset，避免 N 次独立请求
    static func parseAssets(from list: [[String: Any]]) -> [PhotoAssetModel] {
        // 1. 收集所有 local 类型的 assetId
        let localIds = list.compactMap { dict -> String? in
            guard dict["type"] as? String == "local" else { return nil }
            return dict["assetId"] as? String
        }

        // 2. 一次性批量查询所有 PHAsset
        var assetMap = [String: PHAsset]()
        if !localIds.isEmpty {
            PHAsset.fetchAssets(withLocalIdentifiers: localIds, options: nil)
                .enumerateObjects { asset, _, _ in
                    assetMap[asset.localIdentifier] = asset
                }
        }

        // 3. 遍历列表组装模型
        return list.compactMap { dict in
            guard let type = dict["type"] as? String else { return nil }
            switch type {
            case "local":
                guard let assetId = dict["assetId"] as? String,
                      let phAsset = assetMap[assetId]
                else { return nil }
                return PhotoAssetModel(asset: phAsset)
            case "network":
                guard let urlStr = dict["url"] as? String,
                      let url = URL(string: urlStr),
                      let mediaTypeStr = dict["mediaType"] as? String
                else { return nil }
                return PhotoAssetModel(networkURL: url, mediaType: parseMediaType(mediaTypeStr, dict: dict))
            default:
                return nil
            }
        }
    }

    /// 将 Flutter 传入的单个 sourceFrame 转换为 CGRect
    static func parseSourceFrame(from dict: [String: Any]?) -> CGRect {
        guard let dict else { return .zero }
        return CGRect(
            x: dict["x"] as? Double ?? 0,
            y: dict["y"] as? Double ?? 0,
            width: dict["width"] as? Double ?? 0,
            height: dict["height"] as? Double ?? 0
        )
    }

    // MARK: - 构建返回值

    static func buildMediaItems(_ results: [MediaItemResult]) -> [[String: Any]] {
        results.map { $0.toDict() }
    }

    static func buildExportResult(path: String) -> [String: Any] {
        ["filePath": path]
    }

    static func buildThumbnailResult(path: String) -> [String: Any] {
        ["thumbnailPath": path]
    }

    // MARK: - Private

    private static func parseMediaType(_ string: String, dict: [String: Any]) -> PhotoAssetModel.MediaType {
        switch string {
        case "video":
            let duration = dict["duration"] as? Double ?? 0
            let videoURL = (dict["videoUrl"] as? String).flatMap { URL(string: $0) }
            return .video(duration: duration, videoURL: videoURL)
        case "livePhoto":
            let videoURL = (dict["videoUrl"] as? String).flatMap { URL(string: $0) }
            return .livePhoto(videoURL: videoURL)
        default:
            return .image
        }
    }
}
