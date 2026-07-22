package com.newtrip.live_photo_gallery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MediaMapTest {

    @Test
    fun `doubleValue 支持 Number 与数字字符串，否则 0`() {
        assertEquals(3.0, mapOf("k" to 3).doubleValue("k"), 0.0)
        assertEquals(3.5, mapOf("k" to "3.5").doubleValue("k"), 0.0)
        assertEquals(0.0, mapOf("k" to "x").doubleValue("k"), 0.0)
        assertEquals(0.0, emptyMap<String, Any?>().doubleValue("k"), 0.0)
        assertEquals(0.0, (null as Map<String, Any?>?).doubleValue("k"), 0.0)
    }

    @Test
    fun `doubleValueOrNull 缺失或非法返回 null`() {
        assertEquals(2.0, mapOf("k" to 2).doubleValueOrNull("k"))
        assertNull(mapOf("k" to "x").doubleValueOrNull("k"))
        assertNull(emptyMap<String, Any?>().doubleValueOrNull("k"))
        assertNull((null as Map<String, Any?>?).doubleValueOrNull("k"))
    }

    @Test
    fun `intValue 截断小数、解析字符串，否则 0`() {
        assertEquals(2, mapOf("k" to 2.9).intValue("k"))
        assertEquals(7, mapOf("k" to "7").intValue("k"))
        assertEquals(0, mapOf("k" to "x").intValue("k"))
        assertEquals(0, emptyMap<String, Any?>().intValue("k"))
    }
}
