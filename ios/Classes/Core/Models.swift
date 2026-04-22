import Foundation
import Photos
import UIKit
import CryptoKit

// MARK: - 相册模型

struct AlbumModel {
    let collection: PHAssetCollection
    let count: Int

    var title: String {
        // 1. 系统智能相册：subtype 精确映射
        if collection.assetCollectionType == .smartAlbum,
           let chinese = Self.smartAlbumChineseNames[collection.assetCollectionSubtype] {
            return chinese
        }
        // 2. 兜底：对已知英文名做映射（适用于 iCloud / 系统生成的非 SmartAlbum 相册）
        if let raw = collection.localizedTitle,
           let chinese = Self.knownEnglishTitles[raw] {
            return chinese
        }
        return collection.localizedTitle ?? "未命名相册"
    }

    // MARK: - 系统相册中文映射

    private static let smartAlbumChineseNames: [PHAssetCollectionSubtype: String] = [
        .smartAlbumUserLibrary:     "最近项目",
        .smartAlbumRecentlyAdded:   "最近保存",
        .smartAlbumFavorites:       "个人收藏",
        .smartAlbumVideos:          "视频",
        .smartAlbumSelfPortraits:   "自拍",
        .smartAlbumScreenshots:     "屏幕快照",
        .smartAlbumLivePhotos:      "实况照片",
        .smartAlbumBursts:          "连拍快照",
        .smartAlbumPanoramas:       "全景照片",
        .smartAlbumTimelapses:      "延时摄影",
        .smartAlbumSlomoVideos:     "慢动作",
        .smartAlbumDepthEffect:     "人像",
        .smartAlbumAnimated:        "动图",
        .smartAlbumLongExposures:   "长曝光",
        .smartAlbumAllHidden:       "已隐藏",
        .smartAlbumUnableToUpload:  "无法上传",
        .smartAlbumGeneric:         "通用",
    ]

    /// 英文标题兜底映射（针对非 SmartAlbum 的系统相册）
    private static let knownEnglishTitles: [String: String] = [
        "Recently Saved":   "最近保存",
        "Camera Roll":      "相机胶卷",
        "Recents":          "最近项目",
        "Favorites":        "个人收藏",
        "Videos":           "视频",
        "Selfies":          "自拍",
        "Screenshots":      "屏幕快照",
        "Live Photos":      "实况照片",
        "Portraits":        "人像",
        "Panoramas":        "全景照片",
        "Time-lapse":       "延时摄影",
        "Slo-mo":           "慢动作",
        "Bursts":           "连拍快照",
        "Animated":         "动图",
        "Long Exposure":    "长曝光",
        "Hidden":           "已隐藏",
        "All Photos":       "所有照片",
        "My Photo Stream":  "我的照片流",
        "Imports":          "导入",
    ]
}

// MARK: - 照片资源模型

class PhotoAssetModel {

    // MARK: - Source Type

    enum SourceType {
        case photoLibrary(asset: PHAsset)
        case network(url: URL, mediaType: MediaType)
        case localFile(url: URL, mediaType: MediaType)
    }

    enum MediaType {
        case image
        case video(duration: TimeInterval, videoURL: URL?)
        case livePhoto(videoURL: URL?)

        var typeString: String {
            switch self {
            case .image:    return "image"
                case .video:    return "video"
            case .livePhoto: return "livePhoto"
            }
        }
    }

    // MARK: - Properties

    let sourceType: SourceType
    var isSelected: Bool = false
    var editedPath: String?

    // MARK: - Computed Properties

