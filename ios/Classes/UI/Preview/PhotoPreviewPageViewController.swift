import UIKit
import Photos
import AVFoundation

// MARK: - 单张照片预览控制器

class SinglePhotoViewController: UIViewController {
    
    let asset: PhotoAssetModel
    let config: PickerConfig
    var isSelected: Bool
    
    lazy var scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.delegate = self
        sv.minimumZoomScale = UIConstants.Preview.minimumZoomScale
        sv.maximumZoomScale = UIConstants.Preview.maximumZoomScale
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.contentInsetAdjustmentBehavior = .never
        sv.alwaysBounceVertical = false
        sv.alwaysBounceHorizontal = false
        return sv
    }()
    
    let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        return iv
    }()

    /// 播放器栈（AVPlayer / AVPlayerLayer / 三类观察者）的持有者。
    /// 懒加载：只有视频页加载素材、或长按播放 Live Photo 时才创建，
    /// 页面释放时随之析构并拆除观察者。
    /// ⚠️ 纯图片页必须永远不触发本属性：viewWillDisappear 每页都会调 stopVideo()，
    /// 若转发时不先判断 hasVideoPlayerController，200 张的相册就会实例化 200 个控制器。
    private lazy var videoPlayerController: PreviewVideoPlayerController = {
        self.hasVideoPlayerController = true
        return PreviewVideoPlayerController(
            hostView: self.view,
            scrollView: self.scrollView,
            imageView: self.imageView,
            playButton: self.playButton,
            controlsView: self.videoControlsView,
            loadingIndicator: self.loadingIndicator
        )
    }()

    /// videoPlayerController 是否已实例化；读它不会触发懒加载，
    /// 因此可以在转发前安全地判断「这一页到底有没有播放器」。
    private var hasVideoPlayerController = false

    /// 相册 Live Photo 的原生播放器（PHLivePhotoView）。
    /// 懒加载：只有 .photoLibrary 来源长按播放 Live Photo 时才创建，纯图片/视频页不触发。
    /// 代次由 videoPlayerController 统一持有，本播放器只负责显示/移除 PHLivePhotoView。
    private lazy var livePhotoPlayer: PreviewLivePhotoPlayer = {
        self.hasLivePhotoPlayer = true
        return PreviewLivePhotoPlayer(hostView: self.view, imageView: self.imageView)
    }()

    /// livePhotoPlayer 是否已实例化；读它不会触发懒加载，纯视频页 stopVideo() 据此免于空转实例化。
    private var hasLivePhotoPlayer = false

    private var isLoadingVideo = false  // 防止异步加载期间重复触发

    /// 是否已展示过首帧图片。opportunistic 会多次回调（先降质后高清），
    /// 只在首次拿到非空图片时做交叉淡入，后续升清直接替换避免每次闪烁。
    private var hasDisplayedImage = false

    /// 记录 PHImageManager 的图片请求 ID，页面消失时取消以释放内存压力
    private var imageRequestID: PHImageRequestID?
    /// 记录视频资源请求 ID，页面消失时取消
    private var videoRequestID: PHImageRequestID?
    /// 记录 Live Photo 请求 ID，页面消失时取消，避免回调乱序与内存积压
    private var livePhotoRequestID: PHImageRequestID?

    // 视频控制 UI
    private let playButton: UIButton = {
        let button = UIButton(type: .custom)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        button.layer.cornerRadius = 35
        button.isHidden = true
        return button
    }()

    /// 视频底部控制条（播放/暂停 + 时间 + 可拖动进度）。
    /// 由页面创建并注入 videoPlayerController；纯图片页始终隐藏，不产生播放器。
    private let videoControlsView: PreviewVideoControlsView = {
        let controls = PreviewVideoControlsView()
        controls.isHidden = true
        return controls
    }()

    // 加载指示器
    private let loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.color = .white
        indicator.hidesWhenStopped = true
        return indicator
    }()

    /// 图片加载失败时的错误浮层（懒加载）：居中的警示图标 +「加载失败，点按重试」文案，
    /// 半透明深色圆角背景，整块可点。仅在真正失败时才创建并加入视图层级，
    /// 成功的纯图片页永不实例化；点按即重跑 imageRetryAction 记录的加载动作。
    private var imageErrorOverlay: UIControl?

    /// 错误浮层「点按重试」要重跑的加载动作：网络图失败重跑 loadNetworkImage，
    /// 本地文件失败重跑 loadImage()。展示浮层时按来源写入，点按时执行。
    private var imageRetryAction: (() -> Void)?

    init(asset: PhotoAssetModel, config: PickerConfig, isSelected: Bool) {
        self.asset = asset
        self.config = config
        self.isSelected = isSelected
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        setupUI()
        loadImage()

        if asset.isVideo {
            loadVideo()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从 UIPageViewController 滑回视频页时，重新加载播放器
        // isLoadingVideo 防止 viewDidLoad 的异步请求还未完成时再次触发
        if asset.isVideo && !videoPlayerController.hasPlayer && !isLoadingVideo {
            loadVideo()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopVideo()
        // 复位错误浮层，避免复用的页面翻回时残留上一轮的加载失败态
        hideImageErrorOverlay()
        // 取消未完成的 PHImageManager 请求，快速翻页时避免回调乱序和内存积压
        if let id = imageRequestID {
            PHImageManager.default().cancelImageRequest(id)
            imageRequestID = nil
        }
        if let id = videoRequestID {
            PHImageManager.default().cancelImageRequest(id)
            videoRequestID = nil
        }
        if let id = livePhotoRequestID {
            PHImageManager.default().cancelImageRequest(id)
            livePhotoRequestID = nil
        }
    }

    private func setupUI() {
        view.addSubview(scrollView)
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        scrollView.addSubview(imageView)
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // 添加播放按钮
        view.addSubview(playButton)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 70),
            playButton.heightAnchor.constraint(equalToConstant: 70)
        ])
        playButton.addTarget(self, action: #selector(playButtonTapped), for: .touchUpInside)

        // 添加视频控制条：贴底部安全区。选择模式下父级底栏（原图/裁剪/完成）会盖在
        // pageViewController 之上，故此处把控制条抬到父级底栏上方（54pt 内容高 + 间距），
        // 避免滑块被遮住无法拖动；纯预览模式没有父级底栏，则贴近底部即可。
        view.addSubview(videoControlsView)
        videoControlsView.translatesAutoresizingMaskIntoConstraints = false
        let controlsBottomInset: CGFloat = config.showRadio ? 62 : 12
        NSLayoutConstraint.activate([
            videoControlsView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            videoControlsView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            videoControlsView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                                      constant: -controlsBottomInset),
            videoControlsView.heightAnchor.constraint(equalToConstant: 44)
        ])

        // 添加加载指示器
        view.addSubview(loadingIndicator)
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        // 视频播放/暂停通过 playButton 控制，不额外添加点击手势（避免与父级 bar 切换手势冲突）

        // 双击复原缩放
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }
    
    func loadImage() {
        // 显示加载指示器
        loadingIndicator.startAnimating()
        // 一次新的加载开始：清掉上一轮可能残留的错误浮层
        hideImageErrorOverlay()

        switch asset.sourceType {
        case .photoLibrary(let phAsset):
            asset.editedPath = nil
            loadPhotoLibraryImage(phAsset)
        case .network(let url, let mediaType):
            if let editedURL = existingEditedImageURL() {
                loadLocalFileImage(editedURL, mediaType: .image)
                return
            }
            loadNetworkImage(url, mediaType: mediaType)
        case .localFile(let url, let mediaType):
            if let editedURL = existingEditedImageURL() {
                loadLocalFileImage(editedURL, mediaType: .image)
                return
            }
            loadLocalFileImage(url, mediaType: mediaType)
        }
    }

    func applyEditedImage(_ image: UIImage, animated: Bool = true) {
        loadingIndicator.stopAnimating()

        // 裁剪后新图长宽比可能与原图不同：先复位缩放并让 imageView 重新铺满可视区，
        // 对齐首次加载的布局（imageView.frame == scrollView.bounds + scaleAspectFit 居中），
        // 否则新图会被 letterbox 在旧的 frame 里。
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        scrollView.contentOffset = .zero
        imageView.frame = scrollView.bounds

        let updates = {
            self.imageView.image = image
            self.imageView.alpha = 1
        }

        guard animated, imageView.image != nil else {
            updates()
            return
        }

        UIView.transition(
            with: imageView,
            duration: 0.18,
            options: [.transitionCrossDissolve, .beginFromCurrentState, .allowAnimatedContent],
            animations: updates
        )
    }

    private func existingEditedImageURL() -> URL? {
        guard let editedPath = asset.editedPath, !editedPath.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: editedPath) else {
            asset.editedPath = nil
            return nil
        }
        return URL(fileURLWithPath: editedPath)
    }

    private func loadPhotoLibraryImage(_ phAsset: PHAsset) {
        // 取消上一次未完成的请求，快速翻页时避免内存积压
        if let prev = imageRequestID {
            PHImageManager.default().cancelImageRequest(prev)
            imageRequestID = nil
        }

        let options = PHImageRequestOptions()
        // opportunistic：先回调一张降质图立即显示、再回调最终高清图升清，
        // 避免 highQualityFormat 下「先空白转圈、最后高清图突兀弹入」的闪现。
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.resizeMode = .exact
        options.version = .current

        imageRequestID = PHImageManager.default().requestImage(
            for: phAsset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { [weak self] image, info in
            // opportunistic 下本回调会被多次调用：先降质、后高清。
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 任何一张图片（含降质）到手即停转圈；最终回调即便无图也停，避免卡死。
                if image != nil || !isDegraded {
                    self.loadingIndicator.stopAnimating()
                }
                self.setImageCrossfadingIfFirst(image)
                // 仅在最终高清回调时清空 requestID；降质回调保留 ID，
                // 让 viewWillDisappear 仍能取消尚未返回的高清请求。
                if !isDegraded {
                    self.imageRequestID = nil
                }
            }
        }
    }

    /// 首帧图片交叉淡入：第一次拿到非空图片时用 0.2s 交叉溶解淡入，消除首次打开/翻页的空白闪现；
    /// 之后的（opportunistic 升清）赋值直接替换，避免每次升清都闪一下。
    private func setImageCrossfadingIfFirst(_ image: UIImage?) {
        guard let image = image else { return }
        // 成功拿到图片（含降质首帧）：移除可能残留的错误浮层
        hideImageErrorOverlay()
        guard !hasDisplayedImage else {
            imageView.image = image
            return
        }
        hasDisplayedImage = true
        UIView.transition(
            with: imageView,
            duration: 0.2,
            options: [.transitionCrossDissolve, .beginFromCurrentState]
        ) {
            self.imageView.image = image
        }
    }

    private func loadNetworkImage(_ url: URL, mediaType: PhotoAssetModel.MediaType) {
        // 三种 mediaType 的网络封面加载逻辑相同：拉取封面图展示。
        // （视频/实况的播放另走 videoUrl，与此处封面加载无关。）
        PhotoLibraryManager.shared.loadNetworkImage(from: url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loadingIndicator.stopAnimating()
                if case .success(let image) = result {
                    self.setImageCrossfadingIfFirst(image)
                } else {
                    // 网络封面加载失败：展示错误浮层，点按重试重跑本次网络加载
                    self.showImageErrorOverlay { [weak self] in
                        self?.loadNetworkImage(url, mediaType: mediaType)
                    }
                }
            }
        }
    }

    private func loadLocalFileImage(_ url: URL, mediaType: PhotoAssetModel.MediaType) {
        switch mediaType {
        case .image, .livePhoto:
            if let image = UIImage(contentsOfFile: url.path) {
                setImageCrossfadingIfFirst(image)
                loadingIndicator.stopAnimating()
            } else {
                // 本地文件读取失败（文件缺失/损坏）：展示错误浮层，点按重试重跑 loadImage()
                showImageErrorOverlay { [weak self] in
                    self?.loadImage()
                }
            }
        case .video:
            let asset = AVURLAsset(url: url)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true

            // 使用 iOS 15 兼容写法（image(at:) 仅 iOS 16+）
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var actualTime = CMTime.zero
                let cgImage = try? imageGenerator.copyCGImage(at: .zero, actualTime: &actualTime)
                DispatchQueue.main.async {
                    self?.imageView.image = cgImage.map { UIImage(cgImage: $0) }
                    self?.loadingIndicator.stopAnimating()
                }
            }
        }
    }

    // MARK: - 图片加载失败浮层

    /// 展示错误浮层并停转圈；retry 为点按重试时要重跑的加载动作（按来源不同）。
    private func showImageErrorOverlay(retry: @escaping () -> Void) {
        imageRetryAction = retry
        loadingIndicator.stopAnimating()
        let overlay = imageErrorOverlay ?? makeImageErrorOverlay()
        overlay.isHidden = false
        view.bringSubviewToFront(overlay)
    }

    /// 隐藏错误浮层；未创建过则直接返回，避免为了隐藏而懒加载实例化。
    private func hideImageErrorOverlay() {
        imageErrorOverlay?.isHidden = true
    }

    private func makeImageErrorOverlay() -> UIControl {
        // 整块浮层用 UIControl：点按（.touchUpInside）即重试。同时它命中父级 pan/单击手势的
        // 「落在 UIControl 上就让行」判断（gestureRecognizer(_:shouldReceive:)），因此卡片区域内
        // 不会误触发下拉关闭 / bar 显隐，正好把点按留给重试；隐藏时 isHidden 使其不参与命中测试，
        // 不影响下拉关闭与双击。
        let overlay = UIControl()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        overlay.layer.cornerRadius = 12
        overlay.isHidden = true

        let icon = UIImageView(image: UIImage(
            systemName: "exclamationmark.triangle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        ))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "加载失败，点按重试"
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .center
        stack.isUserInteractionEnabled = false  // 让点按落到 overlay 自身
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)

        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -24),
        ])

        overlay.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            // 点按重试：先隐藏浮层并重新转圈，再重跑对应来源的加载动作
            self.hideImageErrorOverlay()
            self.loadingIndicator.startAnimating()
            self.imageRetryAction?()
        }, for: .touchUpInside)

        imageErrorOverlay = overlay
        return overlay
    }

    // MARK: - Video Loading & Playback

    private func loadVideo() {
        switch asset.sourceType {
        case .photoLibrary(let phAsset):
            loadPhotoLibraryVideo(phAsset)
        case .network(let coverUrl, let mediaType):
            guard case .video(_, let videoURL) = mediaType else { return }
            let playURL = videoURL ?? coverUrl
            DispatchQueue.main.async { self.videoPlayerController.setupVideoPlayer(with: playURL) }
        case .localFile(let url, _):
            DispatchQueue.main.async { self.videoPlayerController.setupVideoPlayer(with: url) }
        }
    }

    private func loadPhotoLibraryVideo(_ phAsset: PHAsset) {
        // 取消上一次未完成的视频请求
        if let prev = videoRequestID {
            PHImageManager.default().cancelImageRequest(prev)
            videoRequestID = nil
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        isLoadingVideo = true
        videoRequestID = PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { [weak self] avAsset, _, _ in
            guard let self = self, let urlAsset = avAsset as? AVURLAsset else {
                DispatchQueue.main.async { self?.isLoadingVideo = false }
                return
            }

            DispatchQueue.main.async {
                self.videoRequestID = nil
                self.isLoadingVideo = false
                self.videoPlayerController.setupVideoPlayer(with: urlAsset.url)
            }
        }
    }

    @objc private func playButtonTapped() {
        videoPlayerController.togglePlayPause()
    }

    // MARK: - Live Photo 播放

    // 相册来源用 PHLivePhotoView 原生播放；网络/本地来源没有真正的 PHLivePhoto，
    // 仍走 videoPlayerController 的 AVPlayer 路径。播放状态机（是否播放中、播放代次）
    // 全部封装在 videoPlayerController，页面只负责把代次原样回传/比对。

    func playLivePhoto() {
        guard asset.isLivePhoto else { return }
        // 已在播放中则直接忽略本次长按（去重）
        guard let generation = videoPlayerController.beginLivePhotoPlayback() else { return }

        switch asset.sourceType {
        case .photoLibrary:
            playPhotoLibraryLivePhoto(generation: generation)
        case .network(_, let mediaType):
            if case .livePhoto(let videoURL) = mediaType, let videoURL = videoURL {
                DispatchQueue.main.async {
                    self.videoPlayerController.playVideoDirectly(url: videoURL, generation: generation)
                }
            } else {
                videoPlayerController.abortLivePhotoPlayback()
            }
        case .localFile(_, let mediaType):
            if case .livePhoto(let videoURL) = mediaType, let videoURL = videoURL {
                DispatchQueue.main.async {
                    self.videoPlayerController.playVideoDirectly(url: videoURL, generation: generation)
                }
            } else {
                videoPlayerController.abortLivePhotoPlayback()
            }
        }
    }

    private func playPhotoLibraryLivePhoto(generation: Int) {
        guard let phAsset = asset.asset else {
            videoPlayerController.abortLivePhotoPlayback()
            return
        }

        // 取消上一次未完成的 Live Photo 请求，快速长按/翻页时避免回调乱序
        if let prev = livePhotoRequestID {
            PHImageManager.default().cancelImageRequest(prev)
            livePhotoRequestID = nil
        }

        let options = PHLivePhotoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        // generation 为本次播放代次；抬指(stopVideo)会自增代次。
        // 请求返回后据此比对：手指已抬起或已开始新一轮播放时整个结果作废，绝不开始播放。
        livePhotoRequestID = PHImageManager.default().requestLivePhoto(
            for: phAsset,
            targetSize: livePhotoTargetSize(),
            contentMode: .aspectFit,
            options: options
        ) { [weak self] livePhoto, info in
            guard let self = self else { return }
            // 忽略 opportunistic 先返回的降质版本，只在最终高清结果上开始播放
            if (info?[PHImageResultIsDegradedKey] as? Bool) ?? false { return }

            DispatchQueue.main.async {
                // 代次比对必须先于一切副作用（含清空 requestID）：过期结果既不播放、
                // 也不能清空 livePhotoRequestID——否则旧请求的迟到回调会把新一轮请求的
                // ID 抹掉，导致新请求无法在 viewWillDisappear 被取消（请求泄漏至完成）。
                guard self.videoPlayerController.isPlaybackGenerationCurrent(generation) else { return }
                self.livePhotoRequestID = nil
                guard let livePhoto = livePhoto else {
                    self.videoPlayerController.abortLivePhotoPlayback()
                    return
                }
                self.livePhotoPlayer.play(livePhoto)
            }
        }
    }

    /// PHLivePhoto 请求的目标尺寸：按屏幕像素取 view 的物理尺寸，取不到时退回最大尺寸。
    private func livePhotoTargetSize() -> CGSize {
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return PHImageManagerMaximumSize }
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    /// 停止播放并复原封面图；预览页翻页 / 抬指时由外部调用。
    /// 从未播放过的页面（纯图片页）不会因此实例化任何播放器。
    ///
    /// - videoPlayerController.stopVideo() 自增播放代次（作废进行中的 Live Photo 请求回调）、
    ///   拆除 AVPlayer 观察者、把封面图淡回 alpha 1；
    /// - livePhotoPlayer.stop() 移除相册来源的 PHLivePhotoView。
    /// 两者各管各的视图，代次这一单一状态只由 videoPlayerController 持有。
    func stopVideo() {
        guard hasVideoPlayerController else { return }
        videoPlayerController.stopVideo()
        if hasLivePhotoPlayer {
            livePhotoPlayer.stop()
        }
    }

    /// 由 PageViewController 宿主在「本页成为当前可见页」时调用：
    /// 满足 autoPlayVideo 配置且为真视频时，武装播放器的自动播放（就绪即播）。
    /// 相册 Live Photo 不在此列（那是长按微视频）。武装是幂等的：
    /// 播放器尚未创建时仅置位，viewDidLoad/viewWillAppear 的 loadVideo 就绪后消费。
    func activateIfCurrent() {
        guard config.autoPlayVideo, asset.isVideo else { return }
        videoPlayerController.enableAutoPlayOnReady()
    }
}

