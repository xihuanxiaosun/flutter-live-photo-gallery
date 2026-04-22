import Foundation
import Photos
import UIKit

class ExportManager {

    static let shared = ExportManager()

    private init() {
        // App 启动/插件首次初始化时，清理上次遗留的临时文件
        // 避免多次选图后 /tmp 目录持续膨胀
        cleanupTempFiles()
    }

    /// 插件临时文件前缀，便于识别和清理
    private static let tempFilePrefix = "lpg_"

    // MARK: - PHAsset 查找

    func fetchAsset(by localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    // MARK: - 统一导出媒体文件

    func export(
        assetId: String,
        format: ExportFormat,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let asset = fetchAsset(by: assetId) else {
            completion(.failure(PhotoLibraryError.assetNotFound))
            return
        }
        switch format {
        case .image:
            PhotoLibraryManager.shared.exportFullImage(for: asset, completion: completion)
        case .video:
            PhotoLibraryManager.shared.exportVideo(for: asset, completion: completion)
        case .livePhotoVideo:
            PhotoLibraryManager.shared.exportLivePhotoVideo(for: asset, completion: completion)
        }
    }

    // MARK: - 单张缩略图导出

    func exportThumbnail(
        assetId: String,
        size: CGSize,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let asset = fetchAsset(by: assetId) else {
            completion(.failure(PhotoLibraryError.assetNotFound))
            return
        }
        saveThumbnail(for: asset, size: size, completion: completion)
    }

    // MARK: - 批量缩略图（pickAssets 选完后调用）

    func batchExportThumbnails(
        for models: [PhotoAssetModel],
        size: CGSize = CGSize(width: 200, height: 200),
        completion: @escaping ([MediaItemResult]) -> Void
    ) {
        guard !models.isEmpty else { completion([]); return }

        var results = [Int: MediaItemResult]()
        let group = DispatchGroup()

        for (index, model) in models.enumerated() {
            group.enter()
            switch model.sourceType {
            case .photoLibrary(let phAsset):
                let thumbnailProducer: (@escaping (Result<String, Error>) -> Void) -> Void = { done in
                    if let editedPath = model.editedPath, !editedPath.isEmpty {
                        self.saveLocalImageThumbnail(filePath: editedPath, size: size, completion: done)
                    } else {
                        self.saveThumbnail(for: phAsset, size: size, completion: done)
                    }
                }
                thumbnailProducer { result in
                    let outAssetId = (model.editedPath?.isEmpty == false) ? model.editedPath! : phAsset.localIdentifier
                    let outSize = self.localImageSize(filePath: model.editedPath)
                    results[index] = MediaItemResult(
                        localId: outAssetId,
                        type: model.mediaType.typeString,
                        thumbnailPath: (try? result.get()) ?? "",
                        width: outSize?.0 ?? model.width,
                        height: outSize?.1 ?? model.height,
                        duration: model.isVideo ? Double(model.videoDuration) : nil
                    )
                    group.leave()
                }
            case .network(let coverUrl, _):
                let thumbnailProducer: (@escaping (Result<String, Error>) -> Void) -> Void = { done in
                    if let editedPath = model.editedPath, !editedPath.isEmpty {
                        self.saveLocalImageThumbnail(filePath: editedPath, size: size, completion: done)
                    } else {
                        self.saveNetworkThumbnail(
                            networkId: model.id,
                            url: coverUrl,
                            size: size,
                            completion: done
                        )
                    }
                }
                thumbnailProducer { result in
                    let outAssetId = (model.editedPath?.isEmpty == false) ? model.editedPath! : model.id
                    let outSize = self.localImageSize(filePath: model.editedPath)
                    // Network 资源当前无法从 PhotoLibrary 获取原始像素尺寸，这里以目标尺寸回填。
                    results[index] = MediaItemResult(
                        localId: outAssetId,
                        type: model.mediaType.typeString,
                        thumbnailPath: (try? result.get()) ?? "",
                        width: outSize?.0 ?? Int(size.width),
                        height: outSize?.1 ?? Int(size.height),
                        duration: {
                            switch model.mediaType {
                            case .video(let duration, _): return duration
                            default: return nil
                            }
                        }()
                    )
                    group.leave()
                }
            case .localFile(_, _):
                // 当前版本 Flutter 侧仅传递了 local/network，localFile 暂不处理。
                results[index] = MediaItemResult(
                    localId: (model.editedPath?.isEmpty == false) ? model.editedPath! : model.id,
                    type: model.mediaType.typeString,
                    thumbnailPath: "",
                    width: 0,
                    height: 0,
                    duration: model.isVideo ? Double(model.videoDuration) : nil
                )
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion((0..<models.count).compactMap { results[$0] })
        }
    }

    // MARK: - 临时文件清理

    /// 清理插件产生的临时文件
    func cleanupTempFiles() {
        let tmpDir = FileConstants.temporaryDirectory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: tmpDir) else { return }
        for file in files where file.hasPrefix(Self.tempFilePrefix) {
            try? fm.removeItem(atPath: (tmpDir as NSString).appendingPathComponent(file))
        }
    }

    // MARK: - Private

    /// 确定性文件名：同一资源同一尺寸只生成一次，命中缓存直接返回
    private func thumbnailFileName(for asset: PHAsset, size: CGSize) -> String {
        // 使用 localIdentifier 的 sanitized 形式避免路径分隔符问题
        let sanitizedId = asset.localIdentifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        return "\(Self.tempFilePrefix)\(sanitizedId)_\(Int(size.width))x\(Int(size.height)).jpg"
    }

    private func saveThumbnail(
        for asset: PHAsset,
        size: CGSize,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let fileName = thumbnailFileName(for: asset, size: size)
        let path = (FileConstants.temporaryDirectory as NSString).appendingPathComponent(fileName)

        // 缓存命中：文件已存在，直接返回路径
        if FileManager.default.fileExists(atPath: path) {
            completion(.success(path))
            return
        }

        PhotoLibraryManager.shared.requestThumbnail(for: asset, size: size) { image in
            guard let image,
                  let data = image.opaque().jpegData(compressionQuality: 0.8) else {
                completion(.failure(PhotoLibraryError.exportFailed(
                    underlying: NSError(
                        domain: "ExportManager", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "缩略图生成失败"]
                    )
                )))
                return
            }
            do {
                try data.write(to: URL(fileURLWithPath: path))
                completion(.success(path))
            } catch {
                completion(.failure(PhotoLibraryError.saveFailed(underlying: error)))
            }
        }
    }

