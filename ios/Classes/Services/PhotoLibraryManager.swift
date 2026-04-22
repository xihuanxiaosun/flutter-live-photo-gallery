import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import ImageIO

class PhotoLibraryManager: PhotoLibraryManaging {

    static let shared = PhotoLibraryManager()

    private lazy var imageManager: PHCachingImageManager = {
        let manager = PHCachingImageManager()
        manager.allowsCachingHighQualityImages = CacheConstants.allowsHighQualityImageCaching
        return manager
    }()

    /// 带超时配置的 URLSession，用于所有网络图片/视频封面加载
    /// 连接超时 15s，资源超时 30s，避免网络差时永久挂起
    private lazy var networkSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - 获取相册列表

    /// 使用 PickerConfig 获取相册列表（考虑 filterConfig 的优先级）
    func fetchAlbums(config: PickerConfig) -> [AlbumModel] {
        return fetchAlbums(enableVideo: config.effectiveEnableVideo)
    }

    /// enableVideo: 是否将视频计入 count（与 fetchAssets 保持一致）
    func fetchAlbums(enableVideo: Bool = true) -> [AlbumModel] {
        var albums: [AlbumModel] = []

        let fetchOptions = PHFetchOptions()
        if enableVideo {
            fetchOptions.predicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
        } else {
            fetchOptions.predicate = NSPredicate(
                format: "mediaType == %d",
                PHAssetMediaType.image.rawValue
            )
        }

        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
            .enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: fetchOptions).count
                if count > 0 { albums.append(AlbumModel(collection: collection, count: count)) }
            }

        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: fetchOptions).count
                if count > 0 { albums.append(AlbumModel(collection: collection, count: count)) }
            }

        albums.sort { lhs, rhs in
            if lhs.collection.assetCollectionSubtype == .smartAlbumUserLibrary { return true }
            if rhs.collection.assetCollectionSubtype == .smartAlbumUserLibrary { return false }
            return lhs.count > rhs.count
        }

        return albums
    }

    // MARK: - 获取相册照片

    /// 使用 PickerConfig 获取相册中的照片（考虑所有过滤条件）
    func fetchAssets(
        in collection: PHAssetCollection,
        config: PickerConfig
    ) -> [PhotoAssetModel] {
        return fetchAssets(
            in: collection,
            enableVideo: config.effectiveEnableVideo,
            enableLivePhoto: config.effectiveEnableLivePhoto,
            videoMaxDuration: config.videoMaxDuration
        )
    }

    func fetchAssets(in collection: PHAssetCollection, enableVideo: Bool, enableLivePhoto: Bool) -> [PhotoAssetModel] {
        return fetchAssets(in: collection, enableVideo: enableVideo, enableLivePhoto: enableLivePhoto, videoMaxDuration: 0)
    }

    func fetchAssets(
        in collection: PHAssetCollection,
        enableVideo: Bool = true,
        enableLivePhoto: Bool = true,
        videoMaxDuration: TimeInterval = 0
    ) -> [PhotoAssetModel] {
        let fetchOptions = PHFetchOptions()

        // 构建媒体类型谓词
        let typePredicate: NSPredicate
        if enableVideo {
            typePredicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
        } else {
            typePredicate = NSPredicate(
                format: "mediaType == %d", PHAssetMediaType.image.rawValue
            )
        }

        // 附加视频时长过滤（超出时长的视频不进入列表，而非灰显）
        if enableVideo && videoMaxDuration > 0 {
            let durationPredicate = NSPredicate(
                format: "duration <= %f OR mediaType != %d",
                videoMaxDuration,
                PHAssetMediaType.video.rawValue
            )
            fetchOptions.predicate = NSCompoundPredicate(
                andPredicateWithSubpredicates: [typePredicate, durationPredicate]
            )
        } else {
            fetchOptions.predicate = typePredicate
        }

        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        var assets: [PhotoAssetModel] = []
        PHAsset.fetchAssets(in: collection, options: fetchOptions).enumerateObjects { asset, _, _ in
            let model = PhotoAssetModel(asset: asset)
            // enableLivePhoto=false 时过滤掉实况照片
            if !enableLivePhoto && model.isLivePhoto { return }
            assets.append(model)
        }
        return assets
    }

    // MARK: - 缩略图

    @discardableResult
    func requestThumbnail(for asset: PHAsset, size: CGSize, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        return imageManager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
            // .opportunistic 会触发两次回调：先降级模糊图，再清晰图。
            // 调用方（DispatchGroup、saveThumbnail 等）只期望一次 completion，
            // 过滤掉降级结果，只在最终清晰图时回调，防止 group.leave() 多次触发崩溃。
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            guard !isDegraded else { return }
            completion(image)
        }
    }

    // MARK: - 导出图片

    func exportFullImage(for asset: PHAsset, useOriginal: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
        if useOriginal {
            exportOriginalImageData(for: asset, completion: completion)
        } else {
            exportResizedImage(for: asset, completion: completion)
        }
    }

    /// 原图导出：使用 requestImageDataAndOrientation 直接获取原始字节流，
    /// 避免将全分辨率图片解码成 UIImage（可达数百 MB），有效规避 OOM。
    private func exportOriginalImageData(for asset: PHAsset, completion: @escaping (Result<String, Error>) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.version = .current  // 如有编辑则导出编辑后版本

        imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
            guard let data = data else {
                let error = info?[PHImageErrorKey] as? Error ?? PhotoLibraryError.exportFailed(
                    underlying: NSError(domain: "PhotoLibraryManager", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "无法获取原始图片数据"])
                )
                completion(.failure(error))
                return
            }

            let ext = Self.fileExtension(for: uti)
            let filePath = (FileConstants.temporaryDirectory as NSString)
                .appendingPathComponent("lpg_\(UUID().uuidString).\(ext)")
            do {
                try data.write(to: URL(fileURLWithPath: filePath))
                completion(.success(filePath))
            } catch {
                completion(.failure(PhotoLibraryError.saveFailed(underlying: error)))
            }
        }
    }

    /// 非原图导出：下采样至 1600×1600，JPEG 85% 压缩，内存安全
    private func exportResizedImage(for asset: PHAsset, completion: @escaping (Result<String, Error>) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.resizeMode = .exact

        imageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: 1600, height: 1600),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            guard let image = image else {
                let error = info?[PHImageErrorKey] as? Error ?? PhotoLibraryError.exportFailed(
                    underlying: NSError(domain: "PhotoLibraryManager", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "无法获取图片"])
                )
                completion(.failure(error))
                return
            }

            guard let data = image.opaque().jpegData(compressionQuality: 0.85) else {
                completion(.failure(PhotoLibraryError.exportFailed(
                    underlying: NSError(domain: "PhotoLibraryManager", code: -2,
                                        userInfo: [NSLocalizedDescriptionKey: "无法转换为JPEG"])
                )))
                return
            }

            let filePath = (FileConstants.temporaryDirectory as NSString)
                .appendingPathComponent("lpg_\(UUID().uuidString).jpg")
            do {
                try data.write(to: URL(fileURLWithPath: filePath))
                completion(.success(filePath))
            } catch {
                completion(.failure(PhotoLibraryError.saveFailed(underlying: error)))
            }
        }
    }

    /// 根据 UTI 推断文件扩展名，兜底返回 "jpg"
    private static func fileExtension(for uti: String?) -> String {
        guard let uti = uti else { return "jpg" }
        if #available(iOS 14.0, *) {
            return UTType(uti)?.preferredFilenameExtension ?? "jpg"
        }
        // iOS 13 兜底映射
        let map: [String: String] = [
            "public.jpeg":              "jpg",
            "public.png":               "png",
            "public.heic":              "heic",
            "public.heif":              "heic",
            "public.tiff":              "tiff",
            "public.gif":               "gif",
            "com.adobe.raw-image":      "dng",
            "com.apple.raw-image":      "dng",
            "org.webmproject.webp":     "webp",
        ]
        return map[uti] ?? "jpg"
    }

    // MARK: - 导出 Live Photo 视频

    func exportLivePhotoVideo(for asset: PHAsset, completion: @escaping (Result<String, Error>) -> Void) {
        guard asset.mediaSubtypes.contains(.photoLive) else {
            completion(.failure(LivePhotoError.notLivePhoto))
            return
        }

        LivePhotoExtractor.shared.extractVideo(from: asset) { result in
            completion(result.map { $0.path })
        }
    }

    // MARK: - 导出视频

    func exportVideo(for asset: PHAsset, completion: @escaping (Result<String, Error>) -> Void) {
        guard asset.mediaType == .video else {
            completion(.failure(PhotoLibraryError.invalidMediaType))
            return
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
            guard let urlAsset = avAsset as? AVURLAsset else {
                completion(.failure(PhotoLibraryError.exportFailed(
                    underlying: NSError(domain: "PhotoLibraryManager", code: -2,
                                        userInfo: [NSLocalizedDescriptionKey: "无法获取视频资源"])
                )))
                return
            }

            let outputURL = URL(fileURLWithPath: (FileConstants.temporaryDirectory as NSString)
                .appendingPathComponent("lpg_\(UUID().uuidString).\(FileConstants.videoExtension)"))

            guard let exportSession = AVAssetExportSession(asset: urlAsset, presetName: AVAssetExportPreset1920x1080) else {
                completion(.failure(LivePhotoError.exportSessionCreationFailed))
                return
            }

            // 使用 iOS 15 兼容写法（export(to:as:) 仅 iOS 18+）
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
            Task {
                do {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        exportSession.exportAsynchronously {
                            if exportSession.status == .completed {
                                cont.resume()
                            } else {
                                cont.resume(throwing: exportSession.error
                                    ?? PhotoLibraryError.exportFailed(
                                        underlying: NSError(domain: "PhotoLibraryManager", code: -3)))
                            }
                        }
                    }
                    completion(.success(outputURL.path))
                } catch {
                    completion(.failure(PhotoLibraryError.exportFailed(underlying: error)))
                }
            }
        }
    }

    // MARK: - 缓存管理

    func startCaching(for assets: [PHAsset], size: CGSize) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        imageManager.startCachingImages(for: assets, targetSize: size, contentMode: .aspectFill, options: options)
    }

    func stopCaching(for assets: [PHAsset], size: CGSize) {
        imageManager.stopCachingImages(for: assets, targetSize: size, contentMode: .aspectFill, options: nil)
    }

    func stopCachingAll() {
        imageManager.stopCachingImagesForAllAssets()
    }

    func cancelImageRequest(_ requestID: PHImageRequestID) {
        imageManager.cancelImageRequest(requestID)
    }

    // MARK: - 文件大小

    func estimateFileSize(for asset: PHAsset) -> Int64 {
        if asset.mediaType == .image {
            return Int64(asset.pixelWidth * asset.pixelHeight) * 3 / 12
        } else if asset.mediaType == .video {
            return Int64(asset.duration) * Int64(10 * 1024 * 1024 / 8)
        }
        return 0
    }

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

