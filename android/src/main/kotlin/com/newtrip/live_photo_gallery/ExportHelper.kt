package com.newtrip.live_photo_gallery

import android.content.Context
import android.graphics.Bitmap
import com.bumptech.glide.Glide
import com.bumptech.glide.load.engine.DiskCacheStrategy
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

// 导出辅助工具
// 负责缩略图生成、文件导出和临时文件清理
// 所有临时文件以 lpg_ 为前缀，方便统一清理
object ExportHelper {

    // 生成缩略图并保存为 JPEG
    // 文件名具有确定性：lpg_{id}_{w}x{h}.jpg，命中缓存则直接返回路径
    fun saveThumbnail(context: Context, asset: MediaAsset, width: Int, height: Int): String {
        // #1 - 主线程保护：Glide .get() 是阻塞调用，禁止在主线程执行
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
            "saveThumbnail 必须在 IO 线程调用"
        }

        val fileName = "lpg_${asset.id}_${width}x${height}.jpg"
        val file = File(context.cacheDir, fileName)

        // 缓存命中，直接返回
        if (file.exists() && file.length() > 0) {
            return file.absolutePath
        }

        // 使用 Glide 同步加载位图，在 IO 线程调用
        val bitmap: Bitmap = Glide.with(context.applicationContext)
            .asBitmap()
            .load(asset.uri)
            .override(width, height)
            .centerCrop()
            .diskCacheStrategy(DiskCacheStrategy.RESOURCE)
            .submit()
            .get() // 阻塞调用，调用方必须在 IO 线程

        // try-finally 保证 bitmap 无论是否发生异常都能释放，防止内存泄漏
        try {
            FileOutputStream(file).use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
            }
        } finally {
            bitmap.recycle()
        }

        return file.absolutePath
    }

    /**
     * 网络资源缩略图落盘（用于 previewAssets 返回给 Flutter）。
     *
     * - 文件名使用传入的 networkId + 尺寸，确保确定性缓存命中
     * - 始终输出 JPEG（与 iOS 对齐，避免 HEIC 等扩展名不一致）
     */
    fun saveNetworkThumbnail(
        context: Context,
        networkId: String,
        url: android.net.Uri,
        width: Int,
        height: Int,
    ): String {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
            "saveNetworkThumbnail 必须在 IO 线程调用"
        }

        val sanitizedId = networkId
            .replace('/', '_')
            .replace(':', '-')

        val fileName = "lpg_${sanitizedId}_${width}x${height}.jpg"
        val file = File(context.cacheDir, fileName)

        // 缓存命中，直接返回
        if (file.exists() && file.length() > 0) {
            return file.absolutePath
        }

        val bitmap: Bitmap = Glide.with(context.applicationContext)
            .asBitmap()
            .load(url)
            .override(width, height)
            .centerCrop()
            .diskCacheStrategy(DiskCacheStrategy.RESOURCE)
            .submit()
            .get()

        try {
            FileOutputStream(file).use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
            }
        } finally {
            bitmap.recycle()
        }

        return file.absolutePath
    }

    /**
     * 本地文件缩略图落盘（裁剪结果等临时文件）。
     */
    fun saveFileThumbnail(
        context: Context,
        filePath: String,
        key: String,
        width: Int,
        height: Int,
    ): String {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
            "saveFileThumbnail 必须在 IO 线程调用"
        }
        val sanitizedKey = key.replace('/', '_').replace(':', '-')
        val fileName = "lpg_${sanitizedKey}_${width}x${height}.jpg"
        val file = File(context.cacheDir, fileName)
        if (file.exists() && file.length() > 0) return file.absolutePath

        val bitmap: Bitmap = Glide.with(context.applicationContext)
            .asBitmap()
            .load(File(filePath))
            .override(width, height)
            .centerCrop()
            .diskCacheStrategy(DiskCacheStrategy.RESOURCE)
            .submit()
            .get()
        try {
            FileOutputStream(file).use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
            }
        } finally {
            bitmap.recycle()
        }
        return file.absolutePath
    }

    // 将图片文件复制到缓存目录，扩展名根据 MIME 类型决定（避免 HEIC 被错命名为 .jpg）
    // 返回缓存文件路径
    fun exportImage(context: Context, asset: MediaAsset): String {
        val ext = when {
            asset.mimeType.contains("png",  ignoreCase = true) -> "png"
            asset.mimeType.contains("webp", ignoreCase = true) -> "webp"
            asset.mimeType.contains("gif",  ignoreCase = true) -> "gif"
            asset.mimeType.contains("heic", ignoreCase = true) -> "heic"
            asset.mimeType.contains("heif", ignoreCase = true) -> "heif"
            else                                               -> "jpg"
        }
        val outputPath = cacheFilePath(context, "lpg_${UUID.randomUUID()}.$ext")
        copyFromUri(context, asset, outputPath)
        return outputPath
    }

    // 将视频文件复制到缓存目录
    fun exportVideo(context: Context, asset: MediaAsset): String {
        val outputPath = cacheFilePath(context, "lpg_${UUID.randomUUID()}.mp4")
        copyFromUri(context, asset, outputPath)
        return outputPath
    }

    // 从动态照片中提取视频轨道（通过 URI，不依赖 _DATA 文件路径）
    fun exportMotionPhotoVideo(context: Context, asset: MediaAsset): String {
        val outputPath = cacheFilePath(context, "lpg_${UUID.randomUUID()}.mp4")
        val success = MotionPhotoHelper.extractVideo(context, asset.uri, outputPath)
        if (!success) {
            throw IllegalStateException("动态照片视频提取失败：${asset.uri}")
        }
        return outputPath
    }

    // 清理缓存目录中所有以 lpg_ 开头的临时文件
    // #22 - 记录删除失败的文件，便于排查权限或文件占用问题
    fun cleanup(context: Context) {
        context.cacheDir.listFiles { file ->
            file.name.startsWith("lpg_")
        }?.forEach { file ->
            if (!file.delete()) {
                android.util.Log.w("LivePhotoGallery", "临时文件删除失败：${file.absolutePath}")
            }
        }
    }

    // 生成缓存文件的完整路径
    private fun cacheFilePath(context: Context, name: String): String {
        return File(context.cacheDir, name).absolutePath
    }

    // 通过 ContentResolver 从 URI 读取内容并写入目标路径
    // #2 - 写入失败时删除已创建的不完整文件，防止后续误用
    private fun copyFromUri(context: Context, asset: MediaAsset, outputPath: String) {
        val inputStream = context.contentResolver.openInputStream(asset.uri)
            ?: throw IllegalStateException("无法打开资源流：${asset.uri}")
        val outputFile = File(outputPath)
        try {
            inputStream.use { input ->
                FileOutputStream(outputFile).use { output ->
                    input.copyTo(output, bufferSize = 8192)
                }
            }
        } catch (e: Exception) {
            outputFile.delete()   // 清除写入失败的不完整文件，防止后续误用
            throw e
        }
    }
}
