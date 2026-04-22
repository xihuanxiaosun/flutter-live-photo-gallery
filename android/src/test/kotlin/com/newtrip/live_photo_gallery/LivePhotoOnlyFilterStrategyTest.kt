package com.newtrip.live_photo_gallery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LivePhotoOnlyFilterStrategyTest {

    @Test
    fun `samsung scan limit uses default in normal mode`() {
        assertEquals(60, MediaStoreHelper.samsungScanLimitFor(true, "all"))
    }

    @Test
    fun `samsung scan limit becomes full scan in livePhotoOnly`() {
        assertEquals(Int.MAX_VALUE, MediaStoreHelper.samsungScanLimitFor(true, "livePhotoOnly"))
    }

    @Test
    fun `non samsung does not request samsung scan`() {
        assertEquals(0, MediaStoreHelper.samsungScanLimitFor(false, "livePhotoOnly"))
        assertEquals(0, MediaStoreHelper.samsungScanLimitFor(false, "all"))
    }

    @Test
    fun `livePhotoOnly keeps only motion-photo images`() {
        assertTrue(
            MediaStoreHelper.shouldKeepInFilterMode(
                mediaType = "image",
                isMotionPhoto = true,
                filterConfig = "livePhotoOnly"
            )
        )
        assertFalse(
            MediaStoreHelper.shouldKeepInFilterMode(
                mediaType = "image",
                isMotionPhoto = false,
                filterConfig = "livePhotoOnly"
            )
        )
        assertFalse(
            MediaStoreHelper.shouldKeepInFilterMode(
                mediaType = "video",
                isMotionPhoto = false,
                filterConfig = "livePhotoOnly"
            )
        )
    }

    @Test
    fun `non livePhotoOnly mode keeps all assets`() {
        assertTrue(MediaStoreHelper.shouldKeepInFilterMode("image", false, "all"))
        assertTrue(MediaStoreHelper.shouldKeepInFilterMode("video", false, "videoOnly"))
        assertTrue(MediaStoreHelper.shouldKeepInFilterMode("image", false, "imageOnly"))
    }
}
