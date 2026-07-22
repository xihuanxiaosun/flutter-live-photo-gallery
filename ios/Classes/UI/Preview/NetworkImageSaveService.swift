import Foundation
import Photos

// MARK: - 网络图片保存结果

/// 网络图片「下载 → 写入系统相册」的最终结果。
///
/// `errorCode` / `errorMessage` 直接对应 Flutter 侧回调字典里的同名字段，
/// 由调用方（预览控制器）负责拼装成字典，本类只负责判定取值。
enum NetworkImageSaveResult {
    /// 保存成功，携带新建资产的本地标识（取不到时为空串）
    case success(assetId: String)
    /// 保存失败，携带与 Flutter 契约一致的错误码与错误描述
    case failure(errorCode: String, errorMessage: String)
}

// MARK: - 网络图片保存服务

/// 把一张网络图片下载到本地并写入系统相册（可选同时加入指定命名相册）。
///
/// 抽出的原因：这段流程串起了 URLSession 下载、临时文件拷贝、`PHPhotoLibrary`
/// 资产创建与相册归属四件事，与预览页的 UI 状态无关。预览控制器只保留按钮禁用、
/// Toast 以及发往 Flutter 的字典拼装，保证线上契约字段可被逐字核对。
///
/// 生命周期：进度 KVO 观察者由本对象持有，因此调用方必须持有本对象直到回调结束；
/// 对象释放即代表下载被放弃，回调不会再触发。
final class NetworkImageSaveService {

    /// 下载任务进度观察者（KVO）
    private var progressObservation: NSKeyValueObservation?

    /// 下载网络图片并写入系统相册。
    ///
    /// - Parameters:
    ///   - url: 图片地址
    ///   - albumName: 目标相册名；空串 = 仅存到「最近项目」，非空 = 同时加入同名相册（不存在则自动创建）
    ///   - progress: 下载进度（0~1），在主线程回调
    ///   - completion: 最终结果，在主线程回调
    func save(
        url: URL,
        albumName: String,
        progress: @escaping (Double) -> Void,
        completion: @escaping (NetworkImageSaveResult) -> Void
    ) {
        // 使用 downloadTask 以支持进度回调（dataTask 不提供字节级进度）
        let downloadSession = URLSession(configuration: .default)
        let task = downloadSession.downloadTask(with: url) { [weak self] tmpURL, response, error in
            guard let self = self else { return }

            // 停止进度观察
            self.progressObservation = nil

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let tmpURL, error == nil, (200..<300).contains(statusCode) else {
                DispatchQueue.main.async {
                    completion(.failure(
                        errorCode: "NETWORK_ERROR",
                        errorMessage: error?.localizedDescription
                            ?? "网络请求失败（HTTP \(statusCode)）"
                    ))
                }
                return
            }

            // 2. 拷贝到应用临时目录（下载 task 的 tmpURL 在回调完成后会被删除）
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("lpg_dl_\(UUID().uuidString).\(ext)")
            do { try FileManager.default.copyItem(at: tmpURL, to: tmp) } catch {
                DispatchQueue.main.async {
                    completion(.failure(
                        errorCode: "SAVE_FAILED",
                        errorMessage: "临时文件写入失败"
                    ))
                }
                return
            }

            self.writeToPhotoLibrary(fileURL: tmp, albumName: albumName, completion: completion)
        }

        // 进度监听（KVO observing task.progress.fractionCompleted）
        progressObservation = task.progress.observe(
            \Progress.fractionCompleted,
            options: [.new]
        ) { taskProgress, _ in
            DispatchQueue.main.async {
                progress(taskProgress.fractionCompleted)
            }
        }
        task.resume()
    }

    /// 把已落盘的临时文件写入系统相册，并按需归入命名相册；写入结束后删除临时文件。
    ///
    /// 需要宿主 App 的 Info.plist 中声明 NSPhotoLibraryAddUsageDescription。
    private func writeToPhotoLibrary(
        fileURL: URL,
        albumName: String,
        completion: @escaping (NetworkImageSaveResult) -> Void
    ) {
        // 3. PHPhotoLibrary 保存（需要宿主 App Info.plist 中的 NSPhotoLibraryAddUsageDescription）
        // #3 fix: 根据 mediaType 选择正确的 PHAssetChangeRequest API
        // 若 saveAlbumName 非空，同时将图片加入指定相册（不存在则自动创建）
        var localId: String?
        let targetAlbumName = albumName
        PHPhotoLibrary.shared().performChanges({
            // ── 创建资产 ──────────────────────────────────────────
            guard let changeRequest = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL) else { return }
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
            try? FileManager.default.removeItem(at: fileURL)
            DispatchQueue.main.async {
                if success {
                    completion(.success(assetId: localId ?? ""))
                } else {
                    let desc = saveError?.localizedDescription ?? ""
                    let code = desc.lowercased().contains("access") || desc.lowercased().contains("permission")
                        ? "PERMISSION_DENIED" : "SAVE_FAILED"
                    completion(.failure(
                        errorCode: code,
                        errorMessage: desc.isEmpty ? "保存失败" : desc
                    ))
                }
            }
        }
    }
}
