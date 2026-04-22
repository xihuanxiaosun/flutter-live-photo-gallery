import UIKit
import Photos

class PhotoGridCell: UICollectionViewCell {
    
    // MARK: - Properties

    private var showRadio: Bool = true
    private var currentRequestID: PHImageRequestID?
    
    // MARK: - UI Components
    
    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        return iv
    }()
    
    private let livePhotoBadge: UIImageView = {
        let iv = UIImageView()
        iv.image = createLivePhotoBadgeImage()
        iv.isHidden = true
        return iv
    }()
    
    private let selectedOverlay: UIView = {
        let view = UIView()
        // 选中时加深色遮罩，使序号数字更清晰可见
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        view.alpha = 0
        return view
    }()
    
    private let videoBadge: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.layer.cornerRadius = 4
        view.isHidden = true
        return view
    }()
    
    private let videoIcon: UIImageView = {
        let iv = UIImageView()
        iv.image = createVideoIcon()
        iv.tintColor = .white
        return iv
    }()
    
    private let durationLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        return label
    }()
    
    private let radioButton: UIView = {
        let view = UIView()
        view.isHidden = true
        return view
    }()
    
    private let radioCircle: UIView = {
        let view = UIView()
        view.layer.cornerRadius = UIConstants.PhotoCell.radioButtonCornerRadius
        view.layer.borderWidth = UIConstants.PhotoCell.radioButtonBorderWidth
        view.layer.borderColor = UIColor.white.cgColor
        // 未选中时加轻微阴影，确保白色边框在浅色图片上可见
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.35
        view.layer.shadowRadius = 2
        view.layer.shadowOffset = .zero
        return view
    }()
    
    private let radioLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textAlignment = .center
        return label
    }()
    
    // MARK: - Initialization
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        // 第一层：添加所有主要视图到 contentView
        contentView.addSubview(imageView)
        contentView.addSubview(livePhotoBadge)
        contentView.addSubview(selectedOverlay)
        contentView.addSubview(videoBadge)
        contentView.addSubview(radioButton)
        
        // 第二层：添加 videoBadge 的子视图
        videoBadge.addSubview(videoIcon)
        videoBadge.addSubview(durationLabel)
        
        // 第二层：添加 radioButton 的子视图
        radioButton.addSubview(radioCircle)
        radioButton.addSubview(radioLabel)
        
        // 禁用所有视图的自动约束
        imageView.translatesAutoresizingMaskIntoConstraints = false
        livePhotoBadge.translatesAutoresizingMaskIntoConstraints = false
        selectedOverlay.translatesAutoresizingMaskIntoConstraints = false
        videoBadge.translatesAutoresizingMaskIntoConstraints = false
        videoIcon.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        radioButton.translatesAutoresizingMaskIntoConstraints = false
        radioCircle.translatesAutoresizingMaskIntoConstraints = false
        radioLabel.translatesAutoresizingMaskIntoConstraints = false
        
        // 设置约束
        NSLayoutConstraint.activate([
            // 图片 - 填满整个 cell
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            
            // Live Photo 角标 - 左上角
            livePhotoBadge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            livePhotoBadge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            livePhotoBadge.widthAnchor.constraint(equalToConstant: UIConstants.PhotoCell.livePhotoBadgeSize),
            livePhotoBadge.heightAnchor.constraint(equalToConstant: UIConstants.PhotoCell.livePhotoBadgeSize),
            
            // 选中遮罩 - 填满整个 cell
            selectedOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            selectedOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            selectedOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            selectedOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            
            // 视频标记 - 左下角
            videoBadge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            videoBadge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            videoBadge.heightAnchor.constraint(equalToConstant: UIConstants.PhotoCell.videoBadgeHeight),
            videoBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),

            // 视频图标 - videoBadge 内部
            videoIcon.leadingAnchor.constraint(equalTo: videoBadge.leadingAnchor, constant: 4),
            videoIcon.centerYAnchor.constraint(equalTo: videoBadge.centerYAnchor),
            videoIcon.widthAnchor.constraint(equalToConstant: UIConstants.PhotoCell.videoIconSize),
            videoIcon.heightAnchor.constraint(equalToConstant: UIConstants.PhotoCell.videoIconSize),
            
            // 时长标签 - videoBadge 内部
            durationLabel.leadingAnchor.constraint(equalTo: videoIcon.trailingAnchor, constant: 4),
            durationLabel.trailingAnchor.constraint(equalTo: videoBadge.trailingAnchor, constant: -4),
            durationLabel.centerYAnchor.constraint(equalTo: videoBadge.centerYAnchor),
            
            // 序号按钮 - 右上角
            radioButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            radioButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            radioButton.widthAnchor.constraint(equalToConstant: UIConstants.PhotoCell.radioButtonSize),
            radioButton.heightAnchor.constraint(equalToConstant: UIConstants.PhotoCell.radioButtonSize),
            
            // 圆圈 - radioButton 内部
            radioCircle.topAnchor.constraint(equalTo: radioButton.topAnchor),
            radioCircle.leadingAnchor.constraint(equalTo: radioButton.leadingAnchor),
            radioCircle.trailingAnchor.constraint(equalTo: radioButton.trailingAnchor),
            radioCircle.bottomAnchor.constraint(equalTo: radioButton.bottomAnchor),
            
            // 序号文字 - radioButton 内部
            radioLabel.centerXAnchor.constraint(equalTo: radioButton.centerXAnchor),
            radioLabel.centerYAnchor.constraint(equalTo: radioButton.centerYAnchor),
        ])
    }
    
    // MARK: - Configuration
    
    func configure(
        with asset: PhotoAssetModel,
        selectionIndex: Int?,
        showRadio: Bool
    ) {
        self.showRadio = showRadio

        // 取消之前的图片请求
        if let requestID = currentRequestID {
            PhotoLibraryManager.shared.cancelImageRequest(requestID)
        }

        // 加载缩略图 - 使用适中的尺寸，性能和清晰度平衡
        // PhotoGridCell 只用于相册照片，所以这里应该总是有 PHAsset
        if let phAsset = asset.asset {
            let size = CGSize(width: bounds.width * 2, height: bounds.height * 2)
            currentRequestID = PhotoLibraryManager.shared.requestThumbnail(for: phAsset, size: size) { [weak self] image in
                DispatchQueue.main.async {
                    self?.imageView.image = image
                }
            }
        }
        
        // Live Photo 角标
        livePhotoBadge.isHidden = !asset.isLivePhoto || asset.isVideo
        
        // 视频标记
        if asset.isVideo {
            videoBadge.isHidden = false
            durationLabel.text = formatDuration(asset.videoDuration)
        } else {
            videoBadge.isHidden = true
        }
        
        // 选中状态（用 alpha 动画代替 isHidden，避免 reloadItems 时闪烁）
        let isSelected = asset.isSelected
        let targetAlpha: CGFloat = isSelected ? 1 : 0
        if selectedOverlay.alpha != targetAlpha {
            UIView.animate(withDuration: 0.15) {
                self.selectedOverlay.alpha = targetAlpha
            }
        }
        
        if showRadio {
            radioButton.isHidden = false
            
            if let index = selectionIndex {
                radioCircle.backgroundColor = tintColor
                radioCircle.layer.borderColor = tintColor.cgColor
                radioLabel.text = "\(index + 1)"
                radioLabel.isHidden = false
            } else {
                radioCircle.backgroundColor = .clear
                radioCircle.layer.borderColor = UIColor.white.cgColor
                radioLabel.isHidden = true
            }
        } else {
            radioButton.isHidden = true
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()

        // 取消图片请求
        if let requestID = currentRequestID {
            PhotoLibraryManager.shared.cancelImageRequest(requestID)
            currentRequestID = nil
        }

        imageView.image = nil
        livePhotoBadge.isHidden = true
        videoBadge.isHidden = true
        selectedOverlay.alpha = 0
        radioButton.isHidden = true
    }
    
    // MARK: - 选中状态局部更新（不触发 prepareForReuse / 图片重载）

    /// 仅刷新遮罩和序号圆圈，不碰缩略图，避免 reloadItems 导致的闪烁
    func updateSelectionState(isSelected: Bool, selectionIndex: Int?, animated: Bool = true) {
        let targetAlpha: CGFloat = isSelected ? 1 : 0
        if selectedOverlay.alpha != targetAlpha {
            if animated {
                UIView.animate(withDuration: 0.15) { self.selectedOverlay.alpha = targetAlpha }
            } else {
                selectedOverlay.alpha = targetAlpha
            }
        }

        guard showRadio else { return }
        if let index = selectionIndex {
            radioCircle.backgroundColor = tintColor
            radioCircle.layer.borderColor = tintColor.cgColor
            radioLabel.text = "\(index + 1)"
            radioLabel.isHidden = false
        } else {
            radioCircle.backgroundColor = .clear
            radioCircle.layer.borderColor = UIColor.white.cgColor
            radioLabel.isHidden = true
        }
    }

    // MARK: - Hit Test

    func isRadioButtonTapped(at point: CGPoint) -> Bool {
        let convertedPoint = convert(point, to: radioButton)
        let expandSize = UIConstants.PhotoCell.radioButtonExpandSize
        let expandedFrame = radioButton.bounds.insetBy(dx: -expandSize, dy: -expandSize)
        return expandedFrame.contains(convertedPoint) && !radioButton.isHidden
    }
    
    // MARK: - Helper Methods
    
    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
    
    private static func createLivePhotoBadgeImage() -> UIImage? {
        let size = CGSize(width: 24, height: 24)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            UIColor.black.withAlphaComponent(0.6).setFill()
            let circle = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 24, height: 24))
            circle.fill()
            
            let text = "LIVE"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(
                x: (24 - textSize.width) / 2,
                y: (24 - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attributes)
        }
    }
    
    private static func createVideoIcon() -> UIImage? {
        let size = CGSize(width: 12, height: 12)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            UIColor.white.setFill()
            
            let triangle = UIBezierPath()
            triangle.move(to: CGPoint(x: 2, y: 1))
            triangle.addLine(to: CGPoint(x: 2, y: 11))
            triangle.addLine(to: CGPoint(x: 10, y: 6))
            triangle.close()
            triangle.fill()
        }
    }
}
