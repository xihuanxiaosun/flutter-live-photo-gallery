import Foundation
import Photos
import AVFoundation

class LivePhotoExtractor: LivePhotoExtracting {

    static let shared = LivePhotoExtractor()
    private init() {}

    // MARK: - 提取 Live Photo 视频

    func extractVideo(from asset: PHAsset, completion: @escaping (Result<URL, Error>) -> Void) {
        guard asset.mediaSubtypes.contains(.photoLive) else {
            completion(.failure(LivePhotoError.notLivePhoto))
            return
        }

        let resources = PHAssetResource.assetResources(for: asset)
        guard let videoResource = resources.first(where: { $0.type == .pairedVideo }) else {
            completion(.failure(LivePhotoError.videoResourceNotFound))
            return
        }

        let fileName = "lpg_\(UUID().uuidString).\(FileConstants.livePhotoExtension)"
        let tempURL = URL(fileURLWithPath: (FileConstants.temporaryDirectory as NSString).appendingPathComponent(fileName))

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        PHAssetResourceManager.default().writeData(for: videoResource, toFile: tempURL, options: options) { [weak self] error in
            if let error = error {
                completion(.failure(LivePhotoError.extractionFailed(underlying: error)))
                return
            }
            self?.checkAndConvertVideo(url: tempURL, completion: completion)
        }
    }

    // MARK: - 检查并转码（HDR → SDR）

    private func checkAndConvertVideo(url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVURLAsset(url: url)

        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else {
                    completion(.success(url))
                    return
                }

                guard let formatDescriptions = try? await videoTrack.load(.formatDescriptions) else {
                    completion(.success(url))
                    return
                }

                let isHDR = formatDescriptions.contains { description in
                    let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]
                    let colorPrimaries = extensions?[kCVImageBufferColorPrimariesKey as String] as? String
                    return colorPrimaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String)
                }

                if isHDR {
                    convertToSDR(inputURL: url, completion: completion)
                } else {
                    completion(.success(url))
                }
            } catch {
                completion(.success(url))
            }
        }
    }

    // MARK: - HDR 转 SDR

    private func convertToSDR(inputURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVURLAsset(url: inputURL)

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPreset1920x1080
        ) else {
            completion(.failure(LivePhotoError.exportSessionCreationFailed))
            return
        }

        let outputURL = URL(fileURLWithPath: (FileConstants.temporaryDirectory as NSString)
            .appendingPathComponent("lpg_\(UUID().uuidString).\(FileConstants.videoExtension)"))

        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let videoTrack = tracks.first {
                    let naturalSize = try await videoTrack.load(.naturalSize)
                    let duration = try await asset.load(.duration)
                    exportSession.videoComposition = makeSDRVideoComposition(
                        videoTrack: videoTrack,
                        naturalSize: naturalSize,
                        duration: duration
                    )
                }
            } catch {
                // 无法加载轨道信息时继续导出（不设置 videoComposition）
            }

            // 使用 iOS 15 兼容写法（export(to:as:) 仅 iOS 18+）
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    exportSession.exportAsynchronously {
                        if exportSession.status == .completed {
                            cont.resume()
                        } else {
                            cont.resume(throwing: exportSession.error
                                ?? LivePhotoError.conversionFailed(
                                    underlying: NSError(domain: "LivePhotoExtractor", code: -1)))
                        }
                    }
                }
                try? FileManager.default.removeItem(at: inputURL)
                completion(.success(outputURL))
            } catch {
                try? FileManager.default.removeItem(at: inputURL)
                completion(.failure(LivePhotoError.conversionFailed(underlying: error)))
            }
        }
    }

    private func makeSDRVideoComposition(
        videoTrack: AVAssetTrack,
        naturalSize: CGSize,
        duration: CMTime
    ) -> AVVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = naturalSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)]
        composition.instructions = [instruction]

        return composition
    }
}
