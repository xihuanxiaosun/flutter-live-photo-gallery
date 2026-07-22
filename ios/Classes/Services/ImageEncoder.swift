import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import ImageIO

/// 图片编码策略（无状态）。
/// 负责两件事：把 UTI 翻译成导出用的扩展名；
/// 按写回相册时的目标 UTI（PNG / HEIC / TIFF，其余走 JPEG）编码 `UIImage`。
/// 从 PhotoLibraryManager 抽出，由 ImageExporter 注入使用。
/// 插件最低支持 iOS 15，因此全程直接使用 `UniformTypeIdentifiers`，不再保留 iOS 13/14 兜底。
final class ImageEncoder {

    /// 根据 UTI 推断文件扩展名，兜底返回 "jpg"
    func fileExtension(for uti: String?) -> String {
        guard let uti = uti else { return "jpg" }
        return UTType(uti)?.preferredFilenameExtension ?? "jpg"
    }

    /// 取回写相册时应该写入的目标文件与其 UTI。
    /// iOS 17 起系统会直接指定渲染类型；更早的系统只能由目标文件后缀反推。
    func renderedOutputDestination(for output: PHContentEditingOutput) -> (url: URL, typeIdentifier: String?) {
        if #available(iOS 17.0, *),
           let type = output.defaultRenderedContentType {
            let destinationURL = (try? output.renderedContentURL(for: type)) ?? output.renderedContentURL
            return (destinationURL, type.identifier)
        }

        let url = output.renderedContentURL
        return (url, UTType(filenameExtension: url.pathExtension)?.identifier)
    }

    /// 按目标 UTI 编码图片；UTI 缺失或未命中 PNG / HEIC / TIFF 时统一回落到 JPEG 95%
    func renderedImageData(for image: UIImage, typeIdentifier: String?) -> Data? {
        let normalizedImage = image.cgImage == nil ? image.opaque() : image

        guard let typeIdentifier, let type = UTType(typeIdentifier) else {
            return normalizedImage.opaque().jpegData(compressionQuality: 0.95)
        }

        if type.conforms(to: .png) {
            return normalizedImage.pngData()
        }

        if type.conforms(to: .heic) || type.identifier == "public.heif" {
            return encodedImageData(from: normalizedImage.opaque(), typeIdentifier: typeIdentifier, compressionQuality: 0.95)
        }

        if type.conforms(to: .tiff) {
            return encodedImageData(from: normalizedImage, typeIdentifier: typeIdentifier, compressionQuality: nil)
        }

        return normalizedImage.opaque().jpegData(compressionQuality: 0.95)
    }

    private func encodedImageData(from image: UIImage, typeIdentifier: String, compressionQuality: CGFloat?) -> Data? {
        let renderedImage = image.cgImage == nil ? image.opaque() : image
        guard let cgImage = renderedImage.cgImage else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, typeIdentifier as CFString, 1, nil) else { return nil }

        var properties: [CFString: Any] = [:]
        if let compressionQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = compressionQuality
        }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
