package com.newtrip.live_photo_gallery

import android.app.Activity
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate
import androidx.appcompat.widget.Toolbar
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.bumptech.glide.Glide
import com.bumptech.glide.ListPreloader.PreloadModelProvider
import com.bumptech.glide.ListPreloader.PreloadSizeProvider
import com.bumptech.glide.RequestBuilder
import com.bumptech.glide.integration.recyclerview.RecyclerViewPreloader
import com.bumptech.glide.load.engine.DiskCacheStrategy
import com.bumptech.glide.util.FixedPreloadSizeProvider
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.button.MaterialButton
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.chip.Chip
import com.google.android.material.chip.ChipGroup
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 媒体选择器 Activity
 *
 * 功能：
 * - 3列宫格展示媒体（按修改时间倒序），等间距，正方形格子
 * - 相册切换（Toolbar 标题点击 → BottomSheet）
 * - 图片/视频分类 Chip 筛选（enableVideo=true 时显示）
 * - 多选（最大 maxCount）+ 序号圆圈
 * - 长按单张进入预览（PreviewActivity），返回后保持滚动位置
 * - 原图勾选
 * - Glide RecyclerViewPreloader 预加载（对齐 iOS PHCachingImageManager）
 * - DiffUtil + PAYLOAD 选中状态局部刷新（防闪烁）
 * - 底部栏 WindowInsets 适配（三段式导航栏）
 */
class MediaPickerActivity : AppCompatActivity() {

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    private lateinit var toolbar:        MaterialToolbar
    private lateinit var recyclerView:   RecyclerView
    private lateinit var progressBar:    ProgressBar
    private lateinit var btnOriginal:    MaterialButton
    private lateinit var btnDone:        MaterialButton
    private lateinit var chipGroup:      ChipGroup
    private lateinit var chipAll:        Chip
    private lateinit var chipImage:      Chip
    private lateinit var chipVideo:      Chip
    private lateinit var titleContainer: LinearLayout
    private lateinit var titleTextView:  TextView
    private lateinit var titleArrowView: ImageView

    // ──────────────────────────────────────────────
    // 状态
    // ──────────────────────────────────────────────

    private lateinit var adapter: MediaGridAdapter
    private lateinit var config: PickerConfig
    private var engineKey = ""

    /** 从 MediaStore 查询到的原始完整列表（当前相册） */
    private var allAssets: List<MediaAsset> = emptyList()
    /** 经 Chip 筛选后显示在宫格中的列表 */
    private var filteredAssets: List<MediaAsset> = emptyList()

    private val selectedAssets = mutableListOf<MediaAsset>()
    private val editedPathByAssetId = mutableMapOf<String, String>()
    private var isOriginalPhoto = false

    // 相册
    private var albums: List<AlbumItem> = emptyList()
    private var currentBucketId: Long = AlbumHelper.ALL_BUCKET_ID
    private var albumSheetDialog: BottomSheetDialog? = null

    // 分类筛选
    private enum class MediaFilter { ALL, IMAGE, VIDEO }
    private var currentFilter = MediaFilter.ALL

    // 长按预览：记录最后进入预览的位置，返回时恢复滚动
    private var lastPreviewPosition = RecyclerView.NO_POSITION
    private var loadRequestToken = 0

    // ──────────────────────────────────────────────
    // 生命周期
    // ──────────────────────────────────────────────

