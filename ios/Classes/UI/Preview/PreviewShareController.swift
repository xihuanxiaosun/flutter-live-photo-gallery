import UIKit
import Photos
import AVFoundation

// MARK: - 预览页分享流程

/// 预览页「分享」按钮背后的完整流程持有者。
///
/// 单独成型的原因：`PHAsset` 并不符合 `UIActivityItemSource`，直接塞进
/// `UIActivityViewController` 会让接收方拿不到任何内容，因此相册资源必须先异步取出
/// 可分享的 `UIImage` / 视频文件 URL 再弹面板。这段取数 + 弹面板的逻辑与预览控制器
/// 的翻页、布局职责无关，抽出后 `PhotoPreviewPageViewController` 只保留一行转发。
final class PreviewShareController {

    /// 弹出分享面板的宿主控制器（弱引用：宿主持有本对象，避免形成循环）
    private weak var host: UIViewController?

    /// iPad 上 popover 的锚点视图，即预览页顶栏的分享按钮
    private let sourceView: UIView

    /// 取当前页资源；索引越界或列表为空时返回 nil，此时不弹面板
    private let assetProvider: () -> PhotoAssetModel?

    init(
        host: UIViewController,
        sourceView: UIView,
        assetProvider: @escaping () -> PhotoAssetModel?
    ) {
        self.host = host
        self.sourceView = sourceView
        self.assetProvider = assetProvider
    }

    /// 分享当前页资源：网络 / 本地文件直接分享 URL，相册资源先异步取出可分享内容
    func shareCurrentAsset() {
        guard let asset = assetProvider() else { return }

        switch asset.sourceType {
        case .network(let url, _):
            presentShare(items: [url])
        case .localFile(let url, _):
            presentShare(items: [url])
        case .photoLibrary(let phAsset):
            // PHAsset 不符合 UIActivityItemSource，直接分享会导致接收方拿不到任何内容。
            // 先异步取出可分享的 UIImage / 视频文件 URL，再弹分享面板。
            shareLibraryAsset(phAsset)
        }
    }

    /// 从相册资源取出可分享内容后再弹分享面板（图片→UIImage，视频→文件 URL）
    private func shareLibraryAsset(_ phAsset: PHAsset) {
        if phAsset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { [weak self] avAsset, _, _ in
                let url = (avAsset as? AVURLAsset)?.url
                DispatchQueue.main.async {
                    guard let self = self, let url = url else { return }
                    self.presentShare(items: [url])
                }
            }
        } else {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImage(
                for: phAsset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { [weak self] image, info in
                // 忽略 opportunistic 先返回的降质图，只用最终高清图，避免弹两次分享面板
                if (info?[PHImageResultIsDegradedKey] as? Bool) ?? false { return }
                DispatchQueue.main.async {
                    guard let self = self, let image = image else { return }
                    self.presentShare(items: [image])
                }
            }
        }
    }

    private func presentShare(items: [Any]) {
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        host?.present(activityVC, animated: true)
    }
}
