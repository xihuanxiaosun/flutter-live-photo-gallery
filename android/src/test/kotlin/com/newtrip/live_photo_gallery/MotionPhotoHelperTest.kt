package com.newtrip.live_photo_gallery

import org.junit.Assert.*
import org.junit.Test

/**
 * MotionPhotoHelper 单元测试
 * 覆盖：文件名启发式检测、XMP marker 检测、XMP 视频长度解析（5 种格式）
 *
 * 注：isSamsungDevice 依赖 Build.MANUFACTURER，JVM 测试中 returnDefaultValues=true
 * 使其返回 "" (非三星)，故非三星路径的名称启发式测试结果可预测。
 */
class MotionPhotoHelperTest {

    // ── isLikelyMotionPhotoByName ────────────────────────────────────────────

    @Test
    fun pixelNewFormatMPDotDetected() {
        assertTrue(MotionPhotoHelper.isLikelyMotionPhotoByName("PXL_20240101_123456.MP.jpg"))
    }

    @Test
    fun pixelFullPathMPDotDetected() {
        assertTrue(
            MotionPhotoHelper.isLikelyMotionPhotoByName(
                "/storage/emulated/0/DCIM/Camera/PXL_20240315_103045.MP.jpg"
            )
        )
    }

    @Test
    fun mvimgPrefixDetected() {
        assertTrue(MotionPhotoHelper.isLikelyMotionPhotoByName("MVIMG_20240101_123456.jpg"))
    }

    @Test
    fun mvimgLowercaseDetected() {
        assertTrue(
            MotionPhotoHelper.isLikelyMotionPhotoByName(
                "/storage/emulated/0/DCIM/Camera/mvimg_20240101.jpg"
            )
        )
    }

    @Test
    fun normalPhotoReturnsFalseOnNonSamsung() {
        // Build.MANUFACTURER returns "" in JVM tests (returnDefaultValues=true) → isSamsungDevice=false
        assertFalse(MotionPhotoHelper.isLikelyMotionPhotoByName("IMG_20240101_123456.jpg"))
    }

    @Test
    fun videoFileReturnsFalseOnNonSamsung() {
        assertFalse(MotionPhotoHelper.isLikelyMotionPhotoByName("VID_20240101_123456.mp4"))
    }

    // ── containsMotionPhotoMarker ────────────────────────────────────────────

    @Test
    fun markerMotionPhoto1Detected() {
        assertTrue(MotionPhotoHelper.containsMotionPhotoMarker("""MotionPhoto="1" """))
    }

    @Test
    fun markerCameraMotionPhoto1Detected() {
        // Camera namespace prefix (no colon in method name)
        assertTrue(MotionPhotoHelper.containsMotionPhotoMarker("""Camera:MotionPhoto="1" """))
    }

    @Test
    fun markerGCameraMotionPhoto1Detected() {
        assertTrue(MotionPhotoHelper.containsMotionPhotoMarker("""GCamera:MotionPhoto="1" """))
    }

    @Test
    fun markerMicroVideo1Detected() {
        assertTrue(MotionPhotoHelper.containsMotionPhotoMarker("""MicroVideo="1" """))
    }

    @Test
    fun markerGCameraMicroVideo1Detected() {
        assertTrue(MotionPhotoHelper.containsMotionPhotoMarker("""GCamera:MicroVideo="1" """))
    }

    @Test
    fun markerSamsungMotionPhotoCaptureFPSDetected() {
        assertTrue(MotionPhotoHelper.containsMotionPhotoMarker("""MotionPhoto_Capture_FPS="30" """))
    }

    @Test
    fun markerSamsungSecMotionPhotoDetected() {
        assertTrue(MotionPhotoHelper.containsMotionPhotoMarker("""sec:MotionPhoto="1" """))
    }

    @Test
    fun regularPhotoWithoutMarkerReturnsFalse() {
        val xmp = """<x:xmpmeta><rdf:Description rdf:about="" Camera:Make="Google"/></x:xmpmeta>"""
        assertFalse(MotionPhotoHelper.containsMotionPhotoMarker(xmp))
    }

    @Test
    fun motionPhotoZeroIsNotMotionPhoto() {
        assertFalse(MotionPhotoHelper.containsMotionPhotoMarker("""MotionPhoto="0" """))
    }

    @Test
    fun emptyXmpReturnsFalse() {
        assertFalse(MotionPhotoHelper.containsMotionPhotoMarker(""))
    }

    // ── parseVideoLength ─────────────────────────────────────────────────────

    @Test
    fun containerAttributeFormat() {
        // Pixel attribute-style: Semantic="Video" Item:Length="..."
        val xmp = """<Item Semantic="Video" Item:Length="987654"/>"""
        assertEquals(987654L, MotionPhotoHelper.parseVideoLength(xmp))
    }

    @Test
    fun secVideoLengthFormat() {
        // Samsung One UI 3
        val xmp = """<rdf:Description sec:VideoLength="555000"/>"""
        assertEquals(555000L, MotionPhotoHelper.parseVideoLength(xmp))
    }

    @Test
    fun microVideoLengthFormat() {
        // Samsung old format (GCamera namespace, no colon in test name)
        val xmp = """<rdf:Description GCamera:MicroVideoLength="300000"/>"""
        assertEquals(300000L, MotionPhotoHelper.parseVideoLength(xmp))
    }

    @Test
    fun microVideoOffsetFormat() {
        // Pixel MVIMG / Samsung oldest format
        val xmp = """<rdf:Description GCamera:MicroVideoOffset="150000"/>"""
        assertEquals(150000L, MotionPhotoHelper.parseVideoLength(xmp))
    }

    @Test
    fun emptyXmpReturns0() {
        assertEquals(0L, MotionPhotoHelper.parseVideoLength(""))
    }

    @Test
    fun unrecognizedFormatReturns0() {
        val xmp = """<x:xmpmeta><rdf:Description rdf:about=""/></x:xmpmeta>"""
        assertEquals(0L, MotionPhotoHelper.parseVideoLength(xmp))
    }

    @Test
    fun priorityContainerAttrOverMicroVideoOffset() {
        // When both formats present, Container attribute wins (higher priority)
        val xmp = """Semantic="Video" Item:Length="99999" GCamera:MicroVideoOffset="11111""""
        assertEquals(99999L, MotionPhotoHelper.parseVideoLength(xmp))
    }

    @Test
    fun prioritySecVideoLengthOverMicroVideoLength() {
        val xmp = """sec:VideoLength="77777" GCamera:MicroVideoLength="44444""""
        assertEquals(77777L, MotionPhotoHelper.parseVideoLength(xmp))
    }
}