extension SinglePhotoViewController: UIScrollViewDelegate {

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // 缩放时居中图片
        let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
        imageView.center = CGPoint(
            x: scrollView.contentSize.width / 2 + offsetX,
            y: scrollView.contentSize.height / 2 + offsetY
        )
    }

    // MARK: - 双击复原

    @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        // 没有可缩放空间（max <= min）时忽略双击
        guard scrollView.maximumZoomScale > scrollView.minimumZoomScale else { return }

        if scrollView.zoomScale > scrollView.minimumZoomScale {
            // 已放大：弹回最小缩放（保留弹簧动画）
            UIView.animate(
                withDuration: 0.3,
                delay: 0,
                usingSpringWithDamping: 0.85,
                initialSpringVelocity: 0.3,
                options: .curveEaseInOut
            ) {
                self.scrollView.setZoomScale(self.scrollView.minimumZoomScale, animated: false)
                self.scrollView.contentOffset = .zero
            }
        } else {
            // 处于最小缩放：以双击点为中心放大到目标倍率
            let targetScale = min(scrollView.maximumZoomScale,
                                  max(scrollView.minimumZoomScale * 3, 2.5))
            let point = gesture.location(in: imageView)
            let width = scrollView.bounds.width / targetScale
            let height = scrollView.bounds.height / targetScale
            let rect = CGRect(x: point.x - width / 2,
                              y: point.y - height / 2,
                              width: width,
                              height: height)
            scrollView.zoom(to: rect, animated: true)
        }
    }
}

