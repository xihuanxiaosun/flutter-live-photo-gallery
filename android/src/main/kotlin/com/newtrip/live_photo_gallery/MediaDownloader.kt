package com.newtrip.live_photo_gallery

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * 网络图片下载 + 写入系统相册（仅依赖 [Context]，可脱离 Activity 单独存在）。
 *
 * UI 编排（下载按钮状态、Toast、`onDownloadResult`/`onDownloadProgress` 回 channel）
 * 仍留在 PreviewActivity——那些需要 engineKey 与 Activity 上下文。
 */
internal class MediaDownloader(private val context: Context) {

    /**
     * 下载 [url] 并保存到系统相册。
     * @param onProgress 进度回调（0.0~1.0），在 IO 线程被调用——调用方需自行切回主线程使用 channel。
     * @return MediaStore uri 字符串；保存失败返回 null。网络/IO 异常向上抛出。
     */
    suspend fun download(
        url: String,
        saveAlbumName: String,
        onProgress: (Double) -> Unit,
    ): String? = withContext(Dispatchers.IO) {
        val ext = DownloadMetadata.extensionFor(url)
        val mimeType = DownloadMetadata.mimeFor(ext)

        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 30_000
            connect()
        }
        // 校验 HTTP 状态码：否则 404/500 的 HTML 错误体会被当作图片写入相册并误报成功。
        if (connection.responseCode !in 200..299) {
            val statusCode = connection.responseCode
            connection.disconnect()
            throw IOException("HTTP $statusCode")
        }
        val totalBytes = connection.contentLengthLong  // -1 if unknown
        val tempFile = File.createTempFile("lpg_dl_", ".$ext", context.cacheDir)
        try {
            connection.inputStream.use { inp ->
                tempFile.outputStream().use { out ->
                    val buffer = ByteArray(8 * 1024)
                    var downloaded = 0L
                    var lastPercent = -1
                    var n: Int
                    while (inp.read(buffer).also { n = it } != -1) {
                        out.write(buffer, 0, n)
                        downloaded += n
                        if (totalBytes > 0) {
                            val pct = (downloaded * 100 / totalBytes).toInt()
                            if (pct != lastPercent) {
                                lastPercent = pct
                                onProgress(downloaded.toDouble() / totalBytes.toDouble())
                            }
                        }
                    }
                }
            }
            saveToMediaStore(tempFile, mimeType, saveAlbumName)
        } finally {
            tempFile.delete()
            connection.disconnect()
        }
    }

    /** 网络/IO 类错误 → NETWORK_ERROR，其余 → SAVE_FAILED（对齐 DownloadErrorCode）。 */
    fun failureCode(e: Throwable): String =
        if (e is IOException) "NETWORK_ERROR" else "SAVE_FAILED"

    /**
     * 将临时文件写入系统媒体库（`Pictures/<albumName>/`）。
     * Android Q（API 29）及以上：ContentValues + IS_PENDING 写入模式（避免部分写入被扫描）。
     * Android 9 及以下：手动写入公共目录再登记 MediaStore（尊重 saveAlbumName）。
     */
    private fun saveToMediaStore(file: File, mimeType: String, saveAlbumName: String): String? {
        val resolver = context.contentResolver
        val displayName = "IMG_${System.currentTimeMillis()}.${file.extension}"
        val albumName = saveAlbumName.ifBlank {
            runCatching { context.packageManager.getApplicationLabel(context.applicationInfo).toString() }
                .getOrDefault("Pictures")
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                put(MediaStore.Images.Media.MIME_TYPE, mimeType)
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/$albumName")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return null
            runCatching {
                resolver.openOutputStream(uri)?.use { out ->
                    file.inputStream().use { it.copyTo(out) }
                }
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }.onFailure {
                resolver.delete(uri, null, null)
                return null
            }
            uri.toString()
        } else {
            // API ≤ 28：insertImage 无法指定目录，会忽略 saveAlbumName。
            // 手动写入 Pictures/<albumName>/ 再登记到 MediaStore，尊重调用方相册名。
            @Suppress("DEPRECATION")
            val picturesDir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                albumName,
            ).apply { if (!exists()) mkdirs() }
            val destFile = File(picturesDir, displayName)
            runCatching {
                file.inputStream().use { input -> destFile.outputStream().use { input.copyTo(it) } }
                @Suppress("DEPRECATION")
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DATA, destFile.absolutePath)
                    put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                    put(MediaStore.Images.Media.MIME_TYPE, mimeType)
                }
                resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)?.toString()
            }.getOrElse {
                destFile.delete()
                null
            }
        }
    }
}
