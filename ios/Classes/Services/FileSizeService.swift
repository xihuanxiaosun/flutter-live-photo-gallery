import Foundation
import Photos
import AVFoundation

/// 文件大小估算与精确统计。
/// 估算值用于选择上限的即时反馈，精确值需要真正拉取数据（可能触发 iCloud 下载）。
/// `PHCachingImageManager` 由 PhotoLibraryManager 注入，与其它服务共用同一实例，
/// 类型上直接声明为 `PHCachingImageManager` 以固化这条约束。
final class FileSizeService {

    private let imageManager: PHCachingImageManager

    init(imageManager: PHCachingImageManager) {
        self.imageManager = imageManager
    }

    func estimateFileSize(for asset: PHAsset) -> Int64 {
        if asset.mediaType == .image {
            return Int64(asset.pixelWidth * asset.pixelHeight) * 3 / 12
        } else if asset.mediaType == .video {
            return Int64(asset.duration) * Int64(10 * 1024 * 1024 / 8)
        }
        return 0
    }

    /// 精确大小：所有分支的 completion 一律切回主线程，
    /// getTotalFileSize 的无锁累加正是依赖这一点保证线程安全。
    func getAccurateFileSize(for asset: PHAsset, completion: @escaping (Int64) -> Void) {
        if asset.mediaType == .image {
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true

            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                DispatchQueue.main.async { completion(Int64(data?.count ?? 0)) }
            }
        } else if asset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true

            imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let urlAsset = avAsset as? AVURLAsset,
                      let size = try? FileManager.default.attributesOfItem(atPath: urlAsset.url.path)[.size] as? Int64 else {
                    DispatchQueue.main.async { completion(0) }
                    return
                }
                DispatchQueue.main.async { completion(size) }
            }
        } else {
            DispatchQueue.main.async { completion(0) }
        }
    }

    /// 计算多个资源的总文件大小
    /// 注意：getAccurateFileSize 回调在主线程，因此此处计数器操作是线程安全的
    func getTotalFileSize(
        for assets: [PHAsset],
        progress: @escaping (Int, Int64) -> Void,
        completion: @escaping (Int64) -> Void
    ) {
        guard !assets.isEmpty else {
            completion(0)
            return
        }

        let group = DispatchGroup()
        var totalAccumulator: Int64 = 0
        var completedCount = 0

        for asset in assets {
            group.enter()
            getAccurateFileSize(for: asset) { size in
                totalAccumulator += size
                completedCount += 1
                progress(completedCount, totalAccumulator)
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(totalAccumulator)
        }
    }
}