// MARK: - 主预览控制器

class PhotoPreviewPageViewController: UIViewController {

    private let allAssets: [PhotoAssetModel]
    private var selectedAssets: [PhotoAssetModel]
    private let config: PickerConfig
    private let completion: ([PhotoAssetModel], Bool) -> Void

    /// UIKit 为裁剪页（TOCropViewController）创建的 UITransitionView。
    /// 自定义转场下（`shouldRemovePresentersView = false`）UIKit 不会在裁剪页消失时
    /// 移除这个容器，必须由我们手动清理，否则窗口里残留一个空的 UITransitionView，
    /// 吞掉之后所有的触摸事件。
    ///
    /// ⚠️ 这是「裁剪协调器」与「转场控制器」之间的共享状态，共有三个写入方：
    /// - `PreviewCropCoordinator.presentCropViewController`：弹出裁剪页后记录容器；
    /// - `PreviewCropCoordinator.cleanupOrphanedWindowContainers`：裁剪页正常关闭后清理并置空；
    /// - `PhotoPreviewPresentationController.dismissalTransitionWillBegin`：
    ///   「裁剪页还在关闭途中，预览页就被关掉」的竞态下抢先清理并置空。
    ///
    /// 因此它只能存放在预览页上——两个协作者都能拿到预览页，却拿不到彼此；
    /// 一旦下沉进协调器，上述竞态就会漏掉清理，留下吞噬触摸的孤儿容器。
    var cropPresentationContainer: UIView?

