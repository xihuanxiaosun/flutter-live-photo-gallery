import Foundation
import Photos

/// 相册内媒体资源读取。
/// 只负责把过滤条件（媒体类型 / 视频时长 / 实况照片）翻译成 `PHFetchOptions` 谓词，
/// 并把 `PHAsset` 包装成 `PhotoAssetModel`；从 PhotoLibraryManager 抽出，facade 直接委托到这里。
final class AssetFetcher {

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
}
