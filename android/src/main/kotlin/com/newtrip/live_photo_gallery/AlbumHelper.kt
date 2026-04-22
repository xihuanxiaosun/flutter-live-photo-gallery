package com.newtrip.live_photo_gallery

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.provider.MediaStore

/** 相册条目（用于 BottomSheet 相册列表） */
data class AlbumItem(
    val bucketId: Long,       // ALL_BUCKET_ID 表示"全部"
    val displayName: String,
    val coverUri: Uri,        // 封面图（最新一张）
    val count: Int
)

/**
 * 相册查询辅助工具
 *
 * 使用 MediaStore.Files 一次查询获取所有相册，
 * 避免分别查 Images / Video 导致的两次 I/O。
 */
object AlbumHelper {

    const val ALL_BUCKET_ID = -1L

    private const val MEDIA_TYPE_IMAGE = 1
    private const val MEDIA_TYPE_VIDEO = 3

    // MediaStore 在 API 29 前通过字符串列名访问，避免版本分支
    private const val COLUMN_BUCKET_ID           = "bucket_id"
    private const val COLUMN_BUCKET_DISPLAY_NAME = "bucket_display_name"

    /**
     * 对齐 iOS：系统相册英文名 → 中文名映射
     * 来源：Android MediaStore bucket_display_name 在部分机型/地区为英文
     */
    private val ALBUM_NAME_MAP = mapOf(
        "Camera"            to "相机",
        "camera"            to "相机",
        "Camera Roll"       to "相机胶卷",
        "Screenshots"       to "屏幕截图",
        "Screen recordings" to "屏幕录制",
        "Download"          to "下载",
        "Downloads"         to "下载",
        "WhatsApp Images"   to "WhatsApp 图片",
        "WhatsApp Video"    to "WhatsApp 视频",
        "Recents"           to "最近项目",
        "Favorites"         to "个人收藏",
        "Videos"            to "视频",
        "Selfies"           to "自拍",
        "Live Photos"       to "实况照片",
        "Portraits"         to "人像",
        "Panoramas"         to "全景照片",
        "Bursts"            to "连拍快照",
        "Animated"          to "动图",
        "Long Exposure"     to "长曝光",
        "Hidden"            to "已隐藏",
        "Recently Saved"    to "最近保存",
        "My Photo Stream"   to "我的照片流",
        "Imports"           to "导入",
        "DCIM"              to "相机",
        "Pictures"          to "图片",
        "Movies"            to "影片",
    )

    /** 将 MediaStore 返回的原始相册名转换为中文（找不到映射则原样返回） */
    private fun localizeAlbumName(raw: String): String = ALBUM_NAME_MAP[raw] ?: raw

    /**
     * 查询设备上所有相册。
     * 返回列表：第一项固定为"所有照片"（ALL_BUCKET_ID），
     * 后续按相册内容数量降序排列。
     */
    fun fetchAlbums(context: Context, config: PickerConfig): List<AlbumItem> {
        // bucketId → 构建器，保留最新封面 URI
        val buckets = LinkedHashMap<Long, BucketBuilder>()
        var totalCount = 0

        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            COLUMN_BUCKET_ID,
            COLUMN_BUCKET_DISPLAY_NAME,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.Files.FileColumns.MIME_TYPE
        )

        val types = mutableListOf(
            "${MediaStore.Files.FileColumns.MEDIA_TYPE} = $MEDIA_TYPE_IMAGE"
        )
        if (config.enableVideo) {
            types.add("${MediaStore.Files.FileColumns.MEDIA_TYPE} = $MEDIA_TYPE_VIDEO")
        }
        val selection = buildString {
            append("(${types.joinToString(" OR ")})")
            append(" AND ${MediaStore.Files.FileColumns.MIME_TYPE} IS NOT NULL")
        }

        context.contentResolver.query(
            MediaStore.Files.getContentUri("external"),
            projection,
            selection,
            null,
            "${MediaStore.Files.FileColumns.DATE_MODIFIED} DESC"
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val bucketIdCol   = cursor.getColumnIndex(COLUMN_BUCKET_ID).takeIf { it >= 0 }
                ?: return emptyList()
            val bucketNameCol = cursor.getColumnIndex(COLUMN_BUCKET_DISPLAY_NAME).takeIf { it >= 0 }
                ?: return emptyList()

            while (cursor.moveToNext()) {
                val id       = cursor.getLong(idCol)
                val bucketId = cursor.getLong(bucketIdCol)
                val rawName  = cursor.getString(bucketNameCol) ?: "未知相册"
                val name     = localizeAlbumName(rawName)   // 英文 → 中文（对齐 iOS）
                val uri      = ContentUris.withAppendedId(
                    MediaStore.Files.getContentUri("external"), id
                )
                totalCount++
                // getOrPut 保证每个 bucket 只记录最新一张作为封面（查询结果已按时间倒序）
                buckets.getOrPut(bucketId) { BucketBuilder(bucketId, name, uri) }.count++
            }
        }

        if (buckets.isEmpty()) return emptyList()

        return buildList {
            // "所有照片" 固定排在最前，封面取最新一张
            add(AlbumItem(ALL_BUCKET_ID, "所有照片", buckets.values.first().coverUri, totalCount))
            // 其余相册按数量降序
            buckets.values.sortedByDescending { it.count }.forEach { b ->
                add(AlbumItem(b.bucketId, b.displayName, b.coverUri, b.count))
            }
        }
    }

    // ──────────────────────────────────────────────
    // 内部构建器（避免在 map 中存储 AlbumItem 然后反复创建）
    // ──────────────────────────────────────────────

    private class BucketBuilder(
        val bucketId: Long,
        val displayName: String,
        val coverUri: Uri,
        var count: Int = 0
    )
}
