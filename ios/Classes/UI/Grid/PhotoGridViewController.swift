import UIKit
import Photos

class PhotoGridViewController: UIViewController {

    // MARK: - Properties

    private let albums: [AlbumModel]
    private var currentAlbum: AlbumModel
    private let config: PickerConfig
    private let completion: ([PhotoAssetModel], Bool) -> Void

    /// 用户尝试超出 maxCount 时触发（参数为 maxCount 值），供 native → Flutter 回调
    var onMaxCountReached: ((Int) -> Void)?

    private var assets: [PhotoAssetModel] = []
    private var sections: [PhotoSection] = []
    private var selectedAssets: [PhotoAssetModel] = []
    private var timeFilterType: TimeFilterType = .month
    private var isOriginalPhoto: Bool = false
    private var accurateTotalSize: Int64 = 0
    /// 每次发起大小计算时递增，回调中对比 token，丢弃过期结果
    private var sizeRequestToken: Int = 0
    private weak var albumDropdown: AlbumDropdownPanel?

    // MARK: - UI Components

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = UIConstants.Grid.spacing
        layout.minimumInteritemSpacing = UIConstants.Grid.spacing
        layout.sectionHeadersPinToVisibleBounds = true

        let width = UIConstants.Grid.itemWidth(containerWidth: view.bounds.width)
        layout.itemSize = CGSize(width: width, height: width)
        layout.headerReferenceSize = CGSize(width: view.bounds.width, height: 44)

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.delegate = self
        cv.dataSource = self
        cv.backgroundColor = .systemBackground
        cv.register(PhotoGridCell.self, forCellWithReuseIdentifier: "PhotoCell")
        cv.register(
            PhotoSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: PhotoSectionHeaderView.reuseIdentifier
        )
        return cv
    }()

    private lazy var bottomBar: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBackground
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.1
        view.layer.shadowOffset = CGSize(width: 0, height: -2)
        view.layer.shadowRadius = 4
        return view
    }()

    private lazy var doneButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "完成"
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs; a.font = .systemFont(ofSize: 15, weight: .semibold); return a
        }
        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        button.isEnabled = false
        return button
    }()

    private lazy var originalPhotoButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "circle",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .light))
        config.title = "原图"
        config.imagePadding = 5
        config.baseForegroundColor = .secondaryLabel
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(originalPhotoToggled), for: .touchUpInside)
        return button
    }()

    private lazy var filterChipsView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .systemBackground
        return scrollView
    }()

    private lazy var chipsStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.distribution = .equalSpacing
        return stack
    }()

    // 用独立 label + imageView 替代 UIButton.Configuration，
    // 这样可以直接对 arrowImageView 做 transform 旋转动画
    private let navTitleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 17, weight: .semibold)
        l.textColor = .label
        return l
    }()

    private let navTitleArrow: UIImageView = {
        let iv = UIImageView()
        iv.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        )
        iv.tintColor = .label
        iv.contentMode = .scaleAspectFit
        return iv
    }()

    // 保留旧名方便其他地方引用（实际已不作为 titleView 使用）
    private var albumTitleButton: UIView { navTitleContainer }

    private lazy var navTitleContainer: UIView = {
        let stack = UIStackView(arrangedSubviews: [navTitleLabel, navTitleArrow])
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(albumTitleTapped))
        stack.addGestureRecognizer(tap)
        return stack
    }()

    // MARK: - Initialization

    init(albums: [AlbumModel], selectedAlbum: AlbumModel, config: PickerConfig, completion: @escaping ([PhotoAssetModel], Bool) -> Void) {
        self.albums = albums
        self.currentAlbum = selectedAlbum
        self.config = config
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupGestures()
        loadAssets()
        updateDoneButton()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        PhotoLibraryManager.shared.stopCachingAll()
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground

        navTitleLabel.text = currentAlbum.title
        navigationItem.titleView = navTitleContainer
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消", style: .plain, target: self, action: #selector(cancelTapped)
        )

        view.addSubview(filterChipsView)
        filterChipsView.addSubview(chipsStackView)
        view.addSubview(collectionView)
        view.addSubview(bottomBar)
        bottomBar.addSubview(originalPhotoButton)
        bottomBar.addSubview(doneButton)

        [filterChipsView, chipsStackView, collectionView, bottomBar, originalPhotoButton, doneButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        // 底部栏延伸至屏幕底部（覆盖 home indicator 区域），内容在安全区域上方居中
        // 参考微信效果：bar 背景到底，按钮在 safe area 上方
        let barContentHeight: CGFloat = UIConstants.BottomBar.height

        NSLayoutConstraint.activate([
            filterChipsView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            filterChipsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filterChipsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filterChipsView.heightAnchor.constraint(equalToConstant: 50),

            chipsStackView.leadingAnchor.constraint(equalTo: filterChipsView.leadingAnchor, constant: 16),
            chipsStackView.trailingAnchor.constraint(equalTo: filterChipsView.trailingAnchor, constant: -16),
            chipsStackView.topAnchor.constraint(equalTo: filterChipsView.topAnchor, constant: 8),
            chipsStackView.bottomAnchor.constraint(equalTo: filterChipsView.bottomAnchor, constant: -8),
            chipsStackView.heightAnchor.constraint(equalToConstant: 34),

            // collectionView 底部对齐安全区域底部上方 barContentHeight
            collectionView.topAnchor.constraint(equalTo: filterChipsView.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                                   constant: -barContentHeight),

            // 底部栏背景：从内容区顶部延伸到屏幕底部
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                           constant: -barContentHeight),

            // 按钮垂直居中于内容区（safe area 上方 barContentHeight 区域）
            originalPhotoButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            originalPhotoButton.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                                         constant: -(barContentHeight / 2)),

            doneButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            doneButton.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                                constant: -(barContentHeight / 2)),
            doneButton.leadingAnchor.constraint(greaterThanOrEqualTo: originalPhotoButton.trailingAnchor,
                                                constant: 12),
        ])

        setupFilterChips()
    }

    private func setupFilterChips() {
        let filters: [TimeFilterType] = [.all, .day, .month, .year]
        for (index, filter) in filters.enumerated() {
            let chip = makeChip(title: filter.rawValue, isSelected: filter == timeFilterType)
            chip.tag = index
            chip.addTarget(self, action: #selector(filterChipTapped(_:)), for: .touchUpInside)
            chipsStackView.addArrangedSubview(chip)
        }
    }

    private func makeChip(title: String, isSelected: Bool) -> UIButton {
        let button = UIButton(type: .system)
        button.layer.cornerRadius = 17
        var btnConfig = UIButton.Configuration.filled()
        btnConfig.title = title
        btnConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs; a.font = .systemFont(ofSize: 14, weight: .medium); return a
        }
        btnConfig.baseForegroundColor = isSelected ? .white : .label
        btnConfig.baseBackgroundColor = isSelected ? .tintColor : UIColor.systemGray6
        btnConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        button.configuration = btnConfig
        return button
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        collectionView.addGestureRecognizer(tap)
    }

    // MARK: - Data

    private func loadAssets() {
        assets = PhotoLibraryManager.shared.fetchAssets(
            in: currentAlbum.collection,
            config: config
        )
        sections = PhotoGrouper.groupAssets(assets, by: timeFilterType)
        collectionView.reloadData()
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true)
        completion([], false)
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
        completion(selectedAssets, isOriginalPhoto)
    }

    @objc private func originalPhotoToggled() {
        isOriginalPhoto.toggle()
        if isOriginalPhoto {
            originalPhotoButton.configuration?.image = UIImage(
                systemName: "checkmark.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            )
            originalPhotoButton.configuration?.baseForegroundColor = originalPhotoButton.tintColor
            if !selectedAssets.isEmpty { updateOriginalPhotoSize() }
        } else {
            originalPhotoButton.configuration?.image = UIImage(
                systemName: "circle",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .light)
            )
            originalPhotoButton.configuration?.baseForegroundColor = .secondaryLabel
            originalPhotoButton.configuration?.title = "原图"
        }
    }

    @objc private func albumTitleTapped() {
        guard let navView = navigationController?.view,
              let navBar = navigationController?.navigationBar else { return }

        // 已展开则收起
        if let existing = albumDropdown {
            existing.dismiss()
            return
        }

        // 箭头向上（展开状态）
        setTitleArrow(up: true)

        let panel = AlbumDropdownPanel()
        albumDropdown = panel

        // 选相册后切换并收起
        panel.onSelect = { [weak self] album in
            guard let self else { return }
            self.switchToAlbum(album)
        }

        // 面板关闭时（点遮罩或选择后）箭头复位
        panel.onDismiss = { [weak self] in
            self?.setTitleArrow(up: false)
            self?.albumDropdown = nil
        }

        panel.show(
            in: navView,
            navBarBottom: navBar.frame.maxY,
            albums: albums,
            currentAlbumTitle: currentAlbum.title
        )
    }

    private func setTitleArrow(up: Bool) {
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) {
            self.navTitleArrow.transform = up
                ? CGAffineTransform(rotationAngle: .pi)
                : .identity
        }
    }

    @objc private func filterChipTapped(_ sender: UIButton) {
        let filters: [TimeFilterType] = [.all, .day, .month, .year]
        guard sender.tag < filters.count else { return }
        timeFilterType = filters[sender.tag]

        for (index, view) in chipsStackView.arrangedSubviews.enumerated() {
            guard let chip = view as? UIButton else { continue }
            let selected = index == sender.tag
            chip.configuration?.baseBackgroundColor = selected ? .tintColor : UIColor.systemGray6
            chip.configuration?.baseForegroundColor = selected ? .white : .label
        }

        sections = PhotoGrouper.groupAssets(assets, by: timeFilterType)
        collectionView.reloadData()
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: location),
              let cell = collectionView.cellForItem(at: indexPath) as? PhotoGridCell,
              indexPath.section < sections.count,
              indexPath.item < sections[indexPath.section].assets.count else {
            return
        }

        let asset = sections[indexPath.section].assets[indexPath.item]
        let cellLocation = gesture.location(in: cell)

        if cell.isRadioButtonTapped(at: cellLocation) {
            toggleSelection(asset: asset, at: indexPath)
        } else {
            openPreview(at: indexPath)
        }
    }

    // MARK: - Selection

    private func toggleSelection(asset: PhotoAssetModel, at indexPath: IndexPath) {
        if asset.isSelected {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            asset.isSelected = false
            selectedAssets.removeAll { $0.id == asset.id }
        } else {
            guard selectedAssets.count < config.maxCount else {
                onMaxCountReached?(config.maxCount)
                showAlert(message: "最多只能选择 \(config.maxCount) 张照片")
                return
            }
            // maxVideoCount 限制：-1 = 无限制
            if config.maxVideoCount >= 0 && (asset.isVideo || asset.isLivePhoto) {
                let currentVideoCount = selectedAssets.filter { $0.isVideo || $0.isLivePhoto }.count
                if currentVideoCount >= config.maxVideoCount {
                    showAlert(message: "最多只能选择 \(config.maxVideoCount) 个视频/实况照片")
                    return
                }
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            asset.isSelected = true
            selectedAssets.append(asset)
        }
        // 刷新所有已选中的 cell，以更新序号（如 1,2,3 去掉 2 后，3 需重排为 2）
        reloadSelectedCells(including: indexPath)
        updateDoneButton()
    }

    /// 直接更新 cell 选中 UI，不触发 reloadItems（避免图片闪烁）
    /// 可见 cell 直接改；不可见 cell 下次 cellForItemAt 时 configure 会自动设对
    private func reloadSelectedCells(including changedIndexPath: IndexPath) {
        var toUpdate = Set<IndexPath>([changedIndexPath])
        for (si, section) in sections.enumerated() {
            for (ii, asset) in section.assets.enumerated() where asset.isSelected {
                toUpdate.insert(IndexPath(item: ii, section: si))
            }
        }
        for indexPath in toUpdate {
            guard let cell = collectionView.cellForItem(at: indexPath) as? PhotoGridCell,
                  indexPath.section < sections.count,
                  indexPath.item < sections[indexPath.section].assets.count else { continue }
            let asset = sections[indexPath.section].assets[indexPath.item]
            let selectionIndex = selectedAssets.firstIndex { $0.id == asset.id }
            cell.updateSelectionState(isSelected: asset.isSelected, selectionIndex: selectionIndex)
        }
    }

    private func updateDoneButton() {
        let count = selectedAssets.count
        doneButton.configuration?.title = count > 0 ? "完成(\(count))" : "完成"
        doneButton.isEnabled = count > 0

        if isOriginalPhoto && count > 0 {
            updateOriginalPhotoSize()
        } else if count == 0 {
            originalPhotoButton.configuration?.title = "原图"
        }
    }

    /// 将原图按钮 UI 同步为当前 isOriginalPhoto 状态（预览返回后调用）
    private func syncOriginalPhotoButtonUI() {
        if isOriginalPhoto {
            originalPhotoButton.configuration?.image = UIImage(
                systemName: "checkmark.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            )
            originalPhotoButton.configuration?.baseForegroundColor = originalPhotoButton.tintColor
            if !selectedAssets.isEmpty { updateOriginalPhotoSize() }
        } else {
            originalPhotoButton.configuration?.image = UIImage(
                systemName: "circle",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .light)
            )
            originalPhotoButton.configuration?.baseForegroundColor = .secondaryLabel
            originalPhotoButton.configuration?.title = "原图"
        }
    }

    private func updateOriginalPhotoSize() {
        let phAssets = selectedAssets.compactMap { $0.asset }
        guard !phAssets.isEmpty else { return }

        // 每次发起新请求时 token +1，回调中对比 token
        // 若 token 已过期（用户又选/取消了图片触发了新请求），直接丢弃旧结果
        sizeRequestToken += 1
        let myToken = sizeRequestToken

        // 计算期间保持当前按钮文字不变（不显示估算跳跃值）
        // 仅在按钮当前没有显示大小时才显示估算，避免闪烁
        let currentTitle = originalPhotoButton.configuration?.title ?? ""
        if currentTitle == "原图" {
            // 还没有任何大小信息时，先显示估算作为占位，用户不会感知跳跃
            let estimated = phAssets.reduce(Int64(0)) { $0 + PhotoLibraryManager.shared.estimateFileSize(for: $1) }
            updateOriginalPhotoButtonTitle(size: estimated, isEstimated: true, animated: false)
        }

        // 异步计算：忽略 progress 中间态，只用最终值
        PhotoLibraryManager.shared.getTotalFileSize(
            for: phAssets,
            progress: { _, _ in /* 不使用中间态，避免跳跃 */ },
            completion: { [weak self] totalSize in
                guard let self, self.sizeRequestToken == myToken else { return }  // token 已过期，丢弃
                self.accurateTotalSize = totalSize
                self.updateOriginalPhotoButtonTitle(size: totalSize, isEstimated: false, animated: true)
            }
        )
    }

    private func updateOriginalPhotoButtonTitle(size: Int64, isEstimated: Bool, animated: Bool = false) {
        let sizeMB = Double(size) / 1024 / 1024
        let sizeText = sizeMB < 1
            ? String(format: "%.0fKB", Double(size) / 1024)
            : String(format: "%.1fMB", sizeMB)
        let prefix = isEstimated ? "原图 约" : "原图 "
        let newTitle = prefix + sizeText

        if animated {
            // 淡出当前文字 → 更新 → 淡入新文字，平滑切换无跳跃感
            UIView.transition(
                with: originalPhotoButton,
                duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: { self.originalPhotoButton.configuration?.title = newTitle }
            )
        } else {
            originalPhotoButton.configuration?.title = newTitle
        }
    }

    // MARK: - Preview

    private func openPreview(at indexPath: IndexPath) {
        var sourceFrame: CGRect = .zero
        if let cell = collectionView.cellForItem(at: indexPath) {
            sourceFrame = cell.convert(cell.bounds, to: nil)
        }

        let globalIndex = calculateGlobalIndex(for: indexPath)

        let previewVC = PhotoPreviewPageViewController(
            assets: assets,
            selectedAssets: selectedAssets,
            initialIndex: globalIndex,
            sourceFrame: sourceFrame,
            config: config,
            isOriginalPhoto: isOriginalPhoto
        ) { [weak self] updatedSelected, updatedIsOriginal in
            guard let self = self else { return }

            // 同步原图状态
            if self.isOriginalPhoto != updatedIsOriginal {
                self.isOriginalPhoto = updatedIsOriginal
                self.syncOriginalPhotoButtonUI()
            }

            let newIds = Set(updatedSelected.map { $0.id })
            let oldIds = Set(self.selectedAssets.map { $0.id })
            self.selectedAssets = updatedSelected

            for (si, section) in self.sections.enumerated() {
                for (ii, asset) in section.assets.enumerated() {
                    let was = oldIds.contains(asset.id)
                    let now = newIds.contains(asset.id)
                    asset.isSelected = now
                    // 选中状态有变化，或仍在选中列表中（序号可能已变），都需要刷新
                    guard was != now || now else { continue }
                    let indexPath = IndexPath(item: ii, section: si)
                    guard let cell = self.collectionView.cellForItem(at: indexPath) as? PhotoGridCell else { continue }
                    let selectionIndex = self.selectedAssets.firstIndex { $0.id == asset.id }
                    cell.updateSelectionState(isSelected: now, selectionIndex: selectionIndex, animated: false)
                }
            }
            self.refreshEditedThumbnailsIfNeeded()
            self.updateDoneButton()
        }

        previewVC.modalPresentationStyle = .custom
        previewVC.transitioningDelegate = previewVC
        present(previewVC, animated: true)
    }

    private func calculateGlobalIndex(for indexPath: IndexPath) -> Int {
        let precedingSections = min(indexPath.section, sections.count)
        return (0..<precedingSections).reduce(0) { $0 + sections[$1].assets.count } + indexPath.item
    }

    private func refreshEditedThumbnailsIfNeeded() {
        var editedIndexPaths: [IndexPath] = []

        for (sectionIndex, section) in sections.enumerated() {
            for (itemIndex, asset) in section.assets.enumerated() where asset.needsThumbnailRefresh {
                asset.needsThumbnailRefresh = false
                editedIndexPaths.append(IndexPath(item: itemIndex, section: sectionIndex))
            }
        }

        guard !editedIndexPaths.isEmpty else { return }
        PhotoLibraryManager.shared.stopCachingAll()
        collectionView.reloadItems(at: editedIndexPaths)
    }

    private func switchToAlbum(_ album: AlbumModel) {
        // 切换相册前先清除当前相册所有资源的选中状态
        for asset in assets { asset.isSelected = false }
        currentAlbum = album
        navTitleLabel.text = album.title
        selectedAssets.removeAll()
        loadAssets()
        updateDoneButton()
    }

    private func showAlert(message: String) {
        let alert = UIAlertController(title: "提示", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UICollectionViewDelegate, UICollectionViewDataSource

extension PhotoGridViewController: UICollectionViewDelegate, UICollectionViewDataSource {

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard section < sections.count else { return 0 }
        return sections[section].assets.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PhotoCell", for: indexPath) as! PhotoGridCell
        guard indexPath.section < sections.count,
              indexPath.item < sections[indexPath.section].assets.count else {
            return cell
        }
        let asset = sections[indexPath.section].assets[indexPath.item]
        let selectionIndex = selectedAssets.firstIndex { $0.id == asset.id }
        cell.configure(with: asset, selectionIndex: selectionIndex, showRadio: config.showRadio)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        guard kind == UICollectionView.elementKindSectionHeader,
              indexPath.section < sections.count else {
            return UICollectionReusableView()
        }
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: PhotoSectionHeaderView.reuseIdentifier,
            for: indexPath
        ) as! PhotoSectionHeaderView
        let section = sections[indexPath.section]
        header.configure(title: section.title, count: section.assets.count)
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {}

    /// 滚动进入视野时预缓存下一批，提升快速滑动时的缩略图加载速度
    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard indexPath.section < sections.count,
              indexPath.item < sections[indexPath.section].assets.count else { return }

        let itemWidth = UIConstants.Grid.itemWidth(containerWidth: collectionView.bounds.width)
        let thumbSize = CGSize(width: itemWidth, height: itemWidth)
        let section = sections[indexPath.section]

        // 预热当前 item 后面 10 个资源（PHCachingImageManager 内部会去重）
        let startIdx = indexPath.item
        let endIdx   = min(startIdx + 10, section.assets.count)
        let toCache  = (startIdx..<endIdx).compactMap { section.assets[$0].asset }
        if !toCache.isEmpty {
            PhotoLibraryManager.shared.startCaching(for: toCache, size: thumbSize)
        }
    }
}
