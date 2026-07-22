package com.newtrip.live_photo_gallery

import android.net.Uri
import org.junit.Assert.assertEquals
import org.junit.Test
import org.mockito.kotlin.mock

class AssetFilterTest {

    private fun asset(type: String, id: Long = 1L) = MediaAsset(
        id = id,
        uri = mock<Uri>(),
        filePath = "",
        mediaType = type,
        duration = 0L,
        width = 0,
        height = 0,
        mimeType = "",
        isMotionPhoto = false,
    )

    private val list = listOf(asset("image", 1), asset("video", 2), asset("image", 3))

    @Test
    fun `IMAGE 仅保留图片`() {
        val out = AssetFilter.filter(list, MediaFilter.IMAGE)
        assertEquals(listOf(1L, 3L), out.map { it.id })
    }

    @Test
    fun `VIDEO 仅保留视频`() {
        val out = AssetFilter.filter(list, MediaFilter.VIDEO)
        assertEquals(listOf(2L), out.map { it.id })
    }

    @Test
    fun `ALL 原样返回`() {
        assertEquals(list, AssetFilter.filter(list, MediaFilter.ALL))
    }
}
