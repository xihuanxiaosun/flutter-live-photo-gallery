package com.newtrip.live_photo_gallery

import android.content.Context
import android.util.AttributeSet
import android.widget.FrameLayout

/**
 * 使用宽度作为最终边长，保证宫格 item 在测量阶段就是正方形，
 * 避免依赖 onAttach 后二次修正高度导致首帧拉伸。
 */
class SquareFrameLayout @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : FrameLayout(context, attrs, defStyleAttr) {

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        super.onMeasure(widthMeasureSpec, widthMeasureSpec)
    }
}
