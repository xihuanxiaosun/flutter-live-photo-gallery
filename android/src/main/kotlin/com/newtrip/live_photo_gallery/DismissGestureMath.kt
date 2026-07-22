package com.newtrip.live_photo_gallery

/** 下拉关闭手势的一帧变换量（纯数值）。 */
internal data class DismissTransform(
    val translationX: Float,
    val translationY: Float,
    val scale: Float,
    val stageAlpha: Float,
    val scrimAlpha: Float,
    val barAlpha: Float,
)

/**
 * 下拉关闭手势的纯数学（可单元测试）。从 PreviewActivity.applyDismissProgress 抽出——
 * 只负责由拖拽位移算出各变换量；把结果应用到具体 View 的部分仍留在 Activity。
 */
internal object DismissGestureMath {
    const val SCALE_FACTOR = 0.36f
    const val MIN_SCALE = 0.60f
    const val HORIZONTAL_FACTOR = 0.35f

    /**
     * @param dy 竖直下拉位移（px，已 coerceAtLeast(0)）
     * @param dx 水平位移（px）
     * @param fadeDistancePx 达到「完全淡出」所需的下拉距离
     */
    fun transformFor(dy: Float, dx: Float, fadeDistancePx: Float): DismissTransform {
        val progress = (dy / fadeDistancePx.coerceAtLeast(1f)).coerceIn(0f, 1f)
        val eased = 1f - (1f - progress) * (1f - progress)
        return DismissTransform(
            translationX = dx * HORIZONTAL_FACTOR,
            translationY = dy,
            scale = (1f - eased * SCALE_FACTOR).coerceAtLeast(MIN_SCALE),
            stageAlpha = (1f - eased * 0.08f).coerceIn(0.92f, 1f),
            scrimAlpha = (1f - eased * 1.28f).coerceIn(0f, 1f),
            barAlpha = (1f - eased * 1.35f).coerceIn(0f, 1f),
        )
    }
}