// MARK: - 网络图片加载

extension PhotoLibraryManager {

    func loadNetworkImage(from url: URL, targetSize: CGSize? = nil, completion: @escaping (Result<UIImage, Error>) -> Void) {
        networkSession.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard
                    let data = data,
                    let image = Self.decodeNetworkImage(data: data, targetSize: targetSize)
                else {
                    completion(.failure(PhotoLibraryError.assetLoadFailed(
                        underlying: NSError(domain: "PhotoLibraryManager", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "无法解析图片数据"])
                    )))
                    return
                }
                completion(.success(image))
            }
        }.resume()
    }

    func loadNetworkLivePhoto(imageURL: URL, videoURL: URL, targetSize: CGSize? = nil, completion: @escaping (Result<(UIImage, URL), Error>) -> Void) {
        loadNetworkImage(from: imageURL, targetSize: targetSize) { result in
            switch result {
            case .success(let image): completion(.success((image, videoURL)))
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    func loadNetworkVideoThumbnail(from url: URL, targetSize: CGSize? = nil, completion: @escaping (Result<UIImage, Error>) -> Void) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let targetSize = targetSize { generator.maximumSize = targetSize }

        // 使用 iOS 15 兼容写法（image(at:) 仅 iOS 16+）
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var actualTime = CMTime.zero
                let cgImage = try generator.copyCGImage(at: .zero, actualTime: &actualTime)
                let image = UIImage(cgImage: cgImage)
                DispatchQueue.main.async { completion(.success(image)) }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(PhotoLibraryError.assetLoadFailed(underlying: error)))
                }
            }
        }
    }

    // Fix: 使用 UIGraphicsImageRenderer 替代已废弃的 UIGraphicsBeginImageContextWithOptions
    private func resizeImage(_ image: UIImage, to targetSize: CGSize) -> UIImage {
        let ratio = min(targetSize.width / image.size.width, targetSize.height / image.size.height)
        let newSize = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// 网络图片解码：优先走下采样，避免大图直接解码带来的内存峰值风险。
    /// - targetSize 有值：按目标尺寸*屏幕 scale 解码。
    /// - targetSize 为空：保底限制到 4096 像素，防止超大原图触发 OOM。
    private static func decodeNetworkImage(data: Data, targetSize: CGSize?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let fallbackMaxPixel: CGFloat = 4096
        let maxPixelSize: CGFloat
        if let targetSize = targetSize, targetSize.width > 0, targetSize.height > 0 {
            maxPixelSize = max(targetSize.width, targetSize.height) * UIScreen.main.scale
        } else {
            maxPixelSize = fallbackMaxPixel
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize)),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
