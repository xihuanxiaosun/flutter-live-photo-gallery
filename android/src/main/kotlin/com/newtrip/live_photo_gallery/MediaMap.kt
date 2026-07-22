package com.newtrip.live_photo_gallery

/**
 * `Map<String, Any?>` 的数值强转辅助（纯逻辑，可单元测试）。
 * 从 PreviewActivity 抽出——预览返回的 asset map 各字段类型不定（Number / String），
 * 统一在此做安全转换。
 */

/** 取 [key] 为 Double；缺失 / 无法解析 → 0.0。 */
internal fun Map<String, Any?>?.doubleValue(key: String): Double =
    when (val value = this?.get(key)) {
        is Number -> value.toDouble()
        is String -> value.toDoubleOrNull() ?: 0.0
        else -> 0.0
    }

/** 取 [key] 为 Double；缺失 / 无法解析 → null。 */
internal fun Map<String, Any?>?.doubleValueOrNull(key: String): Double? =
    when (val value = this?.get(key)) {
        null -> null
        is Number -> value.toDouble()
        is String -> value.toDoubleOrNull()
        else -> null
    }

/** 取 [key] 为 Int；缺失 / 无法解析 → 0。 */
internal fun Map<String, Any?>?.intValue(key: String): Int =
    when (val value = this?.get(key)) {
        is Number -> value.toInt()
        is String -> value.toIntOrNull() ?: 0
        else -> 0
    }
