package com.newtrip.live_photo_gallery

import org.junit.Assert.*
import org.junit.Test

/**
 * PickerConfig 单元测试
 * 覆盖：from()、toJson()、fromJson() 序列化对称性、effectiveEnableVideo/LivePhoto 计算逻辑
 */
class PickerConfigTest {

    // ── from() 默认值 ────────────────────────────────────────────────────────

    @Test
    fun `from - empty args uses all defaults`() {
        val config = PickerConfig.from(emptyMap())
        assertEquals(9, config.maxCount)
        assertEquals(true, config.enableVideo)
        assertEquals(true, config.enableLivePhoto)
        assertEquals(true, config.showRadio)
        assertEquals(false, config.isDarkMode)
        assertEquals(false, config.autoPlayVideo)
        assertEquals(-1, config.maxVideoCount)
        assertEquals(0.0, config.videoMaxDuration, 0.001)
        assertEquals("all", config.filterConfig)
    }

    @Test
    fun `from - provided values override defaults`() {
        val args = mapOf(
            "maxCount"        to 5,
            "enableVideo"     to false,
            "enableLivePhoto" to false,
            "showRadio"       to false,
            "isDarkMode"      to true,
            "autoPlayVideo"   to true,
            "maxVideoCount"   to 3,
            "videoMaxDuration" to 30.0,
            "filterConfig"    to "imageOnly"
        )
        val config = PickerConfig.from(args)
        assertEquals(5, config.maxCount)
        assertFalse(config.enableVideo)
        assertFalse(config.enableLivePhoto)
        assertFalse(config.showRadio)
        assertTrue(config.isDarkMode)
        assertTrue(config.autoPlayVideo)
        assertEquals(3, config.maxVideoCount)
        assertEquals(30.0, config.videoMaxDuration, 0.001)
        assertEquals("imageOnly", config.filterConfig)
    }

    // ── JSON 序列化对称性 ────────────────────────────────────────────────────

    @Test
    fun `toJson and fromJson are symmetric`() {
        val original = PickerConfig(
            maxCount         = 5,
            enableVideo      = true,
            enableLivePhoto  = false,
            showRadio        = false,
            isDarkMode       = true,
            autoPlayVideo    = true,
            maxVideoCount    = 2,
            videoMaxDuration = 60.0,
            filterConfig     = "videoOnly"
        )
        val restored = PickerConfig.fromJson(PickerConfig.toJson(original))
        assertEquals(original.maxCount,         restored.maxCount)
        assertEquals(original.enableVideo,      restored.enableVideo)
        assertEquals(original.enableLivePhoto,  restored.enableLivePhoto)
        assertEquals(original.showRadio,        restored.showRadio)
        assertEquals(original.isDarkMode,       restored.isDarkMode)
        assertEquals(original.autoPlayVideo,    restored.autoPlayVideo)
        assertEquals(original.maxVideoCount,    restored.maxVideoCount)
        assertEquals(original.videoMaxDuration, restored.videoMaxDuration, 0.001)
        assertEquals(original.filterConfig,     restored.filterConfig)
    }

    @Test
    fun `fromJson uses defaults for missing fields`() {
        val config = PickerConfig.fromJson("""{"maxCount":5}""")
        assertEquals(5, config.maxCount)
        assertTrue(config.enableVideo)
        assertTrue(config.enableLivePhoto)
        assertTrue(config.showRadio)
        assertFalse(config.isDarkMode)
        assertEquals("all", config.filterConfig)
        assertEquals(-1, config.maxVideoCount)
    }

    @Test
    fun `from clamps invalid numeric values`() {
        val config = PickerConfig.from(
            mapOf(
                "maxCount" to 0,
                "maxVideoCount" to 0,
                "videoMaxDuration" to -1.0
            )
        )
        assertEquals(1, config.maxCount)
        assertEquals(1, config.maxVideoCount)
        assertEquals(0.0, config.videoMaxDuration, 0.001)
    }

    @Test
    fun `from normalizes unknown filter to all`() {
        val config = PickerConfig.from(mapOf("filterConfig" to "unexpected"))
        assertEquals("all", config.filterConfig)
    }

    // ── effectiveEnableVideo ─────────────────────────────────────────────────

    @Test
    fun `effectiveEnableVideo - imageOnly disables video regardless of enableVideo`() {
        val config = baseConfig(enableVideo = true, filterConfig = "imageOnly")
        assertFalse(config.effectiveEnableVideo)
    }

    @Test
    fun `effectiveEnableVideo - livePhotoOnly disables video`() {
        val config = baseConfig(enableVideo = true, filterConfig = "livePhotoOnly")
        assertFalse(config.effectiveEnableVideo)
    }

    @Test
    fun `effectiveEnableVideo - videoOnly keeps video enabled`() {
        val config = baseConfig(enableVideo = true, filterConfig = "videoOnly")
        assertTrue(config.effectiveEnableVideo)
    }

    @Test
    fun `effectiveEnableVideo - all respects enableVideo true`() {
        assertTrue(baseConfig(enableVideo = true,  filterConfig = "all").effectiveEnableVideo)
    }

    @Test
    fun `effectiveEnableVideo - all respects enableVideo false`() {
        assertFalse(baseConfig(enableVideo = false, filterConfig = "all").effectiveEnableVideo)
    }

    // ── effectiveEnableLivePhoto ─────────────────────────────────────────────

    @Test
    fun `effectiveEnableLivePhoto - imageOnly disables livePhoto`() {
        assertFalse(baseConfig(enableLivePhoto = true, filterConfig = "imageOnly").effectiveEnableLivePhoto)
    }

    @Test
    fun `effectiveEnableLivePhoto - videoOnly disables livePhoto`() {
        assertFalse(baseConfig(enableLivePhoto = true, filterConfig = "videoOnly").effectiveEnableLivePhoto)
    }

    @Test
    fun `effectiveEnableLivePhoto - livePhotoOnly keeps livePhoto`() {
        assertTrue(baseConfig(enableLivePhoto = true, filterConfig = "livePhotoOnly").effectiveEnableLivePhoto)
    }

    @Test
    fun `effectiveEnableLivePhoto - all respects enableLivePhoto true`() {
        assertTrue(baseConfig(enableLivePhoto = true,  filterConfig = "all").effectiveEnableLivePhoto)
    }

    @Test
    fun `effectiveEnableLivePhoto - all respects enableLivePhoto false`() {
        assertFalse(baseConfig(enableLivePhoto = false, filterConfig = "all").effectiveEnableLivePhoto)
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    private fun baseConfig(
        enableVideo: Boolean = true,
        enableLivePhoto: Boolean = true,
        filterConfig: String = "all"
    ) = PickerConfig(
        maxCount        = 9,
        enableVideo     = enableVideo,
        enableLivePhoto = enableLivePhoto,
        showRadio       = true,
        isDarkMode      = false,
        filterConfig    = filterConfig
    )
}