    override fun onCreate(savedInstanceState: Bundle?) {
        applyDarkModeFromIntent()
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_media_picker)
        parseConfig()
        initViews()
        loadAssets()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_PREVIEW && resultCode == Activity.RESULT_OK && data != null) {
            // 预览页选中/取消选中后，同步回选图页
            val itemsJson   = data.getStringExtra(RESULT_ITEMS) ?: "[]"
            val isOriginal  = data.getBooleanExtra(RESULT_IS_ORIGINAL, false)
            val previewIds  = parseSelectedIds(itemsJson)
            val editedMap   = parseEditedPaths(itemsJson)
            val visibleIds  = filteredAssets.mapTo(hashSetOf()) { it.uri.toString() }

            // 仅用预览页结果覆盖“当前筛选列表”的选中状态，保留被筛掉但仍然已选的项
            selectedAssets.removeAll { asset -> visibleIds.contains(asset.uri.toString()) }
            previewIds.forEach { id ->
                filteredAssets.firstOrNull { it.uri.toString() == id }?.let { asset ->
                    if (selectedAssets.none { it.id == asset.id }) {
                        selectedAssets.add(asset)
                    }
                }
            }
            // 裁剪结果只保留仍然选中的项目，避免缓存无限增长
            editedPathByAssetId.keys.retainAll(previewIds.toSet())
            editedPathByAssetId.putAll(editedMap.filterKeys { previewIds.contains(it) })
            adapter.editedPathByAssetId = editedPathByAssetId
            isOriginalPhoto = isOriginal
            updateOriginalButton()

            adapter.selectedAssets = selectedAssets.toList()
            adapter.notifyItemRangeChanged(0, adapter.itemCount, MediaGridAdapter.PAYLOAD_SELECTION)
            updateDoneButton()

            // 滚动回最后预览的位置（P3-J）
            if (lastPreviewPosition != RecyclerView.NO_POSITION) {
                recyclerView.scrollToPosition(lastPreviewPosition)
            }
        }
    }

    // ──────────────────────────────────────────────
    // 初始化
    // ──────────────────────────────────────────────

    private fun applyDarkModeFromIntent() {
        val configJson = intent?.getStringExtra(EXTRA_CONFIG) ?: "{}"
        val isDark = runCatching { PickerConfig.fromJson(configJson).isDarkMode }.getOrDefault(false)
        delegate.localNightMode =
            if (isDark) AppCompatDelegate.MODE_NIGHT_YES else AppCompatDelegate.MODE_NIGHT_NO
    }

    private fun parseConfig() {
        val configJson = intent.getStringExtra(EXTRA_CONFIG) ?: "{}"
        config = PickerConfig.fromJson(configJson)
        engineKey = intent.getStringExtra(EXTRA_ENGINE_KEY) ?: ""
    }

    private fun initViews() {
        toolbar      = findViewById(R.id.toolbar)
        recyclerView = findViewById(R.id.rv_media_grid)
        progressBar  = findViewById(R.id.progress_bar)
        btnOriginal  = findViewById(R.id.btn_original)
        btnDone      = findViewById(R.id.btn_done)
        chipGroup    = findViewById(R.id.chip_group_filter)
        chipAll      = findViewById(R.id.chip_all)
        chipImage    = findViewById(R.id.chip_image)
        chipVideo    = findViewById(R.id.chip_video)

        setupToolbar()
        setupRecyclerView()
        setupBottomBar()
        setupChipFilter()
        updateDoneButton()
    }

    /** Toolbar：标题可点击切换相册，关闭按钮 */
    private fun setupToolbar() {
        toolbar.title = ""
        ensureToolbarTitleView()
        updateToolbarTitle("所有照片")
        toolbar.setNavigationOnClickListener {
            setResult(Activity.RESULT_CANCELED)
            finish()
        }
        toolbar.setOnClickListener { showAlbumPicker() }
    }

    private fun ensureToolbarTitleView() {
        if (::titleContainer.isInitialized) return

        titleTextView = TextView(this).apply {
            setTextColor(resolveThemeColor(com.google.android.material.R.attr.colorOnSurface))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            includeFontPadding = false
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        titleArrowView = ImageView(this).apply {
            setImageResource(R.drawable.ic_expand_more)
            imageTintList = ColorStateList.valueOf(
                resolveThemeColor(com.google.android.material.R.attr.colorOnSurfaceVariant)
            )
        }
        titleContainer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            minimumHeight = dp(40)
            background = resolveSelectableItemBackgroundBorderless()
            isClickable = true
            isFocusable = true
            setPadding(dp(12), dp(8), dp(12), dp(8))
            addView(titleTextView)
            addView(titleArrowView, LinearLayout.LayoutParams(dp(20), dp(20)).apply {
                marginStart = dp(2)
            })
            setOnClickListener { showAlbumPicker() }
        }
        // 子 View 不单独设置 clickListener，触摸事件由 titleContainer 统一处理

        toolbar.addView(
            titleContainer,
            Toolbar.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
        )
    }

    private fun updateToolbarTitle(title: String) {
        titleTextView.text = title
    }

    private fun setAlbumPopupExpanded(expanded: Boolean) {
        titleArrowView.animate()
            .rotation(if (expanded) 180f else 0f)
            .setDuration(160L)
            .start()
    }

    private fun setupRecyclerView() {
        val layoutManager = GridLayoutManager(this, MediaGridAdapter.GRID_COLUMNS)
        recyclerView.layoutManager = layoutManager
        recyclerView.setItemViewCacheSize(ITEM_CACHE_SIZE)

        val spacingPx = (resources.displayMetrics.density * GRID_SPACING_DP + 0.5f).toInt()
        recyclerView.addItemDecoration(GridSpacingItemDecoration(MediaGridAdapter.GRID_COLUMNS, spacingPx))

        adapter = MediaGridAdapter()
        adapter.showSelectionControls = config.showRadio
        adapter.onItemClick = { asset, position -> handleItemPreview(asset, position) }
        adapter.onItemLongClick = { asset, position -> handleItemLongClick(asset, position) }
        adapter.onSelectionClick = { asset, position -> handleItemSelectionToggle(asset, position) }
        recyclerView.adapter = adapter

        attachGlidePreloader()
    }

    private fun setupBottomBar() {
        val bottomBar: View = findViewById(R.id.bottom_bar)
        // 适配三段式虚拟导航栏，防止底部栏被遮挡（P1-C）
        ViewCompat.setOnApplyWindowInsetsListener(bottomBar) { v, insets ->
            val navBars = insets.getInsets(WindowInsetsCompat.Type.navigationBars())
            v.setPadding(v.paddingLeft, v.paddingTop, v.paddingRight, navBars.bottom)
            insets
        }

        if (!config.showRadio) btnOriginal.visibility = View.GONE

        btnOriginal.setOnClickListener {
            isOriginalPhoto = !isOriginalPhoto
            updateOriginalButton()
        }
        btnDone.setOnClickListener {
            if (selectedAssets.isNotEmpty()) exportAndReturn()
        }
        updateOriginalButton()
    }

    /** 分类 Chip：仅在 enableVideo=true 时显示 */
    private fun setupChipFilter() {
        if (!config.enableVideo) {
            chipGroup.visibility = View.GONE
            return
        }
        chipGroup.visibility = View.VISIBLE
        chipGroup.setOnCheckedStateChangeListener { _, checkedIds ->
            currentFilter = when (checkedIds.firstOrNull()) {
                R.id.chip_image -> MediaFilter.IMAGE
                R.id.chip_video -> MediaFilter.VIDEO
                else            -> MediaFilter.ALL
            }
            applyFilter()
        }
    }

    // ──────────────────────────────────────────────
    // Glide 预加载
    // ──────────────────────────────────────────────

    private fun attachGlidePreloader() {
        val cellSizePx = ((resources.displayMetrics.widthPixels -
            dp(GRID_SPACING_DP) * (MediaGridAdapter.GRID_COLUMNS - 1)) / MediaGridAdapter.GRID_COLUMNS)
            .coerceAtLeast(dp(96))
        val sizeProvider: PreloadSizeProvider<MediaAsset> = FixedPreloadSizeProvider(cellSizePx, cellSizePx)
        val modelProvider = object : PreloadModelProvider<MediaAsset> {
            override fun getPreloadItems(position: Int): List<MediaAsset> =
                listOfNotNull(filteredAssets.getOrNull(position))

            override fun getPreloadRequestBuilder(item: MediaAsset): RequestBuilder<*> =
                Glide.with(this@MediaPickerActivity)
                    .load(editedPathByAssetId[item.uri.toString()]?.let { File(it) } ?: item.uri)
                    .override(cellSizePx, cellSizePx)
                    .centerCrop()
        }
        recyclerView.addOnScrollListener(
            RecyclerViewPreloader(Glide.with(this), modelProvider, sizeProvider, PRELOAD_COUNT)
        )
    }

    // ──────────────────────────────────────────────
    // 相册选择器（BottomSheet）
    // ──────────────────────────────────────────────

    private fun showAlbumPicker() {
        if (albums.isEmpty()) {
            Toast.makeText(this, "相册加载中，请稍后重试", Toast.LENGTH_SHORT).show()
            return
        }
        albumSheetDialog?.dismiss()

        val sheetHeight = minOf(dp(420), albums.size * dp(72) + dp(32))
        val popupContent = RecyclerView(this).apply {
            layoutManager = androidx.recyclerview.widget.LinearLayoutManager(this@MediaPickerActivity)
            overScrollMode = View.OVER_SCROLL_NEVER
            setPadding(0, dp(8), 0, dp(16))
            clipToPadding = false
            adapter = AlbumAdapter(albums, currentBucketId) { selected ->
                albumSheetDialog?.dismiss()
                if (selected.bucketId != currentBucketId) {
                    currentBucketId = selected.bucketId
                    updateToolbarTitle(selected.displayName)
                    // 切换相册时重置筛选和选中（避免跨相册残留选中）
                    currentFilter = MediaFilter.ALL
                    selectedAssets.clear()
                    editedPathByAssetId.clear()
                    this@MediaPickerActivity.adapter.selectedAssets = emptyList()
                    this@MediaPickerActivity.adapter.editedPathByAssetId = emptyMap()
                    isOriginalPhoto = false
                    updateOriginalButton()
                    updateDoneButton()
                    chipAll.isChecked = true
                    loadAssets()
                }
            }
        }

        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(24).toFloat()
                setColor(resolveThemeColor(com.google.android.material.R.attr.colorSurface))
            }
            addView(
                popupContent,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    sheetHeight,
                )
            )
        }

        val dialog = BottomSheetDialog(this).apply {
            setContentView(container)
            setCanceledOnTouchOutside(true)
            setOnDismissListener {
                setAlbumPopupExpanded(false)
                albumSheetDialog = null
            }
        }
        albumSheetDialog = dialog
        setAlbumPopupExpanded(true)
        dialog.show()
    }

    // ──────────────────────────────────────────────
    // 数据加载
    // ──────────────────────────────────────────────

    private fun loadAssets() {
        val requestToken = ++loadRequestToken
        progressBar.visibility = View.VISIBLE
        recyclerView.visibility = View.GONE

        lifecycleScope.launch {
            // 并发加载资源列表；相册列表仅首次进入时查询，切相册时复用缓存
            val assetsDeferred = async(Dispatchers.IO) {
                runCatching { MediaStoreHelper.fetchAll(this@MediaPickerActivity, config, currentBucketId) }
            }
            val albumsDeferred = if (albums.isEmpty()) {
                async(Dispatchers.IO) {
                    runCatching { AlbumHelper.fetchAlbums(this@MediaPickerActivity, config) }
                }
            } else {
                null
            }

            val assetsResult = assetsDeferred.await()
            val albumsResult = albumsDeferred?.await()

            if (requestToken != loadRequestToken || isFinishing || isDestroyed) {
                return@launch
            }

            progressBar.visibility = View.GONE

            albumsResult?.onSuccess { list -> albums = list }

            assetsResult.onSuccess { assets ->
                allAssets = assets
                applyFilter()  // 更新 filteredAssets 并提交 adapter
                recyclerView.visibility = View.VISIBLE
                if (assets.isEmpty()) {
                    Toast.makeText(this@MediaPickerActivity, "没有找到媒体文件", Toast.LENGTH_SHORT).show()
                }
            }.onFailure {
                recyclerView.visibility = View.VISIBLE
                Toast.makeText(this@MediaPickerActivity, "加载失败，请重试", Toast.LENGTH_SHORT).show()
            }
        }
    }

    /** 根据当前 currentFilter 过滤 allAssets 并提交到 adapter */
    private fun applyFilter() {
        filteredAssets = when (currentFilter) {
            MediaFilter.IMAGE -> allAssets.filter { it.mediaType == "image" }
            MediaFilter.VIDEO -> allAssets.filter { it.mediaType == "video" }
            MediaFilter.ALL   -> allAssets
        }
        adapter.selectedAssets = selectedAssets.toList()
        adapter.editedPathByAssetId = editedPathByAssetId
        adapter.submitList(filteredAssets)
    }

    // ──────────────────────────────────────────────
    // 选中交互
    // ──────────────────────────────────────────────

    private fun handleItemSelectionToggle(asset: MediaAsset, position: Int) {
        val existingIndex = selectedAssets.indexOfFirst { it.id == asset.id }

        if (existingIndex >= 0) {
            selectedAssets.removeAt(existingIndex)
            adapter.selectedAssets = selectedAssets.toList()
            // 先清除本项圆圈，再刷新其余已选项序号（因序号整体前移）
            adapter.updateSelectionState(position)
            refreshSelectionNumbers()
        } else {
            if (selectedAssets.size >= config.maxCount) {
                // 通知 Flutter 侧 onMaxCountReached
                LivePhotoGalleryPlugin.getChannel(engineKey)?.invokeMethod(
                    "onMaxCountReached",
                    mapOf("maxCount" to config.maxCount)
                )
                Toast.makeText(this, "最多只能选择 ${config.maxCount} 张", Toast.LENGTH_SHORT).show()
                return
            }
            // maxVideoCount 限制：-1 = 无限制
            val isVideoOrLive = asset.mediaType == "video" || asset.isMotionPhoto
            if (config.maxVideoCount >= 0 && isVideoOrLive) {
                val currentVideoCount = selectedAssets.count { it.mediaType == "video" || it.isMotionPhoto }
                if (currentVideoCount >= config.maxVideoCount) {
                    Toast.makeText(this, "最多只能选择 ${config.maxVideoCount} 个视频/动态照片", Toast.LENGTH_SHORT).show()
                    return
                }
            }
            selectedAssets.add(asset)
            adapter.selectedAssets = selectedAssets.toList()
            recyclerView.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            adapter.updateSelectionState(position)
        }

        updateDoneButton()
    }

    private fun handleItemPreview(asset: MediaAsset, position: Int) {
        openPreview(position, triggerLongPressHaptic = false)
    }

    /** 长按：进入单张预览（P3-J：记录位置，返回后滚动） */
    private fun handleItemLongClick(asset: MediaAsset, position: Int) {
        openPreview(position, triggerLongPressHaptic = true)
    }

    private fun openPreview(position: Int, triggerLongPressHaptic: Boolean) {
        lastPreviewPosition = position
        if (triggerLongPressHaptic) {
            recyclerView.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        }

        // 快照当前列表引用（避免 IO 线程与主线程并发修改）
        val snapshot = filteredAssets
        val visibleIds = snapshot.mapTo(hashSetOf()) { it.uri.toString() }
        val selectedSnap = selectedAssets
            .map { it.uri.toString() }
            .filter { visibleIds.contains(it) }

        // JSON 构建放到 IO 线程，避免大量图片时主线程 jank
        lifecycleScope.launch {
            val assetsJson   = withContext(Dispatchers.IO) { buildAssetsJson(snapshot) }
            val selectedJson = withContext(Dispatchers.IO) {
                JSONArray().also { arr -> selectedSnap.forEach { arr.put(it) } }.toString()
            }

            startActivityForResult(
                Intent(this@MediaPickerActivity, PreviewActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
                    putExtra(PreviewActivity.EXTRA_ASSETS,        assetsJson)
                    putExtra(PreviewActivity.EXTRA_INITIAL_INDEX, position)
                    putExtra(PreviewActivity.EXTRA_SELECTED_IDS,  selectedJson)
                    putExtra(PreviewActivity.EXTRA_SHOW_RADIO,          config.showRadio)
                    putExtra(PreviewActivity.EXTRA_DARK_MODE,           config.isDarkMode)
                    putExtra(PreviewActivity.EXTRA_MAX_COUNT,           config.maxCount)
                    putExtra(PreviewActivity.EXTRA_MAX_VIDEO_COUNT,     config.maxVideoCount)
                    putExtra(PreviewActivity.EXTRA_AUTO_PLAY_VIDEO,     config.autoPlayVideo)
                    putExtra(PreviewActivity.EXTRA_ENGINE_KEY,          engineKey)
                    buildSourceFrame(position)?.let { source ->
                        putExtra(PreviewActivity.EXTRA_SOURCE_LEFT, source.left.toFloat())
                        putExtra(PreviewActivity.EXTRA_SOURCE_TOP, source.top.toFloat())
                        putExtra(PreviewActivity.EXTRA_SOURCE_WIDTH, source.width().toFloat())
                        putExtra(PreviewActivity.EXTRA_SOURCE_HEIGHT, source.height().toFloat())
                    }
                },
                REQUEST_PREVIEW
            )
            overridePendingTransition(0, 0)
        }
    }

    private fun buildAssetsJson(assets: List<MediaAsset>): String {
        val arr = JSONArray()
        assets.forEach { a ->
            arr.put(JSONObject().apply {
                put("assetId",   a.uri.toString())
                // 对齐 iOS：Live Photo 返回 "livePhoto" 而非 "image"
                put("mediaType", if (a.isMotionPhoto) "livePhoto" else a.mediaType)
                put("duration", if (a.mediaType == "video") a.duration / 1000.0 else null)
                put("width",     a.width)
                put("height",    a.height)
                editedPathByAssetId[a.uri.toString()]?.let { put("editedPath", it) }
            })
        }
        return arr.toString()
    }

    private fun buildSourceFrame(position: Int): Rect? {
        val itemView = recyclerView.layoutManager?.findViewByPosition(position) ?: return null
        val rect = Rect()
        return if (itemView.getGlobalVisibleRect(rect) && rect.width() > 0 && rect.height() > 0) {
            rect
        } else {
            null
        }
    }

    /**
     * 刷新所有已选 item 的序号（取消选中后序号整体前移）
     * 优化：只遍历 selectedAssets（O(selected.size × filtered.size)），
     * 而非遍历全量 itemCount（O(allAssets.size)）
     */
    private fun refreshSelectionNumbers() {
        selectedAssets.forEach { asset ->
            val position = filteredAssets.indexOfFirst { it.id == asset.id }
            if (position >= 0) adapter.updateSelectionState(position)
        }
    }

    private fun updateDoneButton() {
        val count = selectedAssets.size
        btnDone.text    = if (count > 0) "完成($count)" else "完成"
        btnDone.isEnabled = count > 0
    }

    private fun updateOriginalButton() {
        btnOriginal.isChecked = isOriginalPhoto
        if (isOriginalPhoto) {
            btnOriginal.text = "原图 已开"
            btnOriginal.backgroundTintList = ColorStateList.valueOf(0x140A84FF)
            btnOriginal.strokeWidth = dp(1)
            btnOriginal.strokeColor = ColorStateList.valueOf(0xFF0A84FF.toInt())
            btnOriginal.setTextColor(0xFF0A84FF.toInt())
            btnOriginal.iconTint = ColorStateList.valueOf(0xFF0A84FF.toInt())
        } else {
            btnOriginal.text = "原图"
            btnOriginal.backgroundTintList = ColorStateList.valueOf(0x00000000)
            btnOriginal.strokeWidth = 0
            btnOriginal.strokeColor = null
            btnOriginal.setTextColor(resolveThemeColor(com.google.android.material.R.attr.colorOnSurface))
            btnOriginal.iconTint = ColorStateList.valueOf(resolveThemeColor(com.google.android.material.R.attr.colorPrimary))
        }
    }

    // ──────────────────────────────────────────────
    // 导出并返回
    // ──────────────────────────────────────────────

    private fun exportAndReturn() {
        progressBar.visibility = View.VISIBLE
        btnDone.isEnabled = false

        lifecycleScope.launch {
            val items = withContext(Dispatchers.IO) {
                selectedAssets.map { asset ->
                    async {
                        val editedPath = editedPathByAssetId[asset.uri.toString()]
                        val thumbPath = runCatching {
                            if (!editedPath.isNullOrBlank()) {
                                ExportHelper.saveNetworkThumbnail(
                                    context = this@MediaPickerActivity,
                                    networkId = "local_edit_${asset.id}",
                                    url = Uri.fromFile(java.io.File(editedPath)),
                                    width = 200,
                                    height = 200
                                )
                            } else {
                                ExportHelper.saveThumbnail(this@MediaPickerActivity, asset, 200, 200)
                            }
                        }.getOrDefault("")
                        val outDuration = if (asset.mediaType == "video") asset.duration / 1000.0 else null
                        mapOf(
                            "assetId"       to (editedPath ?: asset.uri.toString()),
                            // 对齐 iOS：Live Photo 返回 "livePhoto" 而非 "image"
                            "mediaType"     to if (asset.isMotionPhoto) "livePhoto" else asset.mediaType,
                            "thumbnailPath" to thumbPath,
                            "editedPath"    to editedPath,
                            "duration"      to outDuration,
                            "width"         to asset.width,
                            "height"        to asset.height
                        )
                    }
                }.awaitAll()
            }

            val arr = JSONArray()
            items.forEach { item ->
                arr.put(JSONObject().apply {
                    put("assetId",       item["assetId"])
                    put("mediaType",     item["mediaType"])
                    put("thumbnailPath", item["thumbnailPath"])
                    put("editedPath",    item["editedPath"])
                    put("duration",      item["duration"])
                    put("width",         item["width"])
                    put("height",        item["height"])
                })
            }

            setResult(Activity.RESULT_OK, Intent().apply {
                putExtra(RESULT_ITEMS,       arr.toString())
                putExtra(RESULT_IS_ORIGINAL, isOriginalPhoto)
            })
            finish()
        }
    }

    // ──────────────────────────────────────────────
    // 工具
    // ──────────────────────────────────────────────

    /** 从预览页返回的 JSON 中解析已选 assetId 列表 */
    private fun parseSelectedIds(json: String): List<String> {
        return runCatching {
            val arr = JSONArray(json)
            (0 until arr.length()).map { i ->
                val obj = arr.getJSONObject(i)
                obj.optString("originAssetId").ifBlank { obj.optString("assetId") }
            }
                .filter { it.isNotBlank() }
        }.getOrDefault(emptyList())
    }

    /** 从预览页返回 JSON 解析每个 assetId 对应的 editedPath */
    private fun parseEditedPaths(json: String): Map<String, String> {
        return runCatching {
            val arr = JSONArray(json)
            buildMap {
                for (i in 0 until arr.length()) {
                    val obj = arr.getJSONObject(i)
                    val id = obj.optString("originAssetId").ifBlank { obj.optString("assetId") }
                    val edited = obj.optString("editedPath")
                    if (id.isNotBlank() && edited.isNotBlank()) put(id, edited)
                }
            }
        }.getOrDefault(emptyMap())
    }

    // ──────────────────────────────────────────────
    // 相册列表 Adapter（内部类，无需独立文件）
    // ──────────────────────────────────────────────

    private inner class AlbumAdapter(
        private val items: List<AlbumItem>,
        private val activeBucketId: Long,
        val onSelect: (AlbumItem) -> Unit
    ) : RecyclerView.Adapter<AlbumViewHolder>() {

        override fun getItemCount() = items.size

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): AlbumViewHolder {
            val view = LayoutInflater.from(parent.context)
                .inflate(R.layout.item_album, parent, false)
            return AlbumViewHolder(view)
        }

        override fun onBindViewHolder(holder: AlbumViewHolder, position: Int) {
            holder.bind(items[position], activeBucketId)
        }
    }

    private inner class AlbumViewHolder(itemView: View) : RecyclerView.ViewHolder(itemView) {
        private val cover: ImageView  = itemView.findViewById(R.id.iv_album_cover)
        private val name:  TextView   = itemView.findViewById(R.id.tv_album_name)
        private val count: TextView   = itemView.findViewById(R.id.tv_album_count)
        private val check: ImageView  = itemView.findViewById(R.id.iv_album_check)

        fun bind(item: AlbumItem, activeBucketId: Long) {
            name.text  = item.displayName
            count.text = item.count.toString()
            check.visibility = if (item.bucketId == activeBucketId) View.VISIBLE else View.GONE

            Glide.with(cover.context)
                .load(item.coverUri)
                .override(56, 56)
                .centerCrop()
                .diskCacheStrategy(DiskCacheStrategy.RESOURCE)
                .into(cover)

            itemView.setOnClickListener {
                (bindingAdapter as? AlbumAdapter)?.let { adapter ->
                    adapter.onSelect(item)
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // 常量
    // ──────────────────────────────────────────────

    companion object {
        const val EXTRA_CONFIG       = "config"
        const val EXTRA_ENGINE_KEY   = "engineKey"
        const val RESULT_ITEMS       = "items"
        const val RESULT_IS_ORIGINAL = "isOriginalPhoto"

        private const val REQUEST_PREVIEW   = 3001  // 长按预览请求码
        private const val ITEM_CACHE_SIZE   = 20
        private const val PRELOAD_COUNT     = 10
        private const val GRID_SPACING_DP   = 2
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    private fun resolveThemeColor(attr: Int): Int {
        val typedValue = TypedValue()
        theme.resolveAttribute(attr, typedValue, true)
        return typedValue.data
    }

    private fun resolveSelectableItemBackgroundBorderless() =
        obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackgroundBorderless)).let { attrs ->
            try { attrs.getDrawable(0) } finally { attrs.recycle() }
        }
}