    /// 保存网络图片完成后的回调（nil = 不显示下载按钮）
    private let downloadCallback: (([String: Any]) -> Void)?

    /// 下载进度回调：["url": String, "progress": Double(0~1)]
    private let downloadProgressCallback: (([String: Any]) -> Void)?

    /// 用户尝试超出 maxCount 时触发（参数为 maxCount 值）
    var onMaxCountReached: ((Int) -> Void)?

    /// 保存图片时使用的相册名称，空串 = 仅存到「最近项目」，非空 = 同时加入同名相册
    private let saveAlbumName: String

    /// 网络图片「下载 + 写入相册」的执行者（持有下载任务的进度观察者）
    private let saveService = NetworkImageSaveService()

    /// 分享流程的执行者（懒加载：首次点分享时才连同锚点按钮一起创建）
    private lazy var shareController = PreviewShareController(
        host: self,
        sourceView: shareButton,
        assetProvider: { [weak self] () -> PhotoAssetModel? in
            guard let self = self,
                  !self.allAssets.isEmpty,
                  self.currentIndex < self.allAssets.count else { return nil }
            return self.allAssets[self.currentIndex]
        }
    )

    /// 裁剪流程的编排者兼 TOCropViewController 代理（代理为 weak，必须在此强持有）
    private lazy var cropCoordinator = PreviewCropCoordinator(host: self)

    private var currentIndex: Int
    /// 打开预览时的初始索引。翻页后 sourceFrame 已过期，仅当仍停在此页时才允许飞回缩略图。
    private let initialIndex: Int
    private var sourceFrame: CGRect
    var pageViewController: UIPageViewController!
    var currentPhotoVC: SinglePhotoViewController?

    private var panGesture: UIPanGestureRecognizer!
    private var barToggleTap: UITapGestureRecognizer!
    private var isInteractiveDismissing = false
    private var barsVisibleBeforeInteractiveDismiss = true
    private(set) var dismissalBackgroundAlpha: CGFloat = 1.0
    
    // MARK: - Bar State

    private var barsVisible = true
    private var isOriginalPhoto = false

    // MARK: - UI Components

    // 顶部栏：从 view.top 延伸至 safeArea.top + 44，覆盖状态栏实现沉浸式效果
    private let topBar: UIVisualEffectView = {
        UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    }()

