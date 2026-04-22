import UIKit
import Photos

class AlbumListViewController: UIViewController {
    
    // MARK: - Properties

    private var albums: [AlbumModel] = []
    private let config: PickerConfig
    private let completion: ([PhotoAssetModel], Bool) -> Void
    
    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.delegate = self
        table.dataSource = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "AlbumCell")
        table.rowHeight = 70
        return table
    }()
    
    // MARK: - Initialization

    init(config: PickerConfig, completion: @escaping ([PhotoAssetModel], Bool) -> Void) {
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
        loadAlbums()
    }
    
    private func setupUI() {
        title = "选择相册"
        view.backgroundColor = .systemBackground
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(cancelTapped)
        )
        
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    
    private func loadAlbums() {
        albums = PhotoLibraryManager.shared.fetchAlbums()
        tableView.reloadData()
    }
    
    @objc private func cancelTapped() {
        dismiss(animated: true)
        completion([], false)
    }
}

// MARK: - UITableViewDelegate, UITableViewDataSource

extension AlbumListViewController: UITableViewDelegate, UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return albums.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "AlbumCell", for: indexPath)
        let album = albums[indexPath.row]
        
        cell.textLabel?.text = album.title
        cell.detailTextLabel?.text = "\(album.count)"
        cell.accessoryType = .disclosureIndicator
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let album = albums[indexPath.row]

        let gridVC = PhotoGridViewController(
            albums: albums,
            selectedAlbum: album,
            config: config,
            completion: completion
        )
        navigationController?.pushViewController(gridVC, animated: true)
    }
}
