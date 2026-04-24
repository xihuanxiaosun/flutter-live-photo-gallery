import UIKit
import Photos
import AVFoundation
import TOCropViewController

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

    private var videoPlayer: AVPlayer?
    private var videoPlayerLayer: AVPlayerLayer?
    private var isPlaying = false
    private var playerObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?  // 类型安全 KVO，自动绑定到被观察的 item
    private var isLoadingVideo = false  // 防止异步加载期间重复触发

    /// 记录 PHImageManager 的图片请求 ID，页面消失时取消以释放内存压力
    private var imageRequestID: PHImageRequestID?
    /// 记录视频资源请求 ID，页面消失时取消
    private var videoRequestID: PHImageRequestID?

    // 视频控制 UI
    private let playButton: UIButton = {
        let button = UIButton(type: .custom)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        button.layer.cornerRadius = 35
        button.isHidden = true
        return button
    }()

    private let progressBar: UIProgressView = {
        let progress = UIProgressView(progressViewStyle: .default)
        progress.progressTintColor = .white
        progress.trackTintColor = UIColor.white.withAlphaComponent(0.3)
        progress.isHidden = true
        return progress
    }()

    // 加载指示器
    private let loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.color = .white
        indicator.hidesWhenStopped = true
        return indicator
    }()
    
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
        if asset.isVideo && videoPlayer == nil && !isLoadingVideo {
            loadVideo()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopVideo()
        // 取消未完成的 PHImageManager 请求，快速翻页时避免回调乱序和内存积压
        if let id = imageRequestID {
            PHImageManager.default().cancelImageRequest(id)
            imageRequestID = nil
        }
        if let id = videoRequestID {
            PHImageManager.default().cancelImageRequest(id)
            videoRequestID = nil
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

        // 添加进度条
        view.addSubview(progressBar)
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            progressBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            progressBar.heightAnchor.constraint(equalToConstant: 2)
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
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        scrollView.contentOffset = .zero

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
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.resizeMode = .exact
        options.version = .current

        imageRequestID = PHImageManager.default().requestImage(
            for: phAsset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { [weak self] image, _ in
            DispatchQueue.main.async {
                self?.imageRequestID = nil
                self?.imageView.image = image
                self?.loadingIndicator.stopAnimating()
            }
        }
    }

    private func loadNetworkImage(_ url: URL, mediaType: PhotoAssetModel.MediaType) {
        switch mediaType {
        case .image:
            PhotoLibraryManager.shared.loadNetworkImage(from: url) { [weak self] result in
                DispatchQueue.main.async {
                    self?.loadingIndicator.stopAnimating()
                    if case .success(let image) = result {
                        self?.imageView.image = image
                    }
                }
            }
        case .video:
            // 网络视频封面 URL（MediaAssetInput.url）用于展示缩略图；播放使用 videoUrl。
            PhotoLibraryManager.shared.loadNetworkImage(from: url) { [weak self] result in
                DispatchQueue.main.async {
                    self?.loadingIndicator.stopAnimating()
                    if case .success(let image) = result {
                        self?.imageView.image = image
                    }
                }
            }
        case .livePhoto:
            PhotoLibraryManager.shared.loadNetworkImage(from: url) { [weak self] result in
                DispatchQueue.main.async {
                    self?.loadingIndicator.stopAnimating()
                    if case .success(let image) = result {
                        self?.imageView.image = image
                    }
                }
            }
        }
    }

    private func loadLocalFileImage(_ url: URL, mediaType: PhotoAssetModel.MediaType) {
        switch mediaType {
        case .image, .livePhoto:
            if let image = UIImage(contentsOfFile: url.path) {
                imageView.image = image
            }
            loadingIndicator.stopAnimating()
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
    
    // MARK: - Video Loading & Playback

    private func loadVideo() {
        switch asset.sourceType {
        case .photoLibrary(let phAsset):
            loadPhotoLibraryVideo(phAsset)
        case .network(let coverUrl, let mediaType):
            guard case .video(_, let videoURL) = mediaType else { return }
            let playURL = videoURL ?? coverUrl
            DispatchQueue.main.async { self.setupVideoPlayer(with: playURL) }
        case .localFile(let url, _):
            DispatchQueue.main.async { self.setupVideoPlayer(with: url) }
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
                self.setupVideoPlayer(with: urlAsset.url)
            }
        }
    }

    private func setupVideoPlayer(with url: URL) {
        let player = AVPlayer(url: url)
        let playerLayer = AVPlayerLayer(player: player)

        playerLayer.frame = view.bounds
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.clear.cgColor

        view.layer.insertSublayer(playerLayer, above: scrollView.layer)

        self.videoPlayer = player
        self.videoPlayerLayer = playerLayer

        // ⚠️ 先隐藏播放按钮，等视频准备好再显示
        playButton.isHidden = true
        playButton.alpha = 1.0  // 重置 alpha，防止上次播放时被隐藏后残留
        loadingIndicator.startAnimating()

        // 监听视频状态（类型安全 KVO，自动绑定到此 playerItem 实例）
        statusObservation = player.currentItem?.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    self.loadingIndicator.stopAnimating()
                    self.playButton.isHidden = false
                    self.updatePlayButton(isPlaying: false)
                case .failed:
                    self.loadingIndicator.stopAnimating()
                    self.playButton.isHidden = true
                default:
                    break
                }
            }
        }

        // 监听播放完成
        playerObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.videoPlaybackEnded()
        }

        // 监听播放进度
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updateProgress(time: time)
        }
    }

    @objc private func playButtonTapped() {
        togglePlayPause()
    }

    private func togglePlayPause() {
        guard let player = videoPlayer else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
            updatePlayButton(isPlaying: false)
        } else {
            player.play()
            isPlaying = true
            updatePlayButton(isPlaying: true)
            progressBar.isHidden = false

            // 隐藏图片显示视频
            UIView.animate(withDuration: 0.3) {
                self.imageView.alpha = 0
            }

        }
    }

    private func updatePlayButton(isPlaying: Bool) {
        let iconName = isPlaying ? "pause.fill" : "play.fill"
        let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .medium)
        let image = UIImage(systemName: iconName, withConfiguration: config)
        playButton.setImage(image, for: .normal)
        playButton.tintColor = .white

        // 播放时隐藏按钮
        UIView.animate(withDuration: 0.3) {
            self.playButton.alpha = isPlaying ? 0 : 1
        }
    }

    private func updateProgress(time: CMTime) {
        guard let duration = videoPlayer?.currentItem?.duration else { return }
        let durationSeconds = CMTimeGetSeconds(duration)
        let currentSeconds = CMTimeGetSeconds(time)

        if durationSeconds > 0 {
            progressBar.progress = Float(currentSeconds / durationSeconds)
        }
    }

    private func videoPlaybackEnded() {
        isPlaying = false
        updatePlayButton(isPlaying: false)

        // 重置播放位置
        videoPlayer?.seek(to: .zero)

        // 显示图片
        UIView.animate(withDuration: 0.3) {
            self.imageView.alpha = 1
        }
    }

    // MARK: - Live Photo 播放

    func playLivePhoto() {
        guard asset.isLivePhoto, !isPlaying else { return }

        isPlaying = true

        switch asset.sourceType {
        case .photoLibrary(let phAsset):
            playPhotoLibraryLivePhoto(phAsset)
        case .network(_, let mediaType):
            if case .livePhoto(let videoURL) = mediaType, let videoURL = videoURL {
                DispatchQueue.main.async {
                    self.playVideoDirectly(url: videoURL)
                }
            } else {
                isPlaying = false
            }
        case .localFile(_, let mediaType):
            if case .livePhoto(let videoURL) = mediaType, let videoURL = videoURL {
                DispatchQueue.main.async {
                    self.playVideoDirectly(url: videoURL)
                }
            } else {
                isPlaying = false
            }
        }
    }

    private func playPhotoLibraryLivePhoto(_ phAsset: PHAsset) {
        guard let asset = asset.asset else {
            isPlaying = false
            return
        }

        LivePhotoExtractor.shared.extractVideo(from: asset) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let url):
                DispatchQueue.main.async {
                    self.playVideoDirectly(url: url)
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isPlaying = false
                }
            }
        }
    }
    
    private func playVideoDirectly(url: URL) {
        let player = AVPlayer(url: url)
        let playerLayer = AVPlayerLayer(player: player)
        
        playerLayer.frame = view.bounds
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.clear.cgColor
        
        view.layer.insertSublayer(playerLayer, above: scrollView.layer)
        
        self.videoPlayer = player
        self.videoPlayerLayer = playerLayer
        
        // 等待一小段时间后播放
        DispatchQueue.main.asyncAfter(deadline: .now() + UIConstants.Animation.videoPlayDelay) { [weak self] in
            guard let self = self else { return }

            UIView.animate(withDuration: UIConstants.Animation.fadeInOutDuration) {
                self.imageView.alpha = 0
            }
            
            self.videoPlayer?.play()
        }
        
        // 监听播放完成
        playerObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.stopVideo()
        }
    }

    func stopVideo() {
        // statusObservation 设为 nil 即自动从对应的 AVPlayerItem 移除观察者
        // 无论 playerItem 是否已替换，都不会崩溃
        statusObservation = nil

        // 移除通知观察者
        if let observer = playerObserver {
            NotificationCenter.default.removeObserver(observer)
            playerObserver = nil
        }

        if let observer = timeObserver {
            videoPlayer?.removeTimeObserver(observer)
            timeObserver = nil
        }

        // 重置播放按钮状态（包含 alpha，防止播放时隐藏后残留）
        playButton.alpha = 1.0
        progressBar.isHidden = true

        UIView.animate(withDuration: UIConstants.Animation.fadeInOutDuration, animations: {
            self.imageView.alpha = 1.0
        }) { [weak self] _ in
            self?.videoPlayer?.pause()
            self?.videoPlayerLayer?.removeFromSuperlayer()
            self?.videoPlayer = nil
            self?.videoPlayerLayer = nil
            self?.isPlaying = false
            self?.playButton.isHidden = true
        }
    }

    deinit {
        // statusObservation 是 NSKeyValueObservation，ARC 释放时自动 invalidate，无需手动移除
        // 但显式置 nil 更清晰，防止极端情况下延迟释放
        statusObservation = nil

        if let observer = playerObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = timeObserver {
            videoPlayer?.removeTimeObserver(observer)
        }
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
        guard scrollView.zoomScale > scrollView.minimumZoomScale else { return }
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
    }
}

