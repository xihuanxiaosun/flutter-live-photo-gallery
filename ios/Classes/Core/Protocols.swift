import Foundation
import Photos
import UIKit

// MARK: - 照片库管理协议

protocol PhotoLibraryManaging {
    func fetchAlbums(enableVideo: Bool) -> [AlbumModel]
    func fetchAssets(in collection: PHAssetCollection, enableVideo: Bool, enableLivePhoto: Bool) -> [PhotoAssetModel]

    @discardableResult
    func requestThumbnail(
        for asset: PHAsset,
        size: CGSize,
        completion: @escaping (UIImage?) -> Void
    ) -> PHImageRequestID

    func exportFullImage(
        for asset: PHAsset,
        useOriginal: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    )

    func exportVideo(
        for asset: PHAsset,
        completion: @escaping (Result<String, Error>) -> Void
    )

    func exportLivePhotoVideo(
        for asset: PHAsset,
        completion: @escaping (Result<String, Error>) -> Void
    )

    func startCaching(for assets: [PHAsset], size: CGSize)
    func stopCaching(for assets: [PHAsset], size: CGSize)
    func stopCachingAll()
    func cancelImageRequest(_ requestID: PHImageRequestID)

    func estimateFileSize(for asset: PHAsset) -> Int64

    func getAccurateFileSize(
        for asset: PHAsset,
        completion: @escaping (Int64) -> Void
    )

    func getTotalFileSize(
        for assets: [PHAsset],
        progress: @escaping (Int, Int64) -> Void,
        completion: @escaping (Int64) -> Void
    )
}

// MARK: - Live Photo 提取协议

protocol LivePhotoExtracting {
    func extractVideo(
        from asset: PHAsset,
        completion: @escaping (Result<URL, Error>) -> Void
    )
}
