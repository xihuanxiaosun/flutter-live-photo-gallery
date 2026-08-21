package com.newtrip.live_photo_gallery

import android.content.Context
import android.graphics.Matrix
import android.graphics.RectF
import android.graphics.drawable.Drawable
import android.util.AttributeSet
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.animation.DecelerateInterpolator
import android.widget.OverScroller
import androidx.appcompat.widget.AppCompatImageView
import kotlin.math.roundToInt

/**
 * 轻量级的缩放图片控件。
 *
 * 目标：
 * - 缩放跟随手指焦点，而不是固定从中心缩放
 * - 已缩放状态下拖动不会被父容器轻易抢走
 * - 支持双击 1x / 2.5x 切换
 */
class ZoomableImageView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : AppCompatImageView(context, attrs, defStyleAttr) {

    private val baseMatrix = Matrix()
    private val suppMatrix = Matrix()
    private val drawMatrix = Matrix()
    private val matrixValues = FloatArray(9)
    private val displayRect = RectF()

    private var viewWidth = 0
    private var viewHeight = 0

    // 记录最近一次缩放焦点，供 onScaleEnd 过度放大回弹到 MAX_SCALE 时复用
    private var lastFocusX = 0f
    private var lastFocusY = 0f
    // 平移惯性（fling）：单指快速拖动松手后的减速滑动
    private var flingRunnable: FlingRunnable? = null

    val currentScale: Float
        get() = getMatrixScale()

    /**
     * 单击确认回调：预览模式下用于「单击图片关闭预览」。
     * onSingleTapConfirmed 会等过双击超时窗口才触发，故不会与双击放大冲突。
     * 默认 null（不处理单击）；由 PreviewViewHolder.bind 按图片/视频、预览/选择模式设置或复位。
     */
    var onSingleTap: (() -> Unit)? = null

    /**
     * 长按回调：预览模式下用于「长按图片弹出保存底部弹窗」。
     * GestureDetector 的 onLongPress 独立于 tap/doubleTap 触发，故不会与单击关闭、双击放大冲突。
     * 默认 null（不处理长按）；由 PreviewViewHolder.bind 按「网络静图 + 允许保存」设置或复位。
     */
    var onLongPress: (() -> Unit)? = null

    private val scaleDetector = ScaleGestureDetector(
        context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                parent?.requestDisallowInterceptTouchEvent(true)
                cancelFling()
                return true
            }

            override fun onScale(detector: ScaleGestureDetector): Boolean {
                // 用未 coerce 的原始缩放值参与运算，避免低于 MIN 的橡皮筋被 coerce 隐藏而不断复利下探
                val current = rawMatrixScale()
                // 橡皮筋：允许短暂越界（低于 MIN、高于 MAX）带阻尼，松手后在 onScaleEnd 回弹
                val target = (current * detector.scaleFactor)
                    .coerceIn(MIN_SCALE * 0.9f, MAX_SCALE * 1.15f)
                val delta = target / current
                lastFocusX = detector.focusX
                lastFocusY = detector.focusY
                suppMatrix.postScale(delta, delta, detector.focusX, detector.focusY)
                checkAndDisplayMatrix()
                return true
            }