// MARK: - 主预览控制器

class PhotoPreviewPageViewController: UIViewController, TOCropViewControllerDelegate {
    
    private let allAssets: [PhotoAssetModel]
    private var selectedAssets: [PhotoAssetModel]
    private let config: PickerConfig
    private let completion: ([PhotoAssetModel], Bool) -> Void

    /// The UITransitionView UIKit created for the crop-VC presentation.
    /// UIKit fails to remove this container when the crop VC is dismissed from
    /// within a custom-presentation parent (shouldRemovePresentersView = false).
    /// We capture it on presentation and remove it manually after crop dismisses.
    /// Accessible from PhotoPreviewPresentationController for race-condition cleanup.
    var cropPresentationContainer: UIView?

    /// 保存网络图片完成后的回调（nil = 不显示下载按钮）
    private let downloadCallback: (([String: Any]) -> Void)?

    /// 下载进度回调：["url": String, "progress": Double(0~1)]
    private let downloadProgressCallback: (([String: Any]) -> Void)?

    /// 用户尝试超出 maxCount 时触发（参数为 maxCount 值）
    var onMaxCountReached: ((Int) -> Void)?

    /// 保存图片时使用的相册名称，空串 = 仅存到「最近项目」，非空 = 同时加入同名相册
    private let saveAlbumName: String

