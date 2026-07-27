import UIKit
import AVFoundation

// MARK: - 预览页视频播放控制器

/// 单张预览页里 AVPlayer 相关的全部状态与生命周期的持有者。
///
/// 抽出的原因：`SinglePhotoViewController` 原本同时负责「取素材」（PHImageManager /
/// 网络下载）与「放素材」（AVPlayer、图层、三类观察者），后者的观察者拆除顺序非常
/// 敏感，混在页面生命周期里极易被误改。抽出后播放器的创建、观察者注册与拆除全部
/// 收敛在本类，页面只负责把 URL 交进来。
///
/// Live Photo 的播放状态机（是否播放中 + 播放代次）同样封装在本类，
/// 只通过 beginLivePhotoPlayback() / abortLivePhotoPlayback() /
/// playVideoDirectly(url:generation:) 三个入口暴露；页面不再直接读写这两个状态，
/// 因此新增一条中止分支时不可能忘记复位。
///
/// 本类不创建任何视图：播放按钮、底部控制条、加载指示器与图片视图都由页面创建并注入，
/// 本类只负责在播放状态变化时更新它们，并接收控制条的播放/暂停/拖动回调执行 seek。
final class PreviewVideoPlayerController {

    // MARK: - 注入的视图

    /// 播放器图层挂载的宿主视图（即页面的 view）
    private let hostView: UIView

    /// 仅用于确定播放器图层的插入位置：必须位于 scrollView 图层之上
    private let scrollView: UIScrollView

    /// 播放时淡出、停止时淡入的封面图
    private let imageView: UIImageView

    private let playButton: UIButton
    private let controlsView: PreviewVideoControlsView
    private let loadingIndicator: UIActivityIndicatorView

    // MARK: - 播放器状态

    private var videoPlayer: AVPlayer?
    private var videoPlayerLayer: AVPlayerLayer?
    private var playerObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?  // 类型安全 KVO，自动绑定到被观察的 item

    /// 是否正在播放。对外只通过 beginLivePhotoPlayback() / abortLivePhotoPlayback() 改写，
    /// 避免调用方漏掉某条中止分支导致该页的 Live Photo 永久无法再播。
    private var isPlaying = false

    /// 本页成为当前页时是否自动播放（config.autoPlayVideo）。由宿主 enableAutoPlayOnReady() 置位；
    /// 播放器就绪即消费，翻走时 stopVideo() 复位，避免离屏页或旧页自行恢复播放。
    private var autoPlayOnReady = false

    /// 是否已创建播放器。页面从 UIPageViewController 滑回时据此决定要不要重新加载。
    var hasPlayer: Bool { videoPlayer != nil }

    /// Live Photo 播放代次：每次 stopVideo() 自增，用于作废进行中的异步抽帧回调，
    /// 防止手指抬起后抽帧才完成、Live Photo 突然自行播放且无法停止。
    /// 抽帧编排留在页面里，但代次的读取与比对全部封装在本类，页面只负责原样回传。
    private var playbackGeneration = 0

    init(
        hostView: UIView,
        scrollView: UIScrollView,
        imageView: UIImageView,
        playButton: UIButton,
        controlsView: PreviewVideoControlsView,
        loadingIndicator: UIActivityIndicatorView
    ) {
        self.hostView = hostView
        self.scrollView = scrollView
        self.imageView = imageView
        self.playButton = playButton
        self.controlsView = controlsView
        self.loadingIndicator = loadingIndicator

        // 控制条只把交互回传给本类，由本类执行播放/暂停与 seek。
        controlsView.onPlayPauseTapped = { [weak self] in self?.togglePlayPause() }
        controlsView.onScrubEnded = { [weak self] fraction in self?.seek(toFraction: fraction) }
    }

    // MARK: - 播放器装配

