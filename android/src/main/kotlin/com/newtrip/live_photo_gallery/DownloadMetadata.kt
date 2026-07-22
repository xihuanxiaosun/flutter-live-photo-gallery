package com.newtrip.live_photo_gallery

/**
 * 网络下载文件的扩展名 / MIME 解析（纯逻辑，可单元测试）。
 * 从 PreviewActivity.downloadCurrentAsset 抽出。
 */
internal object DownloadMetadata {

    /**
     * 从 URL 推断文件扩展名（小写）。
     * 先用 URI 解析 path 再取扩展名，避免 URL 含 `?param` 时截取出错（原 "#1 fix"）。
     * 仅接受 2~5 位纯字母扩展名，否则回退 `"jpg"`。
     */
    fun extensionFor(url: String): String =
        runCatching {
            java.net.URI(url).path
                .substringAfterLast('.').lowercase()
                .takeIf { it.length in 2..5 && it.all(Char::isLetter) }
        }.getOrNull() ?: "jpg"

    /** 扩展名 → MIME（未知回退 `image/jpeg`）。 */
    fun mimeFor(ext: String): String = when (ext) {
        "png"  -> "image/png"
        "gif"  -> "image/gif"
        "webp" -> "image/webp"
        else   -> "image/jpeg"
    }
}