    /// Network 缩略图导出（写入 iOS temp，并以 networkId + size 做确定性缓存命中）
    private func saveNetworkThumbnail(
        networkId: String,
        url: URL,
        size: CGSize,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let sanitizedId = networkId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        let fileName = "\(Self.tempFilePrefix)\(sanitizedId)_\(Int(size.width))x\(Int(size.height)).jpg"
        let path = (FileConstants.temporaryDirectory as NSString).appendingPathComponent(fileName)

        // 缓存命中：文件已存在，直接返回路径
        if FileManager.default.fileExists(atPath: path) {
            completion(.success(path))
            return
        }

        PhotoLibraryManager.shared.loadNetworkImage(from: url, targetSize: size) { result in
            switch result {
            case .success(let image):
                guard let data = image.opaque().jpegData(compressionQuality: 0.8) else {
                    completion(.failure(PhotoLibraryError.exportFailed(
                        underlying: NSError(domain: "ExportManager", code: -1, userInfo: [
                            NSLocalizedDescriptionKey: "缩略图编码失败"
                        ])
                    )))
                    return
                }
                do {
                    try data.write(to: URL(fileURLWithPath: path))
                    completion(.success(path))
                } catch {
                    completion(.failure(PhotoLibraryError.saveFailed(underlying: error)))
                }
            case .failure(let error):
                completion(.failure(PhotoLibraryError.assetLoadFailed(underlying: error)))
            }
        }
    }

    private func saveLocalImageThumbnail(
        filePath: String,
        size: CGSize,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let image = UIImage(contentsOfFile: filePath) else {
            completion(.failure(PhotoLibraryError.assetLoadFailed(
                underlying: NSError(domain: "ExportManager", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "裁剪图读取失败"
                ])
            )))
            return
        }

        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = rendered.opaque().jpegData(compressionQuality: 0.85) else {
            completion(.failure(PhotoLibraryError.exportFailed(
                underlying: NSError(domain: "ExportManager", code: -3)
            )))
            return
        }
        let fileName = "\(Self.tempFilePrefix)local_\(UUID().uuidString)_\(Int(size.width))x\(Int(size.height)).jpg"
        let path = (FileConstants.temporaryDirectory as NSString).appendingPathComponent(fileName)
        do {
            try data.write(to: URL(fileURLWithPath: path))
            completion(.success(path))
        } catch {
            completion(.failure(PhotoLibraryError.saveFailed(underlying: error)))
        }
    }

    private func localImageSize(filePath: String?) -> (Int, Int)? {
        guard let filePath, !filePath.isEmpty,
              let image = UIImage(contentsOfFile: filePath) else { return nil }
        return (Int(image.size.width), Int(image.size.height))
    }
}
