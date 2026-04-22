import UIKit
import Photos

/// 插件业务核心，对外暴露 4 个 API
/// （原名 LivePhotoGalleryPlugin，此处改名避免与 Flutter 插件入口类冲突）
class LivePhotoGalleryCore {

    static let shared = LivePhotoGalleryCore()
    private init() {}

    /// 插件统一回调类型
    /// success: Any? 可为 nil / [String:Any] / [[String:Any]]
    typealias PluginCompletion = (Result<Any?, Error>) -> Void

    // MARK: - pickAssets
    // Flutter 传入: PickerConfig 字段（isDarkMode, maxCount, enableVideo 等）
    // 返回: { items: [[String:Any]], isOriginalPhoto: Bool }

    func pickAssets(
        args: [String: Any],
        from viewController: UIViewController,
        maxCountReachedCallback: ((Int) -> Void)? = nil,
        completion: @escaping PluginCompletion
    ) {
        let config = PluginBridge.parsePickerConfig(from: args)

        // 在后台线程获取相册列表，避免阻塞 UI
        DispatchQueue.global(qos: .userInitiated).async {
            let allAlbums = PhotoLibraryManager.shared.fetchAlbums(config: config)

            DispatchQueue.main.async {
                guard let defaultAlbum = allAlbums.first else {
                    completion(.success(["items": [] as [[String: Any]], "isOriginalPhoto": false]))
                    return
                }

                let gridVC = PhotoGridViewController(
                    albums: allAlbums,
                    selectedAlbum: defaultAlbum,
                    config: config
                ) { assets, isOriginalPhoto in
                    guard !assets.isEmpty else {
                        completion(.success(["items": [] as [[String: Any]], "isOriginalPhoto": false]))
                        return
                    }
                    ExportManager.shared.batchExportThumbnails(for: assets) { results in
                        completion(.success([
                            "items": PluginBridge.buildMediaItems(results),
                            "isOriginalPhoto": isOriginalPhoto,
                        ] as [String: Any]))
                    }
                }

                gridVC.onMaxCountReached = maxCountReachedCallback

                let nav = UINavigationController(rootViewController: gridVC)
                nav.modalPresentationStyle = .fullScreen
                nav.overrideUserInterfaceStyle = config.isDarkMode ? .dark : .light
                viewController.present(nav, animated: true)
            }
        }
    }

    // MARK: - previewAssets
    // Flutter 传入:
    //   assets: [{type, assetId/url, mediaType, videoUrl?, duration?}]
    //   initialIndex: Int
    //   sourceFrame: {x, y, width, height}
    //   selectedAssetIds: [String]
    //   config 字段（isDarkMode, showRadio, maxCount 等，与 pickAssets 同级）
    // 返回: { items: [[String:Any]], isOriginalPhoto: Bool }

    func previewAssets(
        args: [String: Any],
        from viewController: UIViewController,
        downloadCallback: (([String: Any]) -> Void)? = nil,
        downloadProgressCallback: (([String: Any]) -> Void)? = nil,
        maxCountReachedCallback: ((Int) -> Void)? = nil,
        completion: @escaping PluginCompletion
    ) {
        guard let assetDicts = args["assets"] as? [[String: Any]], !assetDicts.isEmpty else {
            completion(.failure(PhotoLibraryError.invalidMediaType))
            return
        }

        let assets = PluginBridge.parseAssets(from: assetDicts)
        let initialIndex = max(0, min(args["initialIndex"] as? Int ?? 0, assets.count - 1))
        let config = PluginBridge.parsePickerConfig(from: args)
        let sourceFrame = PluginBridge.parseSourceFrame(from: args["sourceFrame"] as? [String: Any])

        // 预选中的资源（通过 ID 列表匹配）
        let selectedIds = Set(args["selectedAssetIds"] as? [String] ?? [])
        var selectedAssets: [PhotoAssetModel] = []
        if !selectedIds.isEmpty {
            for asset in assets where selectedIds.contains(asset.id) {
                asset.isSelected = true
                selectedAssets.append(asset)
            }
        }

        let saveAlbumName = args["saveAlbumName"] as? String ?? ""

        let previewVC = PhotoPreviewPageViewController(
            assets: assets,
            selectedAssets: selectedAssets,
            initialIndex: initialIndex,
            sourceFrame: sourceFrame,
            config: config,
            downloadCallback: downloadCallback,
            downloadProgressCallback: downloadProgressCallback,
            saveAlbumName: saveAlbumName
        ) { updatedSelected, isOriginalPhoto in
            guard !updatedSelected.isEmpty else {
                completion(.success([
                    "items": [] as [[String: Any]],
                    "isOriginalPhoto": isOriginalPhoto,
                ] as [String: Any]))
                return
            }
            ExportManager.shared.batchExportThumbnails(for: updatedSelected) { results in
                completion(.success([
                    "items": PluginBridge.buildMediaItems(results),
                    "isOriginalPhoto": isOriginalPhoto,
                ] as [String: Any]))
            }
        }

        previewVC.onMaxCountReached = maxCountReachedCallback

        // 使用 .custom + transitioningDelegate，才能触发 PhotoPreviewAnimator 的飞入/飞回动画
        // .fullScreen 会让 UIKit 忽略 transitioningDelegate，导致自定义转场完全不生效
        previewVC.modalPresentationStyle = .custom
        previewVC.transitioningDelegate = previewVC
        previewVC.overrideUserInterfaceStyle = config.isDarkMode ? .dark : .light
        viewController.present(previewVC, animated: true)
    }

    // MARK: - getThumbnail
    // Flutter 传入: assetId, width, height
    // 返回: {thumbnailPath: String}

    func getThumbnail(
        args: [String: Any],
        completion: @escaping PluginCompletion
    ) {
        guard let assetId = args["assetId"] as? String else {
            completion(.failure(PhotoLibraryError.assetNotFound))
            return
        }
        let size = CGSize(
            width: args["width"] as? Double ?? 200,
            height: args["height"] as? Double ?? 200
        )
        ExportManager.shared.exportThumbnail(assetId: assetId, size: size) { result in
            switch result {
            case .success(let path):
                completion(.success(PluginBridge.buildThumbnailResult(path: path)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - exportAsset
    // Flutter 传入: assetId, format ("image" | "video" | "livePhotoVideo")
    // 返回: {filePath: String}

    func exportAsset(
        args: [String: Any],
        completion: @escaping PluginCompletion
    ) {
        guard let assetId = args["assetId"] as? String,
              let formatStr = args["format"] as? String,
              let format = ExportFormat(rawValue: formatStr)
        else {
            completion(.failure(PhotoLibraryError.invalidMediaType))
            return
        }
        ExportManager.shared.export(assetId: assetId, format: format) { result in
            switch result {
            case .success(let path):
                completion(.success(PluginBridge.buildExportResult(path: path)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}
