package com.newtrip.live_photo_gallery

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ResultItemMapperTest {

    @Test
    fun `outMediaType 把动态照片映射为 livePhoto`() {
        assertEquals("livePhoto", ResultItemMapper.outMediaType("image", isMotionPhoto = true))
        assertEquals("image", ResultItemMapper.outMediaType("image", isMotionPhoto = false))
        assertEquals("video", ResultItemMapper.outMediaType("video", isMotionPhoto = false))
    }

    @Test
    fun `outDuration 仅视频返回秒级时长`() {
        assertEquals(2.5, ResultItemMapper.outDuration("video", 2500L)!!, 1e-6)
        assertNull(ResultItemMapper.outDuration("image", 2500L))
    }

    @Test
    fun `localItem assetId 优先 editedPath，includeOriginId 控制 originAssetId`() {
        val edited = ResultItemMapper.localItem(
            originAssetId = "id1", editedPath = "/edit.jpg", mediaType = "image",
            isMotionPhoto = false, durationMs = 0L, thumbPath = "/t.jpg",
            width = 10, height = 20, includeOriginId = true,
        )
        assertEquals("/edit.jpg", edited["assetId"])
        assertEquals("id1", edited["originAssetId"])

        val picker = ResultItemMapper.localItem(
            originAssetId = "id2", editedPath = null, mediaType = "video",
            isMotionPhoto = false, durationMs = 3000L, thumbPath = "/t.jpg",
            width = 10, height = 20, includeOriginId = false,
        )
        assertEquals("id2", picker["assetId"])
        assertFalse(picker.containsKey("originAssetId"))
        assertEquals(3.0, picker["duration"])
    }

    @Test
    fun `networkItem 始终带 originAssetId`() {
        val item = ResultItemMapper.networkItem(
            originAssetId = "network_abc", editedPath = null, mediaType = "livePhoto",
            durationSec = null, thumbPath = "/t.jpg", width = 4, height = 3,
        )
        assertEquals("network_abc", item["assetId"])
        assertEquals("network_abc", item["originAssetId"])
        assertEquals("livePhoto", item["mediaType"])
    }

    @Test
    fun `toJson round-trip 保形，includeOriginId 决定是否输出 originAssetId`() {
        val items = listOf(
            ResultItemMapper.localItem(
                originAssetId = "id1", editedPath = null, mediaType = "image",
                isMotionPhoto = false, durationMs = 0L, thumbPath = "/t.jpg",
                width = 10, height = 20, includeOriginId = true,
            ),
        )
        val withOrigin = JSONArray(ResultItemMapper.toJson(items, includeOriginId = true)).getJSONObject(0)
        assertEquals("id1", withOrigin.getString("assetId"))
        assertEquals("id1", withOrigin.getString("originAssetId"))
        assertEquals("image", withOrigin.getString("mediaType"))
        assertEquals(10, withOrigin.getInt("width"))

        val noOrigin = JSONArray(ResultItemMapper.toJson(items, includeOriginId = false)).getJSONObject(0)
        assertFalse(noOrigin.has("originAssetId"))
    }
}
