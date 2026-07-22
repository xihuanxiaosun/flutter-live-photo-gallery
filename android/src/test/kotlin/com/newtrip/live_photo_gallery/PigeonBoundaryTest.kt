package com.newtrip.live_photo_gallery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pigeon 边界（wire）契约测试。
 *
 * Pigeon 只保证「三端枚举的序号一致」，不保证 native 内部消费的字符串正确：
 * LivePhotoGalleryPlugin.kt 底部那几个 `.wire` 扩展 / `pgXxxOf()` 函数是本次迁移
 * 唯一的手工对齐点，写错一个字面量（例如 `PgMediaFilter.VIDEO_ONLY -> "imageOnly"`）
 * 编译通过、其它测试全绿，但选择器会直接筛错媒体类型。
 *
 * 因此这里逐值钉死每个映射，并对每个枚举做穷举校验：新增枚举值时，
 * `when` 分支缺失是编译期错误，而映射表长度不匹配则在此立即失败。
 *
 * 对应的 Dart 侧同类测试见 test/pigeon_boundary_test.dart。
 */
class PigeonBoundaryTest {

    // ── PgMediaFilter.wire ───────────────────────────────────────────────────

    @Test
    fun `PgMediaFilter wire - 每个值映射到既有 native 字符串`() {
        assertEquals("all", PgMediaFilter.ALL.wire)
        assertEquals("imageOnly", PgMediaFilter.IMAGE_ONLY.wire)
        assertEquals("videoOnly", PgMediaFilter.VIDEO_ONLY.wire)
        assertEquals("livePhotoOnly", PgMediaFilter.LIVE_PHOTO_ONLY.wire)
    }

    @Test
    fun `PgMediaFilter wire - 穷举且互不重复`() {
        val wires = PgMediaFilter.values().map { it.wire }
        assertEquals(listOf("all", "imageOnly", "videoOnly", "livePhotoOnly"), wires)
        assertEquals(wires.size, wires.toSet().size)
    }

    @Test
    fun `PgMediaFilter wire - 全部能被 PickerConfig 的 normalizeFilter 接受`() {
        // wire 字符串若拼错，PickerConfig.from 会静默回落成 "all"
        PgMediaFilter.values().forEach { filter ->
            val config = PickerConfig.from(mapOf("filterConfig" to filter.wire))
            assertEquals(
                "PgMediaFilter.$filter 的 wire 值未被 PickerConfig 识别",
                filter.wire,
                config.filterConfig
            )
        }
    }

    // ── PgMediaType.wire ─────────────────────────────────────────────────────

    @Test
    fun `PgMediaType wire - 每个值映射到公开 API 字符串`() {
        assertEquals("image", PgMediaType.IMAGE.wire)
        assertEquals("video", PgMediaType.VIDEO.wire)
        assertEquals("livePhoto", PgMediaType.LIVE_PHOTO.wire)
    }

    @Test
    fun `PgMediaType wire - 穷举且互不重复`() {
        val wires = PgMediaType.values().map { it.wire }
        assertEquals(listOf("image", "video", "livePhoto"), wires)
        assertEquals(wires.size, wires.toSet().size)
    }

    // ── PgAssetSource.wire ───────────────────────────────────────────────────

    @Test
    fun `PgAssetSource wire - local network`() {
        assertEquals("local", PgAssetSource.LOCAL.wire)
        assertEquals("network", PgAssetSource.NETWORK.wire)
        assertEquals(listOf("local", "network"), PgAssetSource.values().map { it.wire })
    }

    // ── PgExportFormat.wire ──────────────────────────────────────────────────

    @Test
    fun `PgExportFormat wire - image video livePhotoVideo`() {
        assertEquals("image", PgExportFormat.IMAGE.wire)
        assertEquals("video", PgExportFormat.VIDEO.wire)
        assertEquals("livePhotoVideo", PgExportFormat.LIVE_PHOTO_VIDEO.wire)
        assertEquals(
            listOf("image", "video", "livePhotoVideo"),
            PgExportFormat.values().map { it.wire }
        )
    }

    // ── pgMediaTypeOf ────────────────────────────────────────────────────────

    @Test
    fun `pgMediaTypeOf - 已知字符串精确映射`() {
        assertEquals(PgMediaType.IMAGE, pgMediaTypeOf("image"))
        assertEquals(PgMediaType.VIDEO, pgMediaTypeOf("video"))
        assertEquals(PgMediaType.LIVE_PHOTO, pgMediaTypeOf("livePhoto"))
    }

