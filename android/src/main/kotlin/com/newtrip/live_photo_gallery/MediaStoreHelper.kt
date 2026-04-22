package com.newtrip.live_photo_gallery

import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.provider.MediaStore

// MediaStore 查询辅助工具
// 负责从系统媒体库获取图片和视频资源列表
object MediaStoreHelper {

    // MediaStore 媒体类型常量
    private const val MEDIA_TYPE_IMAGE = 1
    private const val MEDIA_TYPE_VIDEO = 3

    /**
     * 查询媒体资源，按修改时间降序排列
     *
     * @param bucketId 相册过滤：传入 AlbumHelper.ALL_BUCKET_ID 查全部，
     *                 传入具体 bucket_id 则只查该相册
     */
    fun fetchAll(
        context: Context,
        config: PickerConfig,
        bucketId: Long = AlbumHelper.ALL_BUCKET_ID
    ): List<MediaAsset> {
        val results = mutableListOf<MediaAsset>()

        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DATA,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.Files.FileColumns.DURATION,
            MediaStore.Files.FileColumns.WIDTH,
            MediaStore.Files.FileColumns.HEIGHT,
            MediaStore.Files.FileColumns.MIME_TYPE
        )

        // 构建媒体类型过滤条件（含相册过滤）
        val selection = buildSelection(config, bucketId)

        val sortOrder = "${MediaStore.Files.FileColumns.DATE_MODIFIED} DESC"
        val queryUri = MediaStore.Files.getContentUri("external")

        val cursor: Cursor? = context.contentResolver.query(
            queryUri,
            projection,
            selection,
            null,
            sortOrder
        )

