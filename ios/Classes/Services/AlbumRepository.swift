import Foundation
import Photos

/// 相册列表读取。
/// 只负责把系统智能相册 + 用户相册聚合成 `AlbumModel` 并排序（相机胶卷置顶、其余按数量降序），
/// 不持有任何图片请求资源；从 PhotoLibraryManager 抽出，facade 直接委托到这里。
final class AlbumRepository {

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
}