    @Test
    fun `pgMediaTypeOf - null 空串 大小写错误 未知值一律归一到 IMAGE`() {
        // 结果 JSON 里 mediaType 缺失时 optString 返回空串，此前会原样透给 Dart，
        // 现在统一成 image（见 CHANGELOG 的行为变化说明）
        assertEquals(PgMediaType.IMAGE, pgMediaTypeOf(null))
        assertEquals(PgMediaType.IMAGE, pgMediaTypeOf(""))
        assertEquals(PgMediaType.IMAGE, pgMediaTypeOf("Video"))
        assertEquals(PgMediaType.IMAGE, pgMediaTypeOf("live_photo"))
        assertEquals(PgMediaType.IMAGE, pgMediaTypeOf("gif"))
    }

    @Test
    fun `pgMediaTypeOf - 与 wire 互为逆映射`() {
        PgMediaType.values().forEach { type ->
            assertEquals(type, pgMediaTypeOf(type.wire))
        }
    }

    // ── pgDownloadErrorCodeOf ────────────────────────────────────────────────

    @Test
    fun `pgDownloadErrorCodeOf - 三个已知码精确映射`() {
        assertEquals(PgDownloadErrorCode.PERMISSION_DENIED, pgDownloadErrorCodeOf("PERMISSION_DENIED"))
        assertEquals(PgDownloadErrorCode.NETWORK_ERROR, pgDownloadErrorCodeOf("NETWORK_ERROR"))
        assertEquals(PgDownloadErrorCode.SAVE_FAILED, pgDownloadErrorCodeOf("SAVE_FAILED"))
    }

    @Test
    fun `pgDownloadErrorCodeOf - null 空串 未知码回退 UNKNOWN`() {
        assertEquals(PgDownloadErrorCode.UNKNOWN, pgDownloadErrorCodeOf(null))
        assertEquals(PgDownloadErrorCode.UNKNOWN, pgDownloadErrorCodeOf(""))
        assertEquals(PgDownloadErrorCode.UNKNOWN, pgDownloadErrorCodeOf("UNKNOWN"))
        assertEquals(PgDownloadErrorCode.UNKNOWN, pgDownloadErrorCodeOf("permission_denied"))
        assertEquals(PgDownloadErrorCode.UNKNOWN, pgDownloadErrorCodeOf("INVALID_ARGS"))
    }

    // ── PgPickerConfig.toPickerConfig ────────────────────────────────────────

    private fun pgConfig(
        isDarkMode: Boolean = false,
        maxCount: Long = 9,
        enableVideo: Boolean = true,
        enableLivePhoto: Boolean = true,
        showRadio: Boolean = true,
        maxVideoCount: Long = -1,
        videoMaxDuration: Double = 0.0,
        filterConfig: PgMediaFilter = PgMediaFilter.ALL,
        cropConfig: PgCropConfig? = null
    ) = PgPickerConfig(
        isDarkMode = isDarkMode,
        maxCount = maxCount,
        enableVideo = enableVideo,
        enableLivePhoto = enableLivePhoto,
        showRadio = showRadio,
        maxVideoCount = maxVideoCount,
        videoMaxDuration = videoMaxDuration,
        filterConfig = filterConfig,
        cropConfig = cropConfig
    )

    @Test
    fun `toPickerConfig - 默认值逐字段还原`() {
        val config = pgConfig().toPickerConfig()
        assertEquals(9, config.maxCount)
        assertEquals(true, config.enableVideo)
        assertEquals(true, config.enableLivePhoto)
        assertEquals(true, config.showRadio)
        assertEquals(false, config.isDarkMode)
        assertEquals(-1, config.maxVideoCount)
        assertEquals(0.0, config.videoMaxDuration, 0.0001)
        assertEquals("all", config.filterConfig)
    }

    @Test
    fun `toPickerConfig - 全部非默认值逐字段还原且不串位`() {
        val config = pgConfig(
            isDarkMode = true,
            maxCount = 3,
            enableVideo = false,
            enableLivePhoto = true,
            showRadio = false,
            maxVideoCount = 2,
            videoMaxDuration = 30.5,
            filterConfig = PgMediaFilter.LIVE_PHOTO_ONLY
        ).toPickerConfig()
        assertEquals(3, config.maxCount)
        assertEquals(false, config.enableVideo)
        assertEquals(true, config.enableLivePhoto)
        assertEquals(false, config.showRadio)
        assertEquals(true, config.isDarkMode)
        assertEquals(2, config.maxVideoCount)
        assertEquals(30.5, config.videoMaxDuration, 0.0001)
        assertEquals("livePhotoOnly", config.filterConfig)
    }

    @Test
    fun `toPickerConfig - 每个 filterConfig 枚举值都能穿透到 PickerConfig`() {
        PgMediaFilter.values().forEach { filter ->
            assertEquals(
                filter.wire,
                pgConfig(filterConfig = filter).toPickerConfig().filterConfig
            )
        }
    }

    @Test
    fun `toPickerConfig - maxCount 归一化 非正值抬到 1`() {
        assertEquals(1, pgConfig(maxCount = 0).toPickerConfig().maxCount)
        assertEquals(1, pgConfig(maxCount = -5).toPickerConfig().maxCount)
        assertEquals(1, pgConfig(maxCount = 1).toPickerConfig().maxCount)
        assertEquals(100, pgConfig(maxCount = 100).toPickerConfig().maxCount)
    }

