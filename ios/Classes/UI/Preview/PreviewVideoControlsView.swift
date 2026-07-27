import UIKit

// MARK: - 预览页视频控制条

/// 全屏预览里 AVPlayer 视频的底部控制条：播放/暂停、当前时间 / 总时长、可拖动进度。
///
/// 纯视图：不持有 AVPlayer，也不感知播放代次。所有交互都通过闭包回调交给
/// `PreviewVideoPlayerController`，由后者执行 play / pause / seek。之所以单独成文件，
/// 是为了把「怎么显示」与「怎么放」彻底分开——播放器控制器只调用
/// `setPlaying` / `setProgress` / `reset` 三个方法，绝不直接摆布这里的子视图。
///
/// 仅服务于 AVPlayer 的普通视频路径。相册 Live Photo 走 `PHLivePhotoView`，
/// 是长按瞬时播放，不挂本控制条。
final class PreviewVideoControlsView: UIView {

    // MARK: - 交互回调

    /// 播放/暂停按钮被点击
    var onPlayPauseTapped: (() -> Void)?

    /// 用户结束拖动，参数为 0~1 的目标进度；调用方据此 seek
    var onScrubEnded: ((Float) -> Void)?

    // MARK: - 子视图

    private let playPauseButton = UIButton(type: .system)
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private let slider = UISlider()

    // MARK: - 状态

    /// 是否正在被用户拖动：为真时忽略 `setProgress`，避免时间观察者与手指抢滑块。
    private var isScrubbing = false

    /// 最近一次已知的总时长（秒）；拖动过程中据此把滑块比例换算成时间标签。
    private var durationSeconds: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 视图装配

    private func setupUI() {
        // 深色半透明底条
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 12
        blur.clipsToBounds = true
        addSubview(blur)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let content = blur.contentView

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: symbolConfig), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)

        for label in [currentTimeLabel, durationLabel] {
            label.textColor = .white
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        currentTimeLabel.text = "0:00"
        durationLabel.text = "0:00"
        currentTimeLabel.textAlignment = .left
        durationLabel.textAlignment = .right

        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.setThumbImage(makeThumbImage(), for: .normal)
        slider.value = 0
        slider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        let stack = UIStackView(arrangedSubviews: [playPauseButton, currentTimeLabel, slider, durationLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        // 三个非滑块控件不参与拉伸，滑块吃掉剩余空间
        playPauseButton.setContentHuggingPriority(.required, for: .horizontal)
        playPauseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        currentTimeLabel.setContentHuggingPriority(.required, for: .horizontal)
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            playPauseButton.widthAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
    }

    /// 白色圆点滑块 thumb（系统默认 thumb 偏大且带阴影，这里换成克制的小圆点）
    private func makeThumbImage() -> UIImage {
        let diameter: CGFloat = 12
        return UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter)).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        }
    }

    // MARK: - 对外更新入口

    /// 更新播放/暂停按钮图标
    func setPlaying(_ isPlaying: Bool) {
        let name = isPlaying ? "pause.fill" : "play.fill"
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        playPauseButton.setImage(UIImage(systemName: name, withConfiguration: symbolConfig), for: .normal)
    }

    /// 用当前播放时间与总时长刷新时间标签与滑块。
    /// 拖动过程中整体忽略，避免时间观察者驱动的刷新与手指相争。
    /// 总时长未知 / 无穷（直播、尚未就绪）时右侧显示 "--:--" 且滑块归零。
    func setProgress(current: TimeInterval, duration: TimeInterval) {
        guard !isScrubbing else { return }
        let safeDuration = (duration.isFinite && duration > 0) ? duration : 0
        durationSeconds = safeDuration
        currentTimeLabel.text = Self.formatTime(current)
        durationLabel.text = safeDuration > 0 ? Self.formatTime(safeDuration) : "--:--"
        slider.value = safeDuration > 0 ? Float(min(max(current / safeDuration, 0), 1)) : 0
    }

    /// 复位到初始态（停止播放后调用）
    func reset() {
        isScrubbing = false
        durationSeconds = 0
        slider.value = 0
        currentTimeLabel.text = "0:00"
        durationLabel.text = "0:00"
        setPlaying(false)
    }

    // MARK: - 交互

    @objc private func playPauseTapped() {
        onPlayPauseTapped?()
    }

    @objc private func scrubBegan() {
        isScrubbing = true
    }

    @objc private func scrubChanged() {
        // 拖动中实时把当前时间标签跟到滑块位置（总时长已知时）
        guard durationSeconds > 0 else { return }
        currentTimeLabel.text = Self.formatTime(Double(slider.value) * durationSeconds)
    }

    @objc private func scrubEnded() {
        // 不在此处放开 isScrubbing：先请求 seek，等它真正落定后由控制器调 endScrubbing()。
        // 否则 seek 完成前的周期性回调会读到尚未更新的 currentTime，把滑块短暂拉回旧位置（回跳）。
        onScrubEnded?(slider.value)
    }

    /// 由控制器在 `player.seek` 完成后（或无法 seek 时）调用，恢复周期性进度更新。
    func endScrubbing() {
        isScrubbing = false
    }

    // MARK: - 工具

    /// 秒 → `m:ss`；非法 / 未知时长返回 "--:--"
    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