        cursor?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val dataCol = c.getColumnIndex(MediaStore.Files.FileColumns.DATA)
            val nameCol = c.getColumnIndex(MediaStore.Files.FileColumns.DISPLAY_NAME)
            val typeCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
            val durationCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DURATION)
            val widthCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.WIDTH)
            val heightCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.HEIGHT)
            val mimeCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MIME_TYPE)

            while (c.moveToNext()) {
                val id = c.getLong(idCol)
                // _DATA 在 Android 10+ Scoped Storage 下不稳定，这里只作为启发式来源；
                // 拿不到时回退到 DISPLAY_NAME，避免影响资源可见性。
                val filePath = c.getStringOrNull(dataCol)
                    ?: c.getStringOrNull(nameCol)
                    ?: ""
                val mediaTypeInt = c.getInt(typeCol)
                val duration = c.getLong(durationCol)
                val width = c.getInt(widthCol)
                val height = c.getInt(heightCol)
                val mimeType = c.getString(mimeCol) ?: ""

                val mediaType = when (mediaTypeInt) {
                    MEDIA_TYPE_IMAGE -> "image"
                    MEDIA_TYPE_VIDEO -> "video"
                    else -> continue
                }

                // content URI 格式：content://media/external/file/{id}
                val contentUri: Uri = ContentUris.withAppendedId(
                    MediaStore.Files.getContentUri("external"),
                    id
                )

                // Motion Photo 检测策略：
                // - Pixel：文件名启发（MP. / MVIMG），O(1) 无 I/O，准确率高
                // - Samsung：文件名无规律，此处先标记为"候选"（isSamsung=true 时全部 JPEG 候选）
                //   实际精确判断在 refineMotionPhotosForSamsung() 中批量 XMP 扫描
                val isMotionPhotoCandidate = mediaType == "image"
                    && config.effectiveEnableLivePhoto
                    && MotionPhotoHelper.isLikelyMotionPhotoByName(filePath)

                // 非 Samsung 设备直接用启发式结果；Samsung 设备候选后续精确扫描
                val isMotionPhoto = isMotionPhotoCandidate && !MotionPhotoHelper.isSamsungDevice

                results.add(
                    MediaAsset(
                        id = id,
                        uri = contentUri,
                        filePath = filePath,
                        mediaType = mediaType,
                        duration = duration,
                        width = width,
                        height = height,
                        mimeType = mimeType,
                        isMotionPhoto = isMotionPhoto
                    )
                )
            }
        }

        // Samsung 设备：批量扫描前 SAMSUNG_SCAN_LIMIT 张 JPEG 的 XMP（I/O 受控）
        // 其余照片 isMotionPhoto=false，用户浏览时 fetchById 会精确判断
        if (config.effectiveEnableLivePhoto && MotionPhotoHelper.isSamsungDevice) {
            val scanLimit = samsungScanLimitFor(
                isSamsungDevice = MotionPhotoHelper.isSamsungDevice,
                filterConfig = config.filterConfig
            )
            refineSamsungMotionPhotos(context, results, scanLimit)
        }

        return results.filter {
            shouldKeepInFilterMode(
                mediaType = it.mediaType,
                isMotionPhoto = it.isMotionPhoto,
                filterConfig = config.filterConfig
            )
        }
    }

    /**
     * Samsung 设备专用：对前 N 张图片做精确 XMP 扫描，更新 isMotionPhoto 标记
     *
     * 限制扫描数量（SAMSUNG_SCAN_LIMIT）以控制 I/O 压力：
     * 用户最常操作最近拍摄的照片（排在列表最前），优先精确标注这部分。
     * 超出范围的照片首次通过 fetchById 展示时再精确判断（懒加载）。
     */
    private fun refineSamsungMotionPhotos(
        context: Context,
        results: MutableList<MediaAsset>,
        maxScanCount: Int
    ) {
        var scanned = 0
        for (i in results.indices) {
            val asset = results[i]
            if (asset.mediaType != "image") continue
            if (scanned >= maxScanCount) break
            scanned++
            val precise = runCatching {
                MotionPhotoHelper.isMotionPhoto(context, asset.uri)
            }.getOrDefault(false)
            if (precise) {
                results[i] = asset.copy(isMotionPhoto = true)
            }
        }
    }

    // 通过 assetId（URI 字符串）查询单个媒体资源
    fun fetchById(context: Context, assetId: String): MediaAsset? {
        val uri = Uri.parse(assetId)
        val id = uri.lastPathSegment?.toLongOrNull() ?: run {
            android.util.Log.w("MediaStoreHelper",
                "fetchById: URI '$assetId' 末段无法解析为数字 ID，跳过 MediaStore 查询")
            return null
        }

        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DATA,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.Files.FileColumns.DURATION,
            MediaStore.Files.FileColumns.WIDTH,
            MediaStore.Files.FileColumns.HEIGHT,
            MediaStore.Files.FileColumns.MIME_TYPE
        )

        val queryUri = MediaStore.Files.getContentUri("external")
        val selection = "${MediaStore.Files.FileColumns._ID} = ?"
        val selectionArgs = arrayOf(id.toString())

        val cursor: Cursor? = context.contentResolver.query(
            queryUri,
            projection,
            selection,
            selectionArgs,
            null
        )

        return cursor?.use { c ->
            if (!c.moveToFirst()) return null

            val idCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val dataCol = c.getColumnIndex(MediaStore.Files.FileColumns.DATA)
            val nameCol = c.getColumnIndex(MediaStore.Files.FileColumns.DISPLAY_NAME)
            val typeCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
            val durationCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DURATION)
            val widthCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.WIDTH)
            val heightCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.HEIGHT)
            val mimeCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MIME_TYPE)

            val fileId = c.getLong(idCol)
            val filePath = c.getStringOrNull(dataCol)
                ?: c.getStringOrNull(nameCol)
                ?: ""
            val mediaTypeInt = c.getInt(typeCol)
            val duration = c.getLong(durationCol)
            val width = c.getInt(widthCol)
            val height = c.getInt(heightCol)
            val mimeType = c.getString(mimeCol) ?: ""

            val mediaType = when (mediaTypeInt) {
                MEDIA_TYPE_IMAGE -> "image"
                MEDIA_TYPE_VIDEO -> "video"
                else -> return null
            }

            val contentUri: Uri = ContentUris.withAppendedId(
                MediaStore.Files.getContentUri("external"),
                fileId
            )

            // fetchById 时做精确 XMP 检测（通过 URI，不依赖 _DATA 文件路径）
            val isMotionPhoto = mediaType == "image"
                && MotionPhotoHelper.isMotionPhoto(context, contentUri)

            MediaAsset(
                id = fileId,
                uri = contentUri,
                filePath = filePath,
                mediaType = mediaType,
                duration = duration,
                width = width,
                height = height,
                mimeType = mimeType,
                isMotionPhoto = isMotionPhoto
            )
        }
    }

    // Samsung 精确扫描的最大条数（控制 I/O 压力，对齐首屏可见范围）
    private const val SAMSUNG_SCAN_LIMIT = 60  // 降低至约 1 屏高度，控制首次加载 IO 压力

    // @VisibleForTesting
    internal fun samsungScanLimitFor(isSamsungDevice: Boolean, filterConfig: String): Int {
        if (!isSamsungDevice) return 0
        return if (filterConfig == "livePhotoOnly") Int.MAX_VALUE else SAMSUNG_SCAN_LIMIT
    }

    // @VisibleForTesting
    internal fun shouldKeepInFilterMode(
        mediaType: String,
        isMotionPhoto: Boolean,
        filterConfig: String
    ): Boolean {
        return when (filterConfig) {
            "livePhotoOnly" -> mediaType == "image" && isMotionPhoto
            else -> true
        }
    }

    // 构建 MediaStore 查询的 selection 条件（考虑 filterConfig 和 videoMaxDuration）
    // @VisibleForTesting
    internal fun buildSelection(config: PickerConfig, bucketId: Long): String {
        val typeConditions = mutableListOf<String>()

        // 图片：imageOnly / livePhotoOnly / all 时显示；videoOnly 时隐藏
        if (config.filterConfig != "videoOnly") {
            typeConditions.add("${MediaStore.Files.FileColumns.MEDIA_TYPE} = $MEDIA_TYPE_IMAGE")
        }
        // 视频：effectiveEnableVideo 为真时才加入
        if (config.effectiveEnableVideo) {
            typeConditions.add("${MediaStore.Files.FileColumns.MEDIA_TYPE} = $MEDIA_TYPE_VIDEO")
        }

        // 兜底：至少查图片，防止 typeConditions 为空导致 SQL 错误
        if (typeConditions.isEmpty()) {
            typeConditions.add("${MediaStore.Files.FileColumns.MEDIA_TYPE} = $MEDIA_TYPE_IMAGE")
        }

        val typeClause   = "(${typeConditions.joinToString(" OR ")})"
        val mimeClause   = "${MediaStore.Files.FileColumns.MIME_TYPE} IS NOT NULL"
        val bucketClause = if (bucketId != AlbumHelper.ALL_BUCKET_ID)
            " AND bucket_id = $bucketId" else ""

        // 视频时长上限过滤：仅对视频生效，图片（DURATION=0）不受影响
        val durationClause = if (config.effectiveEnableVideo && config.videoMaxDuration > 0) {
            val maxMs = (config.videoMaxDuration * 1000).toLong()
            " AND (${MediaStore.Files.FileColumns.MEDIA_TYPE} != $MEDIA_TYPE_VIDEO" +
                " OR ${MediaStore.Files.FileColumns.DURATION} <= $maxMs)"
        } else ""

        return "$typeClause AND $mimeClause$bucketClause$durationClause"
    }

    private fun Cursor.getStringOrNull(index: Int): String? {
        if (index < 0 || isNull(index)) return null
        return getString(index)
    }
}