    var id: String {
        switch sourceType {
        case .photoLibrary(let asset):
            return asset.localIdentifier
        case .network(let url, let mediaType):
            // Use stable hash (CryptoKit) instead of Swift's hashValue (process-dependent).
            let videoURLString: String = {
                switch mediaType {
                case .video(_, let v): return v?.absoluteString ?? ""
                case .livePhoto(let v): return v?.absoluteString ?? ""
                case .image: return ""
                }
            }()
            let mediaTypeString: String = mediaType.typeString
            let canonical = "network|mediaType=\(mediaTypeString)|url=\(url.absoluteString)|videoUrl=\(videoURLString)"
            let digest = SHA256.hash(data: Data(canonical.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return "network_\(hex)"
        case .localFile(let url, _):
            return "local_\(url.lastPathComponent)"
        }
    }

    var mediaType: MediaType {
        switch sourceType {
        case .photoLibrary(let asset):
            // ⚠️ 必须先判断 Live Photo，因为 Live Photo 的 mediaType 也是 .image
            if asset.mediaSubtypes.contains(.photoLive) {
                return .livePhoto(videoURL: nil)
            } else if asset.mediaType == .video {
                    return .video(duration: asset.duration, videoURL: nil)
            } else {
                return .image
            }
        case .network(_, let type), .localFile(_, let type):
            return type
        }
    }

    var isLivePhoto: Bool {
        if case .livePhoto = mediaType { return true }
        return false
    }

    var isVideo: Bool {
        if case .video = mediaType { return true }
        return false
    }

    var videoDuration: Int {
        if case .video(let duration, _) = mediaType { return Int(duration) }
        return 0
    }

    var width: Int {
        if case .photoLibrary(let asset) = sourceType { return Int(asset.pixelWidth) }
        return 0
    }

    var height: Int {
        if case .photoLibrary(let asset) = sourceType { return Int(asset.pixelHeight) }
        return 0
    }

    var createDate: Date {
        if case .photoLibrary(let asset) = sourceType { return asset.creationDate ?? Date() }
        return Date()
    }

    var asset: PHAsset? {
        if case .photoLibrary(let asset) = sourceType { return asset }
        return nil
    }

    // MARK: - Initialization

    init(asset: PHAsset) {
        self.sourceType = .photoLibrary(asset: asset)
    }

    init(networkURL: URL, mediaType: MediaType) {
        self.sourceType = .network(url: networkURL, mediaType: mediaType)
    }

    init(localFileURL: URL, mediaType: MediaType) {
        self.sourceType = .localFile(url: localFileURL, mediaType: mediaType)
    }
}

// MARK: - 导出格式

enum ExportFormat: String {
    case image          = "image"
    case video          = "video"
    case livePhotoVideo = "livePhotoVideo"
}

// MARK: - 选择结果（返回给 Flutter）

struct MediaItemResult {
    let localId: String       // PHAsset.localIdentifier
    let type: String          // "image" | "video" | "livePhoto"
    let thumbnailPath: String // 本地临时缩略图路径
    let width: Int
    let height: Int
    let duration: Double?     // 秒（仅 video），其他为 nil

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "assetId": localId,       // Dart 侧使用 assetId
            "mediaType": type,        // Dart 侧使用 mediaType
            "thumbnailPath": thumbnailPath,
            "width": width,
            "height": height,
        ]
        if let duration { dict["duration"] = duration }
        return dict
    }
}

// MARK: - 选择器配置

struct PickerConfig {
    let maxCount: Int
    let maxVideoCount: Int          // -1 = unlimited
    let enableLivePhoto: Bool
    let enableVideo: Bool
    let autoPlayVideo: Bool
    let showRadio: Bool
    let isDarkMode: Bool
    let videoMaxDuration: TimeInterval  // 0 = no limit (seconds)
    let filterConfig: String       // "all" | "imageOnly" | "videoOnly" | "livePhotoOnly"

    init(from dict: [String: Any]) {
        let maxCount = dict["maxCount"] as? Int ?? 9
        let maxVideoCount = dict["maxVideoCount"] as? Int ?? -1
        let videoMaxDuration = dict["videoMaxDuration"] as? Double ?? 0
        let filterConfig = dict["filterConfig"] as? String ?? "all"

        self.maxCount        = max(maxCount, 1)
        self.maxVideoCount   = maxVideoCount == -1 ? -1 : max(maxVideoCount, 1)
        self.enableLivePhoto = dict["enableLivePhoto"] as? Bool   ?? true
        self.enableVideo     = dict["enableVideo"]     as? Bool   ?? true
        self.autoPlayVideo   = dict["autoPlayVideo"]   as? Bool   ?? false
        self.showRadio       = dict["showRadio"]       as? Bool   ?? true
        self.isDarkMode      = dict["isDarkMode"]      as? Bool   ?? false
        self.videoMaxDuration = max(videoMaxDuration, 0)
        switch filterConfig {
        case "all", "imageOnly", "videoOnly", "livePhotoOnly":
            self.filterConfig = filterConfig
        default:
            self.filterConfig = "all"
        }
    }

    /// enableVideo 经 filterConfig 修正后的实际值
    var effectiveEnableVideo: Bool {
        switch filterConfig {
        case "imageOnly", "livePhotoOnly": return false
        default: return enableVideo
        }
    }

    /// enableLivePhoto 经 filterConfig 修正后的实际值
    var effectiveEnableLivePhoto: Bool {
        switch filterConfig {
        case "imageOnly", "videoOnly": return false
        default: return enableLivePhoto
        }
    }
}

