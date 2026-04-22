import UIKit

extension UIImage {

    /// 将带 Alpha 通道的图像拍平为不透明图像。
    /// PHImageManager 返回的图默认带 Alpha（RGBA），直接 jpegData 会触发系统警告
    /// 并额外占用一倍内存。调用此方法后再编码为 JPEG 可避免该问题。
    func opaque(background: UIColor = .white) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            background.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
