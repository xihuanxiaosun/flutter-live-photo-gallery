package com.newtrip.live_photo_gallery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewResultParserTest {

    @Test
    fun `selectedIds 优先 originAssetId 回退 assetId 并丢弃空白`() {
        val json = """
            [{"originAssetId":"o1","assetId":"a1"},
             {"originAssetId":"","assetId":"a2"},
             {"assetId":""}]
        """.trimIndent()
        assertEquals(listOf("o1", "a2"), PreviewResultParser.selectedIds(json))
    }

    @Test
    fun `selectedIds malformed 返回空列表`() {
        assertTrue(PreviewResultParser.selectedIds("not json").isEmpty())
    }

    @Test
    fun `editedPaths 仅保留 id 与 editedPath 均非空的项`() {
        val json = """
            [{"assetId":"a1","editedPath":"/p1"},
             {"assetId":"a2","editedPath":""},
             {"assetId":"a3"}]
        """.trimIndent()
        assertEquals(mapOf("a1" to "/p1"), PreviewResultParser.editedPaths(json))
    }

    @Test
    fun `editedPaths 优先 originAssetId 作为键`() {
        val json = """[{"originAssetId":"o1","assetId":"a1","editedPath":"/p1"}]"""
        assertEquals(mapOf("o1" to "/p1"), PreviewResultParser.editedPaths(json))
    }

    @Test
    fun `editedPaths malformed 返回空 map`() {
        assertTrue(PreviewResultParser.editedPaths("{bad").isEmpty())
    }
}