    @Test
    fun `toPickerConfig - maxVideoCount 归一化 -1 表无限制 其余非正值抬到 1`() {
        assertEquals(-1, pgConfig(maxVideoCount = -1).toPickerConfig().maxVideoCount)
        assertEquals(1, pgConfig(maxVideoCount = 0).toPickerConfig().maxVideoCount)
        assertEquals(1, pgConfig(maxVideoCount = -3).toPickerConfig().maxVideoCount)
        assertEquals(5, pgConfig(maxVideoCount = 5).toPickerConfig().maxVideoCount)
    }

    @Test
    fun `toPickerConfig - videoMaxDuration 归一化 负值归零`() {
        assertEquals(0.0, pgConfig(videoMaxDuration = -1.0).toPickerConfig().videoMaxDuration, 0.0001)
        assertEquals(0.0, pgConfig(videoMaxDuration = 0.0).toPickerConfig().videoMaxDuration, 0.0001)
        assertEquals(15.0, pgConfig(videoMaxDuration = 15.0).toPickerConfig().videoMaxDuration, 0.0001)
    }

    @Test
    fun `toPickerConfig - Long 到 Int 的窄化不丢值`() {
        // pigeon 的整数一律是 Long，PickerConfig 用 Int；转换必须走 toInt()，
        // 否则 args map 里是 Long，`as? Int` 会失配并静默回落成默认值
        val config = pgConfig(maxCount = 7, maxVideoCount = 4).toPickerConfig()
        assertEquals(7, config.maxCount)
        assertEquals(4, config.maxVideoCount)
    }

    @Test
    fun `toPickerConfig - cropConfig 不参与 PickerConfig 且 autoPlayVideo 保持默认`() {
        // cropConfig 由预览页单独消费，不进 PickerConfig；autoPlayVideo 无对应契约字段
        val config = pgConfig(
            cropConfig = PgCropConfig(aspectRatioX = 16.0, aspectRatioY = 9.0)
        ).toPickerConfig()
        assertEquals(false, config.autoPlayVideo)
    }

    @Test
    fun `toPickerConfig - effectiveEnable 派生值随 filterConfig 生效`() {
        // wire 字符串直接驱动这两个派生属性，映射写错会在这里暴露
        val imageOnly = pgConfig(filterConfig = PgMediaFilter.IMAGE_ONLY).toPickerConfig()
        assertEquals(false, imageOnly.effectiveEnableVideo)
        assertEquals(false, imageOnly.effectiveEnableLivePhoto)

        val videoOnly = pgConfig(filterConfig = PgMediaFilter.VIDEO_ONLY).toPickerConfig()
        assertEquals(true, videoOnly.effectiveEnableVideo)
        assertEquals(false, videoOnly.effectiveEnableLivePhoto)

        val livePhotoOnly = pgConfig(filterConfig = PgMediaFilter.LIVE_PHOTO_ONLY).toPickerConfig()
        assertEquals(false, livePhotoOnly.effectiveEnableVideo)
        assertEquals(true, livePhotoOnly.effectiveEnableLivePhoto)

        val all = pgConfig(filterConfig = PgMediaFilter.ALL).toPickerConfig()
        assertEquals(true, all.effectiveEnableVideo)
        assertEquals(true, all.effectiveEnableLivePhoto)
    }

    @Test
    fun `toPickerConfig - JSON 往返后仍等价（Activity 侧通过 Intent extra 收到的形状）`() {
        val config = pgConfig(
            isDarkMode = true,
            maxCount = 6,
            enableVideo = false,
            showRadio = false,
            maxVideoCount = 2,
            videoMaxDuration = 20.0,
            filterConfig = PgMediaFilter.VIDEO_ONLY
        ).toPickerConfig()
        val restored = PickerConfig.fromJson(PickerConfig.toJson(config))
        assertEquals(config, restored)
    }

    // ── 事件侧：PgDownloadResultEvent 的失败码来源 ────────────────────────────

    @Test
    fun `pgDownloadErrorCodeOf - 覆盖 PgDownloadErrorCode 的每个取值`() {
        // UNKNOWN 没有对应的 native 字符串（是兜底），其余三个必须能被反解出来
        val reachable = listOf("PERMISSION_DENIED", "NETWORK_ERROR", "SAVE_FAILED")
            .map { pgDownloadErrorCodeOf(it) }
            .toSet()
        assertEquals(
            PgDownloadErrorCode.values().toSet() - PgDownloadErrorCode.UNKNOWN,
            reachable
        )
        assertNull(PgDownloadErrorCode.values().find { it !in reachable && it != PgDownloadErrorCode.UNKNOWN })
    }
}
