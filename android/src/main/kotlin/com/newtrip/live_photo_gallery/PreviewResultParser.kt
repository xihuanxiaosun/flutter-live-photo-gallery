package com.newtrip.live_photo_gallery

import org.json.JSONArray

/**
 * 解析「预览页返回的 JSON」——纯逻辑，可单元测试。
 * 从 MediaPickerActivity 抽出（parseSelectedIds / parseEditedPaths）。
 */
internal object PreviewResultParser {

    /** 已选 assetId 列表（优先 originAssetId，回退 assetId；丢弃空白；malformed → 空列表）。 */
    fun selectedIds(json: String): List<String> = runCatching {
        val arr = JSONArray(json)
        (0 until arr.length())
            .map { i ->
                val obj = arr.getJSONObject(i)
                obj.optString("originAssetId").ifBlank { obj.optString("assetId") }
            }
            .filter { it.isNotBlank() }
    }.getOrDefault(emptyList())

    /** assetId → editedPath（仅保留 id 与 editedPath 均非空的项；malformed → 空 map）。 */
    fun editedPaths(json: String): Map<String, String> = runCatching {
        val arr = JSONArray(json)
        buildMap {
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                val id = obj.optString("originAssetId").ifBlank { obj.optString("assetId") }
                val edited = obj.optString("editedPath")
                if (id.isNotBlank() && edited.isNotBlank()) put(id, edited)
            }
        }
    }.getOrDefault(emptyMap())
}