    private let closeButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        config.baseForegroundColor = .white
        return UIButton(configuration: config)
    }()

    private let selectButton: UIButton = {
        UIButton(type: .custom)
    }()

    private let countLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        return label
    }()

    /// 分享按钮：现两种模式均隐藏（见 updateUI）；视图与 PreviewShareController 保留待用。
    private lazy var shareButton: UIButton = {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(
            systemName: "square.and.arrow.up",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        )
        cfg.baseForegroundColor = .white
        let btn = UIButton(configuration: cfg)
        btn.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        return btn
    }()

    /// 下载按钮：仅当 downloadCallback 非 nil 且当前页为网络资产时显示
    private lazy var downloadButton: UIButton = {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(
            systemName: "arrow.down.to.line",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        )
        cfg.baseForegroundColor = .white
        let btn = UIButton(configuration: cfg)
        btn.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)
        btn.isHidden = true
        return btn
    }()

    // 底部栏：背景延伸至屏幕底部，按钮在安全区域上方居中（微信风格）
    private let bottomBar: UIVisualEffectView = {
        UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    }()

    private lazy var previewOriginalButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "circle",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .light))
        config.title = "原图"
        config.imagePadding = 5
        config.baseForegroundColor = .white
        config.contentInsets = .zero
        let btn = UIButton(configuration: config)
        btn.addTarget(self, action: #selector(previewOriginalToggled), for: .touchUpInside)
        return btn
    }()

    private lazy var previewCropButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "crop",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        config.title = "裁剪"
        config.imagePadding = 5
        config.baseForegroundColor = .white
        config.contentInsets = .zero
        let btn = UIButton(configuration: config)
        btn.addTarget(self, action: #selector(previewCropTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var previewDoneButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "完成"
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs; a.font = .systemFont(ofSize: 15, weight: .semibold); return a
        }
        let btn = UIButton(configuration: config)
        btn.addTarget(self, action: #selector(previewDoneTapped), for: .touchUpInside)
        return btn
    }()

    // ── 底部页码指示器 ──────────────────────────────────────────────
    // bar 的兄弟视图（不在 topBar/bottomBar 内），底部居中；常驻显示，不随 bar 显隐淡出。
    // ≤8 张用一排小圆点，>8 张用「n / total」胶囊；二选一，按数量在构建时确定。

    /// 底部页码圆点视图（仅 2...8 张时非空；更多或视频页时为空/隐藏）
    private var pageIndicatorDots: [UIView] = []

    private lazy var pageIndicator: UIView = makePageIndicator()

    private func makePageIndicator() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isUserInteractionEnabled = false

        // 底部圆点只服务「少量图文混排」（2...8 张，信息流常见场景）：当前页白色、其余
        // 白色 α0.35。超过 8 张不再显示底部指示，改由顶部 n/m 计数承担，避免两处重复计数。
        guard allAssets.count > 1, allAssets.count <= 8 else { return container }

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<allAssets.count {
            let dot = UIView()
            dot.backgroundColor = UIColor.white.withAlphaComponent(0.35)
            dot.layer.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
            stack.addArrangedSubview(dot)
            pageIndicatorDots.append(dot)
        }
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    // MARK: - Initialization
    
    init(
        assets: [PhotoAssetModel],
        selectedAssets: [PhotoAssetModel],
        initialIndex: Int,
        sourceFrame: CGRect,
        config: PickerConfig,
        isOriginalPhoto: Bool = false,
        downloadCallback: (([String: Any]) -> Void)? = nil,
        downloadProgressCallback: (([String: Any]) -> Void)? = nil,
        saveAlbumName: String = "",
        completion: @escaping ([PhotoAssetModel], Bool) -> Void
    ) {
        self.allAssets = assets
        self.selectedAssets = selectedAssets
        self.currentIndex = initialIndex
        self.initialIndex = initialIndex
        self.sourceFrame = sourceFrame
        self.config = config
        self.isOriginalPhoto = isOriginalPhoto
        self.downloadCallback = downloadCallback
        self.downloadProgressCallback = downloadProgressCallback
        self.saveAlbumName = saveAlbumName
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        // 预览背景两种模式皆为深色，状态栏固定用浅色内容（白色图标）。
        // 本 VC 以 .custom 呈现，需显式接管状态栏外观（否则沿用呈现方的样式）。
        modalPresentationCapturesStatusBarAppearance = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    /// 预览背景恒为深色（两种模式一致），状态栏统一用浅色内容（白色图标）。
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        dismissalBackgroundAlpha = 1.0
        
        setupPageViewController()
        setupUI()
        setupGestures()
        updateUI()

        // 自定义转场下由本 VC 接管状态栏外观，主动刷新一次以应用 .lightContent
        setNeedsStatusBarAppearanceUpdate()
    }
    
    private func setupPageViewController() {
        pageViewController = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: nil
        )
        pageViewController.delegate = self
        pageViewController.dataSource = self

        // 安全检查
        guard !allAssets.isEmpty else {
            return
        }

        // 确保初始索引有效
        currentIndex = max(0, min(currentIndex, allAssets.count - 1))

        let initialVC = createPhotoViewController(at: currentIndex)
        currentPhotoVC = initialVC

        pageViewController.setViewControllers(
            [initialVC],
            direction: .forward,
            animated: false
        )

        // 初始页即当前页：若开启自动播放，武装该页视频（就绪即播）
        initialVC.activateIfCurrent()

        addChild(pageViewController)
        view.insertSubview(pageViewController.view, at: 0)
        pageViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pageViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            pageViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pageViewController.didMove(toParent: self)
    }
    
    private func setupUI() {
        // ── 顶部栏 ──────────────────────────────────────────────────
        // 从 view.top 延伸至 safeArea.top + 44，覆盖状态栏实现沉浸式
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        topBar.contentView.addSubview(closeButton)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(countLabel)

        selectButton.translatesAutoresizingMaskIntoConstraints = false
        selectButton.addTarget(self, action: #selector(selectButtonTapped), for: .touchUpInside)
        topBar.contentView.addSubview(selectButton)

        shareButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(shareButton)

        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(downloadButton)

        // ── 底部栏 ──────────────────────────────────────────────────
        // 背景延伸至屏幕底部，按钮居中于安全区域上方 54pt 内容区
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        previewOriginalButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.contentView.addSubview(previewOriginalButton)

        previewCropButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.contentView.addSubview(previewCropButton)

        previewDoneButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.contentView.addSubview(previewDoneButton)

        // showRadio=false（纯预览）时完成按钮始终可用，showRadio=true 时初始根据已选数量
        previewDoneButton.isEnabled = !self.config.showRadio || !selectedAssets.isEmpty

        let barContentH: CGFloat = 54  // safe area 上方内容高度

        NSLayoutConstraint.activate([
            // 顶部栏：view 顶部 → safeArea.top + 44
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 44),

            // 关闭按钮：左侧，垂直居中于 safeArea.top + 22
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 4),
            closeButton.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 22),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            // 计数标签：居中
            countLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            countLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 22),

            // 选择按钮：右侧
            selectButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            selectButton.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 22),
            selectButton.widthAnchor.constraint(equalToConstant: UIConstants.Preview.selectButtonSize),
            selectButton.heightAnchor.constraint(equalToConstant: UIConstants.Preview.selectButtonSize),

            // 下载按钮：垂直居中 + 固定尺寸
            downloadButton.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 22),
            downloadButton.widthAnchor.constraint(equalToConstant: 44),
            downloadButton.heightAnchor.constraint(equalToConstant: 44),

            // 分享按钮：下载按钮左侧
            shareButton.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 22),
            shareButton.widthAnchor.constraint(equalToConstant: 44),
            shareButton.heightAnchor.constraint(equalToConstant: 44),

            // 底部栏：safeArea.bottom - barContentH → view.bottom
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -barContentH),

            // 原图按钮：左侧，居中于内容区
            previewOriginalButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            previewOriginalButton.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                                           constant: -(barContentH / 2)),

            // 裁剪按钮：中间偏左，避免与「完成」拥挤
            previewCropButton.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor, constant: -12),
            previewCropButton.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                                       constant: -(barContentH / 2)),

            // 完成按钮：右侧，居中于内容区
            previewDoneButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            previewDoneButton.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                                       constant: -(barContentH / 2)),
        ])

        // 纯预览模式（showRadio: false）：整条顶栏 + 整个底部栏一并隐藏（微信式沉浸预览）。
        // 顶栏（关闭 / 计数 / 分享 / 下载）整体隐去，改为单击图片即关闭（见 handleBarToggleTap）；
        // 底部栏（原图 + 完成）在此模式下无意义。选择模式两栏均保留。
        topBar.isHidden       = !config.showRadio
        selectButton.isHidden = !config.showRadio
        bottomBar.isHidden    = !config.showRadio

        // 按钮水平排列（右→左）：[selectButton] [downloadButton] [shareButton]
        // showRadio=false 时 selectButton 隐藏，下载和分享按钮右对齐
        if config.showRadio {
            downloadButton.trailingAnchor
                .constraint(equalTo: selectButton.leadingAnchor, constant: -4)
                .isActive = true
        } else {
            downloadButton.trailingAnchor
                .constraint(equalTo: topBar.trailingAnchor, constant: -16)
                .isActive = true
        }
        shareButton.trailingAnchor
            .constraint(equalTo: downloadButton.leadingAnchor, constant: -4)
            .isActive = true

        // ── 底部页码指示器（bar 的兄弟视图，常驻显示，不随 bar 淡出）──────────
        view.addSubview(pageIndicator)
        // 选择模式有底部栏时抬到栏上方，避免与其重叠（对齐视频控制条的 62/12 内边距）
        let indicatorBottomInset: CGFloat = config.showRadio ? 62 : 12
        NSLayoutConstraint.activate([
            pageIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageIndicator.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                                  constant: -indicatorBottomInset),
        ])
        // 仅 1 张（或空）时无需页码
        pageIndicator.isHidden = allAssets.count <= 1
    }

    private func setupGestures() {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = LivePhotoConstants.longPressDuration
        view.addGestureRecognizer(longPress)

        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        view.addGestureRecognizer(panGesture)

        // 单击切换 bar 显示/隐藏（沉浸式）
        // 注意：在 gestureRecognizer(_:shouldRequireFailureOf:) 中让它等双击失败，防止冲突
        barToggleTap = UITapGestureRecognizer(target: self, action: #selector(handleBarToggleTap(_:)))
        barToggleTap.delegate = self
        view.addGestureRecognizer(barToggleTap)
    }
    
    private func createPhotoViewController(at index: Int) -> SinglePhotoViewController {
        // 安全检查：确保索引在有效范围内
        let safeIndex = max(0, min(index, allAssets.count - 1))
        let asset = allAssets[safeIndex]
        let isSelected = selectedAssets.contains(where: { $0.id == asset.id })
        return SinglePhotoViewController(asset: asset, config: config, isSelected: isSelected)
    }

    private func setPreviewBackgroundAlpha(_ alpha: CGFloat) {
        let clampedAlpha = min(max(alpha, 0), 1)
        dismissalBackgroundAlpha = clampedAlpha
        view.backgroundColor = UIColor.black.withAlphaComponent(clampedAlpha)
    }

    private func setBarsAlpha(_ alpha: CGFloat) {
        topBar.alpha = alpha
        if !bottomBar.isHidden {
            bottomBar.alpha = alpha
        }
        // 底部圆点常驻：不随 bar 显隐淡出（alpha 保持 1）；显隐规则仍由 updatePageIndicator 决定。
        // 仅 present/dismiss 会随整个 pageViewController.view 一起动画，属预期。
    }

    private func hideBarsForInteractiveDismiss() {
        barsVisibleBeforeInteractiveDismiss = barsVisible
        UIView.animate(
            withDuration: UIConstants.Animation.fadeInOutDuration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
        ) {
            self.setBarsAlpha(0)
            // 圆点平时常驻，但下拉关闭时跟随一起淡出，避免图片飞走时底部还留着圆点
            self.pageIndicator.alpha = 0
        }
    }

    private func restoreBarsAfterInteractiveDismiss(animated: Bool) {
        let targetAlpha: CGFloat = barsVisibleBeforeInteractiveDismiss ? 1 : 0
        let animations = {
            self.setBarsAlpha(targetAlpha)
            self.pageIndicator.alpha = 1   // 取消下拉后圆点恢复常驻
        }

        guard animated else {
            animations()
            return
        }

        UIView.animate(
            withDuration: UIConstants.Animation.fadeInOutDuration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
        ) {
            animations()
        }
    }

    // 下拉手势数学已抽到 DismissGestureMath（纯，view.bounds.height 作参数传入）
    private func dismissProgress(for translationY: CGFloat) -> CGFloat {
        DismissGestureMath.progress(translationY: translationY, viewHeight: view.bounds.height)
    }

    private func interactiveDismissTransform(for translation: CGPoint) -> CGAffineTransform {
        DismissGestureMath.transform(translation: translation, viewHeight: view.bounds.height)
    }
    
    private func updateUI() {
        // 安全检查
        guard !allAssets.isEmpty, currentIndex >= 0, currentIndex < allAssets.count else {
            return
        }

        let currentAsset = allAssets[currentIndex]

        countLabel.text = "\(currentIndex + 1) / \(allAssets.count)"

        updatePageIndicator()

        selectButton.isSelected = selectedAssets.contains(where: { $0.id == currentAsset.id })

        // 底部完成按钮：有选择时才可点击（纯预览模式始终可用）
        let hasSelection = !selectedAssets.isEmpty
        if config.showRadio {
            let count = selectedAssets.count
            previewDoneButton.isEnabled = hasSelection
            previewDoneButton.configuration?.title = count > 0 ? "完成(\(count))" : "完成"
        }

        if config.showRadio, let index = selectedAssets.firstIndex(where: { $0.id == currentAsset.id }) {
            selectButton.setImage(
                SelectionBadgeRenderer.number(index + 1, color: view.tintColor),
                for: .selected
            )
        } else {
            selectButton.setImage(SelectionBadgeRenderer.circle(filled: false, color: .white), for: .normal)
            selectButton.setImage(SelectionBadgeRenderer.circle(filled: true, color: view.tintColor), for: .selected)
        }

        // 下载按钮：仅支持“网络图片”保存到相册（对齐 README 行为约定）
        if downloadCallback != nil {
            let isNetworkImage: Bool = {
                if case .network(_, let mediaType) = currentAsset.sourceType {
                    if case .image = mediaType { return true }
                }
                return false
            }()
            downloadButton.isHidden = !isNetworkImage
        } else {
            downloadButton.isHidden = true
        }

        // 分享按钮：两种模式均不显示——预览模式整条顶栏已隐藏，选择模式也去掉分享入口。
        // 视图与 PreviewShareController 保留但常隐（dead-but-harmless），便于日后需要时恢复。
        shareButton.isHidden = true

        // 裁剪按钮：仅在“选择模式(showRadio=true)”且当前资源为 image 时显示
        let isImageAsset: Bool = {
            if case .image = currentAsset.mediaType { return true }
            return false
        }()
        previewCropButton.isHidden = !(config.showRadio && isImageAsset)
    }

    /// 刷新底部页码指示器到 currentIndex：圆点高亮当前点，胶囊更新文字。仅 1 张时隐藏。
    private func updatePageIndicator() {
        // 仅 2...8 张图文显示底部圆点；视频页底部由播放控制条（含进度滑块）占据，一并隐藏，
        // 避免与滑块同处底部重叠（视频自带进度条提供位置语境，翻回图片页再恢复）。
        guard allAssets.count > 1, allAssets.count <= 8,
              currentIndex >= 0, currentIndex < allAssets.count,
              !allAssets[currentIndex].isVideo else {
            pageIndicator.isHidden = true
            return
        }
        pageIndicator.isHidden = false
        for (i, dot) in pageIndicatorDots.enumerated() {
            dot.backgroundColor = (i == currentIndex)
                ? UIColor.white
                : UIColor.white.withAlphaComponent(0.35)
        }
    }

    // MARK: - Actions
    
    @objc private func closeTapped() {
        dismiss(animated: true) {
            self.completion(self.selectedAssets, self.isOriginalPhoto)
        }
    }

    /// 保存当前网络图片/视频到系统相册
    @objc private func downloadTapped() {
        guard let callback = downloadCallback else { return }
        // 在途去重：downloadButton.isEnabled 是保存进行中的闭锁（保存开始置 false、完成恢复）。
        // 长按保存路径不经过按钮，这里显式据此拦截，避免重复长按触发并发重复保存。
        guard downloadButton.isEnabled else { return }

        // #7 fix: currentIndex 越界防护
        guard currentIndex < allAssets.count else { return }
        let asset = allAssets[currentIndex]

        // 仅支持网络图片保存；video/livePhoto 不支持写入（避免契约/体验不一致）
        guard case .network(let url, let mediaType) = asset.sourceType else { return }
        guard case .image = mediaType else {
            callback([
                "status":       "failed",
                "url":          url.absoluteString,
                "errorCode":    "INVALID_ARGS",
                "errorMessage": "showDownloadButton 仅支持保存网络图片"
            ])
            return
        }

        downloadButton.isEnabled = false
        let progressCallback = downloadProgressCallback
        let urlString = url.absoluteString

        saveService.save(
            url: url,
            albumName: saveAlbumName,
            progress: { fractionCompleted in
                progressCallback?([
                    "url":      urlString,
                    "progress": fractionCompleted,
                ])
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                self.downloadButton.isEnabled = true
                switch result {
                case .success(let assetId):
                    callback([
                        "status":  "success",
                        "url":     urlString,
                        "assetId": assetId,
                    ])
                    self.showSaveToast("已保存到相册")
                case .failure(let errorCode, let errorMessage):
                    callback([
                        "status":       "failed",
                        "url":          urlString,
                        "errorCode":    errorCode,
                        "errorMessage": errorMessage,
                    ])
                }
            }
        )
    }

    /// 临时 Toast（iOS 无原生 Toast，用 UILabel 淡出模拟）
    /// #5 fix: 移除无效的 frame.size.width 赋值，改用文字两端补空格实现内边距
    private func showSaveToast(_ text: String) {
        let label = UILabel()
        label.text = "  \(text)  "          // 两端空格作为水平内边距，兼容 Auto Layout
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        label.textAlignment = .center
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),
            label.heightAnchor.constraint(equalToConstant: 36),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        UIView.animate(withDuration: 0.3, delay: 1.4, options: .curveEaseIn) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }

    @objc private func previewDoneTapped() {
        dismiss(animated: true) {
            self.completion(self.selectedAssets, self.isOriginalPhoto)
        }
    }

    @objc private func previewOriginalToggled() {
        isOriginalPhoto.toggle()
        if isOriginalPhoto {
            previewOriginalButton.configuration?.image = UIImage(
                systemName: "checkmark.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            )
        } else {
            previewOriginalButton.configuration?.image = UIImage(
                systemName: "circle",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .light)
            )
            previewOriginalButton.configuration?.title = "原图"
        }
    }

    @objc private func previewCropTapped() {
        cropCoordinator.startCropping()
    }

    @objc private func handleBarToggleTap(_ gesture: UITapGestureRecognizer) {
        // 保存弹窗已弹出时，点击空白交给弹窗遮罩自身处理（仅关闭弹窗），不触发关闭预览/显隐工具栏
        if saveSheetDim != nil { return }
        // 预览模式（showRadio=false）：顶/底栏已整体隐藏，单击图片即关闭预览（微信式），
        // 走与关闭按钮相同的路径（dismiss + completion）。视频播放键 / 控制条 / 分享等 UIControl
        // 已由 gestureRecognizer(_:shouldReceive:) 排除，双击缩放由 shouldRequireFailureOf 保证不误触。
        if !config.showRadio {
            // 缩放放大时不关闭：与下拉关闭保持一致（下拉仅在 zoomScale==1 时生效），
            // 避免用户放大看细节时单击误触退出。
            guard (currentPhotoVC?.scrollView.zoomScale ?? 1.0) <= 1.0 else { return }
            // 视频页单击不关闭：交给播放键/控制条处理（与 Android 一致，避免看视频时误关）。
            if currentPhotoVC?.asset.isVideo == true { return }
            closeTapped()
            return
        }

        // 点击到可见 bar 区域时不触发（让按钮正常响应）
        let loc = gesture.location(in: view)
        let inTop = topBar.frame.contains(loc)
        let inBottom = !bottomBar.isHidden && bottomBar.frame.contains(loc)
        if inTop || inBottom { return }

        barsVisible.toggle()
        UIView.animate(withDuration: UIConstants.Animation.fadeInOutDuration) {
            self.setBarsAlpha(self.barsVisible ? 1 : 0)
        }
    }
    
    @objc private func selectButtonTapped() {
        guard !allAssets.isEmpty, currentIndex >= 0, currentIndex < allAssets.count else {
            return
        }

        let currentAsset = allAssets[currentIndex]

        if let index = selectedAssets.firstIndex(where: { $0.id == currentAsset.id }) {
            selectedAssets.remove(at: index)
            currentAsset.isSelected = false
        } else {
            let isVideoOrLive = currentAsset.isVideo || currentAsset.isLivePhoto
            let currentVideoCount = selectedAssets.filter { $0.isVideo || $0.isLivePhoto }.count
            switch SelectionLimits.canAdd(
                currentCount: selectedAssets.count,
                maxCount: config.maxCount,
                currentVideoCount: currentVideoCount,
                maxVideoCount: config.maxVideoCount,
                isVideoOrLive: isVideoOrLive
            ) {
            case .maxCount:
                onMaxCountReached?(config.maxCount)
                showAlert(message: "最多只能选择 \(config.maxCount) 张照片")
                return
            case .maxVideo:
                showAlert(message: "最多只能选择 \(config.maxVideoCount) 个视频/实况照片")
                return
            case .ok:
                break
            }
            selectedAssets.append(currentAsset)
            currentAsset.isSelected = true
        }

        // 同步当前页的选中状态
        currentPhotoVC?.isSelected = currentAsset.isSelected
        updateUI()
    }

    @objc private func shareTapped() {
        shareController.shareCurrentAsset()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let currentPhotoVC = currentPhotoVC else { return }
        
        switch gesture.state {
        case .began:
            // 触感反馈先行：无论接下来是播放 Live Photo 还是弹保存动作表，长按落定即给一次中度反馈
            let feedback = UIImpactFeedbackGenerator(style: .medium)
            feedback.impactOccurred()

            if currentPhotoVC.asset.isLivePhoto {
                // Live Photo：长按播放微视频（相册/网络/本地的播放分流在 playLivePhoto 内部处理）
                currentPhotoVC.playLivePhoto()
            } else if downloadCallback != nil && isCurrentAssetNetworkImage() {
                // 网络静态图片且调用方开启了保存（downloadCallback != nil 即为「允许保存」）：
                // 长按弹出保存动作表，确认后复用 downloadTapped 的既有保存逻辑。
                presentSaveActionSheet()
            }

        case .ended, .cancelled:
            currentPhotoVC.stopVideo()

        default:
            break
        }
    }

    /// 当前页是否为「网络静态图片」：镜像 downloadTapped 的守卫
    /// （currentIndex 越界防护 + sourceType 为 .network 且 mediaType 为 .image），
    /// 用作长按保存动作表的开启条件，与下载按钮的可用条件保持一致。
    private func isCurrentAssetNetworkImage() -> Bool {
        guard currentIndex < allAssets.count else { return false }
        guard case .network(_, let mediaType) = allAssets[currentIndex].sourceType else { return false }
        guard case .image = mediaType else { return false }
        return true
    }

    /// 当前保存弹窗的遮罩层（nil 表示未弹出）
    private weak var saveSheetDim: UIView?

    /// 弹出底部保存弹窗：仅「保存图片 / 取消」两项，确认后复用 downloadTapped 的网络图保存逻辑。
    ///
    /// 不用系统 UIAlertController：预览页是自定义转场呈现（.custom + 保留下层视图），
    /// 从其上弹系统 actionSheet 会出现呈现/命中异常（按钮错位、点不动）。改为在本页 view 内
    /// 自绘底部弹窗，呈现可靠，也与 Android 的 BottomSheetDialog 观感一致。
    private func presentSaveActionSheet() {
        guard saveSheetDim == nil else { return }  // 防重复弹出

        // 半透明遮罩，点击空白处关闭
        let dim = UIView(frame: view.bounds)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.alpha = 0
        let dimTap = UITapGestureRecognizer(target: self, action: #selector(dismissSaveSheet))
        // 关键：默认 cancelsTouchesInView=true 会把落在「保存图片」按钮上的触摸取消掉，
        // 导致按钮的 touchUpInside 不触发（点了不保存）。置 false 让按钮与遮罩各自响应，
        // 遮罩的 dismissSaveSheet 幂等，重复调用无副作用。
        dimTap.cancelsTouchesInView = false
        dim.addGestureRecognizer(dimTap)
        view.addSubview(dim)
        saveSheetDim = dim

        // 「保存图片 / 取消」竖排，贴底部安全区
        let saveButton = makeSaveSheetButton(title: "保存图片")
        saveButton.addTarget(self, action: #selector(saveSheetConfirmTapped), for: .touchUpInside)
        let cancelButton = makeSaveSheetButton(title: "取消")
        cancelButton.addTarget(self, action: #selector(dismissSaveSheet), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [saveButton, cancelButton])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        dim.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: dim.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: dim.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: dim.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            saveButton.heightAnchor.constraint(equalToConstant: 52),
            cancelButton.heightAnchor.constraint(equalToConstant: 52),
        ])

        // 从底部滑入 + 遮罩淡入
        stack.transform = CGAffineTransform(translationX: 0, y: 220)
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
            dim.alpha = 1
            stack.transform = .identity
        }
    }

    /// 保存弹窗内单个按钮：白色/深色圆角卡片、居中文字。
    private func makeSaveSheetButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17)
        button.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.16, alpha: 1) : .white }
        button.layer.cornerRadius = 12
        button.clipsToBounds = true
        return button
    }

    @objc private func saveSheetConfirmTapped() {
        dismissSaveSheet()
        downloadTapped()
    }

    @objc private func dismissSaveSheet() {
        guard let dim = saveSheetDim else { return }
        saveSheetDim = nil
        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseIn) {
            dim.alpha = 0
        } completion: { _ in
            dim.removeFromSuperview()
        }
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        let verticalTranslation = max(translation.y, 0)
        let progress = dismissProgress(for: verticalTranslation)

        switch gesture.state {
        case .began:
            guard velocity.y > 0,
                  abs(velocity.y) > abs(velocity.x),
                  currentPhotoVC?.scrollView.zoomScale == 1.0 else {
                return
            }

            isInteractiveDismissing = true

            // 禁用 PageViewController 的滚动，防止左右切换
            pageViewController.dataSource = nil
            hideBarsForInteractiveDismiss()

        case .changed:
            guard isInteractiveDismissing else { return }

            pageViewController.view.transform = interactiveDismissTransform(for: translation)
            setPreviewBackgroundAlpha(1.0 - progress)

        case .ended, .cancelled:
            guard isInteractiveDismissing else { return }

            let shouldDismiss = progress > UIConstants.Preview.dismissProgressThreshold || velocity.y > UIConstants.Preview.dismissVelocityThreshold

            if shouldDismiss {
                self.dismiss(animated: true) {
                    self.completion(self.selectedAssets, self.isOriginalPhoto)
                }
            } else {
                // 回弹动画（使用弹簧效果）
                UIView.animate(
                    withDuration: 0.4,
                    delay: 0,
                    usingSpringWithDamping: 0.75,
                    initialSpringVelocity: abs(velocity.y) / 1000,
                    options: [.curveEaseOut, .allowUserInteraction]
                ) {
                    self.setPreviewBackgroundAlpha(1.0)
                    self.pageViewController.view.transform = .identity
                    self.restoreBarsAfterInteractiveDismiss(animated: false)
                }

                // 恢复 PageViewController 的滚动
                pageViewController.dataSource = self
            }

            isInteractiveDismissing = false

        default:
            break
        }
    }
    
    private func showAlert(message: String) {
        let alert = UIAlertController(title: "提示", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }

}

