package com.newtrip.live_photo_gallery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * AssetSelectionId 的契约测试（重构安全网 + 跨端一致性守护）。
 *
 * golden 哈希由 `printf '%s' <canonical> | shasum -a 256` 计算得出，
 * 与 iOS `PhotoAssetModel.id`（Models.swift）使用完全相同的规范串。
 * 任一端改动规范串都会让这里失败，从而阻止「跨端选择状态错乱」这类静默回归。
 */
class AssetSelectionIdTest {

    @Test
    fun `network image (no video) 生成稳定 golden id`() {
        val id = AssetSelectionId.forNetwork(
            mediaType = "image",
            coverUrl = "https://x/i.jpg",
            videoUrl = null,
        )
        assertEquals(
            "network_2154acac6a5daf57df4b128b66ec38b62dc0baf15011bf0866cc9f3baf1bfa69",
            id,
        )
    }

    @Test
    fun `network livePhoto (with video) 生成稳定 golden id`() {
        val id = AssetSelectionId.forNetwork(
            mediaType = "livePhoto",
            coverUrl = "https://x/i.jpg",
            videoUrl = "https://x/v.mov",
        )
        assertEquals(
            "network_f293e4b148bb8978151b2e4defd6d4ca1e7f19f325c743fdeeec84514d11604f",
            id,
        )
    }

    @Test
    fun `videoUrl 为 null 与空串结果一致（规范串统一用空串）`() {
        val a = AssetSelectionId.forNetwork("image", "https://x/i.jpg", null)
        val b = AssetSelectionId.forNetwork("image", "https://x/i.jpg", "")
        assertEquals(a, b)
    }

    @Test
    fun `coverUrl 为空返回 null`() {
        assertNull(AssetSelectionId.forNetwork("image", null, null))
        assertNull(AssetSelectionId.forNetwork("image", "", null))
        assertNull(AssetSelectionId.forNetwork("image", "   ", null))
    }

    @Test
    fun `of() network 走哈希，local 走 assetId 回退 url`() {
        // network
        assertEquals(
            "network_2154acac6a5daf57df4b128b66ec38b62dc0baf15011bf0866cc9f3baf1bfa69",
            AssetSelectionId.of(
                mapOf("type" to "network", "url" to "https://x/i.jpg", "mediaType" to "image"),
            ),
        )
        // local: 优先 assetId
        assertEquals(
            "content://media/external/file/42",
            AssetSelectionId.of(
                mapOf("type" to "local", "assetId" to "content://media/external/file/42"),
            ),
        )
        // local: 无 assetId 回退 url
        assertEquals(
            "https://x/i.jpg",
            AssetSelectionId.of(mapOf("type" to "local", "url" to "https://x/i.jpg")),
        )
        // null 输入
        assertNull(AssetSelectionId.of(null))
    }
}
