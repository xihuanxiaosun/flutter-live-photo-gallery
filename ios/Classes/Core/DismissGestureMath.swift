import CoreGraphics

/// 预览页「下拉关闭」手势的纯数学。从 PhotoPreviewPageViewController 抽出——
/// 只算数值，把 `view.bounds.height` 作为参数传入，便于隔离与复核。
enum DismissGestureMath {

    /// 下拉进度 0~1（超过 `viewHeight * 0.85` 即视为完全）。
    static func progress(translationY: CGFloat, viewHeight: CGFloat) -> CGFloat {
        let normalizedDistance = max(viewHeight * 0.85, 1)
        return min(max(translationY / normalizedDistance, 0), 1)
    }

    /// 交互式关闭的变换：随下拉进度缩小（下限 0.58）+ 跟随平移。
    static func transform(translation: CGPoint, viewHeight: CGFloat) -> CGAffineTransform {
        let verticalTranslation = max(translation.y, 0)
        let p = progress(translationY: verticalTranslation, viewHeight: viewHeight)
        let scale = max(0.58, 1.0 - (p * 0.42))
        let horizontalTranslation = p > 0 ? translation.x * 0.98 : 0
        return CGAffineTransform(translationX: horizontalTranslation, y: verticalTranslation)
            .scaledBy(x: scale, y: scale)
    }
}
