package com.newtrip.live_photo_gallery

import org.junit.Assert.assertEquals
import org.junit.Test

class DownloadMetadataTest {

    @Test
    fun `扩展名从 URI path 解析并去掉 query`() {
        // "#1 fix"：URL 含 ?param 时也能取到正确扩展名
        assertEquals("png", DownloadMetadata.extensionFor("https://h/a.PNG?x=1"))
        assertEquals("jpeg", DownloadMetadata.extensionFor("https://h/photo.jpeg"))
    }

    @Test
    fun `非法扩展名回退 jpg`() {
        assertEquals("jpg", DownloadMetadata.extensionFor("https://h/a"))            // 无点
        assertEquals("jpg", DownloadMetadata.extensionFor("https://h/a.jpeg2000"))  // 长度 > 5
        assertEquals("jpg", DownloadMetadata.extensionFor("https://h/a.7z"))        // 含非字母
    }

    @Test
    fun `mime 映射`() {
        assertEquals("image/png", DownloadMetadata.mimeFor("png"))
        assertEquals("image/gif", DownloadMetadata.mimeFor("gif"))
        assertEquals("image/webp", DownloadMetadata.mimeFor("webp"))
        assertEquals("image/jpeg", DownloadMetadata.mimeFor("jpg"))
        assertEquals("image/jpeg", DownloadMetadata.mimeFor("heic"))
    }
}
