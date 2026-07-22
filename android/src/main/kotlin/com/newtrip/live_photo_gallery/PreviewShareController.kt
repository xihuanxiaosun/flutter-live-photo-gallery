package com.newtrip.live_photo_gallery

import android.app.Activity
import android.content.Intent
import android.net.Uri

/**
 * 预览页「分享当前资源」的行为（依赖 [Activity] 弹系统分享面板）。
 * 本地资源用 content:// URI 走 EXTRA_STREAM；网络资源用 http(s) 链接走 EXTRA_TEXT
 * （链接不能放进 EXTRA_STREAM，接收方无法读取该 URI）。
 */
internal class PreviewShareController(private val activity: Activity) {

    fun share(asset: Map<String, Any?>) {
        val assetId = (asset["assetId"] as? String)?.takeIf { it.isNotBlank() }
        val url = (asset["url"] as? String)?.takeIf { it.isNotBlank() }
        val videoUrl = (asset["videoUrl"] as? String)?.takeIf { it.isNotBlank() }
        val mediaType = (asset["mediaType"] as? String) ?: "image"

        runCatching {
            val sendIntent = if (assetId != null) {
                Intent(Intent.ACTION_SEND).apply {
                    type = if (mediaType == "video") "video/*" else "image/*"
                    putExtra(Intent.EXTRA_STREAM, Uri.parse(assetId))
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            } else {
                val link = videoUrl ?: url ?: return
                Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, link)
                }
            }
            activity.startActivity(Intent.createChooser(sendIntent, "分享"))
        }
    }
}
