import Foundation
import CoreGraphics

// MARK: - Live Photo 常量

enum LivePhotoConstants {
    static let defaultDuration: Int = 1500
    static let longPressDuration: TimeInterval = 0.3
}

// MARK: - UI 常量

enum UIConstants {
    enum Grid {
        static let itemsPerRow: Int = 3
        static let spacing: CGFloat = 2

        static func itemWidth(containerWidth: CGFloat) -> CGFloat {
            return (containerWidth - spacing * CGFloat(itemsPerRow - 1)) / CGFloat(itemsPerRow)
        }
    }

    enum PhotoCell {
        static let radioButtonExpandSize: CGFloat = 10
        static let radioButtonSize: CGFloat = 24
        static let radioButtonCornerRadius: CGFloat = 12
        static let radioButtonBorderWidth: CGFloat = 2
        static let livePhotoBadgeSize: CGFloat = 24
        static let videoBadgeHeight: CGFloat = 20
        static let videoIconSize: CGFloat = 12
    }

    enum BottomBar {
        static let height: CGFloat = 60
    }

    enum Preview {
        static let topBarHeight: CGFloat = 50
        static let closeButtonFontSize: CGFloat = 36
        static let selectButtonSize: CGFloat = 30
        static let dismissProgressThreshold: CGFloat = 0.25
        static let dismissVelocityThreshold: CGFloat = 1000
        static let minimumZoomScale: CGFloat = 1.0
        static let maximumZoomScale: CGFloat = 3.0
    }

    enum Animation {
        static let transitionDuration: TimeInterval = 0.3
        static let fadeInOutDuration: TimeInterval = 0.15
        static let videoPlayDelay: TimeInterval = 0.1
    }
}

// MARK: - 缓存配置

enum CacheConstants {
    static let thumbnailCacheMultiplier: Int = 3
    static let allowsHighQualityImageCaching: Bool = false
}

// MARK: - 文件配置

enum FileConstants {
    static let imageExtension = "jpg"
    static let videoExtension = "mp4"
    static let livePhotoExtension = "mov"

    static var temporaryDirectory: String {
        return NSTemporaryDirectory()
    }
}
