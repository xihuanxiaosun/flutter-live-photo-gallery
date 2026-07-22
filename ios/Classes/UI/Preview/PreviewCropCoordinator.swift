import UIKit
import Photos
import TOCropViewController

// MARK: - 裁剪宿主协议

/// 裁剪协调器回连预览页所需的最小能力集合。
///
/// 用协议而不是直接引用 `PhotoPreviewPageViewController`，是为了让预览页的
/// allAssets / currentIndex / config 等内部状态继续保持 private，只暴露裁剪流程
/// 真正需要的几个入口。协议继承自 `UIViewController`，因此协调器可以直接
/// present / dismiss，并访问 `presentationController`。
protocol PreviewCropHost: UIViewController {

    /// UIKit 为裁剪页创建的 UITransitionView。
    /// ⚠️ 必须存放在预览页上：`PhotoPreviewPresentationController.dismissalTransitionWillBegin`
    /// 也会读写它来处理「预览与裁剪同时消失」的竞态。
    var cropPresentationContainer: UIView? { get set }

    /// 当前是否允许发起裁剪（纯预览模式不提供裁剪入口）
    var isCropActionEnabled: Bool { get }

    /// 当前页资源；索引越界时返回 nil
    var currentCropTargetAsset: PhotoAssetModel? { get }

    /// 把裁剪结果应用到当前页
    func applyCroppedImage(_ image: UIImage)

    /// 底部轻提示
    func showCropToast(_ text: String)

    /// 错误弹窗
    func showCropFailureAlert(message: String)
}

// MARK: - 裁剪协调器

/// 预览页裁剪流程（TOCropViewController）的编排者与代理。
///
/// 抽出的原因：裁剪一次要串起「取可裁剪的原图 → 弹裁剪页 → 回写结果 → 收拾 UIKit
/// 遗留的转场容器」四件事，其中最后一步依赖自定义转场的实现细节，和预览页的翻页、
/// 选择逻辑完全无关。集中在一个类里可以让这段易碎逻辑一眼看全。
///
/// 因为 `TOCropViewControllerDelegate` 是 Objective-C 协议，本类必须继承 NSObject；
/// 又因为 `TOCropViewController.delegate` 是 weak，宿主必须强持有本对象。
final class PreviewCropCoordinator: NSObject, TOCropViewControllerDelegate {

    /// 宿主预览页（弱引用：宿主强持有本对象）
    private weak var host: PreviewCropHost?

    init(host: PreviewCropHost) {
        self.host = host
        super.init()
    }

    // MARK: - 入口

    /// 对当前页资源发起裁剪（非选择模式、索引越界、非图片资源均直接忽略）
    func startCropping() {
        guard let host = host,
              host.isCropActionEnabled,
              let asset = host.currentCropTargetAsset else { return }
        guard case .image = asset.mediaType else { return }

        loadCroppableImage(for: asset) { [weak self] image in
            guard let self = self, let image = image else {
                self?.host?.showCropFailureAlert(message: "当前资源无法裁剪")
                return
            }

            self.presentCropViewController(with: image)
        }
    }

    private func presentCropViewController(with image: UIImage) {
        guard let host = host else { return }

        let cropVC = TOCropViewController(image: image)
        cropVC.delegate = self
        cropVC.aspectRatioLockEnabled = false
        cropVC.resetAspectRatioEnabled = true
        cropVC.rotateButtonsHidden = true
        // Use .overFullScreen to avoid disturbing the underlying .custom presentation's
        // containerView hierarchy, which would break the dismiss transition.
        cropVC.modalPresentationStyle = .overFullScreen
        host.present(cropVC, animated: true) { [weak self, weak cropVC] in
            // Capture crop's UITransitionView after presentation completes.
            // UIKit adds cropVC.view to a new UITransitionView (the container).
            // We need this reference to remove it manually after crop dismisses,
            // because UIKit's default cleanup is broken in our custom-presentation context.
            self?.host?.cropPresentationContainer = cropVC?.view.superview
        }
    }

    // MARK: - 取原图

