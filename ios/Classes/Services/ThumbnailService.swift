import Foundation
import Photos
import UIKit

/// 网格缩略图请求。
/// 必须与 CachePrewarmer / ImageExporter / FileSizeService 共用同一个 `PHCachingImageManager`
/// （由 PhotoLibraryManager 注入），否则预热的缓存无法命中，
/// 返回的 requestID 也无法被 `cancelImageRequest` 取消。
/// 依赖直接声明为 `PHCachingImageManager` 而非父类 `PHImageManager`，
/// 让这条约束由类型系统而不是注释来保证。
final class ThumbnailService {

    private let imageManager: PHCachingImageManager

    init(imageManager: PHCachingImageManager) {
        self.imageManager = imageManager
    }

    @discardableResult
    func requestThumbnail(for asset: PHAsset, size: CGSize, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.version = .current

        return imageManager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
            // .opportunistic 会触发两次回调：先降级模糊图，再清晰图。
            // 调用方（DispatchGroup、saveThumbnail 等）只期望一次 completion，
            // 过滤掉降级结果，只在最终清晰图时回调，防止 group.leave() 多次触发崩溃。
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            guard !isDegraded else { return }
            completion(image)
        }
    }

    /// 取消 `requestThumbnail` 返回的请求 ID。
    /// 取消必须发给发起请求的那个 manager，因此这条转发只能留在本类：
    /// 走 CachePrewarmer 虽然当前也能生效（两者持有同一实例），
    /// 但那只是巧合，一旦注入关系改变就会静默失效。
    func cancelImageRequest(_ requestID: PHImageRequestID) {
        imageManager.cancelImageRequest(requestID)
    }
}
