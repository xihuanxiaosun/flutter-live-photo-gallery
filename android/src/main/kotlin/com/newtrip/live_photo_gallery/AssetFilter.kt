package com.newtrip.live_photo_gallery

/** 选择器顶部「类型」筛选。 */
internal enum class MediaFilter { ALL, IMAGE, VIDEO }

/**
 * 按类型过滤资源列表（纯逻辑，可单元测试）。从 MediaPickerActivity.applyFilter 抽出。
 */
internal object AssetFilter {
    fun filter(assets: List<MediaAsset>, filter: MediaFilter): List<MediaAsset> = when (filter) {
        MediaFilter.IMAGE -> assets.filter { it.mediaType == "image" }
        MediaFilter.VIDEO -> assets.filter { it.mediaType == "video" }
        MediaFilter.ALL -> assets
    }
}
