package com.newtrip.live_photo_gallery

import org.junit.Assert.*
import org.junit.Test

/**
 * MediaStoreHelper.buildSelection 单元测试
 *
 * 注意：MediaStore.Files.FileColumns.* 是 Android 运行时常量，JVM 测试中返回 null。
 * 断言改为检查编译期内联的整数值（MEDIA_TYPE_IMAGE=1, MEDIA_TYPE_VIDEO=3）以及
 * 数值字面量（如时长 ms 值），而非列名字符串。
 */
class MediaStoreSelectionTest {

    // 对应 MediaStoreHelper 私有常量
    private val IMG = "= 1"   // MEDIA_TYPE_IMAGE
    private val VID = "= 3"   // MEDIA_TYPE_VIDEO
    private val ALL_BUCKET = -1L

    // ── filterConfig 基本类型过滤 ─────────────────────────────────────────────

    @Test
    fun filterAll_includesImageAndVideo() {
        val sql = build(enableVideo = true, filterConfig = "all")
        assertTrue("应包含 image 类型",  sql.contains(IMG))
        assertTrue("应包含 video 类型",  sql.contains(VID))
    }

    @Test
    fun filterImageOnly_excludesVideo() {
        val sql = build(enableVideo = true, filterConfig = "imageOnly")
        assertTrue("应包含 image 类型",  sql.contains(IMG))
        assertFalse("不应包含 video 类型", sql.contains(VID))
    }

    @Test
    fun filterVideoOnly_excludesImage() {
        val sql = build(enableVideo = true, filterConfig = "videoOnly")
        assertFalse("不应包含 image 类型（videoOnly 模式）", sql.contains(IMG))
        assertTrue("应包含 video 类型",  sql.contains(VID))
    }

    @Test
    fun filterLivePhotoOnly_excludesVideo() {
        val sql = build(enableVideo = true, filterConfig = "livePhotoOnly")
        assertTrue("应包含 image 类型（Live Photo 是图片）", sql.contains(IMG))
        assertFalse("不应包含 video 类型", sql.contains(VID))
    }

    @Test
    fun enableVideoFalse_excludesVideoRegardlessOfFilter() {
        val sql = build(enableVideo = false, filterConfig = "all")
        assertFalse("enableVideo=false 时不应包含视频", sql.contains(VID))
    }

    // ── videoMaxDuration 过滤 ─────────────────────────────────────────────────

    @Test
    fun videoMaxDurationZero_noDurationClause() {
        val sql = build(enableVideo = true, videoMaxDuration = 0.0)
        // 不应出现时长数值（30000、60000 等）
        assertFalse("duration=0 时不应添加时长过滤", sql.contains("30000"))
    }

    @Test
    fun videoMaxDurationPositive_addsDurationClauseWithCorrectMs() {
        val sql = build(enableVideo = true, videoMaxDuration = 30.0)
        // 30 秒 = 30000 ms 应出现在 SQL 中
        assertTrue("时长应为 30000ms", sql.contains("30000"))
    }

    @Test
    fun videoMaxDurationPositive_durationClauseExemptsImages() {
        val sql = build(enableVideo = true, videoMaxDuration = 60.0)
        // 子句格式：(MEDIA_TYPE != 3 OR DURATION <= 60000)
        // 在 JVM 测试中列名为 null，断言只检查数值部分和排除逻辑
        assertTrue("时长值 60000 应出现在 SQL 中", sql.contains("60000"))
        // 视频豁免标记：!= 3 确保图片不受 DURATION 过滤影响
        assertTrue("duration 子句应有视频豁免 (!= 3)", sql.contains("!= 3"))
    }

    @Test
    fun videoMaxDuration_ignoredWhenEnableVideoFalse() {
        val sql = build(enableVideo = false, videoMaxDuration = 30.0)
        assertFalse("无视频时不应有 duration 子句", sql.contains("30000"))
    }

    // ── bucket 过滤 ───────────────────────────────────────────────────────────

    @Test
    fun specificBucket_addsBucketIdClause() {
        val sql = MediaStoreHelper.buildSelection(config(), 42L)
        assertTrue("指定 bucket 时应包含 bucket_id 过滤", sql.contains("bucket_id = 42"))
    }

    @Test
    fun allBucketId_noBucketClause() {
        val sql = MediaStoreHelper.buildSelection(config(), ALL_BUCKET)
        assertFalse("ALL_BUCKET 时不应有 bucket_id 过滤", sql.contains("bucket_id"))
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    private fun build(
        enableVideo: Boolean = true,
        enableLivePhoto: Boolean = true,
        filterConfig: String = "all",
        videoMaxDuration: Double = 0.0,
        bucketId: Long = ALL_BUCKET
    ) = MediaStoreHelper.buildSelection(config(enableVideo, enableLivePhoto, filterConfig, videoMaxDuration), bucketId)

    private fun config(
        enableVideo: Boolean = true,
        enableLivePhoto: Boolean = true,
        filterConfig: String = "all",
        videoMaxDuration: Double = 0.0
    ) = PickerConfig(
        maxCount         = 9,
        enableVideo      = enableVideo,
        enableLivePhoto  = enableLivePhoto,
        showRadio        = true,
        isDarkMode       = false,
        videoMaxDuration = videoMaxDuration,
        filterConfig     = filterConfig
    )
}
