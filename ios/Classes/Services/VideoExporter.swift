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

    /// - Parameter original: true 时用 `AVAssetExportPresetPassthrough` 原样拷贝原始轨道
    ///   （不转码、不降分辨率），容器沿用源文件类型；若该资源不支持 passthrough 则回退到
    ///   `AVAssetExportPreset1920x1080`（≤1080p mp4），与 original == false 的行为一致。
    func exportVideo(for asset: PHAsset, original: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
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

            // 选择导出预设：original 优先 passthrough（原样拷贝轨道），否则 1080p 转码。
            // passthrough 不改编码，容器沿用源文件扩展名即可，保证输出类型必被支持。
            let usePassthrough = original
                && AVAssetExportSession.exportPresets(compatibleWith: urlAsset)
                    .contains(AVAssetExportPresetPassthrough)
            let presetName = usePassthrough
                ? AVAssetExportPresetPassthrough
                : AVAssetExportPreset1920x1080
            let (fileType, ext): (AVFileType, String) = usePassthrough
                ? Self.passthroughContainer(for: urlAsset)
                : (.mp4, FileConstants.videoExtension)

            let outputURL = URL(fileURLWithPath: (FileConstants.temporaryDirectory as NSString)
                .appendingPathComponent("lpg_\(UUID().uuidString).\(ext)"))

            guard let exportSession = AVAssetExportSession(asset: urlAsset, presetName: presetName) else {
                completion(.failure(LivePhotoError.exportSessionCreationFailed))
                return
            }

            Task {
                do {
                    // 使用 iOS 15 兼容写法（export(to:as:) 仅 iOS 18+）
                    try await exportSession.exportAsync(
                        to: outputURL,
                        as: fileType,
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

    /// passthrough 导出的输出容器：沿用源文件扩展名，避免把 .mov 原始轨道硬塞进 mp4。
    private static func passthroughContainer(for urlAsset: AVURLAsset) -> (fileType: AVFileType, ext: String) {
        switch urlAsset.url.pathExtension.lowercased() {
        case "mov", "qt":
            return (.mov, "mov")
        case "m4v":
            return (.m4v, "m4v")
        default:
            // mp4 及未知扩展名统一按 mp4 容器（passthrough 不改编码，源多为 mp4/mov）
            return (.mp4, "mp4")
        }
    }
}