    /// 创建 AVPlayer 与 AVPlayerLayer 并挂到 scrollView 图层之上，返回新建的 player。
    /// 这是 setupVideoPlayer(with:) 与 playVideoDirectly(url:) 两条入口唯一共享的部分，
    /// 两者后续的观察者/自动播放策略完全不同，因此只抽公共装配、不合并入口。
    private func makePlayer(url: URL) -> AVPlayer {
        let player = AVPlayer(url: url)
        let playerLayer = AVPlayerLayer(player: player)

        playerLayer.frame = hostView.bounds
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.clear.cgColor

        hostView.layer.insertSublayer(playerLayer, above: scrollView.layer)

        self.videoPlayer = player
        self.videoPlayerLayer = playerLayer

        return player
    }

    /// 普通视频入口：带播放按钮、状态 KVO 与周期性进度观察，等用户点按钮才播放。
    func setupVideoPlayer(with url: URL) {
        let player = makePlayer(url: url)

        // ⚠️ 先隐藏播放按钮与控制条，等视频准备好再显示
        playButton.isHidden = true
        playButton.alpha = 1.0  // 重置 alpha，防止上次播放时被隐藏后残留
        controlsView.isHidden = true
        controlsView.reset()
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
                    // 就绪即显示控制条，让用户立刻看到总时长并可拖动
                    self.controlsView.isHidden = false
                    self.controlsView.setProgress(current: 0, duration: CMTimeGetSeconds(item.duration))
                    // 宿主已标记本页为当前页且开启自动播放：就绪即播（updatePlayButton 会淡出中央按钮）
                    if self.autoPlayOnReady && !self.isPlaying {
                        self.startPlayback()
                    }
                case .failed:
                    self.loadingIndicator.stopAnimating()
                    self.playButton.isHidden = true
                    self.controlsView.isHidden = true
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

    // MARK: - Live Photo 播放状态机

    /// 发起一次 Live Photo 播放。
    ///
    /// 已在播放中时返回 nil（长按去重）；否则标记为播放中，并返回本次播放代次——
    /// 调用方必须把它原样回传给 `playVideoDirectly(url:generation:)`，
    /// 抬指（stopVideo）自增代次后本次播放即自动作废。
    func beginLivePhotoPlayback() -> Int? {
        guard !isPlaying else { return nil }
        isPlaying = true
        return playbackGeneration
    }

    /// 放弃本次 Live Photo 播放（没有可播放的素材 / 抽帧失败）。
    /// 只清除「播放中」标记，不自增代次：此时播放器还没创建，没有回调需要作废。
    func abortLivePhotoPlayback() {
        isPlaying = false
    }

    /// 校验某次 Live Photo 播放代次是否仍是当前代次（手指未抬起、未开始新一轮）。
    /// PHLivePhotoView 路径（相册来源）在 requestLivePhoto 回调里据此决定是否真正开始播放，
    /// 与 `playVideoDirectly(url:generation:)` 内部的守卫同源——代次这一状态只存在于本类。
    func isPlaybackGenerationCurrent(_ generation: Int) -> Bool {
        generation == playbackGeneration
    }

    /// Live Photo 入口：无播放按钮，延迟一小段时间后自动播放并淡出封面图，
    /// 播放结束直接走 stopVideo() 复原。
    ///
    /// - Parameter generation: `beginLivePhotoPlayback()` 返回的播放代次；
    ///   与当前代次不符（手指已抬起）时整个调用直接作废，不创建播放器。
    func playVideoDirectly(url: URL, generation: Int) {
        guard generation == playbackGeneration else { return }

        let player = makePlayer(url: url)

        // 等待一小段时间后播放
        DispatchQueue.main.asyncAfter(deadline: .now() + UIConstants.Animation.videoPlayDelay) { [weak self] in
            guard let self = self else { return }

            // ⚠️ 延迟期间可能已经抬指：stopVideo() 会自增代次、把封面图淡回 alpha 1
            // 并在动画完成时置空播放器。此时若继续把封面图淡出，页面上既无播放器图层
            // 又无封面图，会整页空白。
            guard self.playbackGeneration == generation, self.videoPlayer != nil else { return }

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

    // MARK: - 播放控制

    func togglePlayPause() {
        guard let player = videoPlayer else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
            updatePlayButton(isPlaying: false)
        } else {
            startPlayback()
        }
    }

    /// 开始播放：togglePlayPause 的「播放」分支与自动播放共用，行为与原分支一致。
    private func startPlayback() {
        guard let player = videoPlayer else { return }
        player.play()
        isPlaying = true
        updatePlayButton(isPlaying: true)
        controlsView.isHidden = false

        // 隐藏图片显示视频
        UIView.animate(withDuration: 0.3) {
            self.imageView.alpha = 0
        }
    }

    /// 宿主在「本页成为当前可见页」时调用：开启自动播放。
    /// 播放器已就绪且未在播放则立即开始，否则仅置位、待 readyToPlay 时消费。
    func enableAutoPlayOnReady() {
        autoPlayOnReady = true
        if let player = videoPlayer,
           player.currentItem?.status == .readyToPlay,
           !isPlaying {
            startPlayback()
        }
    }

    /// 把 0~1 的进度换算成时间并 seek。总时长未知时忽略。
    private func seek(toFraction fraction: Float) {
        guard let player = videoPlayer,
              let duration = player.currentItem?.duration,
              duration.isNumeric else {
            // 无法 seek 时也要恢复进度更新，否则滑块会卡在「拖动中」状态
            controlsView.endScrubbing()
            return
        }
        let seconds = Double(fraction) * CMTimeGetSeconds(duration)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero) { [weak self] _ in
            // seek 完成回调线程不固定，切回主线程再恢复周期性进度更新
            DispatchQueue.main.async { self?.controlsView.endScrubbing() }
        }
    }

    private func updatePlayButton(isPlaying: Bool) {
        let iconName = isPlaying ? "pause.fill" : "play.fill"
        let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .medium)
        let image = UIImage(systemName: iconName, withConfiguration: config)
        playButton.setImage(image, for: .normal)
        playButton.tintColor = .white

        // 控制条上的小播放/暂停键与中央大按钮同步图标
        controlsView.setPlaying(isPlaying)

        // 播放时隐藏中央大按钮（控制条上的小键仍可用于暂停）
        UIView.animate(withDuration: 0.3) {
            self.playButton.alpha = isPlaying ? 0 : 1
        }
    }

