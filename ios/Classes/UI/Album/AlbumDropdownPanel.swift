import UIKit
import Photos

// MARK: - AlbumDropdownPanel

/// 从导航栏下方滑出的相册切换面板（微信风格）
final class AlbumDropdownPanel: UIView {

    // MARK: - Callbacks

    var onSelect: ((AlbumModel) -> Void)?
    /// 面板关闭时回调（点遮罩或选择后均触发）
    var onDismiss: (() -> Void)?

    // MARK: - Private State

    private var albums: [AlbumModel] = []
    private var currentAlbumTitle: String = ""
    private var navBarBottom: CGFloat = 0
    private let panelHeight: CGFloat = UIScreen.main.bounds.height * 0.5

    // MARK: - UI

    /// 点击关闭的半透明遮罩（navBarBottom 以下区域）
    private let dimView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        return v
    }()

    /// 裁剪容器：从 navBarBottom 起，高度从 0 动画到 panelHeight
    /// 这样面板看起来是从 appbar 下方向下展开，而不是从屏幕顶部滑入
    private let clipArea: UIView = {
        let v = UIView()
        v.clipsToBounds = true  // 关键：裁剪溢出内容
        return v
    }()

    /// 面板内容（在 clipArea 内部，位置固定在 (0,0)）
    private let panel: UIView = {
        let v = UIView()
        v.backgroundColor = .systemBackground
        v.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        v.layer.cornerRadius = 16
        return v
    }()

    /// 顶部拖动指示条
    private let handleBar: UIView = {
        let v = UIView()
        v.backgroundColor = .tertiaryLabel
        v.layer.cornerRadius = 2.5
        return v
    }()

    private let tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.separatorStyle = .none
        tv.backgroundColor = .clear
        tv.showsVerticalScrollIndicator = false
        tv.register(AlbumDropdownCell.self, forCellReuseIdentifier: AlbumDropdownCell.reuseId)
        return tv
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        tableView.delegate = self
        tableView.dataSource = self
        setupLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func setupLayout() {
        addSubview(dimView)
        addSubview(clipArea)
        clipArea.addSubview(panel)
        panel.addSubview(handleBar)
        panel.addSubview(tableView)
    }

    // MARK: - Show / Dismiss

    /// 展示面板。container 为 navigationController.view，navBarBottom 为导航栏底部 Y
    func show(
        in container: UIView,
        navBarBottom: CGFloat,
        albums: [AlbumModel],
        currentAlbumTitle: String
    ) {
        self.albums = albums
        self.currentAlbumTitle = currentAlbumTitle
        self.navBarBottom = navBarBottom

        frame = container.bounds
        container.addSubview(self)

        let w = bounds.width
        let h = bounds.height

        // 遮罩：navBarBottom 以下全部区域
        dimView.frame = CGRect(x: 0, y: navBarBottom, width: w, height: h - navBarBottom)
        dimView.alpha = 0

        // clipArea：从 navBarBottom 开始，初始高度为 0（动画展开到 panelHeight）
        // clipsToBounds=true 保证面板内容被正确裁剪，动画才有效果
        clipArea.frame = CGRect(x: 0, y: navBarBottom, width: w, height: 0)

        // panel：在 clipArea 内部占满完整高度（固定不动，由 clipArea 高度控制显示范围）
        panel.frame = CGRect(x: 0, y: 0, width: w, height: panelHeight)

        // 拖动条
        handleBar.frame = CGRect(x: (w - 36) / 2, y: 8, width: 36, height: 5)

        // TableView
        tableView.frame = CGRect(x: 0, y: 20, width: w, height: panelHeight - 20)
        tableView.reloadData()
        if let idx = albums.firstIndex(where: { $0.title == currentAlbumTitle }) {
            tableView.scrollToRow(at: IndexPath(row: idx, section: 0), at: .middle, animated: false)
        }

        // 遮罩点击关闭
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismiss))
        dimView.addGestureRecognizer(tap)

        // 动画：clipArea 高度从 0 展开到 panelHeight，面板从 appbar 下方向下展开
        UIView.animate(
            withDuration: 0.36,
            delay: 0,
            usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0.3,
            options: [.curveEaseOut]
        ) {
            self.dimView.alpha = 1
            self.clipArea.frame.size.height = self.panelHeight
        }
    }

    // MARK: - Hit Test

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 导航栏及以上区域（状态栏 + 导航栏）穿透处理：
        // AlbumDropdownPanel 铺满全屏，若不穿透则会吞掉导航栏按钮（取消等）的触摸事件
        if navBarBottom > 0, point.y < navBarBottom {
            return nil
        }
        return super.hitTest(point, with: event)
    }

    @objc func dismiss() {
        UIView.animate(
            withDuration: 0.24,
            delay: 0,
            options: [.curveEaseIn]
        ) {
            self.dimView.alpha = 0
            self.clipArea.frame.size.height = 0
        } completion: { _ in
            self.removeFromSuperview()
            self.onDismiss?()
        }
    }
}

