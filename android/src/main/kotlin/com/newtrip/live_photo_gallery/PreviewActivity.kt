package com.newtrip.live_photo_gallery

import android.animation.ValueAnimator
import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.RectF
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate
import androidx.appcompat.widget.AppCompatImageView
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.RecyclerView
import androidx.viewpager2.widget.ViewPager2
import com.bumptech.glide.Glide
import com.bumptech.glide.load.engine.DiskCacheStrategy
import com.bumptech.glide.load.resource.drawable.DrawableTransitionOptions
import com.google.android.material.button.MaterialButton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import com.yalantis.ucrop.UCrop
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * 资源预览 Activity
 *
 * 功能：
 * - ViewPager2 横向滑动浏览
 * - 图片：ZoomableImageView（双指缩放、双击放大、平移边界限制）
 * - 视频：缩略图 + 居中播放按钮，点击跳系统播放器
 * - 下拉关闭手势（仅 1x 缩放时生效，拖拽超阈值自动滑出关闭）
 * - showRadio=false：纯预览模式，隐藏底部栏和选择按钮
 * - WindowInsets 适配，防止系统栏遮挡顶/底栏
 */
class PreviewActivity : AppCompatActivity() {

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    private lateinit var previewContent: FrameLayout
    private lateinit var viewPager:   ViewPager2
    private lateinit var previewStage: View
    private lateinit var previewScrim: View
    private lateinit var tvCount:     TextView
    private lateinit var btnClose:    ImageView
    private lateinit var btnDownload: ImageView
    private lateinit var btnSelect:   MaterialButton
    private lateinit var btnOriginal: MaterialButton
    private lateinit var btnCrop:     MaterialButton
    private lateinit var btnDone:     MaterialButton
    private lateinit var bottomBar:   View
    private lateinit var topBar:      View
    private lateinit var pageIndicator: LinearLayout

    // ──────────────────────────────────────────────
    // 状态
    // ──────────────────────────────────────────────

    private var previewAssets: List<Map<String, Any?>> = emptyList()
    private var initialIndex  = 0
    private var showRadio     = true
    private var isDarkMode    = false
    private var maxCount      = 9
    private var maxVideoCount = -1            // -1 = no limit
    private var autoPlayVideo        = false  // 对齐 iOS：进入视频页时自动打开系统播放器
    private var showDownloadButton   = false  // 网络图片显示保存按钮
    private var engineKey     = ""            // 对应 LivePhotoGalleryPlugin 实例的唯一标识
    private var saveAlbumName = ""            // 保存图片的相册名，空串 = 用 App 名
    private var sourceFrame: RectF? = null

    // 网络图下载 + 存相册（IO 已抽到 MediaDownloader）
    private val mediaDownloader by lazy { MediaDownloader(this) }

    // 内联视频播放（ExoPlayer 生命周期已抽到 VideoPlaybackController）
    private val videoController by lazy { VideoPlaybackController(this) }
    private var btnShare: android.widget.ImageView? = null

    private val selectedIds = mutableListOf<String>()
    private val editedPathByAssetId = mutableMapOf<String, String>()
    private var isOriginalPhoto = false
    private var hasPlayedEnterAnimation = false
    private var enterAnimationRetryCount = 0
    private var transitionImageView: AppCompatImageView? = null
    /** 已自动播放过的 position 集合，防止页面滚回时重复触发 */
    private val autoPlayedPositions = mutableSetOf<Int>()

    private val cropLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val id = pendingCropAssetId
        pendingCropAssetId = null
        if (result.resultCode != Activity.RESULT_OK || id.isNullOrBlank()) return@registerForActivityResult
        val data = result.data ?: return@registerForActivityResult
        val outputUri = UCrop.getOutput(data) ?: return@registerForActivityResult
        val outputPath = outputUri.path ?: return@registerForActivityResult

