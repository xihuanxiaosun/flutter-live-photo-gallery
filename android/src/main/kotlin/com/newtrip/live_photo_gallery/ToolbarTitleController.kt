package com.newtrip.live_photo_gallery

import android.app.Activity
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.widget.Toolbar

/**
 * Toolbar 自定义标题：可点击切相册的标题文字 + 下拉箭头。从 MediaPickerActivity 抽出。
 * 点击回调经 [onTitleClick] 交回调用方（打开相册弹层）。
 */
internal class ToolbarTitleController(
    private val activity: Activity,
    private val toolbar: Toolbar,
    private val onTitleClick: () -> Unit,
) {
    private lateinit var container: LinearLayout
    private lateinit var textView: TextView
    private lateinit var arrowView: ImageView

    fun setup(initialTitle: String) {
        toolbar.title = ""
        ensureView()
        setTitle(initialTitle)
    }

    fun setTitle(title: String) {
        textView.text = title
    }

    /** 相册弹层展开/收起时旋转箭头。 */
    fun setExpanded(expanded: Boolean) {
        arrowView.animate().rotation(if (expanded) 180f else 0f).setDuration(160L).start()
    }

    private fun ensureView() {
        if (::container.isInitialized) return
        textView = TextView(activity).apply {
            setTextColor(resolveThemeColor(com.google.android.material.R.attr.colorOnSurface))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            setTypeface(typeface, Typeface.BOLD)
            includeFontPadding = false
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        arrowView = ImageView(activity).apply {
            setImageResource(R.drawable.ic_expand_more)
            imageTintList = ColorStateList.valueOf(
                resolveThemeColor(com.google.android.material.R.attr.colorOnSurfaceVariant)
            )
        }
        container = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            minimumHeight = dp(40)
            background = resolveSelectableItemBackgroundBorderless()
            isClickable = true
            isFocusable = true
            setPadding(dp(12), dp(8), dp(12), dp(8))
            addView(textView)
            addView(arrowView, LinearLayout.LayoutParams(dp(20), dp(20)).apply { marginStart = dp(2) })
            setOnClickListener { onTitleClick() }
        }
        toolbar.addView(
            container,
            Toolbar.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )
    }

    private fun dp(value: Int): Int =
        (value * activity.resources.displayMetrics.density).toInt()

    private fun resolveThemeColor(attr: Int): Int {
        val tv = TypedValue()
        activity.theme.resolveAttribute(attr, tv, true)
        return tv.data
    }

    private fun resolveSelectableItemBackgroundBorderless() =
        activity.obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackgroundBorderless))
            .let { attrs -> try { attrs.getDrawable(0) } finally { attrs.recycle() } }
}