    /// 下载任务进度观察者（KVO）
    private var downloadProgressObservation: NSKeyValueObservation?

    private var currentIndex: Int
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

    /// 分享按钮：始终显示（点击后弹出系统分享面板）
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
        self.sourceFrame = sourceFrame
        self.config = config
        self.isOriginalPhoto = isOriginalPhoto
        self.downloadCallback = downloadCallback
        self.downloadProgressCallback = downloadProgressCallback
        self.saveAlbumName = saveAlbumName
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        dismissalBackgroundAlpha = 1.0
        
        setupPageViewController()
        setupUI()
        setupGestures()
        updateUI()
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

        // 纯预览模式（showRadio: false）：隐藏整个底部栏（原图 + 完成按钮均无意义）
        // 同时隐藏顶部的选择按钮；仅保留顶部关闭按钮和计数
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
    }

    private func hideBarsForInteractiveDismiss() {
        barsVisibleBeforeInteractiveDismiss = barsVisible
        UIView.animate(
            withDuration: UIConstants.Animation.fadeInOutDuration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
        ) {
            self.setBarsAlpha(0)
        }
    }

    private func restoreBarsAfterInteractiveDismiss(animated: Bool) {
        let targetAlpha: CGFloat = barsVisibleBeforeInteractiveDismiss ? 1 : 0
        let animations = {
            self.setBarsAlpha(targetAlpha)
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

    private func dismissProgress(for translationY: CGFloat) -> CGFloat {
        let normalizedDistance = max(view.bounds.height * 0.85, 1)
        return min(max(translationY / normalizedDistance, 0), 1)
    }

    private func interactiveDismissTransform(for translation: CGPoint) -> CGAffineTransform {
        let verticalTranslation = max(translation.y, 0)
        let progress = dismissProgress(for: verticalTranslation)
        let scale = max(0.58, 1.0 - (progress * 0.42))
        let horizontalTranslation = progress > 0 ? translation.x * 0.98 : 0

        return CGAffineTransform(translationX: horizontalTranslation, y: verticalTranslation)
            .scaledBy(x: scale, y: scale)
    }
    
    private func updateUI() {
        // 安全检查
        guard !allAssets.isEmpty, currentIndex >= 0, currentIndex < allAssets.count else {
            return
        }

        let currentAsset = allAssets[currentIndex]

        countLabel.text = "\(currentIndex + 1) / \(allAssets.count)"

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
                createNumberImage(number: index + 1, color: view.tintColor),
                for: .selected
            )
        } else {
            selectButton.setImage(createCircleImage(filled: false, color: .white), for: .normal)
            selectButton.setImage(createCircleImage(filled: true, color: view.tintColor), for: .selected)
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

        // 分享按钮：始终可见（无论本地/网络）
        shareButton.isHidden = false

        // 裁剪按钮：仅在“选择模式(showRadio=true)”且当前资源为 image 时显示
        let isImageAsset: Bool = {
            if case .image = currentAsset.mediaType { return true }
            return false
        }()
        previewCropButton.isHidden = !(config.showRadio && isImageAsset)
    }
    
    // MARK: - Actions
    
    @objc private func closeTapped() {
        dismiss(animated: true) {
            self.completion(self.selectedAssets, self.isOriginalPhoto)
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
        guard let cropContainer = cropPresentationContainer else { return }

        // If our view ended up inside the crop container (UIKit moved it there),
        // restore it to our own UITransitionView before removing the crop container.
        if let myContainer = presentationController?.containerView,
           view.superview === cropContainer {
            view.frame = myContainer.bounds
            myContainer.addSubview(view)   // reparents: crop container → preview container
        }

        cropContainer.removeFromSuperview()
        cropPresentationContainer = nil
    }

    private func dismissCropViewController(
        _ cropViewController: TOCropViewController,
        completion: (() -> Void)? = nil
    ) {
        cropViewController.dismiss(animated: true) { [weak self] in
            self?.cleanupOrphanedWindowContainers()
            completion?()
        }
    }

    private func clearTemporaryEditedFile(for asset: PhotoAssetModel) {
        guard let old = asset.editedPath, !old.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: old)
        asset.editedPath = nil
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

    /// 保存当前网络图片/视频到系统相册
    @objc private func downloadTapped() {
        guard let callback = downloadCallback else { return }

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

        // 使用 downloadTask 以支持进度回调（dataTask 不提供字节级进度）
        let downloadSession = URLSession(configuration: .default)
        let task = downloadSession.downloadTask(with: url) { [weak self] tmpURL, response, error in
            guard let self = self else { return }

            // 停止进度观察
            self.downloadProgressObservation = nil

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let tmpURL, error == nil, (200..<300).contains(statusCode) else {
                DispatchQueue.main.async {
                    self.downloadButton.isEnabled = true
                    callback([
                        "status":       "failed",
                        "url":          urlString,
                        "errorCode":    "NETWORK_ERROR",
                        "errorMessage": error?.localizedDescription
                            ?? "网络请求失败（HTTP \(statusCode)）",
                    ])
                }
                return
            }

            // 2. 拷贝到应用临时目录（下载 task 的 tmpURL 在回调完成后会被删除）
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("lpg_dl_\(UUID().uuidString).\(ext)")
            do { try FileManager.default.copyItem(at: tmpURL, to: tmp) } catch {
                DispatchQueue.main.async {
                    self.downloadButton.isEnabled = true
                    callback([
                        "status":       "failed",
                        "url":          urlString,
                        "errorCode":    "SAVE_FAILED",
                        "errorMessage": "临时文件写入失败",
                    ])
                }
                return
            }

            // 3. PHPhotoLibrary 保存（需要宿主 App Info.plist 中的 NSPhotoLibraryAddUsageDescription）
            // #3 fix: 根据 mediaType 选择正确的 PHAssetChangeRequest API
            // 若 saveAlbumName 非空，同时将图片加入指定相册（不存在则自动创建）
            var localId: String?
            let targetAlbumName = self.saveAlbumName
            let urlStringForCallback = urlString
            PHPhotoLibrary.shared().performChanges({
                // ── 创建资产 ──────────────────────────────────────────
                guard let changeRequest = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: tmp) else { return }
                localId = changeRequest.placeholderForCreatedAsset?.localIdentifier

                // ── 加入命名相册（saveAlbumName 非空时）────────────────
                guard !targetAlbumName.isEmpty,
                      let placeholder = changeRequest.placeholderForCreatedAsset else { return }

                // 查找已有同名相册
                let fetchResult = PHAssetCollection.fetchAssetCollections(
                    with: .album, subtype: .albumRegular, options: nil)
                var existingAlbum: PHAssetCollection?
                fetchResult.enumerateObjects { collection, _, stop in
                    if collection.localizedTitle == targetAlbumName {
                        existingAlbum = collection
                        stop.pointee = true
                    }
                }

                if let album = existingAlbum {
                    // 已有相册 → 追加
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                } else {
                    // 新建相册并加入
                    let albumReq = PHAssetCollectionChangeRequest
                        .creationRequestForAssetCollection(withTitle: targetAlbumName)
                    albumReq.addAssets([placeholder] as NSArray)
                }
            }) { success, saveError in
                try? FileManager.default.removeItem(at: tmp)
                DispatchQueue.main.async {
                    self.downloadButton.isEnabled = true
                    if success {
                        callback([
                            "status":  "success",
                            "url":     urlStringForCallback,
                            "assetId": localId ?? "",
                        ])
                        self.showSaveToast("已保存到相册")
                    } else {
                        let desc = saveError?.localizedDescription ?? ""
                        let code = desc.lowercased().contains("access") || desc.lowercased().contains("permission")
                            ? "PERMISSION_DENIED" : "SAVE_FAILED"
                        callback([
                            "status":       "failed",
                            "url":          urlStringForCallback,
                            "errorCode":    code,
                            "errorMessage": desc.isEmpty ? "保存失败" : desc,
                        ])
                    }
                }
            }
        }

        // 进度监听（KVO observing task.progress.fractionCompleted）
        downloadProgressObservation = task.progress.observe(
            \Progress.fractionCompleted,
            options: [.new]
        ) { progress, _ in
            DispatchQueue.main.async {
                progressCallback?([
                    "url":      urlString,
                    "progress": progress.fractionCompleted,
                ])
            }
        }
        task.resume()
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
        guard config.showRadio,
              currentIndex >= 0,
              currentIndex < allAssets.count else { return }
        let asset = allAssets[currentIndex]
        guard case .image = asset.mediaType else { return }

        loadCroppableImage(for: asset) { [weak self] image in
            guard let self, let image else {
                self?.showAlert(message: "当前资源无法裁剪")
                return
            }

            let cropVC = TOCropViewController(image: image)
            cropVC.delegate = self
            cropVC.aspectRatioLockEnabled = false
            cropVC.resetAspectRatioEnabled = true
            cropVC.rotateButtonsHidden = true
            // Use .overFullScreen to avoid disturbing the underlying .custom presentation's
            // containerView hierarchy, which would break the dismiss transition.
            cropVC.modalPresentationStyle = .overFullScreen
            self.present(cropVC, animated: true) { [weak self, weak cropVC] in
                // Capture crop's UITransitionView after presentation completes.
                // UIKit adds cropVC.view to a new UITransitionView (the container).
                // We need this reference to remove it manually after crop dismisses,
                // because UIKit's default cleanup is broken in our custom-presentation context.
                self?.cropPresentationContainer = cropVC?.view.superview
            }
        }
    }

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

    func cropViewController(
        _ cropViewController: TOCropViewController,
        didCropTo image: UIImage,
        with cropRect: CGRect,
        angle: Int
    ) {
        _ = cropRect
        _ = angle
        guard currentIndex >= 0, currentIndex < allAssets.count else {
            dismissCropViewController(cropViewController)
            return
        }

        let asset = allAssets[currentIndex]
        persistCroppedImage(image, for: asset) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.currentPhotoVC?.applyEditedImage(image, animated: false)
                self.dismissCropViewController(cropViewController) {
                    self.showSaveToast("裁剪完成")
                }
            case .failure(let error):
                self.dismissCropViewController(cropViewController) { [weak self] in
                    self?.showAlert(message: error.localizedDescription)
                }
            }
        }
    }

    func cropViewController(_ cropViewController: TOCropViewController, didFinishCancelled cancelled: Bool) {
        _ = cancelled
        dismissCropViewController(cropViewController)
    }

    @objc private func handleBarToggleTap(_ gesture: UITapGestureRecognizer) {
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
            if selectedAssets.count >= config.maxCount {
                onMaxCountReached?(config.maxCount)
                showAlert(message: "最多只能选择 \(config.maxCount) 张照片")
                return
            }
            // maxVideoCount 限制：-1 = 无限制
            if config.maxVideoCount >= 0 && (currentAsset.isVideo || currentAsset.isLivePhoto) {
                let currentVideoCount = selectedAssets.filter { $0.isVideo || $0.isLivePhoto }.count
                if currentVideoCount >= config.maxVideoCount {
                    showAlert(message: "最多只能选择 \(config.maxVideoCount) 个视频/实况照片")
                    return
                }
            }
            selectedAssets.append(currentAsset)
            currentAsset.isSelected = true
        }

        // 同步当前页的选中状态
        currentPhotoVC?.isSelected = currentAsset.isSelected
        updateUI()
    }

    @objc private func shareTapped() {
        guard !allAssets.isEmpty, currentIndex < allAssets.count else { return }
        let asset = allAssets[currentIndex]

        var activityItems: [Any] = []
        switch asset.sourceType {
        case .network(let url, _):
            activityItems = [url]
        case .photoLibrary(let phAsset):
            // PHAsset 通过 UIActivityItemSource 协议可直接传递给 UIActivityViewController
            activityItems = [phAsset]
        case .localFile(let url, _):
            activityItems = [url]
        }

        let activityVC = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = shareButton
            popover.sourceRect = shareButton.bounds
        }
        present(activityVC, animated: true)
    }
    
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let currentPhotoVC = currentPhotoVC else { return }
        
        switch gesture.state {
        case .began:
            currentPhotoVC.playLivePhoto()
            
            let feedback = UIImpactFeedbackGenerator(style: .medium)
            feedback.impactOccurred()
            
        case .ended, .cancelled:
            currentPhotoVC.stopVideo()
            
        default:
            break
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
    
    private func createCircleImage(filled: Bool, color: UIColor) -> UIImage? {
        let size = CGSize(width: 30, height: 30)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            if filled {
                color.setFill()
                let circle = UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 24, height: 24))
                circle.fill()
                
                UIColor.white.setStroke()
                let checkmark = UIBezierPath()
                checkmark.move(to: CGPoint(x: 10, y: 15))
                checkmark.addLine(to: CGPoint(x: 13, y: 18))
                checkmark.addLine(to: CGPoint(x: 20, y: 11))
                checkmark.lineWidth = 2
                checkmark.lineCapStyle = .round
                checkmark.stroke()
            } else {
                UIColor.white.setStroke()
                let circle = UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 24, height: 24))
                circle.lineWidth = 2
                circle.stroke()
            }
        }
    }
    
    private func createNumberImage(number: Int, color: UIColor) -> UIImage? {
        let size = CGSize(width: 30, height: 30)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            color.setFill()
            let circle = UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 24, height: 24))
            circle.fill()
            
            let text = "\(number)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(
                x: (30 - textSize.width) / 2,
                y: (30 - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attributes)
        }
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
        // pan 手势只在图片没有缩放时才生效
        if gestureRecognizer == panGesture {
            guard let currentPhotoVC = currentPhotoVC else { return false }
            return currentPhotoVC.scrollView.zoomScale == 1.0
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
        return PhotoPreviewAnimator(isPresenting: true)
    }
    
    func animationController(
        forDismissed dismissed: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        return PhotoPreviewAnimator(isPresenting: false, sourceFrame: sourceFrame)
    }
}