            override fun onScaleEnd(detector: ScaleGestureDetector) {
                parent?.requestDisallowInterceptTouchEvent(currentScale > MIN_SCALE + 0.01f)
                val rawScale = rawMatrixScale()
                when {
                    // 过度放大：回弹到 MAX_SCALE（复用缩放动画 + 最近焦点）
                    rawScale > MAX_SCALE -> animateScaleTo(MAX_SCALE, lastFocusX, lastFocusY)
                    // 缩到 1x 附近（含橡皮筋下探）：复位到初始 fit 状态
                    rawScale < MIN_SCALE + 0.01f -> resetTransform()
                }
            }
        }
    )

    private val gestureDetector = GestureDetector(
        context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent): Boolean {
                // 新一次触摸开始，取消正在进行的惯性滑动
                cancelFling()
                return true
            }

            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                // 单击确认（已过双击超时窗口）：触发外部回调，不与双击放大冲突。
                // 仅在未放大（缩放归位）时触发——与下拉关闭一致，避免放大看细节时误触退出。
                if (currentScale <= MIN_SCALE + 0.01f) onSingleTap?.invoke()
                return true
            }

            override fun onDoubleTap(e: MotionEvent): Boolean {
                val target = if (currentScale > 1.2f) MIN_SCALE else DOUBLE_TAP_SCALE
                animateScaleTo(target, e.x, e.y)
                return true
            }

            override fun onLongPress(e: MotionEvent) {
                // 长按：触发外部回调（如弹出保存底部弹窗）。onLongPress 会抢占后续 tap/doubleTap，
                // 故与单击关闭、双击放大互斥，不会误触。
                onLongPress?.invoke()
            }

            override fun onScroll(
                e1: MotionEvent?,
                e2: MotionEvent,
                distanceX: Float,
                distanceY: Float
            ): Boolean {
                if (currentScale <= MIN_SCALE + 0.01f) return false
                cancelFling()
                suppMatrix.postTranslate(-distanceX, -distanceY)
                checkAndDisplayMatrix()
                return true
            }

            override fun onFling(
                e1: MotionEvent?,
                e2: MotionEvent,
                velocityX: Float,
                velocityY: Float
            ): Boolean {
                // 仅在已放大时启用平移惯性；未放大时交给下拉关闭/横向翻页
                if (currentScale <= MIN_SCALE + 0.01f) return false
                startFling(velocityX, velocityY)
                return true
            }
        }
    )

    init {
        scaleType = ScaleType.MATRIX
    }

    override fun setImageDrawable(drawable: Drawable?) {
        super.setImageDrawable(drawable)
        updateBaseMatrix()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        viewWidth = w
        viewHeight = h
        updateBaseMatrix()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.pointerCount > 1 || currentScale > MIN_SCALE + 0.01f) {
            parent?.requestDisallowInterceptTouchEvent(true)
        }
        val scaleHandled = scaleDetector.onTouchEvent(event)
        val gestureHandled = gestureDetector.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (currentScale <= MIN_SCALE + 0.01f) {
                    parent?.requestDisallowInterceptTouchEvent(false)
                }
            }
        }
        return scaleHandled || gestureHandled || super.onTouchEvent(event)
    }

    fun resetTransform() {
        cancelFling()
        suppMatrix.reset()
        applyMatrix()
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        // 防止 View 脱离窗口后 fling 回调继续 post 造成泄漏
        cancelFling()
    }

    fun getDisplayRectOnScreen(): RectF? {
        val rect = getDisplayRect() ?: return null
        val location = IntArray(2)
        getLocationOnScreen(location)
        return RectF(
            rect.left + location[0],
            rect.top + location[1],
            rect.right + location[0],
            rect.bottom + location[1],
        )
    }

    private fun updateBaseMatrix() {
        val drawable = drawable ?: return
        if (viewWidth <= 0 || viewHeight <= 0) return

        baseMatrix.reset()
        val drawableWidth = drawable.intrinsicWidth.toFloat().coerceAtLeast(1f)
        val drawableHeight = drawable.intrinsicHeight.toFloat().coerceAtLeast(1f)
        val scale = minOf(viewWidth / drawableWidth, viewHeight / drawableHeight)
        val dx = (viewWidth - drawableWidth * scale) / 2f
        val dy = (viewHeight - drawableHeight * scale) / 2f
        baseMatrix.postScale(scale, scale)
        baseMatrix.postTranslate(dx, dy)
        suppMatrix.reset()
        applyMatrix()
    }

    private fun getDrawMatrix(): Matrix {
        drawMatrix.set(baseMatrix)
        drawMatrix.postConcat(suppMatrix)
        return drawMatrix
    }

    private fun applyMatrix() {
        imageMatrix = getDrawMatrix()
    }

    private fun getDisplayRect(matrix: Matrix = getDrawMatrix()): RectF? {
        val drawable = drawable ?: return null
        displayRect.set(0f, 0f, drawable.intrinsicWidth.toFloat(), drawable.intrinsicHeight.toFloat())
        matrix.mapRect(displayRect)
        return displayRect
    }

    private fun checkAndDisplayMatrix() {
        val rect = getDisplayRect() ?: return
        var deltaX = 0f
        var deltaY = 0f

        if (rect.width() <= viewWidth) {
            deltaX = (viewWidth - rect.width()) / 2f - rect.left
        } else if (rect.left > 0) {
            deltaX = -rect.left
        } else if (rect.right < viewWidth) {
            deltaX = viewWidth - rect.right
        }

        if (rect.height() <= viewHeight) {
            deltaY = (viewHeight - rect.height()) / 2f - rect.top
        } else if (rect.top > 0) {
            deltaY = -rect.top
        } else if (rect.bottom < viewHeight) {
            deltaY = viewHeight - rect.bottom
        }

        suppMatrix.postTranslate(deltaX, deltaY)
        applyMatrix()
    }

    private fun animateScaleTo(targetScale: Float, focalX: Float, focalY: Float) {
        val startScale = currentScale
        val animator = android.animation.ValueAnimator.ofFloat(startScale, targetScale)
        animator.duration = ANIM_DURATION_MS
        animator.interpolator = DecelerateInterpolator()
        animator.addUpdateListener { valueAnimator ->
            val value = valueAnimator.animatedValue as Float
            val current = currentScale
            val delta = value / current
            suppMatrix.postScale(delta, delta, focalX, focalY)
            checkAndDisplayMatrix()
        }
        animator.start()
    }

    private fun getMatrixScale(): Float {
        suppMatrix.getValues(matrixValues)
        return matrixValues[Matrix.MSCALE_X].coerceAtLeast(MIN_SCALE)
    }

    /** 原始缩放值（不 coerce），供橡皮筋越界判定与松手回弹读取真实倍数 */
    private fun rawMatrixScale(): Float {
        suppMatrix.getValues(matrixValues)
        return matrixValues[Matrix.MSCALE_X]
    }

    private fun cancelFling() {
        flingRunnable?.cancel()
        flingRunnable = null
    }

    private fun startFling(velocityX: Float, velocityY: Float) {
        cancelFling()
        val runnable = FlingRunnable(context).also { it.fling(velocityX.toInt(), velocityY.toInt()) }
        flingRunnable = runnable
        postOnAnimation(runnable)
    }

    /**
     * 平移惯性：OverScroller 驱动的减速滑动。
     * 每帧按滚动增量 postTranslate，再走 checkAndDisplayMatrix() 收回边界，图片不会滑出可视范围。
     * 起点取 -rect.left/top、速度取负，确保滚动方向与边界与 checkAndDisplayMatrix 的约束一致。
     */
    private inner class FlingRunnable(context: Context) : Runnable {
        private val scroller = OverScroller(context)
        private var currentX = 0
        private var currentY = 0

        fun fling(velocityX: Int, velocityY: Int) {
            val rect = getDisplayRect() ?: return
            val startX = (-rect.left).roundToInt()
            val minX: Int
            val maxX: Int
            if (viewWidth < rect.width()) {
                minX = 0
                maxX = (rect.width() - viewWidth).roundToInt()
            } else {
                minX = startX
                maxX = startX
            }
            val startY = (-rect.top).roundToInt()
            val minY: Int
            val maxY: Int
            if (viewHeight < rect.height()) {
                minY = 0
                maxY = (rect.height() - viewHeight).roundToInt()
            } else {
                minY = startY
                maxY = startY
            }
            currentX = startX
            currentY = startY
            // 起止一致（无可滚动余量）时无需惯性
            if (startX != maxX || startY != maxY) {
                scroller.fling(startX, startY, -velocityX, -velocityY, minX, maxX, minY, maxY, 0, 0)
            }
        }

        fun cancel() {
            scroller.forceFinished(true)
            removeCallbacks(this)
        }

        override fun run() {
            if (scroller.isFinished) return
            if (scroller.computeScrollOffset()) {
                val newX = scroller.currX
                val newY = scroller.currY
                suppMatrix.postTranslate((currentX - newX).toFloat(), (currentY - newY).toFloat())
                checkAndDisplayMatrix()
                currentX = newX
                currentY = newY
                postOnAnimation(this)
            }
        }
    }

    companion object {
        private const val MIN_SCALE = 1f
        private const val MAX_SCALE = 5f
        private const val DOUBLE_TAP_SCALE = 2.5f
        private const val ANIM_DURATION_MS = 220L
    }
}