// MARK: - PreviewCropHost

/// 裁剪协调器所需的宿主能力：只暴露当前资源与三个反馈入口，
/// allAssets / currentIndex / config 等内部状态继续保持 private。
extension PhotoPreviewPageViewController: PreviewCropHost {

    var isCropActionEnabled: Bool {
        config.showRadio
    }

    var currentCropTargetAsset: PhotoAssetModel? {
        guard currentIndex >= 0, currentIndex < allAssets.count else { return nil }
        return allAssets[currentIndex]
    }

    func applyCroppedImage(_ image: UIImage) {
        // 以「当前真正可见的那一页」为准，而不是缓存的 currentPhotoVC——
        // 裁剪期间自定义转场可能已让缓存指向陈旧/错误的页，导致裁剪结果贴不到眼前这张。
        let visibleVC = pageViewController.viewControllers?.first as? SinglePhotoViewController
        (visibleVC ?? currentPhotoVC)?.applyEditedImage(image, animated: false)
    }

    func showCropToast(_ text: String) {
        showSaveToast(text)
    }

    func showCropFailureAlert(message: String) {
        showAlert(message: message)
    }
}

// MARK: - UIPageViewControllerDelegate & DataSource

extension PhotoPreviewPageViewController: UIPageViewControllerDelegate, UIPageViewControllerDataSource {
    
    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard currentIndex > 0 else { return nil }
        return createPhotoViewController(at: currentIndex - 1)
    }
    
    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard currentIndex < allAssets.count - 1 else { return nil }
        return createPhotoViewController(at: currentIndex + 1)
    }
    
    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard completed,
              let currentVC = pageViewController.viewControllers?.first as? SinglePhotoViewController,
              let index = allAssets.firstIndex(where: { $0.id == currentVC.asset.id }) else {
            return
        }
        
        // 停止上一个视频页的播放（避免声音持续）
        for vc in previousViewControllers {
            (vc as? SinglePhotoViewController)?.stopVideo()
        }

        currentIndex = index
        currentPhotoVC = currentVC
        updateUI()

        // 新的当前页：若开启自动播放，武装其视频（离屏预实例化的邻页不会自动播放）
        currentVC.activateIfCurrent()
    }
}

