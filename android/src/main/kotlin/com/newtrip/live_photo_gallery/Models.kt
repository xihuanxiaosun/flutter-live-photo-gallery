package com.newtrip.live_photo_gallery

import android.net.Uri

// ──────────────────────────────────────────────
// 媒体资源数据模型
// ──────────────────────────────────────────────

/** 单个媒体资源（图片 / 视频 / 动态照片） */
data class MediaAsset(
    val id: Long,
    val uri: Uri,
    val filePath: String,       // 文件路径或显示名，仅用于 Motion Photo 启发式判断
    val mediaType: String,      // "image" | "video"
    val duration: Long,         // 毫秒，图片为 0
    val width: Int,
    val height: Int,
    val mimeType: String,
    val isMotionPhoto: Boolean  // 是否为动态照片（Motion Photo）
)

// ──────────────────────────────────────────────
// 选择器配置
// ──────────────────────────────────────────────

/** 从 Flutter 传入的 MethodChannel args 构建选择器配置 */
data class PickerConfig(
    val maxCount: Int,
    val enableVideo: Boolean,
    val enableLivePhoto: Boolean,
    val showRadio: Boolean,
    val isDarkMode: Boolean,
    /** 对齐 iOS：进入视频页时自动触发系统播放器（默认 false） */
    val autoPlayVideo: Boolean = false,
    /** 最多可选视频/动态照片数量（-1 = 无限制） */
    val maxVideoCount: Int = -1,
    /** 视频最长时长限制（秒，0 = 无限制） */
    val videoMaxDuration: Double = 0.0,
    /** 媒体类型过滤："all" | "imageOnly" | "videoOnly" | "livePhotoOnly" */
    val filterConfig: String = "all"
) {
    /** enableVideo 经 filterConfig 修正后的实际值 */
    val effectiveEnableVideo: Boolean get() = when (filterConfig) {
        "imageOnly", "livePhotoOnly" -> false
        else -> enableVideo
    }

    /** enableLivePhoto 经 filterConfig 修正后的实际值 */
    val effectiveEnableLivePhoto: Boolean get() = when (filterConfig) {
        "imageOnly", "videoOnly" -> false
        else -> enableLivePhoto
    }

    companion object {
        private fun normalizeFilter(value: String?): String = when (value) {
            "all", "imageOnly", "videoOnly", "livePhotoOnly" -> value
            else -> "all"
        }

        private fun normalizeMaxCount(value: Int?): Int = when {
            value == null -> 9
            value <= 0 -> 1
            else -> value
        }

        private fun normalizeMaxVideoCount(value: Int?): Int = when {
            value == null -> -1
            value == -1 -> -1
            value <= 0 -> 1
            else -> value
        }

        private fun normalizeVideoMaxDuration(value: Double?): Double = when {
            value == null -> 0.0
            value < 0 -> 0.0
            else -> value
        }

        /**
         * 从 MethodChannel args map 构建配置，带安全默认值
         * 用于 LivePhotoGalleryPlugin.pickAssets / previewAssets
         */
        fun from(args: Map<String, Any>): PickerConfig = PickerConfig(
            maxCount         = normalizeMaxCount(args["maxCount"] as? Int),
            enableVideo      = (args["enableVideo"]      as? Boolean) ?: true,
            enableLivePhoto  = (args["enableLivePhoto"]  as? Boolean) ?: true,
            showRadio        = (args["showRadio"]        as? Boolean) ?: true,
            isDarkMode       = (args["isDarkMode"]       as? Boolean) ?: false,
            autoPlayVideo    = (args["autoPlayVideo"]    as? Boolean) ?: false,
            maxVideoCount    = normalizeMaxVideoCount(args["maxVideoCount"] as? Int),
            videoMaxDuration = normalizeVideoMaxDuration(args["videoMaxDuration"] as? Double),
            filterConfig     = normalizeFilter(args["filterConfig"] as? String)
        )

        /** 序列化为 JSON 字符串，用于通过 Intent extra 传递给 Activity */
        fun toJson(config: PickerConfig): String {
            return org.json.JSONObject().apply {
                put("maxCount",          config.maxCount)
                put("enableVideo",       config.enableVideo)
                put("enableLivePhoto",   config.enableLivePhoto)
                put("showRadio",         config.showRadio)
                put("isDarkMode",        config.isDarkMode)
                put("autoPlayVideo",     config.autoPlayVideo)
                put("maxVideoCount",     config.maxVideoCount)
                put("videoMaxDuration",  config.videoMaxDuration)
                put("filterConfig",      config.filterConfig)
            }.toString()
        }

        /** 从 JSON 字符串反序列化（Activity 侧使用） */
        fun fromJson(json: String): PickerConfig {
            val obj = org.json.JSONObject(json)
            return PickerConfig(
                maxCount         = normalizeMaxCount(obj.optInt("maxCount", 9)),
                enableVideo      = obj.optBoolean("enableVideo", true),
                enableLivePhoto  = obj.optBoolean("enableLivePhoto", true),
                showRadio        = obj.optBoolean("showRadio", true),
                isDarkMode       = obj.optBoolean("isDarkMode", false),
                autoPlayVideo    = obj.optBoolean("autoPlayVideo", false),
                maxVideoCount    = normalizeMaxVideoCount(obj.optInt("maxVideoCount", -1)),
                videoMaxDuration = normalizeVideoMaxDuration(obj.optDouble("videoMaxDuration", 0.0)),
                filterConfig     = normalizeFilter(obj.optString("filterConfig", "all"))
            )
        }
    }
}
