package com.newtrip.live_photo_gallery

import android.content.Context
import android.net.Uri
import android.os.Build
import androidx.exifinterface.media.ExifInterface
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream

/**
 * 动态照片（Motion Photo）辅助工具
 *
 * 兼容厂商：
 *   - Google Pixel（新格式）：Container:Directory / Item:Semantic="Video" / Item:Length
 *   - Google Pixel（旧格式）：GCamera:MicroVideo / GCamera:MicroVideoOffset
 *   - Samsung（XMP 格式）   ：GCamera:MotionPhoto / MicroVideoOffset
 *
 * 重要说明：
 *   - 不再依赖 MediaStore._DATA 文件路径（Android 10+ Scoped Storage 下可能不可访问）
 *   - 使用 ContentResolver.openFileDescriptor / openInputStream 通过 URI 访问内容
 *   - 对于无法通过 ContentResolver 访问的路径（如 MediaStoreHelper.fetchAll 中的启发式判断），
 *     单独保留 isLikelyMotionPhotoByName() 做文件名快速过滤，避免 I/O 开销
 */
object MotionPhotoHelper {

    // 正则表达式常量（object 级，避免每次 parseVideoLength 调用重新编译）
    private val REGEX_CONTAINER_ELEMENT = Regex(
        """Semantic[^>]*?>\s*Video\s*</[^>]+?>\s*.*?Length[^>]*?>\s*(\d+)\s*</""",
        RegexOption.DOT_MATCHES_ALL
    )
    private val REGEX_CONTAINER_ATTR   = Regex("""Semantic\s*=\s*"Video"[^/]*?Length\s*=\s*"(\d+)"""")
    private val REGEX_SEC_VIDEO_LENGTH = Regex("""sec:VideoLength\s*=\s*"(\d+)"""")
    private val REGEX_MICRO_VIDEO_LEN  = Regex("""MicroVideoLength\s*=\s*"(\d+)"""")
    private val REGEX_MICRO_VIDEO_OFF  = Regex("""MicroVideoOffset\s*=\s*"(\d+)"""")

    // ──────────────────────────────────────────────
    // 公开 API
    // ──────────────────────────────────────────────

    /**
     * 通过 URI 检测是否为动态照片（精确，读取 XMP 元数据）
     * 仅在需要精确判断时调用（如 fetchById）
     */
    fun isMotionPhoto(context: Context, uri: Uri): Boolean {
        return try {
            context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                val exif = ExifInterface(pfd.fileDescriptor)
                val xmp = exif.getAttribute(ExifInterface.TAG_XMP) ?: return false
                containsMotionPhotoMarker(xmp)
            } ?: false
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 文件名启发式快速判断（O(1)，不做 I/O）
     * 仅在 MediaStoreHelper.fetchAll 批量查询时使用，减少 XMP 读取开销
     * 返回 true 表示"可能是动态照片"，后续按需调用 isMotionPhoto(context, uri) 精确验证
     *
     * 覆盖厂商命名规则：
     * - Google Pixel 新格式：PXL_20240101_123456.MP.jpg
     * - Google Pixel 旧格式：MVIMG_20240101_123456.jpg
     * - Samsung Galaxy（所有型号）：文件名通常为标准时间戳，无特殊前缀
     *   → Samsung 设备统一返回 true，由 isMotionPhoto(context, uri) 精确过滤
     */
    fun isLikelyMotionPhotoByName(filePath: String): Boolean {
        val name = filePath.substringAfterLast("/").uppercase()
        if (name.contains("MP.") || name.startsWith("MVIMG")) return true
        // Samsung 设备：文件名不含特殊标记，但设备上大量照片可能是 Motion Photo
        // 统一交给 URI-based XMP 验证处理（fetchAll 已在 enableLivePhoto=true 时调用）
        if (isSamsungDevice) return true
        return false
    }

    /**
     * 当前设备是否为 Samsung（惰性缓存，进程生命周期内只读一次 Build.MANUFACTURER）
     * 注意：Boolean 属性名以 "is" 开头时，JVM getter 与同名函数冲突，
     * 故统一使用属性形式，调用方去掉括号。
     */
    val isSamsungDevice: Boolean by lazy {
        Build.MANUFACTURER.equals("samsung", ignoreCase = true)
    }

    /**
     * 从动态照片中提取视频轨道，写入 outputPath
     *
     * 实现方式：
     * 1. 解析 XMP 获取视频字节长度（支持新/旧格式）
     * 2. 通过 ParcelFileDescriptor 获取总文件大小
     * 3. 跳过前部图片数据，流式写出文件末尾视频字节
     *
     * 不再使用 RandomAccessFile(filePath)，完全基于 URI，兼容 Android 10+ Scoped Storage
     *
     * #6 - 提取失败或异常时清理已创建的不完整输出文件，防止后续误用
     */
    fun extractVideo(context: Context, uri: Uri, outputPath: String): Boolean {
        val outputFile = java.io.File(outputPath)
        return try {
            // 单次打开 FD：同时读取 XMP 和文件总大小，减少 syscall 开销
            var videoLength = 0L
            var totalSize   = 0L
            context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                val exif = ExifInterface(pfd.fileDescriptor)
                val xmp = exif.getAttribute(ExifInterface.TAG_XMP) ?: return false
                videoLength = parseVideoLength(xmp)
                totalSize   = pfd.statSize
            } ?: return false

            if (videoLength <= 0L) return false
            if (totalSize <= 0L || totalSize < videoLength) return false

            val startOffset = totalSize - videoLength
            val success = context.contentResolver.openInputStream(uri)?.use { input ->
                if (!skipFully(input, startOffset)) return@use false
                FileOutputStream(outputPath).use { out ->
                    copyFixedLength(input, out, videoLength)
                }
            } ?: false

            if (!success) {
                outputFile.delete()
                return false
            }
            outputFile.length() > 0
        } catch (e: Exception) {
            outputFile.delete()   // 异常时也清理不完整文件
            false
        }
    }

    // ──────────────────────────────────────────────
    // 内部工具
    // ──────────────────────────────────────────────

    /** 检查 XMP 字符串中是否包含动态照片标识
     * #24 - 改为 internal，允许单元测试直接访问 */
    internal fun containsMotionPhotoMarker(xmp: String): Boolean {
        // Google Pixel 新/旧格式
        if (xmp.contains("MotionPhoto=\"1\""))         return true
        if (xmp.contains("Camera:MotionPhoto=\"1\""))  return true
        if (xmp.contains("GCamera:MotionPhoto=\"1\"")) return true
        if (xmp.contains("MicroVideo=\"1\""))           return true
        if (xmp.contains("GCamera:MicroVideo=\"1\""))  return true
        // Samsung One UI 3+ 新格式（Galaxy S21/S22/S23/S24 系列）
        // 使用 MotionPhoto_Capture_FPS 字段标识视频帧率
        if (xmp.contains("MotionPhoto_Capture_FPS"))   return true
        // Samsung 部分机型使用 Camera:MotionPhoto 或 sec:MotionPhoto
        if (xmp.contains("sec:MotionPhoto"))            return true
        return false
    }

    /**
     * 从 XMP 字符串中解析视频字节长度
     * 按优先级依次尝试：
     *   1. Container 新格式（Pixel Android 12+/Samsung One UI 4+）
     *   2. 属性写法 Container 格式
     *   3. Samsung sec:VideoLength（One UI 3 中间格式）
     *   4. MicroVideoLength（Samsung 旧格式）
     *   5. MicroVideoOffset（Pixel MVIMG / Samsung 最旧格式）
     *
     * #24 - 改为 internal，允许单元测试直接访问；使用 object 级正则常量，避免重复编译
     */
    internal fun parseVideoLength(xmp: String): Long {
        // 1. 新格式元素写法：<Item:Semantic>Video</Item:Semantic>...<Item:Length>12345</Item:Length>
        REGEX_CONTAINER_ELEMENT.find(xmp)?.groupValues?.get(1)?.toLongOrNull()?.let { return it }

        // 2. 新格式属性写法：Item:Semantic="Video" Item:Length="12345"
        REGEX_CONTAINER_ATTR.find(xmp)?.groupValues?.get(1)?.toLongOrNull()?.let { return it }

        // 3. Samsung One UI 3 格式：sec:VideoLength
        REGEX_SEC_VIDEO_LENGTH.find(xmp)?.groupValues?.get(1)?.toLongOrNull()?.let { return it }

        // 4. Samsung 旧格式：MicroVideoLength 显式长度
        REGEX_MICRO_VIDEO_LEN.find(xmp)?.groupValues?.get(1)?.toLongOrNull()?.let { return it }

        // 5. Samsung / Pixel MVIMG 最旧格式：MicroVideoOffset = 从文件末尾偏移量 = 视频长度
        REGEX_MICRO_VIDEO_OFF.find(xmp)?.groupValues?.get(1)?.toLongOrNull()?.let { return it }

        return 0L
    }

    private fun skipFully(input: InputStream, bytesToSkip: Long): Boolean {
        var remaining = bytesToSkip
        while (remaining > 0) {
            val skipped = input.skip(remaining)
            if (skipped > 0) {
                remaining -= skipped
                continue
            }
            if (input.read() == -1) return false
            remaining--
        }
        return true
    }

    private fun copyFixedLength(input: InputStream, output: OutputStream, length: Long): Boolean {
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var remaining = length
        while (remaining > 0) {
            val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            if (read <= 0) return false
            output.write(buffer, 0, read)
            remaining -= read
        }
        output.flush()
        return true
    }
}
