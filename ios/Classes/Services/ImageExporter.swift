import Foundation
import Photos
import UIKit

/// 图片导出与编辑写回。
/// 拥有「导出到临时文件」和「把裁剪结果写回相册」两条链路；
/// 编码格式的判定全部委托给注入的 `ImageEncoder`，
/// `PHCachingImageManager` 由 PhotoLibraryManager 注入（与缩略图/预热共用同一实例，
/// 类型上直接声明为 `PHCachingImageManager` 以固化这条约束）。
final class ImageExporter {

    private let imageManager: PHCachingImageManager
    private let encoder: ImageEncoder

    init(imageManager: PHCachingImageManager, encoder: ImageEncoder) {
        self.imageManager = imageManager
        self.encoder = encoder
    }

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

        let encoder = self.encoder
        imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
            guard let data = data else {
                let error = info?[PHImageErrorKey] as? Error ?? PhotoLibraryError.exportFailed(
                    underlying: NSError(domain: "PhotoLibraryManager", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "无法获取原始图片数据"])
                )
                completion(.failure(error))
                return
            }

            let ext = encoder.fileExtension(for: uti)
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
        options.version = .current

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

    func persistEditedImage(_ image: UIImage, for asset: PHAsset, completion: @escaping (Result<Void, Error>) -> Void) {
        let encoder = self.encoder
        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true

            asset.requestContentEditingInput(with: options) { input, info in
                let inputError = info[PHContentEditingInputErrorKey] as? Error

                guard let input = input else {
                    let error = inputError
                        ?? PhotoLibraryError.assetLoadFailed(
                            underlying: NSError(
                                domain: "PhotoLibraryManager",
                                code: -4,
                                userInfo: [NSLocalizedDescriptionKey: "无法获取图片编辑输入"]
                            )
                        )
                    Self.finishPersistEditedImage(completion, result: .failure(error))
                    return
                }

                let output = PHContentEditingOutput(contentEditingInput: input)
                let renderedOutput = encoder.renderedOutputDestination(for: output)

                guard let data = encoder.renderedImageData(
                    for: image,
                    typeIdentifier: renderedOutput.typeIdentifier
                ) else {
                    let error = PhotoLibraryError.exportFailed(
                        underlying: NSError(
                            domain: "PhotoLibraryManager",
                            code: -5,
                            userInfo: [NSLocalizedDescriptionKey: "无法生成裁剪后的图片数据"]
                        )
                    )
                    Self.finishPersistEditedImage(completion, result: .failure(error))
                    return
                }

                do {
                    try data.write(to: renderedOutput.url, options: .atomic)
                } catch {
                    Self.finishPersistEditedImage(completion, result: .failure(PhotoLibraryError.saveFailed(underlying: error)))
                    return
                }

                output.adjustmentData = PHAdjustmentData(
                    formatIdentifier: "com.livephotogallery.crop",
                    formatVersion: "1.0",
                    data: Data("{\"operation\":\"crop\"}".utf8)
                )

                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetChangeRequest(for: asset)
                    request.contentEditingOutput = output
                }) { success, error in
                    if success {
                        Self.finishPersistEditedImage(completion, result: .success(()))
                    } else {
                        let finalError = error ?? PhotoLibraryError.saveFailed(
                            underlying: NSError(
                                domain: "PhotoLibraryManager",
                                code: -6,
                                userInfo: [NSLocalizedDescriptionKey: "写回相册失败"]
                            )
                        )
                        Self.finishPersistEditedImage(completion, result: .failure(finalError))
                    }
                }
            }
        }
    }

    /// 编辑写回的所有回调统一切回主线程（Photos 的回调线程不固定，调用方直接刷 UI）
    private static func finishPersistEditedImage<T>(
        _ completion: @escaping (Result<T, Error>) -> Void,
        result: Result<T, Error>
    ) {
        DispatchQueue.main.async {
            completion(result)
        }
    }
}
