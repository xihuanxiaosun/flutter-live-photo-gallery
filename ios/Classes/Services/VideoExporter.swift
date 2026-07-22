import Foundation
import Photos
import AVFoundation

/// 视频导出。
/// 普通视频走 `PHImageManager.requestAVAsset` + `AVAssetExportSession`；
/// Live Photo 的配对视频交给注入的 `LivePhotoExtracting`（含 HDR→SDR 转码）。
/// `PHCachingImageManager` 由 PhotoLibraryManager 注入，与其它服务共用同一实例，
/// 类型上直接声明为 `PHCachingImageManager` 以固化这条约束。
final class VideoExporter {

    private let imageManager: PHCachingImageManager
    private let livePhotoExtractor: LivePhotoExtracting

    init(imageManager: PHCachingImageManager, livePhotoExtractor: LivePhotoExtracting) {
        self.imageManager = imageManager
        self.livePhotoExtractor = livePhotoExtractor
    }

    // MARK: - 导出 Live Photo 视频

    func exportLivePhotoVideo(for asset: PHAsset, completion: @escaping (Result<String, Error>) -> Void) {
        guard asset.mediaSubtypes.contains(.photoLive) else {
            completion(.failure(LivePhotoError.notLivePhoto))
            return
        }

        livePhotoExtractor.extractVideo(from: asset) { result in
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

            Task {
                do {
                    // 使用 iOS 15 兼容写法（export(to:as:) 仅 iOS 18+）
                    try await exportSession.exportAsync(
                        to: outputURL,
                        as: .mp4,
                        fallbackError: PhotoLibraryError.exportFailed(
                            underlying: NSError(domain: "PhotoLibraryManager", code: -3))
                    )
                    completion(.success(outputURL.path))
                } catch {
                    completion(.failure(PhotoLibraryError.exportFailed(underlying: error)))
                }
            }
        }
    }
}