        editedPathByAssetId[id] = outputPath
        val position = viewPager.currentItem
        val src = previewAssets.getOrNull(position) ?: return@registerForActivityResult
        val mutable = src.toMutableMap()
        mutable["editedPath"] = outputPath
        previewAssets = previewAssets.toMutableList().also { it[position] = mutable }
        viewPager.adapter?.notifyItemChanged(position)
        // 当前页强制刷新，避免 ViewPager 复用时用户误感知“没变化”
        val holder = (viewPager.getChildAt(0) as? RecyclerView)
            ?.findViewHolderForAdapterPosition(position) as? PreviewViewHolder
        holder?.zoomView?.let { imageView ->
            Glide.with(imageView.context)
                .load(File(outputPath))
                .diskCacheStrategy(DiskCacheStrategy.RESOURCE)
                .into(imageView)
            imageView.resetTransform()
        }
        Toast.makeText(this, "裁剪完成", Toast.LENGTH_SHORT).show()
    }
    private var pendingCropAssetId: String? = null

    // ── 下拉关闭手势状态 ──────────────────────────
    private var touchDownY           = 0f
    private var touchDownX           = 0f
    private var dismissDragActive    = false
    private var dismissCancelSent    = false  // 只向 ViewPager2 发一次 CANCEL
    private var velocityTracker: VelocityTracker? = null  // 计算竖直速度，支持快速轻甩关闭

    // 底部导航栏 inset（px），供纯预览模式定位页码指示器
    private var bottomInsetPx = 0

    private val dismissStartThresholdPx  by lazy { resources.displayMetrics.density * DISMISS_START_DP }
    private val dismissCommitThresholdPx by lazy { resources.displayMetrics.density * DISMISS_COMMIT_DP }
    private val dismissFadeDistancePx    by lazy { resources.displayMetrics.density * DISMISS_FADE_DP }

    // ──────────────────────────────────────────────
    // 生命周期
    // ──────────────────────────────────────────────

    override fun onCreate(savedInstanceState: Bundle?) {
        applyDarkMode()
        super.onCreate(savedInstanceState)
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        setContentView(R.layout.activity_preview)
        overridePendingTransition(0, 0)
        parseArgs()
        initViews()
        registerBackHandler()
    }

    override fun onPause() {
        super.onPause()
        videoController.pause()
    }

    override fun onDestroy() {
        super.onDestroy()
        // 清除进场动画重试的 postDelayed 回调，防止 Activity 销毁后短暂持有引用
        // View.handler 是 postDelayed 内部使用的 Handler，removeCallbacksAndMessages(null) 清除所有挂起任务
        if (::previewStage.isInitialized) {
            previewStage.handler?.removeCallbacksAndMessages(null)
        }
        videoController.release()
    }

    private fun setupShareButton() {
        if (btnShare != null) return  // 防止重复添加（Activity 配置变更重建时）
        val widthPx   = resources.getDimensionPixelSize(R.dimen.preview_share_button_width)
        val heightPx  = resources.getDimensionPixelSize(R.dimen.preview_share_button_height)
        val marginEndPx = resources.getDimensionPixelSize(R.dimen.preview_share_button_margin_end)
        val paddingPx = resources.getDimensionPixelSize(R.dimen.preview_share_button_padding)
        val shareBtn = android.widget.ImageView(this).apply {
            layoutParams = FrameLayout.LayoutParams(widthPx, heightPx).also {
                it.gravity = android.view.Gravity.END or android.view.Gravity.CENTER_VERTICAL
                it.marginEnd = marginEndPx
            }
            setImageDrawable(
                ContextCompat.getDrawable(this@PreviewActivity, R.drawable.ic_share)
            )
            imageTintList = android.content.res.ColorStateList.valueOf(Color.WHITE)
            contentDescription = "分享"
            setPadding(paddingPx, paddingPx, paddingPx, paddingPx)
            setOnClickListener { shareCurrentAsset() }
        }
        btnShare = shareBtn
        (topBar as? ViewGroup)?.addView(shareBtn)
    }

    // 分享行为已抽到 PreviewShareController
    private val shareController by lazy { PreviewShareController(this) }
    private fun shareCurrentAsset() {
        val asset = previewAssets.getOrNull(viewPager.currentItem) ?: return
        shareController.share(asset)
    }

    // ──────────────────────────────────────────────
    // 下拉关闭手势（dispatchTouchEvent 最早拦截）
    // ──────────────────────────────────────────────

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                touchDownY        = ev.rawY
                touchDownX        = ev.rawX
                dismissDragActive = false
                dismissCancelSent = false
                velocityTracker?.recycle()
                velocityTracker = VelocityTracker.obtain()
                velocityTracker?.addMovement(ev)
            }
            MotionEvent.ACTION_MOVE -> {
                velocityTracker?.addMovement(ev)
                if (!dismissDragActive) {
                    val dy = ev.rawY - touchDownY
                    val dx = ev.rawX - touchDownX
                    // 触发条件：向下滑动 & 主要垂直 & 当前 ZoomableImageView 未放大
                    if (dy > dismissStartThresholdPx
                        && dy > abs(dx) * DISMISS_VERTICAL_RATIO
                        && currentPageScale() <= 1.05f) {
                        dismissDragActive = true
                    }
                }
                if (dismissDragActive) {
                    // 首次接管：向 ViewPager2 发一次 ACTION_CANCEL，清除其悬挂触摸状态
                    if (!dismissCancelSent) {
                        dismissCancelSent = true
                        val cancelEvent = MotionEvent.obtain(ev).also { it.action = MotionEvent.ACTION_CANCEL }
                        super.dispatchTouchEvent(cancelEvent)
                        cancelEvent.recycle()
                    }
                    val dy = (ev.rawY - touchDownY).coerceAtLeast(0f)
                    val dx = ev.rawX - touchDownX
                    applyDismissProgress(dy = dy, dx = dx)
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                // 计算竖直方向速度（px/s），支持“位移小但下滑快”的轻甩关闭；随后无论是否拖拽都回收 tracker
                val yVelocity = velocityTracker?.let { vt ->
                    vt.addMovement(ev)
                    vt.computeCurrentVelocity(1000)
                    vt.yVelocity
                } ?: 0f
                velocityTracker?.recycle()
                velocityTracker = null
                if (dismissDragActive) {
                    val dy = ev.rawY - touchDownY
                    if (dy > dismissCommitThresholdPx ||
                        (yVelocity > FLING_DISMISS_VELOCITY && dy > dismissStartThresholdPx)) {
                        finishWithSlideDown()
                        return true  // 消费事件，不再传递
                    } else {
                        snapBackFromDismiss()
                    }
                    dismissDragActive = false
                }
            }
        }
        // 拖拽中消费所有触摸（防止 ViewPager2 横向滑动干扰）
        return if (dismissDragActive) true else super.dispatchTouchEvent(ev)
    }

    /** 获取当前页 ZoomableImageView 的缩放倍数 */
    private fun currentPageScale(): Float {
        val holder = (viewPager.getChildAt(0) as? RecyclerView)
            ?.findViewHolderForAdapterPosition(viewPager.currentItem)
        return (holder as? PreviewViewHolder)?.zoomView?.currentScale ?: 1f
    }

    /** 向下滑出屏幕并 finish */
    private fun finishWithSlideDown() {
        animateDismissToSource {
            returnSelectedResults(skipTransition = true)
        }
    }

    /** 手指松开但未达阈值时弹回 */
    private fun snapBackFromDismiss() {
        previewStage.animate()
            .translationX(0f)
            .translationY(0f)
            .scaleX(1f)
            .scaleY(1f)
            .alpha(1f)
            .setDuration(SNAP_BACK_DURATION_MS)
            .start()
        previewScrim.animate().alpha(1f).setDuration(SNAP_BACK_DURATION_MS).start()
        topBar.animate().alpha(1f).setDuration(SNAP_BACK_DURATION_MS).start()
        pageIndicator.animate().alpha(1f).setDuration(SNAP_BACK_DURATION_MS).start()
        if (showRadio) {
            bottomBar.animate().alpha(1f).setDuration(SNAP_BACK_DURATION_MS).start()
        }
    }

    // ──────────────────────────────────────────────
    // 初始化
    // ──────────────────────────────────────────────

    private fun applyDarkMode() {
        isDarkMode = intent?.getBooleanExtra(EXTRA_DARK_MODE, false) ?: false
        delegate.localNightMode =
            if (isDarkMode) AppCompatDelegate.MODE_NIGHT_YES else AppCompatDelegate.MODE_NIGHT_NO
    }

    private fun parseArgs() {
        val assetsJson = intent.getStringExtra(EXTRA_ASSETS) ?: "[]"
        val arr = JSONArray(assetsJson)
        previewAssets = (0 until arr.length()).map { i ->
            val obj = arr.getJSONObject(i)
            buildMap { obj.keys().forEach { key -> put(key, obj.opt(key)) } }
        }
        previewAssets.forEach { asset ->
            val id = selectionIdOf(asset) ?: return@forEach
            val edited = asset["editedPath"] as? String
            if (!edited.isNullOrBlank()) editedPathByAssetId[id] = edited
        }

        initialIndex = intent.getIntExtra(EXTRA_INITIAL_INDEX, 0)
            .coerceIn(0, (previewAssets.size - 1).coerceAtLeast(0))
        showRadio      = intent.getBooleanExtra(EXTRA_SHOW_RADIO, true)
        maxCount       = intent.getIntExtra(EXTRA_MAX_COUNT, 9)
        maxVideoCount  = intent.getIntExtra(EXTRA_MAX_VIDEO_COUNT, -1)
        autoPlayVideo      = intent.getBooleanExtra(EXTRA_AUTO_PLAY_VIDEO,      false)
        showDownloadButton = intent.getBooleanExtra(EXTRA_SHOW_DOWNLOAD_BUTTON, false)
        engineKey          = intent.getStringExtra(EXTRA_ENGINE_KEY)           ?: ""
        saveAlbumName      = intent.getStringExtra(EXTRA_SAVE_ALBUM_NAME)      ?: ""
        sourceFrame = buildSourceFrameFromIntent()

        val selectedJson = intent.getStringExtra(EXTRA_SELECTED_IDS) ?: "[]"
        val selArr = JSONArray(selectedJson)
        val initialSelected = linkedSetOf<String>()
        for (i in 0 until selArr.length()) {
            selArr.optString(i).takeIf { it.isNotBlank() }?.let(initialSelected::add)
        }
        selectedIds.addAll(initialSelected)
    }

    private fun initViews() {
        previewContent = findViewById(R.id.preview_content)
        previewStage   = findViewById(R.id.preview_stage)
        previewScrim   = findViewById(R.id.preview_scrim)
        viewPager      = findViewById(R.id.view_pager)
        tvCount        = findViewById(R.id.tv_count)
        btnClose       = findViewById(R.id.btn_close)
        btnDownload    = findViewById(R.id.btn_download)
        btnSelect      = findViewById(R.id.btn_select)
        btnOriginal    = findViewById(R.id.btn_original)
        btnCrop        = findViewById(R.id.btn_crop)
        btnDone        = findViewById(R.id.btn_done)
        bottomBar      = findViewById(R.id.bottom_bar)
        topBar         = findViewById(R.id.top_bar)
        pageIndicator  = findViewById(R.id.page_indicator)

        applyWindowInsets()

        // 纯预览模式：隐藏底部栏和选择按钮
        bottomBar.visibility = if (showRadio) View.VISIBLE else View.GONE
        btnSelect.visibility = if (showRadio) View.VISIBLE else View.GONE

        viewPager.adapter = PreviewPagerAdapter()
        viewPager.setCurrentItem(initialIndex, false)
        buildPageIndicator()
        // 底栏高度随 inset/旋转变化时，重新定位指示器使其恰好浮在底栏之上
        bottomBar.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> positionPageIndicator() }
        updateCountLabel(initialIndex)
        updateSelectButton(initialIndex)

        viewPager.registerOnPageChangeCallback(object : ViewPager2.OnPageChangeCallback() {
            override fun onPageSelected(position: Int) {
                // 翻页离开正在播放的视频：先停止上一页播放（恢复其封面帧、停音频），
                // 下方 autoPlay 分支再按需为新页启动播放。
                videoController.stopCurrent()
                updateCountLabel(position)
                updateSelectButton(position)
                updateDownloadButton(position)
                updateCropButton(position)
                // 对齐 iOS autoPlayVideo：首次进入视频页时自动打开系统播放器
                if (autoPlayVideo && !autoPlayedPositions.contains(position)) {
                    val asset = previewAssets.getOrNull(position)
                    if ((asset?.get("mediaType") as? String) == "video") {
                        autoPlayedPositions.add(position)
                        viewPager.post { triggerAutoPlay(position) }
                    }
                }
            }
        })

        // 初始页自动播放：setCurrentItem(initialIndex, false) 早于 registerOnPageChangeCallback，
        // onPageSelected 不会为初始页触发，故初始视频页需在此显式补一次自动播放。
        if (autoPlayVideo) {
            val a = previewAssets.getOrNull(initialIndex)
            if ((a?.get("mediaType") as? String) == "video") {
                autoPlayedPositions.add(initialIndex)
                viewPager.post { triggerAutoPlay(initialIndex) }
            }
        }

        btnClose.setOnClickListener {
            returnSelectedResults()
        }

        // 下载按钮：仅在 showDownloadButton=true 且当前资产有 url 时可见
        updateDownloadButton(initialIndex)
        updateCropButton(initialIndex)
        btnDownload.setOnClickListener { downloadCurrentAsset() }

        btnSelect.setOnClickListener {
            val asset   = previewAssets.getOrNull(viewPager.currentItem) ?: return@setOnClickListener
            val assetId = selectionIdOf(asset) ?: return@setOnClickListener
            if (selectedIds.contains(assetId)) {
                selectedIds.remove(assetId)
            } else {
                val mediaType = (asset["mediaType"] as? String) ?: "image"
                val isVideoOrLive = mediaType == "video" || mediaType == "livePhoto"
                val currentVideoCount = selectedIds.count { id ->
                    val a = previewAssets.firstOrNull { selectionIdOf(it) == id }
                    val mt = (a?.get("mediaType") as? String) ?: "image"
                    mt == "video" || mt == "livePhoto"
                }
                when (SelectionLimits.canAdd(
                    currentCount = selectedIds.size,
                    maxCount = maxCount,
                    currentVideoCount = currentVideoCount,
                    maxVideoCount = maxVideoCount,
                    isVideoOrLive = isVideoOrLive,
                )) {
                    SelectionLimits.Result.MAX_COUNT -> {
                        LivePhotoGalleryPlugin.getFlutterApi(engineKey)
                            ?.onMaxCountReached(maxCount.toLong()) {}
                        Toast.makeText(this, "最多只能选择 $maxCount 张", Toast.LENGTH_SHORT).show()
                        return@setOnClickListener
                    }
                    SelectionLimits.Result.MAX_VIDEO -> {
                        Toast.makeText(this, "最多只能选择 $maxVideoCount 个视频/动态照片", Toast.LENGTH_SHORT).show()
                        return@setOnClickListener
                    }
                    SelectionLimits.Result.OK -> Unit
                }
                selectedIds.add(assetId)
            }
            updateSelectButton(viewPager.currentItem)
            updateDoneButton()
        }

        btnOriginal.setOnClickListener {
            isOriginalPhoto = !isOriginalPhoto
            updateOriginalButton()
        }
        btnCrop.setOnClickListener { cropCurrentAsset() }

        btnDone.setOnClickListener { returnSelectedResults() }

        updateDoneButton()
        updateOriginalButton()
        prepareEnterAnimationState()
        scheduleEnterAnimation()
        setupShareButton()
    }

    private fun prepareEnterAnimationState() {
        if (sourceFrame == null) return
        previewStage.alpha = 0f
        previewScrim.alpha = 0f
        topBar.alpha = 0f
        pageIndicator.alpha = 0f
        if (showRadio) {
            bottomBar.alpha = 0f
        }
    }

    private fun scheduleEnterAnimation() {
        if (sourceFrame == null) {
            previewStage.alpha = 1f
            previewScrim.alpha = 1f
            topBar.alpha = 1f
            pageIndicator.alpha = 1f
            if (showRadio) {
                bottomBar.alpha = 1f
            }
            return
        }
        previewStage.viewTreeObserver.addOnPreDrawListener(object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                previewStage.viewTreeObserver.removeOnPreDrawListener(this)
                playEnterAnimationIfNeeded()
                return true
            }
        })
    }

    /** WindowInsets 适配：防止顶栏/底栏被状态栏/导航栏遮挡 */
    private fun applyWindowInsets() {
        ViewCompat.setOnApplyWindowInsetsListener(topBar) { v, insets ->
            val statusBars = insets.getInsets(WindowInsetsCompat.Type.statusBars())
            v.setPadding(v.paddingLeft, statusBars.top, v.paddingRight, v.paddingBottom)
            insets
        }
        ViewCompat.setOnApplyWindowInsetsListener(bottomBar) { v, insets ->
            val navBars = insets.getInsets(WindowInsetsCompat.Type.navigationBars())
            v.setPadding(v.paddingLeft, v.paddingTop, v.paddingRight, navBars.bottom)
            bottomInsetPx = navBars.bottom
            positionPageIndicator()
            insets
        }
    }

    /**
     * 页码指示器的底部间距：
     *   - 选择模式(showRadio=true)：浮在底部操作栏之上（bottomBar.height 已含导航栏 inset padding）
     *   - 纯预览模式：仅在底部安全区(bottomInsetPx)之上
     */
    private fun positionPageIndicator() {
        if (!::pageIndicator.isInitialized) return
        val lp = (pageIndicator.layoutParams as? FrameLayout.LayoutParams) ?: return
        val extra = resources.getDimensionPixelSize(R.dimen.preview_page_indicator_margin_bottom)
        val newBottom = if (showRadio) bottomBar.height + extra else bottomInsetPx + extra
        if (lp.bottomMargin != newBottom) {
            lp.bottomMargin = newBottom
            pageIndicator.layoutParams = lp
        }
    }

    /**
     * 构建页码指示器：≤8 张用圆点，>8 张用 "n / total" 药丸；≤1 张隐藏。
     * 在 adapter/数量已知后调用一次；随后由 updatePageIndicator(position) 驱动高亮/文本。
     */
    private fun buildPageIndicator() {
        pageIndicator.removeAllViews()
        val total = previewAssets.size
        // 底部圆点仅服务「少量图文混排」(2..8，信息流常见场景)：更多时改由顶部 tv_count
        // 计数承担，避免顶/底两处重复计数（与 iOS 一致）。
        if (total <= 1 || total > PAGE_INDICATOR_DOT_MAX) {
            pageIndicator.visibility = View.GONE
            return
        }
        pageIndicator.visibility = View.VISIBLE
        pageIndicator.background = null
        pageIndicator.setPadding(0, 0, 0, 0)
        val size = resources.getDimensionPixelSize(R.dimen.preview_page_indicator_dot_size)
        val gap  = resources.getDimensionPixelSize(R.dimen.preview_page_indicator_dot_gap)
        for (i in 0 until total) {
            val dot = View(this).apply {
                layoutParams = LinearLayout.LayoutParams(size, size).also {
                    if (i > 0) it.marginStart = gap
                }
            }
            pageIndicator.addView(dot)
        }
        updatePageIndicator(viewPager.currentItem)
    }

    /** 高亮当前圆点，由 updateCountLabel 同步驱动；视频页隐藏以让开内联播放控件 */
    private fun updatePageIndicator(position: Int) {
        if (!::pageIndicator.isInitialized) return
        if (pageIndicator.childCount == 0) return
        // 视频页底部由内联 ExoPlayer 控件占据，隐藏圆点避免重叠（视频自带进度条提供
        // 位置语境）；翻回图片页再恢复。
        val mediaType = (previewAssets.getOrNull(position)?.get("mediaType") as? String) ?: "image"
        if (mediaType == "video") {
            pageIndicator.visibility = View.GONE
            return
        }
        pageIndicator.visibility = View.VISIBLE
        for (i in 0 until pageIndicator.childCount) {
            pageIndicator.getChildAt(i).background = makeDotDrawable(active = i == position)
        }
    }

    private fun makeDotDrawable(active: Boolean): android.graphics.drawable.GradientDrawable =
        android.graphics.drawable.GradientDrawable().apply {
            shape = android.graphics.drawable.GradientDrawable.OVAL
            setColor(
                ContextCompat.getColor(
                    this@PreviewActivity,
                    if (active) R.color.preview_dot_active else R.color.preview_dot_inactive,
                )
            )
        }

    // ──────────────────────────────────────────────
    // UI 状态
    // ──────────────────────────────────────────────

    private fun updateCountLabel(position: Int) {
        tvCount.text = "${position + 1}/${previewAssets.size}"
        updatePageIndicator(position)
    }

    private fun updateSelectButton(position: Int) {
        val assetId = selectionIdOf(previewAssets.getOrNull(position))
        if (assetId == null) {
            btnSelect.text = "选择"
            btnSelect.isChecked = false
            btnSelect.isEnabled = false
            return
        }
        btnSelect.isEnabled = true
        val isSelected = selectedIds.contains(assetId)
        btnSelect.text      = if (isSelected) "已选" else "选择"
        btnSelect.isChecked = isSelected
    }

    private fun updateDoneButton() {
        val count         = selectedIds.size
        btnDone.text      = if (count > 0) "完成($count)" else "完成"
        btnDone.isEnabled = count > 0
    }

    private fun updateOriginalButton() {
        btnOriginal.isChecked = isOriginalPhoto
        if (isOriginalPhoto) {
            btnOriginal.text = "原图 已开"
            btnOriginal.backgroundTintList = ColorStateList.valueOf(0x3334C759.toInt())
            btnOriginal.strokeWidth = dp(1)
            btnOriginal.strokeColor = ColorStateList.valueOf(0xFF34C759.toInt())
            btnOriginal.setTextColor(0xFFFFFFFF.toInt())
            btnOriginal.iconTint = ColorStateList.valueOf(0xFF34C759.toInt())
        } else {
            btnOriginal.text = "原图"
            btnOriginal.backgroundTintList = ColorStateList.valueOf(0x00000000.toInt())
            btnOriginal.strokeWidth = 0
            btnOriginal.strokeColor = null
            btnOriginal.setTextColor(0xFFFFFFFF.toInt())
            btnOriginal.iconTint = ColorStateList.valueOf(0xFFFFFFFF.toInt())
        }
    }

    /**
     * 根据当前页资产类型决定下载按钮可见性：
     *   - showDownloadButton=false → 始终隐藏
     *   - 当前资产有 url（网络图片）→ 显示
     *   - 当前资产无 url（本地 assetId）→ 隐藏（已在相册，无需保存）
     */
    private fun updateDownloadButton(position: Int) {
        if (!showDownloadButton) {
            btnDownload.visibility = View.GONE
            return
        }
        val asset = previewAssets.getOrNull(position)
        val type = asset?.get("type") as? String
        val mediaType = asset?.get("mediaType") as? String
        val urlStr = asset?.get("url") as? String
        val isNetworkImage = type == "network" && mediaType == "image"
        val hasUrl = !urlStr.isNullOrBlank()
        btnDownload.visibility = if (isNetworkImage && hasUrl) View.VISIBLE else View.GONE
    }

    /**
     * 裁剪按钮仅在“选择模式(showRadio=true)”且当前资源为本地图片时显示。
     */
    private fun updateCropButton(position: Int) {
        if (!showRadio) {
            btnCrop.visibility = View.GONE
            return
        }
        val asset = previewAssets.getOrNull(position)
        val mediaType = asset?.get("mediaType") as? String
        val type = asset?.get("type") as? String
        val isCroppable = mediaType == "image" && type != "network"
        btnCrop.visibility = if (isCroppable) View.VISIBLE else View.GONE
    }

    private fun cropCurrentAsset() {
        val position = viewPager.currentItem
        val asset = previewAssets.getOrNull(position) ?: return
        val assetId = selectionIdOf(asset) ?: return
        val mediaType = asset["mediaType"] as? String ?: "image"
        if (mediaType != "image") return
        if ((asset["type"] as? String) == "network") {
            Toast.makeText(this, "暂不支持裁剪网络图片", Toast.LENGTH_SHORT).show()
            return
        }

        val sourcePath = editedPathByAssetId[assetId]
        val sourceUri = when {
            !sourcePath.isNullOrBlank() -> Uri.fromFile(File(sourcePath))
            else -> (asset["assetId"] as? String)?.takeIf { it.isNotBlank() }?.let(Uri::parse)
        } ?: run {
            Toast.makeText(this, "当前资源无法裁剪", Toast.LENGTH_SHORT).show()
            return
        }

        val destUri = Uri.fromFile(
            File(cacheDir, "lpg_crop_${System.currentTimeMillis()}_${position}.jpg")
        )
        pendingCropAssetId = assetId
        val intent = UCrop.of(sourceUri, destUri)
            .withOptions(UCrop.Options().apply {
                setCompressionFormat(Bitmap.CompressFormat.JPEG)
                setCompressionQuality(92)
                setHideBottomControls(false)
                setFreeStyleCropEnabled(true)
            })
            .getIntent(this)
        cropLauncher.launch(intent)
    }

    /**
     * 下载当前网络图片并保存到系统相册。
     * 完成后通过 LivePhotoGalleryPlugin.getFlutterApi(engineKey) 回调 Flutter 侧。
     * 同时在 native 层显示 Toast 作为即时反馈（Flutter 在 Activity 覆盖期间无法渲染 UI）。
     */
    private fun downloadCurrentAsset() {
        val position = viewPager.currentItem
        val asset    = previewAssets.getOrNull(position) ?: return
        val url      = (asset["url"] as? String)?.takeIf { it.isNotBlank() } ?: return

        btnDownload.isEnabled = false
        val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

        lifecycleScope.launch {
            // 下载 + 存相册的 IO 已抽到 MediaDownloader；此处只做 UI 编排（按钮/Toast/channel）
            val result = runCatching {
                mediaDownloader.download(url, saveAlbumName) { fraction ->
                    // onProgress 在 IO 线程回调，切回主线程再走 channel
                    mainHandler.post {
                        LivePhotoGalleryPlugin.getFlutterApi(engineKey)
                            ?.onDownloadProgress(url, fraction) {}
                    }
                }
            }

            btnDownload.isEnabled = true

            result.fold(
                onSuccess = { uri ->
                    if (uri != null) {
                        LivePhotoGalleryPlugin.getFlutterApi(engineKey)?.onDownloadResult(
                            PgDownloadResultEvent(url = url, success = true, assetId = uri)
                        ) {}
                        Toast.makeText(this@PreviewActivity, "已保存到相册", Toast.LENGTH_SHORT).show()
                    } else {
                        invokeDownloadFailure(url, "SAVE_FAILED", "保存到相册失败")
                    }
                },
                onFailure = { e ->
                    invokeDownloadFailure(url, mediaDownloader.failureCode(e), e.message ?: "下载失败")
                }
            )
        }
    }

    private fun invokeDownloadFailure(url: String, errorCode: String, message: String) {
        LivePhotoGalleryPlugin.getFlutterApi(engineKey)?.onDownloadResult(
            PgDownloadResultEvent(
                url          = url,
                success      = false,
                errorCode    = pgDownloadErrorCodeOf(errorCode),
                errorMessage = message,
            )
        ) {}
        Toast.makeText(this@PreviewActivity, "保存失败", Toast.LENGTH_SHORT).show()
    }

    private fun applyDismissProgress(dy: Float, dx: Float) {
        val t = DismissGestureMath.transformFor(dy, dx, dismissFadeDistancePx)
        previewStage.translationY = t.translationY
        previewStage.translationX = t.translationX
        previewStage.scaleX = t.scale
        previewStage.scaleY = t.scale
        previewStage.alpha = t.stageAlpha
        previewScrim.alpha = t.scrimAlpha
        topBar.alpha = t.barAlpha
        pageIndicator.alpha = t.barAlpha
        if (showRadio) {
            bottomBar.alpha = t.barAlpha
        }
    }

    // ──────────────────────────────────────────────
    // 返回结果
    // ──────────────────────────────────────────────

    private fun returnSelectedResults(skipTransition: Boolean = false) {
        lifecycleScope.launch {
            if (isFinishing || isDestroyed) return@launch
            val items = withContext(Dispatchers.IO) {
                selectedIds.map { assetId ->
                    async {
                        val asset = runCatching {
                            MediaStoreHelper.fetchById(this@PreviewActivity, assetId)
                        }.getOrNull()

                        if (asset != null) {
                            val editedPath = editedPathByAssetId[assetId]
                            val thumbPath = runCatching {
                                if (!editedPath.isNullOrBlank()) {
                                    ExportHelper.saveFileThumbnail(
                                        context = this@PreviewActivity,
                                        filePath = editedPath,
                                        key = "crop_${assetId.hashCode()}",
                                        width = 200,
                                        height = 200
                                    )
                                } else {
                                    ExportHelper.saveThumbnail(this@PreviewActivity, asset, 200, 200)
                                }
                            }.getOrDefault("")
                            val size = if (!editedPath.isNullOrBlank()) imageSizeFromFile(editedPath) else null
                            ResultItemMapper.localItem(
                                originAssetId = assetId,
                                editedPath = editedPath,
                                mediaType = asset.mediaType,
                                isMotionPhoto = asset.isMotionPhoto,
                                durationMs = asset.duration,
                                thumbPath = thumbPath,
                                width = size?.first ?: asset.width,
                                height = size?.second ?: asset.height,
                                includeOriginId = true,
                            )
                        } else {
                            // 网络图片或无法通过 MediaStore 查到时回退到传入数据
                            // mediaType 直接透传（iOS 侧已正确传入 "livePhoto"）
                            val src = previewAssets.firstOrNull { selectionIdOf(it) == assetId }
                            val mediaTypeOut = src?.get("mediaType") as? String ?: "image"
                            val durationOut: Double? = if (mediaTypeOut == "video") {
                                src.doubleValueOrNull("duration")
                            } else {
                                null
                            }
                            val urlStr = src?.get("url") as? String
                            val thumbPath = if (src?.get("type") == "network" && !urlStr.isNullOrBlank()) {
                                runCatching {
                                    ExportHelper.saveNetworkThumbnail(
                                        context = this@PreviewActivity,
                                        networkId = assetId,
                                        url = Uri.parse(urlStr),
                                        width = 200,
                                        height = 200
                                    )
                                }.getOrDefault("")
                            } else {
                                urlStr ?: ""
                            }
                            // 网络资源的 assetId 由 selectionIdOf 生成，且用于落盘缓存命名
                            ResultItemMapper.networkItem(
                                originAssetId = assetId,
                                editedPath = editedPathByAssetId[assetId],
                                mediaType = mediaTypeOut,
                                durationSec = durationOut,
                                thumbPath = thumbPath,
                                width = src.intValue("width"),
                                height = src.intValue("height"),
                            )
                        }
                    }
                }.awaitAll()
            }

            val resultJson = ResultItemMapper.toJson(items, includeOriginId = true)

            if (isFinishing || isDestroyed) return@launch
            setResult(Activity.RESULT_OK, Intent().apply {
                putExtra(MediaPickerActivity.RESULT_ITEMS,       resultJson)
                putExtra(MediaPickerActivity.RESULT_IS_ORIGINAL, isOriginalPhoto)
            })
            if (skipTransition) {
                finish()
                overridePendingTransition(0, 0)
            } else {
                animateDismissToSource {
                    finish()
                    overridePendingTransition(0, 0)
                }
            }
        }
    }

    private fun registerBackHandler() {
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                returnSelectedResults()
            }
        })
    }

    /** 自动播放：通过系统 Intent 打开视频，对齐 iOS autoPlayVideo 行为 */
    private fun triggerAutoPlay(position: Int) {
        val holder = (viewPager.getChildAt(0) as? RecyclerView)
            ?.findViewHolderForAdapterPosition(position) as? PreviewViewHolder
            ?: return
        holder.invokePlay()
    }

    // 稳定选择 id 的计算已抽到 AssetSelectionId（跨端单一事实源 + 单元测试守护）
    private fun selectionIdOf(asset: Map<String, Any?>?): String? = AssetSelectionId.of(asset)

    private fun buildSourceFrameFromIntent(): RectF? {
        val width = intent.getFloatExtra(EXTRA_SOURCE_WIDTH, 0f)
        val height = intent.getFloatExtra(EXTRA_SOURCE_HEIGHT, 0f)
        if (width <= 0f || height <= 0f) return null
        val left = intent.getFloatExtra(EXTRA_SOURCE_LEFT, 0f)
        val top = intent.getFloatExtra(EXTRA_SOURCE_TOP, 0f)
        return RectF(left, top, left + width, top + height)
    }

    private fun playEnterAnimationIfNeeded() {
        if (hasPlayedEnterAnimation) return
        val frame = sourceFrame ?: return
        if (previewStage.width == 0 || previewStage.height == 0) return
        val mediaRect = resolveCurrentMediaRectOnScreen()
        if (mediaRect == null && enterAnimationRetryCount < MAX_ENTER_RETRIES) {
            enterAnimationRetryCount += 1
            previewStage.postDelayed({ playEnterAnimationIfNeeded() }, ENTER_RETRY_DELAY_MS)
            return
        }
        hasPlayedEnterAnimation = true

        val drawable = currentPreviewDrawable()
        if (mediaRect != null && drawable != null) {
            runEnterOverlayAnimation(frame, mediaRect, drawable)
            return
        }

        val target = buildTransformTo(frame, mediaRect)
        previewStage.apply {
            pivotX = target.pivotX
            pivotY = target.pivotY
            translationX = target.translationX
            translationY = target.translationY
            scaleX = target.scaleX
            scaleY = target.scaleY
            alpha = 0.92f
        }
        if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            Log.d(
                TAG,
                "enterAnimation frame=$frame mediaRect=$mediaRect target=$target stage=${previewStage.width}x${previewStage.height}",
            )
        }
        previewScrim.alpha = 0f

        previewStage.animate()
            .translationX(0f)
            .translationY(0f)
            .scaleX(1f)
            .scaleY(1f)
            .alpha(1f)
            .setDuration(ENTER_ANIM_DURATION_MS)
            .start()
        previewScrim.animate().alpha(1f).setDuration(ENTER_ANIM_DURATION_MS).start()
        topBar.animate().alpha(1f).setDuration(ENTER_ANIM_DURATION_MS).start()
        pageIndicator.animate().alpha(1f).setDuration(ENTER_ANIM_DURATION_MS).start()
        if (showRadio) {
            bottomBar.animate().alpha(1f).setDuration(ENTER_ANIM_DURATION_MS).start()
        }
    }

    private fun animateDismissToSource(onEnd: () -> Unit) {
        val frame = sourceFrame
        if (frame == null || previewStage.width == 0 || previewStage.height == 0) {
            animateDismissOut(onEnd)
            return
        }
        val animatedMediaRect = resolveCurrentAnimatedMediaRectOnScreen()
        val drawable = currentPreviewDrawable()
        if (animatedMediaRect != null && drawable != null) {
            runDismissOverlayAnimation(frame, animatedMediaRect, drawable, onEnd)
            return
        }
        val target = buildTransformTo(frame, resolveCurrentMediaRectOnScreen())
        previewStage.pivotX = target.pivotX
        previewStage.pivotY = target.pivotY
        topBar.animate().alpha(0f).setDuration(DISMISS_ANIM_DURATION_MS).start()
        pageIndicator.animate().alpha(0f).setDuration(DISMISS_ANIM_DURATION_MS).start()
        if (showRadio) {
            bottomBar.animate().alpha(0f).setDuration(DISMISS_ANIM_DURATION_MS).start()
        }
        previewStage.animate()
            .translationX(target.translationX)
            .translationY(target.translationY)
            .scaleX(target.scaleX)
            .scaleY(target.scaleY)
            .alpha(0.92f)
            .setDuration(DISMISS_ANIM_DURATION_MS)
            .withEndAction(onEnd)
            .start()
        previewScrim.animate().alpha(0f).setDuration(DISMISS_ANIM_DURATION_MS).start()
    }

    private fun runEnterOverlayAnimation(
        sourceFrameOnScreen: RectF,
        mediaRectOnScreen: RectF,
        drawable: Drawable,
    ) {
        val fromRect = toLocalRect(sourceFrameOnScreen)
        val toRect = toLocalRect(mediaRectOnScreen)
        val overlay = createTransitionImageView(drawable, fromRect)
        transitionImageView?.let(previewContent::removeView)
        transitionImageView = overlay
        previewContent.addView(overlay)

        if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            Log.d(
                TAG,
                "enterOverlay source=$sourceFrameOnScreen mediaRect=$mediaRectOnScreen localFrom=$fromRect localTo=$toRect",
            )
        }

        animateOverlayBounds(
            overlay = overlay,
            fromRect = fromRect,
            toRect = toRect,
            durationMs = ENTER_ANIM_DURATION_MS,
            onProgress = { progress ->
                previewScrim.alpha = progress
                topBar.alpha = progress
                pageIndicator.alpha = progress
                if (showRadio) {
                    bottomBar.alpha = progress
                }
            },
            onEnd = {
                previewStage.alpha = 1f
                previewScrim.alpha = 1f
                topBar.alpha = 1f
                pageIndicator.alpha = 1f
                if (showRadio) {
                    bottomBar.alpha = 1f
                }
                overlay.animate()
                    .alpha(0f)
                    .setDuration(90L)
                    .withEndAction {
                        previewContent.removeView(overlay)
                        if (transitionImageView === overlay) {
                            transitionImageView = null
                        }
                    }
                    .start()
            },
        )
    }

    private fun runDismissOverlayAnimation(
        sourceFrameOnScreen: RectF,
        mediaRectOnScreen: RectF,
        drawable: Drawable,
        onEnd: () -> Unit,
    ) {
        val fromRect = toLocalRect(mediaRectOnScreen)
        val toRect = toLocalRect(sourceFrameOnScreen)
        val overlay = createTransitionImageView(drawable, fromRect)
        transitionImageView?.let(previewContent::removeView)
        transitionImageView = overlay
        previewContent.addView(overlay)

        previewStage.alpha = 0f
        topBar.alpha = 0f
        pageIndicator.alpha = 0f
        if (showRadio) {
            bottomBar.alpha = 0f
        }
        val initialScrim = previewScrim.alpha

        animateOverlayBounds(
            overlay = overlay,
            fromRect = fromRect,
            toRect = toRect,
            durationMs = DISMISS_ANIM_DURATION_MS,
            onProgress = { progress ->
                previewScrim.alpha = initialScrim * (1f - progress)
            },
            onEnd = {
                previewScrim.alpha = 0f
                previewContent.removeView(overlay)
                if (transitionImageView === overlay) {
                    transitionImageView = null
                }
                onEnd()
            },
        )
    }

    private fun animateDismissOut(onEnd: () -> Unit) {
        topBar.animate().alpha(0f).setDuration(DISMISS_ANIM_DURATION_MS).start()
        pageIndicator.animate().alpha(0f).setDuration(DISMISS_ANIM_DURATION_MS).start()
        if (showRadio) {
            bottomBar.animate().alpha(0f).setDuration(DISMISS_ANIM_DURATION_MS).start()
        }
        previewStage.animate()
            .translationX(previewStage.translationX * 1.1f)
            .translationY(previewStage.translationY + previewStage.height * 0.35f)
            .scaleX(previewStage.scaleX.coerceAtMost(1f) * 0.88f)
            .scaleY(previewStage.scaleY.coerceAtMost(1f) * 0.88f)
            .alpha(0.9f)
            .setDuration(DISMISS_ANIM_DURATION_MS)
            .withEndAction(onEnd)
            .start()
        previewScrim.animate().alpha(0f).setDuration(DISMISS_ANIM_DURATION_MS).start()
    }

    private fun buildTransformTo(frame: RectF, mediaRectOnScreen: RectF? = null): PreviewTransform {
        val stageLocation = IntArray(2)
        previewStage.getLocationOnScreen(stageLocation)
        val targetRectLocal = if (mediaRectOnScreen != null) {
            RectF(
                mediaRectOnScreen.left - stageLocation[0],
                mediaRectOnScreen.top - stageLocation[1],
                mediaRectOnScreen.right - stageLocation[0],
                mediaRectOnScreen.bottom - stageLocation[1],
            )
        } else {
            RectF(
                0f,
                0f,
                previewStage.width.toFloat().coerceAtLeast(1f),
                previewStage.height.toFloat().coerceAtLeast(1f),
            )
        }
        val frameLeft = frame.left - stageLocation[0]
        val frameTop = frame.top - stageLocation[1]
        val targetWidth = targetRectLocal.width().coerceAtLeast(1f)
        val targetHeight = targetRectLocal.height().coerceAtLeast(1f)
        return PreviewTransform(
            translationX = frameLeft - targetRectLocal.left,
            translationY = frameTop - targetRectLocal.top,
            scaleX = (frame.width() / targetWidth).coerceIn(0.05f, 1f),
            scaleY = (frame.height() / targetHeight).coerceIn(0.05f, 1f),
            pivotX = targetRectLocal.left,
            pivotY = targetRectLocal.top,
        )
    }

    /**
     * 是否为「已解码的真图」。占位色 ColorDrawable 的 intrinsicWidth/Height 为 -1，
     * 必须排除：否则 Glide 同步塞入的占位色会让 zoomView.drawable 立即非空，骗过进场
     * 动画“等真图”的重试门，导致 hero 飞入一个尺寸退化的纯色块而非照片本身。
     */
    private fun isDecodedImage(drawable: Drawable?): Boolean =
        drawable != null && drawable.intrinsicWidth > 0 && drawable.intrinsicHeight > 0

    private fun resolveCurrentMediaRectOnScreen(): RectF? {
        val holder = (viewPager.getChildAt(0) as? RecyclerView)
            ?.findViewHolderForAdapterPosition(viewPager.currentItem) as? PreviewViewHolder
            ?: return null
        return if (isDecodedImage(holder.zoomView.drawable)) {
            holder.zoomView.getDisplayRectOnScreen()
                ?: holder.itemView.globalRectF()
        } else {
            null
        }
    }

    private fun resolveCurrentAnimatedMediaRectOnScreen(): RectF? {
        val mediaRect = resolveCurrentMediaRectOnScreen() ?: return null
        val stageLocation = IntArray(2)
        previewStage.getLocationOnScreen(stageLocation)
        val left = transformStageX(mediaRect.left - stageLocation[0]) + stageLocation[0]
        val top = transformStageY(mediaRect.top - stageLocation[1]) + stageLocation[1]
        val right = transformStageX(mediaRect.right - stageLocation[0]) + stageLocation[0]
        val bottom = transformStageY(mediaRect.bottom - stageLocation[1]) + stageLocation[1]
        return RectF(left, top, right, bottom)
    }

    private fun transformStageX(localX: Float): Float =
        previewStage.pivotX + (localX - previewStage.pivotX) * previewStage.scaleX + previewStage.translationX

    private fun transformStageY(localY: Float): Float =
        previewStage.pivotY + (localY - previewStage.pivotY) * previewStage.scaleY + previewStage.translationY

    private fun currentPreviewDrawable(): Drawable? {
        val holder = (viewPager.getChildAt(0) as? RecyclerView)
            ?.findViewHolderForAdapterPosition(viewPager.currentItem) as? PreviewViewHolder
            ?: return null
        val drawable = holder.zoomView.drawable
        if (!isDecodedImage(drawable)) return null   // 占位色不作为 hero 源
        return drawable!!.constantState?.newDrawable(resources)?.mutate() ?: drawable.mutate()
    }

    private fun toLocalRect(screenRect: RectF): RectF {
        val rootLocation = IntArray(2)
        previewContent.getLocationOnScreen(rootLocation)
        return RectF(
            screenRect.left - rootLocation[0],
            screenRect.top - rootLocation[1],
            screenRect.right - rootLocation[0],
            screenRect.bottom - rootLocation[1],
        )
    }

    private fun createTransitionImageView(drawable: Drawable, rect: RectF): AppCompatImageView {
        return AppCompatImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            setImageDrawable(drawable)
            alpha = 1f
            // 不使用 translationX/Y 定位，由 animateOverlayBounds 通过 layout() 直接控制坐标
            // 这样可避免 translation 和 layout 叠加导致双倍偏移
            layoutParams = FrameLayout.LayoutParams(
                rect.width().roundToInt().coerceAtLeast(1),
                rect.height().roundToInt().coerceAtLeast(1),
            )
        }
    }

    private fun animateOverlayBounds(
        overlay: AppCompatImageView,
        fromRect: RectF,
        toRect: RectF,
        durationMs: Long,
        onProgress: (Float) -> Unit,
        onEnd: () -> Unit,
    ) {
        ValueAnimator.ofFloat(0f, 1f).apply {
            duration = durationMs
            addUpdateListener { animator ->
                val progress = animator.animatedFraction
                val left   = lerp(fromRect.left,    toRect.left,    progress).roundToInt()
                val top    = lerp(fromRect.top,     toRect.top,     progress).roundToInt()
                val right  = lerp(fromRect.right,   toRect.right,   progress).roundToInt().coerceAtLeast(left + 1)
                val bottom = lerp(fromRect.bottom,  toRect.bottom,  progress).roundToInt().coerceAtLeast(top  + 1)
                // 直接操作 View 内部坐标，跳过 layoutParams setter 避免每帧触发 requestLayout()
                overlay.layout(left, top, right, bottom)
                onProgress(progress)
            }
            doOnEndCompat(onEnd)
            start()
        }
    }

    private fun lerp(start: Float, end: Float, progress: Float): Float =
        start + (end - start) * progress

    private fun dp(value: Int): Int =
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics
        ).toInt()

    // 数值强转（doubleValue / doubleValueOrNull / intValue）已抽到 MediaMap.kt（可单元测试）

    private fun imageSizeFromFile(path: String): Pair<Int, Int>? {
        return runCatching {
            val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, opts)
            if (opts.outWidth > 0 && opts.outHeight > 0) {
                opts.outWidth to opts.outHeight
            } else {
                null
            }
        }.getOrNull()
    }

    // ──────────────────────────────────────────────
    // ViewPager2 适配器
    // ──────────────────────────────────────────────

    inner class PreviewPagerAdapter : RecyclerView.Adapter<PreviewViewHolder>() {

        override fun getItemCount() = previewAssets.size

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): PreviewViewHolder {
            val container = FrameLayout(parent.context).apply {
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
                setBackgroundColor(0x00000000)
            }

            val zoomView = ZoomableImageView(parent.context).apply {
                layoutParams = FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT
                )
                contentDescription = "资源预览图"
            }

            val playBtn = ImageView(parent.context).apply {
                val sizePx = (64 * parent.context.resources.displayMetrics.density).toInt()
                layoutParams = FrameLayout.LayoutParams(sizePx, sizePx).also {
                    it.gravity = Gravity.CENTER
                }
                setImageDrawable(ContextCompat.getDrawable(parent.context, R.drawable.ic_play_circle))
                alpha = 0.9f
                visibility = View.GONE
                contentDescription = "播放视频"
                val paddingPx = (8 * parent.context.resources.displayMetrics.density).toInt()
                setPadding(paddingPx, paddingPx, paddingPx, paddingPx)
            }

            container.addView(zoomView)
            container.addView(playBtn)
            return PreviewViewHolder(container, zoomView, playBtn)
        }

        override fun onBindViewHolder(holder: PreviewViewHolder, position: Int) {
            val asset = previewAssets.getOrNull(position) ?: return
            holder.bind(asset)
        }

        override fun onViewRecycled(holder: PreviewViewHolder) {
            super.onViewRecycled(holder)
            Glide.with(holder.zoomView.context).clear(holder.zoomView)
            holder.zoomView.resetTransform()
            // 若此 holder 正在承载 PlayerView，撤离并暂停
            videoController.onSurfaceRecycled(holder)
        }
    }

    inner class PreviewViewHolder(
        itemView: View,
        val zoomView: ZoomableImageView,
        private val playBtn: ImageView
    ) : RecyclerView.ViewHolder(itemView), VideoSurface {

        private var currentPlayUri: Uri? = null
        private val container get() = itemView as FrameLayout

        fun bind(asset: Map<String, Any?>) {
            val assetId   = asset["assetId"]   as? String
            val url       = asset["url"]       as? String
            val videoUrl  = asset["videoUrl"]  as? String
            val editedPath = asset["editedPath"] as? String
            val mediaType = (asset["mediaType"] as? String) ?: "image"
            val isVideo   = mediaType == "video"

            // 图片缩略图加载（视频也加载封面帧）
            val thumbTarget: Any? = when {
                !editedPath.isNullOrBlank() -> File(editedPath)
                url != null && !isVideo -> url
                isVideo && videoUrl != null -> videoUrl
                isVideo && url != null -> url
                assetId != null -> Uri.parse(assetId)
                else -> null
            }
            if (thumbTarget != null) {
                // 占位色 + 低分辨率缩略 + 短交叉淡入，消除“空白→图”的突兀闪烁。
                // 占位色 ColorDrawable 会被 isDecodedImage() 视为“未就绪”，故进场 hero 动画
                // 仍会等真图解码后再飞入，不会误用占位色块（见 resolveCurrentMediaRectOnScreen）。
                Glide.with(zoomView.context)
                    .load(thumbTarget)
                    .diskCacheStrategy(DiskCacheStrategy.RESOURCE)
                    .placeholder(ColorDrawable(ContextCompat.getColor(zoomView.context, R.color.preview_placeholder)))
                    .thumbnail(0.15f)
                    .transition(DrawableTransitionOptions.withCrossFade(180))
                    .into(zoomView)
            }

            playBtn.visibility = if (isVideo) View.VISIBLE else View.GONE

            if (isVideo) {
                val playUri = when {
                    videoUrl != null -> Uri.parse(videoUrl)
                    url != null      -> Uri.parse(url)
                    assetId != null  -> Uri.parse(assetId)
                    else             -> null
                }
                this.currentPlayUri = playUri
                val clickHandler = if (playUri != null) View.OnClickListener {
                    // 点击播放按钮：内联 ExoPlayer
                    playBtn.visibility = View.GONE
                    videoController.play(this, playUri)
                } else null
                playBtn.setOnClickListener(clickHandler)
                zoomView.setOnClickListener(clickHandler)
            } else {
                this.currentPlayUri = null
                playBtn.setOnClickListener(null)
                zoomView.setOnClickListener(null)
            }
        }

        /** autoPlayVideo 场景下由 Activity 调用，触发内联 ExoPlayer */
        fun invokePlay() {
            currentPlayUri?.let { uri ->
                playBtn.visibility = View.GONE
                videoController.play(this, uri)
            }
        }

        /**
         * 将 PlayerView 附加到此 holder 的容器中（覆盖在封面帧上方）。
         * 由 Activity.playVideoInHolder() 调用，切换 holder 时自动从旧 holder 移除。
         */
        override fun attachPlayerView(pv: androidx.media3.ui.PlayerView) {
            (pv.parent as? ViewGroup)?.removeView(pv)
            container.addView(pv)
        }

        /**
         * 从此 holder 的容器中移除 PlayerView（切换页或 recycle 时调用）。
         * 移除后封面帧重新可见，播放按钮恢复显示。
         */
        override fun releasePlayerView() {
            for (i in container.childCount - 1 downTo 0) {
                if (container.getChildAt(i) is androidx.media3.ui.PlayerView) {
                    container.removeViewAt(i)
                }
            }
            if (currentPlayUri != null) {
                playBtn.visibility = View.VISIBLE
            }
        }

    }

    // ──────────────────────────────────────────────
    // 常量
    // ──────────────────────────────────────────────

    companion object {
        private const val TAG = "LivePhotoPreview"
        const val EXTRA_ASSETS        = "assets"
        const val EXTRA_INITIAL_INDEX = "initialIndex"
        const val EXTRA_SELECTED_IDS  = "selectedAssetIds"
        const val EXTRA_SHOW_RADIO    = "showRadio"
        const val EXTRA_DARK_MODE     = "isDarkMode"
        const val EXTRA_MAX_COUNT     = "maxCount"
        const val EXTRA_MAX_VIDEO_COUNT        = "maxVideoCount"
        const val EXTRA_AUTO_PLAY_VIDEO        = "autoPlayVideo"
        const val EXTRA_SHOW_DOWNLOAD_BUTTON   = "showDownloadButton"
        const val EXTRA_ENGINE_KEY             = "engineKey"
        const val EXTRA_SAVE_ALBUM_NAME        = "saveAlbumName"
        const val EXTRA_SOURCE_LEFT   = "sourceLeft"
        const val EXTRA_SOURCE_TOP    = "sourceTop"
        const val EXTRA_SOURCE_WIDTH  = "sourceWidth"
        const val EXTRA_SOURCE_HEIGHT = "sourceHeight"

        // 下拉关闭参数
        private const val DISMISS_START_DP       = 6f    // 开始识别下拉手势的最小 Y 位移
        private const val DISMISS_VERTICAL_RATIO = 1.5f  // 垂直/水平位移比：>34°偏角才触发，防误触横滑
        private const val DISMISS_COMMIT_DP      = 120f  // 超过此值触发关闭
        private const val FLING_DISMISS_VELOCITY = 1400f // px/s：快速下滑轻甩关闭的最小竖直速度
        private const val DISMISS_FADE_DP        = 400f  // 背景完全淡出对应的位移
        private const val DISMISS_ANIM_DURATION_MS = 200L
        private const val SNAP_BACK_DURATION_MS    = 250L
        private const val ENTER_ANIM_DURATION_MS   = 240L
        // DISMISS_SCALE_FACTOR / MIN_SCALE / HORIZONTAL_FACTOR 已移入 DismissGestureMath
        private const val ENTER_RETRY_DELAY_MS = 16L
        private const val MAX_ENTER_RETRIES = 10
        // 页码指示器：≤此值用圆点，超过则用 "n / total" 药丸
        private const val PAGE_INDICATOR_DOT_MAX = 8
    }

    private data class PreviewTransform(
        val translationX: Float,
        val translationY: Float,
        val scaleX: Float,
        val scaleY: Float,
        val pivotX: Float,
        val pivotY: Float,
    )

    private fun ValueAnimator.doOnEndCompat(action: () -> Unit) {
        addListener(object : android.animation.Animator.AnimatorListener {
            override fun onAnimationStart(animation: android.animation.Animator) = Unit
            override fun onAnimationEnd(animation: android.animation.Animator) = action()
            override fun onAnimationCancel(animation: android.animation.Animator) {
                if (!(this@PreviewActivity).isFinishing && !(this@PreviewActivity).isDestroyed) {
                    action()
                }
            }
            override fun onAnimationRepeat(animation: android.animation.Animator) = Unit
        })
    }
}

private fun View.globalRectF(): RectF? {
    val location = IntArray(2)
    getLocationOnScreen(location)
    if (width <= 0 || height <= 0) return null
    return RectF(
        location[0].toFloat(),
        location[1].toFloat(),
        location[0] + width.toFloat(),
        location[1] + height.toFloat(),
    )
}

