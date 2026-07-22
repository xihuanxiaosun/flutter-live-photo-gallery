package com.newtrip.live_photo_gallery

import org.junit.Assert.assertEquals
import org.junit.Test

class DismissGestureMathTest {

    private val eps = 1e-4f

    @Test
    fun `位移为 0 时是恒等变换`() {
        val t = DismissGestureMath.transformFor(dy = 0f, dx = 0f, fadeDistancePx = 800f)
        assertEquals(0f, t.translationX, eps)
        assertEquals(0f, t.translationY, eps)
        assertEquals(1f, t.scale, eps)
        assertEquals(1f, t.stageAlpha, eps)
        assertEquals(1f, t.scrimAlpha, eps)
        assertEquals(1f, t.barAlpha, eps)
    }

    @Test
    fun `下拉到 fadeDistance 时达到完全淡出状态`() {
        val fade = 800f
        val t = DismissGestureMath.transformFor(dy = fade, dx = 0f, fadeDistancePx = fade)
        // progress=1 → eased=1
        assertEquals(0.64f, t.scale, eps)       // max(1 - 0.36, 0.60)
        assertEquals(0.92f, t.stageAlpha, eps)  // clamp(1 - 0.08, 0.92, 1)
        assertEquals(0f, t.scrimAlpha, eps)     // clamp(1 - 1.28, 0, 1)
        assertEquals(0f, t.barAlpha, eps)       // clamp(1 - 1.35, 0, 1)
        assertEquals(fade, t.translationY, eps)
    }

    @Test
    fun `水平位移按 HORIZONTAL_FACTOR 缩放，竖直位移原样透传`() {
        val t = DismissGestureMath.transformFor(dy = 100f, dx = 40f, fadeDistancePx = 800f)
        assertEquals(40f * 0.35f, t.translationX, eps)
        assertEquals(100f, t.translationY, eps)
    }

    @Test
    fun `fadeDistance 为 0 时不除零（回退到 1）`() {
        val t = DismissGestureMath.transformFor(dy = 10f, dx = 0f, fadeDistancePx = 0f)
        // progress = clamp(10/1) = 1 → 完全淡出，不抛异常
        assertEquals(0f, t.barAlpha, eps)
    }
}
