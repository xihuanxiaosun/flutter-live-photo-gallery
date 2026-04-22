import Foundation

// MARK: - Live Photo 错误

enum LivePhotoError: LocalizedError {
    case notLivePhoto
    case videoResourceNotFound
    case extractionFailed(underlying: Error)
    case invalidAsset
    case conversionFailed(underlying: Error?)
    case exportSessionCreationFailed

    var errorDescription: String? {
        switch self {
        case .notLivePhoto:
            return "不是 Live Photo"
        case .videoResourceNotFound:
            return "找不到 Live Photo 的视频资源"
        case .extractionFailed(let error):
            return "提取 Live Photo 视频失败: \(error.localizedDescription)"
        case .invalidAsset:
            return "无效的照片资源"
        case .conversionFailed(let error):
            return "视频转码失败\(error.map { ": \($0.localizedDescription)" } ?? "")"
        case .exportSessionCreationFailed:
            return "无法创建导出会话"
        }
    }
}

// MARK: - 照片库错误

enum PhotoLibraryError: LocalizedError {
    case permissionDenied
    case albumNotFound
    case assetLoadFailed(underlying: Error)
    case exportFailed(underlying: Error)
    case invalidMediaType
    case saveFailed(underlying: Error)
    case assetNotFound

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "没有访问照片库的权限"
        case .albumNotFound:
            return "找不到指定的相册"
        case .assetLoadFailed(let error):
            return "加载照片失败: \(error.localizedDescription)"
        case .exportFailed(let error):
            return "导出照片失败: \(error.localizedDescription)"
        case .invalidMediaType:
            return "不支持的媒体类型"
        case .saveFailed(let error):
            return "保存文件失败: \(error.localizedDescription)"
        case .assetNotFound:
            return "找不到指定的媒体资源"
        }
    }
}