// MARK: - UIGestureRecognizerDelegate

extension PhotoPreviewPageViewController: UIGestureRecognizerDelegate {

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // 只允许 pan 和系统手势同时识别，不影响 long press
        if gestureRecognizer == panGesture {
            return true
        }
        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 保存弹窗弹出时，禁用下拉关闭，避免拖动遮罩把整页一起下拉
        if saveSheetDim != nil { return false }
        // pan 手势只在图片没有缩放时才生效
        if gestureRecognizer == panGesture {
            guard let currentPhotoVC = currentPhotoVC else { return false }
            return currentPhotoVC.scrollView.zoomScale == 1.0
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        // 落在控件（视频控制条的滑块 / 播放键等）上的触摸，交给控件自身处理：
        // 下拉关闭 pan 会 cancelsTouchesInView 抢走滑块拖动，单击切换 bar 也会与点击冲突。
        if gestureRecognizer == panGesture || gestureRecognizer == barToggleTap {
            var candidate = touch.view
            while let current = candidate {
                if current is UIControl { return false }
                candidate = current.superview
            }
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // 单击 bar 切换必须等双击失败后才触发，避免双击同时触发 bar 显隐
        if gestureRecognizer == barToggleTap,
           let tap = otherGestureRecognizer as? UITapGestureRecognizer,
           tap.numberOfTapsRequired == 2 {
            return true
        }
        return false
    }
}

// MARK: - UIViewControllerTransitioningDelegate

extension PhotoPreviewPageViewController: UIViewControllerTransitioningDelegate {
    
    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        return PhotoPreviewPresentationController(
            presentedViewController: presented,
            presenting: presenting
        )
    }
    
    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        // 呈现时总是打开在初始页，sourceFrame 有效：传入以启用「从缩略图飞入」分支
        // （与 forDismissed 对称；缺省 .zero 会让 animatePresentation 退回旧的淡入缩放）
        return PhotoPreviewAnimator(isPresenting: true, sourceFrame: sourceFrame)
    }
    
    func animationController(
        forDismissed dismissed: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        // 翻页后原 sourceFrame 已过期，只有仍在初始页时才飞回缩略图，否则退回淡出
        let frame: CGRect = (currentIndex == initialIndex) ? sourceFrame : .zero
        return PhotoPreviewAnimator(isPresenting: false, sourceFrame: frame)
    }
}
