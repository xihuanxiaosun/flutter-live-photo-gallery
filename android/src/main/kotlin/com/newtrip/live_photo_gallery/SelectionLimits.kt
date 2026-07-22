package com.newtrip.live_photo_gallery

/**
 * 多选数量 / 视频数量限制的纯决策逻辑（可单元测试）。
 *
 * 此前 PreviewActivity 与 MediaPickerActivity 各写了一份几乎相同的判断，
 * 这里统一为单一决策；副作用（Toast、onMaxCountReached 回调、触觉反馈）仍留在各自调用点，
 * 因为文案与回调渠道两端不同。
 */
internal object SelectionLimits {

    enum class Result { OK, MAX_COUNT, MAX_VIDEO }

    /**
     * 判断是否可以再选一个资源。
     *
     * @param currentCount      当前已选总数
     * @param maxCount          总数上限
     * @param currentVideoCount 当前已选「视频/动态照片」数
     * @param maxVideoCount     视频/动态照片上限（-1 = 无限制）
     * @param isVideoOrLive     待选项是否为视频/动态照片
     */
    fun canAdd(
        currentCount: Int,
        maxCount: Int,
        currentVideoCount: Int,
        maxVideoCount: Int,
        isVideoOrLive: Boolean,
    ): Result = when {
        currentCount >= maxCount -> Result.MAX_COUNT
        maxVideoCount >= 0 && isVideoOrLive && currentVideoCount >= maxVideoCount -> Result.MAX_VIDEO
        else -> Result.OK
    }
}
