import UIKit
import PhotosUI

// MARK: - 相册 Live Photo 原生播放器

/// 用 `PHLivePhotoView` 覆盖在封面图之上，原生播放相册（`.photoLibrary`）来源的 Live Photo。
///
/// 仅服务于 `.photoLibrary`——只有它能通过 `PHImageManager.requestLivePhoto` 拿到真正的
/// `PHLivePhoto`。`.network` / `.localFile` 只有「静态封面 + MOV 链接」，没有真正的
/// `PHLivePhoto`，因此仍走 `PreviewVideoPlayerController` 的 AVPlayer 路径。
///
/// ⚠️ 播放代次（generation）不在本类：它是 `PreviewVideoPlayerController` 的单一状态。
/// 本类只负责「显示 / 播放 / 移除」`PHLivePhotoView`，不感知手指抬起的时序；
/// 是否真正开始播放由页面在请求回调里用 videoPlayerController 的代次守卫决定。
///
/// 本类不创建除 `PHLivePhotoView` 以外的任何视图：封面图由页面注入，
/// 播放时本类淡出它、停止时由外部（`PreviewVideoPlayerController.stopVideo()`）淡回。
final class PreviewLivePhotoPlayer {

    /// `PHLivePhotoView` 挂载的宿主视图（即页面 view，与旧路径的 AVPlayerLayer 同一位置）
    private let hostView: UIView

    /// 播放时淡出的封面图；淡回由外部 stopVideo() 负责，保持「谁的视图谁动」的边界
    private let imageView: UIImageView

    /// 当前正在播放的 `PHLivePhotoView`；停止时淡出移除并置空
    private var livePhotoView: PHLivePhotoView?

    init(hostView: UIView, imageView: UIImageView) {
        self.hostView = hostView
        self.imageView = imageView
    }

    /// 覆盖一个 `PHLivePhotoView` 在封面图之上并从头播放全程，同时淡出封面图。
    /// 重复调用时先移除旧视图，避免图层叠加。
    func play(_ livePhoto: PHLivePhoto) {
        livePhotoView?.stopPlayback()
        livePhotoView?.removeFromSuperview()

        let lpView = PHLivePhotoView(frame: hostView.bounds)
        lpView.contentMode = .scaleAspectFit
        lpView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        lpView.livePhoto = livePhoto
        hostView.addSubview(lpView)
        self.livePhotoView = lpView

        UIView.animate(withDuration: UIConstants.Animation.fadeInOutDuration) {
            self.imageView.alpha = 0
        }

        lpView.startPlayback(with: .full)
    }

    /// 停止播放并移除 `PHLivePhotoView`（封面图的淡回由外部 stopVideo() 负责）。
    /// 先 stopPlayback 回到关键帧静止图，再随封面图淡入交叉淡出移除，避免整页闪黑。
    func stop() {
        guard let lpView = livePhotoView else { return }
        livePhotoView = nil

        lpView.stopPlayback()
        UIView.animate(withDuration: UIConstants.Animation.fadeInOutDuration, animations: {
            lpView.alpha = 0
        }) { _ in
            lpView.removeFromSuperview()
        }
    }
}
