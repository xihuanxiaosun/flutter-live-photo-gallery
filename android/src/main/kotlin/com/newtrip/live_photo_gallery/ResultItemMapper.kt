package com.newtrip.live_photo_gallery

import org.json.JSONArray
import org.json.JSONObject

/**
 * 「已选资源 → 返回给 Flutter 的结果 map / JSON」的组装逻辑（纯逻辑，可单元测试）。
 *
 * 此前 PreviewActivity.returnSelectedResults 与 MediaPickerActivity.exportAndReturn
 * 各写了一份几乎相同的字段派生 + JSON 组装。缩略图生成 / MediaStore 查询等 I/O 仍留在
 * 各自的协程里，这里只接收已算好的 thumbPath 等，做纯字段映射。
 *
 * 两处唯一差异：预览页带 `originAssetId`（用于跨端选择 round-trip），选择页不带——
 * 由 [includeOriginId] 控制。
 */
internal object ResultItemMapper {

    /** Live Photo / Motion Photo 统一返回 `"livePhoto"`（对齐 iOS），其余透传。 */
    fun outMediaType(mediaType: String, isMotionPhoto: Boolean): String =
        if (isMotionPhoto) "livePhoto" else mediaType

    /** 视频返回秒级时长，其余 null。 */
    fun outDuration(mediaType: String, durationMs: Long): Double? =
        if (mediaType == "video") durationMs / 1000.0 else null

    /** 本地资源 → 结果 map。 */
    fun localItem(
        originAssetId: String,
        editedPath: String?,
        mediaType: String,
        isMotionPhoto: Boolean,
        durationMs: Long,
        thumbPath: String,
        width: Int,
        height: Int,
        includeOriginId: Boolean,
    ): Map<String, Any?> = buildMap {
        put("assetId", editedPath ?: originAssetId)
        if (includeOriginId) put("originAssetId", originAssetId)
        put("mediaType", outMediaType(mediaType, isMotionPhoto))
        put("thumbnailPath", thumbPath)
        put("editedPath", editedPath)
        put("duration", outDuration(mediaType, durationMs))
        put("width", width)
        put("height", height)
    }

    /** 网络 / 回退资源 → 结果 map（始终带 originAssetId；mediaType/duration 已由调用方算好）。 */
    fun networkItem(
        originAssetId: String,
        editedPath: String?,
        mediaType: String,
        durationSec: Double?,
        thumbPath: String,
        width: Int,
        height: Int,
    ): Map<String, Any?> = mapOf(
        "assetId" to (editedPath ?: originAssetId),
        "originAssetId" to originAssetId,
        "mediaType" to mediaType,
        "thumbnailPath" to thumbPath,
        "editedPath" to editedPath,
        "duration" to durationSec,
        "width" to width,
        "height" to height,
    )

    /** 结果 map 列表 → JSON 字符串。[includeOriginId] 与 [localItem] 对应。 */
    fun toJson(items: List<Map<String, Any?>>, includeOriginId: Boolean): String {
        val arr = JSONArray()
        items.forEach { item ->
            arr.put(JSONObject().apply {
                put("assetId", item["assetId"])
                if (includeOriginId) put("originAssetId", item["originAssetId"])
                put("mediaType", item["mediaType"])
                put("thumbnailPath", item["thumbnailPath"])
                put("editedPath", item["editedPath"])
                put("duration", item["duration"])
                put("width", item["width"])
                put("height", item["height"])
            })
        }
        return arr.toString()
    }
}
