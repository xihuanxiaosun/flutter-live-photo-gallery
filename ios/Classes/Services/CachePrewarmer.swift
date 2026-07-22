import Foundation
import Photos
import UIKit

/// 网格滚动时的缩略图预热与停止预热。
/// 持有的 `PHCachingImageManager` 由 PhotoLibraryManager 注入，
/// 与 ThumbnailService 共用同一个实例——预热与真正的请求必须落在同一个 manager 上才有意义。
/// 单个请求的取消属于请求方，由 ThumbnailService 负责，不在本类。
final class CachePrewarmer {

    private let imageManager: PHCachingImageManager

    init(imageManager: PHCachingImageManager) {
        self.imageManager = imageManager
    }

    func startCaching(for assets: [PHAsset], size: CGSize) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.version = .current
        imageManager.startCachingImages(for: assets, targetSize: size, contentMode: .aspectFill, options: options)
    }

    func stopCaching(for assets: [PHAsset], size: CGSize) {
        imageManager.stopCachingImages(for: assets, targetSize: size, contentMode: .aspectFill, options: nil)
    }

    func stopCachingAll() {
        imageManager.stopCachingImagesForAllAssets()
    }
}