    private func updateProgress(time: CMTime) {
        guard let item = videoPlayer?.currentItem else { return }
        // duration 早期可能为 NaN/未知，交由 controlsView.setProgress 兜底处理
        controlsView.setProgress(current: CMTimeGetSeconds(time),
                                 duration: CMTimeGetSeconds(item.duration))
    }

    private func videoPlaybackEnded() {
        isPlaying = false
        updatePlayButton(isPlaying: false)

        // 重置播放位置并把控制条回到起点
        videoPlayer?.seek(to: .zero)
        controlsView.setProgress(current: 0, duration: CMTimeGetSeconds(videoPlayer?.currentItem?.duration ?? .indefinite))

        // 显示图片
        UIView.animate(withDuration: 0.3) {
            self.imageView.alpha = 1
        }
    }

    /// 停止播放并拆除全部观察者。
    /// ⚠️ 顺序敏感：必须先自增播放代次，再拆观察者；removeTimeObserver 必须在
    /// videoPlayer 仍指向被观察的 player 时调用，因此置空只能放在动画完成回调里。
    func stopVideo() {
        // 自增播放代次，作废任何仍在进行中的 Live Photo 抽帧回调（见 playPhotoLibraryLivePhoto）
        playbackGeneration &+= 1

        // 翻走的页不应静默恢复自动播放；宿主在它再次成为当前页时会重新开启
        autoPlayOnReady = false

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
        controlsView.isHidden = true
        controlsView.reset()

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