    private func loadCroppableImage(for asset: PhotoAssetModel, completion: @escaping (UIImage?) -> Void) {
        let finishOnMain: (UIImage?) -> Void = { image in
            DispatchQueue.main.async {
                completion(image)
            }
        }

        switch asset.sourceType {
        case .photoLibrary(let phAsset):
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            options.resizeMode = .none
            options.version = .current
            PHImageManager.default().requestImageDataAndOrientation(
                for: phAsset,
                options: options
            ) { data, _, _, _ in
                finishOnMain(data.flatMap { UIImage(data: $0) })
            }
        case .network(let url, _):
            if let editedPath = asset.editedPath,
               !editedPath.isEmpty,
               FileManager.default.fileExists(atPath: editedPath) {
                finishOnMain(UIImage(contentsOfFile: editedPath))
                return
            }
            asset.editedPath = nil
            PhotoLibraryManager.shared.loadNetworkImage(from: url) { result in
                finishOnMain(try? result.get())
            }
        case .localFile(let url, _):
            if let editedPath = asset.editedPath,
               !editedPath.isEmpty,
               FileManager.default.fileExists(atPath: editedPath) {
                finishOnMain(UIImage(contentsOfFile: editedPath))
                return
            }
            asset.editedPath = nil
            finishOnMain(UIImage(contentsOfFile: url.path))
        }
    }

    // MARK: - 回写裁剪结果

    /// 相册资源写回照片库，网络/本地文件写成临时 JPEG；两条分支都要更新
    /// `editedPath` / `needsThumbnailRefresh`，网格页据此刷新缩略图。
    private func persistCroppedImage(
        _ image: UIImage,
        for asset: PhotoAssetModel,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        switch asset.sourceType {
        case .photoLibrary(let phAsset):
            PhotoLibraryManager.shared.persistEditedImage(image, for: phAsset) { [weak self] result in
                switch result {
                case .success:
                    self?.clearTemporaryEditedFile(for: asset)
                    asset.needsThumbnailRefresh = true
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        case .network, .localFile:
            do {
                try writeTemporaryEditedImage(image, for: asset)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func writeTemporaryEditedImage(_ image: UIImage, for asset: PhotoAssetModel) throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lpg_crop_\(UUID().uuidString).jpg")
        guard let data = image.opaque().jpegData(compressionQuality: 0.92) else {
            throw PhotoLibraryError.exportFailed(
                underlying: NSError(
                    domain: "PhotoPreviewPageViewController",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "无法生成裁剪结果"]
                )
            )
        }

        try data.write(to: fileURL, options: .atomic)
        clearTemporaryEditedFile(for: asset)
        asset.editedPath = fileURL.path
        asset.needsThumbnailRefresh = true
    }

    private func clearTemporaryEditedFile(for asset: PhotoAssetModel) {
        guard let old = asset.editedPath, !old.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: old)
        asset.editedPath = nil
    }

    // MARK: - 关闭裁剪页

    private func dismissCropViewController(
        _ cropViewController: TOCropViewController,
        completion: (() -> Void)? = nil
    ) {
        cropViewController.dismiss(animated: true) { [weak self] in
            self?.cleanupOrphanedWindowContainers()
            completion?()
        }
    }

    /// Restores the preview VC's view to its own UITransitionView and removes the
    /// orphaned crop-presentation container.
    ///
    /// When a `.overFullScreen` VC (crop) is presented from a custom-presentation VC
    /// (preview, using `shouldRemovePresentersView = false`), UIKit moves the preview
    /// VC's view INTO the crop's UITransitionView to maintain the visual stack.
    /// On crop dismiss, UIKit removes the crop container (taking the preview view with
    /// it), leaving the preview's own UITransitionView empty in the window — which then
    /// blocks all touch input.
    ///
    /// Fix: move the preview view back into its own container, then remove the now-empty
    /// crop container.
    private func cleanupOrphanedWindowContainers() {
        guard let host = host, let cropContainer = host.cropPresentationContainer else { return }

        // If our view ended up inside the crop container (UIKit moved it there),
        // restore it to our own UITransitionView before removing the crop container.
        if let myContainer = host.presentationController?.containerView,
           host.view.superview === cropContainer {
            host.view.frame = myContainer.bounds
            myContainer.addSubview(host.view)   // reparents: crop container → preview container
        }

        cropContainer.removeFromSuperview()
        host.cropPresentationContainer = nil
    }

    // MARK: - TOCropViewControllerDelegate

    func cropViewController(
        _ cropViewController: TOCropViewController,
        didCropTo image: UIImage,
        with cropRect: CGRect,
        angle: Int
    ) {
        _ = cropRect
        _ = angle
        guard let asset = host?.currentCropTargetAsset else {
            dismissCropViewController(cropViewController)
            return
        }

        persistCroppedImage(image, for: asset) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.host?.applyCroppedImage(image)
                self.dismissCropViewController(cropViewController) {
                    self.host?.showCropToast("裁剪完成")
                }
            case .failure(let error):
                self.dismissCropViewController(cropViewController) { [weak self] in
                    self?.host?.showCropFailureAlert(message: error.localizedDescription)
                }
            }
        }
    }

    func cropViewController(_ cropViewController: TOCropViewController, didFinishCancelled cancelled: Bool) {
        _ = cancelled
        dismissCropViewController(cropViewController)
    }
}
