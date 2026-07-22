import Foundation
import UIKit
import ImageIO

/// 网络图片加载 + 下采样解码（自包含，拥有带超时的 URLSession）。
/// 从 PhotoLibraryManager 抽出；facade 的 `loadNetworkImage` 委托到这里。
final class NetworkImageLoader {

    /// 带超时配置的 URLSession（连接 15s，资源 30s，避免网络差时永久挂起）。
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func loadNetworkImage(from url: URL, targetSize: CGSize? = nil, completion: @escaping (Result<UIImage, Error>) -> Void) {
        session.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard
                    let data = data,
                    let image = Self.decodeNetworkImage(data: data, targetSize: targetSize)
                else {
                    completion(.failure(PhotoLibraryError.assetLoadFailed(
                        underlying: NSError(domain: "NetworkImageLoader", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "无法解析图片数据"])
                    )))
                    return
                }
                completion(.success(image))
            }
        }.resume()
    }

    /// 网络图片解码：优先走下采样，避免大图直接解码带来的内存峰值风险。
    /// - targetSize 有值：按目标尺寸*屏幕 scale 解码。
    /// - targetSize 为空：保底限制到 4096 像素，防止超大原图触发 OOM。
    private static func decodeNetworkImage(data: Data, targetSize: CGSize?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let fallbackMaxPixel: CGFloat = 4096
        let maxPixelSize: CGFloat
        if let targetSize = targetSize, targetSize.width > 0, targetSize.height > 0 {
            maxPixelSize = max(targetSize.width, targetSize.height) * UIScreen.main.scale
        } else {
            maxPixelSize = fallbackMaxPixel
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize)),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
