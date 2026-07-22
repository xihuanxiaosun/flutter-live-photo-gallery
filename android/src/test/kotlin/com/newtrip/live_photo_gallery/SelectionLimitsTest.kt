package com.newtrip.live_photo_gallery

import org.junit.Assert.assertEquals
import org.junit.Test

class SelectionLimitsTest {

    private fun canAdd(
        count: Int, max: Int, videoCount: Int = 0, maxVideo: Int = -1, isVideo: Boolean = false,
    ) = SelectionLimits.canAdd(count, max, videoCount, maxVideo, isVideo)

    @Test
    fun `未达上限返回 OK`() {
        assertEquals(SelectionLimits.Result.OK, canAdd(count = 8, max = 9))
    }

    @Test
    fun `达到总数上限返回 MAX_COUNT`() {
        assertEquals(SelectionLimits.Result.MAX_COUNT, canAdd(count = 9, max = 9))
    }

    @Test
    fun `视频达到 maxVideoCount 返回 MAX_VIDEO`() {
        assertEquals(
            SelectionLimits.Result.MAX_VIDEO,
            canAdd(count = 3, max = 9, videoCount = 2, maxVideo = 2, isVideo = true),
        )
    }

    @Test
    fun `maxVideoCount 为 -1 时视频不受限`() {
        assertEquals(
            SelectionLimits.Result.OK,
            canAdd(count = 3, max = 9, videoCount = 5, maxVideo = -1, isVideo = true),
        )
    }

    @Test
    fun `非视频项不触发视频上限`() {
        assertEquals(
            SelectionLimits.Result.OK,
            canAdd(count = 3, max = 9, videoCount = 2, maxVideo = 2, isVideo = false),
        )
    }

    @Test
    fun `总数上限优先于视频上限`() {
        // 两者同时超限时先报 MAX_COUNT（对齐原有 if 顺序）
        assertEquals(
            SelectionLimits.Result.MAX_COUNT,
            canAdd(count = 9, max = 9, videoCount = 2, maxVideo = 2, isVideo = true),
        )
    }
}
