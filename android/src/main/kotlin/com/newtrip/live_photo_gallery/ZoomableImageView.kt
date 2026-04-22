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
import androidx.appcompat.widget.AppCompatImageView

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

    val currentScale: Float
        get() = getMatrixScale()

    private val scaleDetector = ScaleGestureDetector(
        context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                parent?.requestDisallowInterceptTouchEvent(true)
                return true
            }

            override fun onScale(detector: ScaleGestureDetector): Boolean {
                val current = currentScale
                val target = (current * detector.scaleFactor).coerceIn(MIN_SCALE, MAX_SCALE)
                val delta = target / current
                suppMatrix.postScale(delta, delta, detector.focusX, detector.focusY)
                checkAndDisplayMatrix()
                return true
            }

            override fun onScaleEnd(detector: ScaleGestureDetector) {
                parent?.requestDisallowInterceptTouchEvent(currentScale > MIN_SCALE + 0.01f)
                if (currentScale <= MIN_SCALE + 0.01f) {
                    resetTransform()
                }
            }
        }
    )

    private val gestureDetector = GestureDetector(
        context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent): Boolean = true

            override fun onDoubleTap(e: MotionEvent): Boolean {
                val target = if (currentScale > 1.2f) MIN_SCALE else DOUBLE_TAP_SCALE
                animateScaleTo(target, e.x, e.y)
                return true
            }

            override fun onScroll(
                e1: MotionEvent?,
                e2: MotionEvent,
                distanceX: Float,
                distanceY: Float
            ): Boolean {
                if (currentScale <= MIN_SCALE + 0.01f) return false
                suppMatrix.postTranslate(-distanceX, -distanceY)
                checkAndDisplayMatrix()
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
        suppMatrix.reset()
        applyMatrix()
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

    companion object {
        private const val MIN_SCALE = 1f
        private const val MAX_SCALE = 5f
        private const val DOUBLE_TAP_SCALE = 2.5f
        private const val ANIM_DURATION_MS = 220L
    }
}
