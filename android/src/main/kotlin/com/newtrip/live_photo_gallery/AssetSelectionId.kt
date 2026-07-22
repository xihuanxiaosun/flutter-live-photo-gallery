package com.newtrip.live_photo_gallery

import java.security.MessageDigest

/**
 * 资源「稳定选择 ID」的单一事实源（Android 侧）。
 *
 * 网络资源没有 PHAsset / MediaStore 的原生 id，为了让「选择状态」能在
 * Dart ↔ native 之间 round-trip，两端用同一套规范串做 SHA-256 生成稳定 id。
 *
 * ⚠️ 规范串必须与 iOS `PhotoAssetModel.id`（ios/Classes/Core/Models.swift）**逐字一致**，
 * 任一端改动都会导致跨端选择状态无法对齐。此处集中管理并由单元测试（含 golden 哈希）钉死，
 * 迁移到 Pigeon 后应作为共享 schema 的一部分。
 *
 * 规范串： `network|mediaType=<type>|url=<cover>|videoUrl=<video>`
 * 结果：   `network_<sha256hex>`
 */
internal object AssetSelectionId {

    /** 网络资源的稳定 id；[coverUrl] 为空返回 null。 */
    fun forNetwork(mediaType: String, coverUrl: String?, videoUrl: String?): String? {
        if (coverUrl.isNullOrBlank()) return null
        val canonical = "network|mediaType=$mediaType|url=$coverUrl|videoUrl=${videoUrl ?: ""}"
        return "network_${sha256Hex(canonical)}"
    }

    /**
     * 从 previewAssets 传入的 asset map 解析选择 id：
     * - `type == "network"` → [forNetwork]
     * - 否则（本地） → assetId，回退 url
     */
    fun of(asset: Map<String, Any?>?): String? {
        if (asset == null) return null
        if (asset["type"] as? String == "network") {
            return forNetwork(
                mediaType = asset["mediaType"] as? String ?: "image",
                coverUrl  = asset["url"] as? String,
                videoUrl  = asset["videoUrl"] as? String,
            )
        }
        return (asset["assetId"] as? String)?.takeIf { it.isNotBlank() }
            ?: (asset["url"] as? String)?.takeIf { it.isNotBlank() }
    }

    fun sha256Hex(input: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(input.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
}
