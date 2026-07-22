import Foundation
import Photos
import UIKit

/// 照片库统一入口（facade）。
/// 本身不含业务逻辑，只负责装配各个单一职责的服务并把调用原样转发过去，
/// 从而让 UI / ExportManager 等调用方保持零改动。
///
/// 关键约束：整个插件只允许存在一个 `PHCachingImageManager`。
/// 缩略图请求、缓存预热、图片导出、文件大小统计必须共用同一实例，
/// 否则预热的缓存无法命中，`cancelImageRequest` 也会取消到错误的 manager 上。
final class PhotoLibraryManager: PhotoLibraryManaging {

    static let shared = PhotoLibraryManager()

    private let albumRepository: AlbumRepository
    private let assetFetcher: AssetFetcher
    private let thumbnailService: ThumbnailService
    private let imageExporter: ImageExporter
    private let videoExporter: VideoExporter
    private let cachePrewarmer: CachePrewarmer
    private let fileSizeService: FileSizeService

    /// 网络图片加载已抽到 NetworkImageLoader（自包含 URLSession + 下采样解码）
    private let networkImageLoader: NetworkImageLoader

    private init() {
        // 唯一的 PHCachingImageManager，注入给所有需要它的服务
        let imageManager = PHCachingImageManager()
        imageManager.allowsCachingHighQualityImages = CacheConstants.allowsHighQualityImageCaching

        albumRepository = AlbumRepository()
        assetFetcher = AssetFetcher()
        thumbnailService = ThumbnailService(imageManager: imageManager)
        imageExporter = ImageExporter(imageManager: imageManager, encoder: ImageEncoder())
        videoExporter = VideoExporter(imageManager: imageManager, livePhotoExtractor: LivePhotoExtractor.shared)
        cachePrewarmer = CachePrewarmer(imageManager: imageManager)
        fileSizeService = FileSizeService(imageManager: imageManager)
        networkImageLoader = NetworkImageLoader()
    }

    // MARK: - 获取相册列表

    /// 使用 PickerConfig 获取相册列表（考虑 filterConfig 的优先级）
    func fetchAlbums(config: PickerConfig) -> [AlbumModel] {
        return albumRepository.fetchAlbums(config: config)
    }

    /// enableVideo: 是否将视频计入 count（与 fetchAssets 保持一致）
    func fetchAlbums(enableVideo: Bool = true) -> [AlbumModel] {
        return albumRepository.fetchAlbums(enableVideo: enableVideo)
    }

    // MARK: - 获取相册照片

    /// 使用 PickerConfig 获取相册中的照片（考虑所有过滤条件）
    func fetchAssets(
        in collection: PHAssetCollection,
        config: PickerConfig
    ) -> [PhotoAssetModel] {
        return assetFetcher.fetchAssets(in: collection, config: config)
    }

    func fetchAssets(in collection: PHAssetCollection, enableVideo: Bool, enableLivePhoto: Bool) -> [PhotoAssetModel] {
        return assetFetcher.fetchAssets(in: collection, enableVideo: enableVideo, enableLivePhoto: enableLivePhoto)
    }

    func fetchAssets(
        in collection: PHAssetCollection,
        enableVideo: Bool = true,
        enableLivePhoto: Bool = true,
        videoMaxDuration: TimeInterval = 0
    ) -> [PhotoAssetModel] {
        return assetFetcher.fetchAssets(
            in: collection,
            enableVideo: enableVideo,
            enableLivePhoto: enableLivePhoto,
            videoMaxDuration: videoMaxDuration
        )
    }

    // MARK: - 缩略图

    @discardableResult
    func requestThumbnail(for asset: PHAsset, size: CGSize, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        return thumbnailService.requestThumbnail(for: asset, size: size, completion: completion)
    }

    // MARK: - 导出图片

    func exportFullImage(for asset: PHAsset, useOriginal: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
        imageExporter.exportFullImage(for: asset, useOriginal: useOriginal, completion: completion)
    }

    func persistEditedImage(_ image: UIImage, for asset: PHAsset, completion: @escaping (Result<Void, Error>) -> Void) {
        imageExporter.persistEditedImage(image, for: asset, completion: completion)
    }

    // MARK: - 导出 Live Photo 视频

    func exportLivePhotoVideo(for asset: PHAsset, completion: @escaping (Result<String, Error>) -> Void) {
        videoExporter.exportLivePhotoVideo(for: asset, completion: completion)
    }

    // MARK: - 导出视频

    func exportVideo(for asset: PHAsset, completion: @escaping (Result<String, Error>) -> Void) {
        videoExporter.exportVideo(for: asset, completion: completion)
    }

    // MARK: - 缓存管理

    func startCaching(for assets: [PHAsset], size: CGSize) {
        cachePrewarmer.startCaching(for: assets, size: size)
    }

    func stopCaching(for assets: [PHAsset], size: CGSize) {
        cachePrewarmer.stopCaching(for: assets, size: size)
    }

    func stopCachingAll() {
        cachePrewarmer.stopCachingAll()
    }

    /// 取消缩略图请求。
    /// 这里的 requestID 只可能来自 `thumbnailService.requestThumbnail`，
    /// 因此取消也必须走同一个服务——虽然它与 CachePrewarmer 持有同一个
    /// PHCachingImageManager，但那是注入的结果，不该被当成调用链的前提。
    func cancelImageRequest(_ requestID: PHImageRequestID) {
        thumbnailService.cancelImageRequest(requestID)
    }

    // MARK: - 文件大小

    func estimateFileSize(for asset: PHAsset) -> Int64 {
        return fileSizeService.estimateFileSize(for: asset)
    }

    func getAccurateFileSize(for asset: PHAsset, completion: @escaping (Int64) -> Void) {
        fileSizeService.getAccurateFileSize(for: asset, completion: completion)
    }

    /// 计算多个资源的总文件大小
    /// 注意：getAccurateFileSize 回调在主线程，因此计数器操作是线程安全的
    func getTotalFileSize(
        for assets: [PHAsset],
        progress: @escaping (Int, Int64) -> Void,
        completion: @escaping (Int64) -> Void
    ) {
        fileSizeService.getTotalFileSize(for: assets, progress: progress, completion: completion)
    }
}

// MARK: - 网络图片加载

extension PhotoLibraryManager {

    func loadNetworkImage(from url: URL, targetSize: CGSize? = nil, completion: @escaping (Result<UIImage, Error>) -> Void) {
        networkImageLoader.loadNetworkImage(from: url, targetSize: targetSize, completion: completion)
    }

}