// MARK: - UITableViewDelegate, UITableViewDataSource

extension AlbumDropdownPanel: UITableViewDelegate, UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        albums.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: AlbumDropdownCell.reuseId, for: indexPath
        ) as! AlbumDropdownCell
        let album = albums[indexPath.row]
        cell.configure(album: album, isSelected: album.title == currentAlbumTitle)
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 72 }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let album = albums[indexPath.row]
        onSelect?(album)
        dismiss()
    }
}

// MARK: - AlbumDropdownCell

private final class AlbumDropdownCell: UITableViewCell {

    static let reuseId = "AlbumDropdownCell"

    // MARK: - UI

    private let coverImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 6
        iv.backgroundColor = .systemGray5
        return iv
    }()

    private let nameLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 16, weight: .semibold)
        l.textColor = .label
        return l
    }()

    private let countLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        return l
    }()

    private let checkmark: UIImageView = {
        let iv = UIImageView()
        iv.image = UIImage(systemName: "checkmark",
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        iv.tintColor = .tintColor
        iv.isHidden = true
        return iv
    }()

    private var requestID: PHImageRequestID?

    // MARK: - Init

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        setupLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupLayout() {
        [coverImageView, nameLabel, countLabel, checkmark].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            // 封面：左边距 16，垂直居中，60×60
            coverImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            coverImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            coverImageView.widthAnchor.constraint(equalToConstant: 56),
            coverImageView.heightAnchor.constraint(equalToConstant: 56),

            // 名称：封面右边 12pt，垂直偏上
            nameLabel.leadingAnchor.constraint(equalTo: coverImageView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: checkmark.leadingAnchor, constant: -8),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -1),

            // 数量：名称正下方
            countLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            countLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            countLabel.topAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 3),

            // 勾选：右边距 20，垂直居中
            checkmark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            checkmark.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 20),
            checkmark.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    // MARK: - Configure

    func configure(album: AlbumModel, isSelected: Bool) {
        nameLabel.text = album.title
        countLabel.text = "\(album.count) 张"
        checkmark.isHidden = !isSelected
        nameLabel.font = isSelected
            ? .systemFont(ofSize: 16, weight: .bold)
            : .systemFont(ofSize: 16, weight: .semibold)

        // 取消旧请求
        if let rid = requestID {
            PHImageManager.default().cancelImageRequest(rid)
        }

        // 获取相册封面（最新一张）
        let fetchOpts = PHFetchOptions()
        fetchOpts.fetchLimit = 1
        fetchOpts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(in: album.collection, options: fetchOpts)

        coverImageView.image = nil
        guard let asset = assets.firstObject else { return }

        let size = CGSize(width: 112, height: 112) // @2x
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true

        requestID = PHImageManager.default().requestImage(
            for: asset, targetSize: size, contentMode: .aspectFill, options: options
        ) { [weak self] image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            guard !isDegraded, let image else { return }
            DispatchQueue.main.async {
                self?.coverImageView.image = image
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let rid = requestID {
            PHImageManager.default().cancelImageRequest(rid)
            requestID = nil
        }
        coverImageView.image = nil
        checkmark.isHidden = true
    }
}
