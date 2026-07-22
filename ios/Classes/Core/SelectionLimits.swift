import Foundation

/// 多选数量 / 视频数量限制的纯决策逻辑。
///
/// 与 Android `SelectionLimits.kt` 对齐（ok / maxCount / maxVideo）。此前预览页
/// `selectButtonTapped` 与宫格 `toggleSelection` 各写了一份几乎相同的判断，
/// 这里统一为单一决策；副作用（弹窗、`onMaxCountReached`、触觉反馈）仍留在各调用点，
/// 因为文案与回调两端不同。
enum SelectionLimits {
    enum Result {
        case ok
        case maxCount
        case maxVideo
    }

    /// 判断是否可以再选一个资源。
    /// - Parameters:
    ///   - currentCount: 当前已选总数
    ///   - maxCount: 总数上限
    ///   - currentVideoCount: 当前已选「视频/实况照片」数
    ///   - maxVideoCount: 视频/实况上限（-1 = 无限制）
    ///   - isVideoOrLive: 待选项是否为视频/实况照片
    static func canAdd(
        currentCount: Int,
        maxCount: Int,
        currentVideoCount: Int,
        maxVideoCount: Int,
        isVideoOrLive: Bool
    ) -> Result {
        if currentCount >= maxCount {
            return .maxCount
        }
        if maxVideoCount >= 0 && isVideoOrLive && currentVideoCount >= maxVideoCount {
            return .maxVideo
        }
        return .ok
    }
}
