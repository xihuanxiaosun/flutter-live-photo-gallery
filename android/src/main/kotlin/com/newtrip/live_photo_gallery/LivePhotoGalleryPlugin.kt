package com.newtrip.live_photo_gallery

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.RectF
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicReference

/**
 * Android 插件主入口
 *
 * 跨端契约由 pigeons/messages.dart 生成（Messages.g.kt），本类实现生成的
 * [LivePhotoGalleryHostApi]；native → Flutter 的三个事件走生成的
 * [LivePhotoGalleryFlutterApi]。生成类型（Pg*）只在本类边界出现，
 * Activity / UI 层继续消费原有的 map / JSON 形状。
 *
 * 权限策略：
 * - pickAssets / previewAssets 调用时若无权限，自动弹系统权限框
 * - 用户授权后自动继续执行（对齐 iOS PHPhotoLibrary 行为，Flutter 侧无需手动 requestPermission）
 * - 用户拒绝后返回 PERMISSION_DENIED，Flutter 侧可引导去设置
 * - requestPermission 方法保留，供 Flutter 侧主动查询/申请使用
 */
class LivePhotoGalleryPlugin : FlutterPlugin, LivePhotoGalleryHostApi, ActivityAware,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {

    /** 强引用持有，注册表里存的是它的 WeakReference（生命周期与本插件实例一致） */
    private var flutterApi: LivePhotoGalleryFlutterApi? = null

    private var context: Context? = null
    private var activity: Activity? = null
    private var activityPluginBinding: ActivityPluginBinding? = null

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    /** 每个插件实例拥有唯一 key，用于在 FlutterApi 注册表中精确索引自己的回调通道 */
    private val engineKey = java.util.UUID.randomUUID().toString()

    // 挂起的 Flutter 回调（AtomicReference 保证原子替换，防止竞争条件）
    private val pendingPickRef       = AtomicReference<PickCallback?>(null)
    private val pendingPreviewRef    = AtomicReference<PickCallback?>(null)
    private val pendingPermissionRef = AtomicReference<PermissionCallback?>(null)

    // pickAssets 触发权限申请时，暂存 config 以便权限授予后继续执行
    @Volatile private var pendingPickConfig: PgPickerConfig? = null

    // ──────────────────────────────────────────────
    // FlutterPlugin 生命周期
    // ──────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        LivePhotoGalleryHostApi.setUp(binding.binaryMessenger, this)
        val api = LivePhotoGalleryFlutterApi(binding.binaryMessenger)
        flutterApi = api
        // 以 engineKey 为索引注册，多引擎场景下各实例互不干扰
        registerFlutterApi(engineKey, api)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        LivePhotoGalleryHostApi.setUp(binding.binaryMessenger, null)
        unregisterFlutterApi(engineKey)
        flutterApi = null
        scope.cancel()
        cancelAllPending()
        pendingPickConfig = null
        context = null
    }

    // ──────────────────────────────────────────────
    // ActivityAware 生命周期
    // ──────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityPluginBinding = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityPluginBinding?.removeActivityResultListener(this)
        activityPluginBinding?.removeRequestPermissionsResultListener(this)
        activityPluginBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        // 先从旧 binding 移除，再绑定新的，防止重复注册
        activityPluginBinding?.removeActivityResultListener(this)
        activityPluginBinding?.removeRequestPermissionsResultListener(this)
        activity = binding.activity
        activityPluginBinding = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityPluginBinding?.removeActivityResultListener(this)
        activityPluginBinding?.removeRequestPermissionsResultListener(this)
        activityPluginBinding = null
        activity = null
    }

    // ──────────────────────────────────────────────
    // pickAssets：启动宫格选图
    // 若无权限：自动弹框申请，授予后继续（对齐 iOS 行为）
    // ──────────────────────────────────────────────

    override fun pickAssets(config: PgPickerConfig, callback: PickCallback) {
        val act = activity ?: run {
            callback(Result.failure(FlutterError(ERR_INVALID_ARGS, "Activity 未就绪", null)))
            return
        }

        if (!hasMediaPermission()) {
            // 暂存 callback 和 config，权限回调后继续执行
            pendingPickRef.getAndSet(callback)?.invoke(Result.success(null))
            pendingPickConfig = config
            ActivityCompat.requestPermissions(act, requiredPermissions(), REQUEST_PERMISSION_FOR_PICK)
            return
        }

        launchPicker(config, act, callback)
    }

    /** 真正启动 MediaPickerActivity（权限已确认） */
    private fun launchPicker(pgConfig: PgPickerConfig, act: Activity, callback: PickCallback) {
        pendingPickRef.getAndSet(callback)?.invoke(Result.success(null))
        val config = pgConfig.toPickerConfig()
        act.startActivityForResult(
            Intent(act, MediaPickerActivity::class.java).apply {
                putExtra(MediaPickerActivity.EXTRA_CONFIG,     PickerConfig.toJson(config))
                putExtra(MediaPickerActivity.EXTRA_ENGINE_KEY, engineKey)
            },
            REQUEST_PICK
        )
    }

    // ──────────────────────────────────────────────
    // previewAssets：启动资源预览
    // ──────────────────────────────────────────────

    override fun previewAssets(request: PgPreviewRequest, callback: PickCallback) {
        val act = activity ?: run {
            callback(Result.failure(FlutterError(ERR_INVALID_ARGS, "Activity 未就绪", null)))
            return
        }

        pendingPreviewRef.getAndSet(callback)?.invoke(Result.success(null))

        // Pg 传输对象 → Activity 侧仍消费的 JSON 形状（null 字段不写入，与此前一致）
        val assetsArray = JSONArray()
        request.assets.forEach { asset ->
            assetsArray.put(JSONObject().apply {
                put("type", asset.type.wire)
                asset.assetId?.let  { put("assetId", it) }
                asset.url?.let      { put("url", it) }
                asset.mediaType?.let { put("mediaType", it.wire) }
                asset.videoUrl?.let { put("videoUrl", it) }
                asset.duration?.let { put("duration", it) }
            })
        }

        val selectedArray = JSONArray().also { arr ->
            request.selectedAssetIds.forEach { arr.put(it) }
        }
        val sourceFrame = toRectF(request.sourceFrame)
        val config = request.config

        act.startActivityForResult(
            Intent(act, PreviewActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
                putExtra(PreviewActivity.EXTRA_ASSETS, assetsArray.toString())
                putExtra(PreviewActivity.EXTRA_INITIAL_INDEX, request.initialIndex.toInt())
                putExtra(PreviewActivity.EXTRA_SELECTED_IDS, selectedArray.toString())
                putExtra(PreviewActivity.EXTRA_SHOW_RADIO,      config.showRadio)
                putExtra(PreviewActivity.EXTRA_DARK_MODE,       config.isDarkMode)
                putExtra(PreviewActivity.EXTRA_MAX_COUNT,       config.maxCount.toInt())
                putExtra(PreviewActivity.EXTRA_MAX_VIDEO_COUNT, config.maxVideoCount.toInt())
                // autoPlayVideo 不在跨端契约中（Dart 侧从未下发），保持默认 false
                putExtra(PreviewActivity.EXTRA_AUTO_PLAY_VIDEO,      false)
                putExtra(PreviewActivity.EXTRA_SHOW_DOWNLOAD_BUTTON, request.showDownloadButton)
                putExtra(PreviewActivity.EXTRA_ENGINE_KEY,           engineKey)
                putExtra(PreviewActivity.EXTRA_SAVE_ALBUM_NAME,      request.saveAlbumName)
                if (sourceFrame != null) {
                    putExtra(PreviewActivity.EXTRA_SOURCE_LEFT, sourceFrame.left)
                    putExtra(PreviewActivity.EXTRA_SOURCE_TOP, sourceFrame.top)
                    putExtra(PreviewActivity.EXTRA_SOURCE_WIDTH, sourceFrame.width())
                    putExtra(PreviewActivity.EXTRA_SOURCE_HEIGHT, sourceFrame.height())
                }
            },
            REQUEST_PREVIEW
        )
        act.overridePendingTransition(0, 0)
    }

    // ──────────────────────────────────────────────
    // getThumbnail
    // ──────────────────────────────────────────────

    override fun getThumbnail(
        assetId: String,
        width: Double,
        height: Double,
        callback: (Result<String?>) -> Unit
    ) {
        val ctx = context ?: run {
            callback(Result.failure(FlutterError(ERR_INVALID_ARGS, "Context 未就绪", null)))
            return
        }
        // 对齐 iOS 默认值 200×200（默认值由 Dart 门面提供）
        val w = width.toInt()
        val h = height.toInt()

        scope.launch {
            val path = withContext(Dispatchers.IO) {
                runCatching {
                    val asset = MediaStoreHelper.fetchById(ctx, assetId) ?: return@withContext null
                    ExportHelper.saveThumbnail(ctx, asset, w, h)
                }.getOrNull()
            }
            when {
                path != null -> callback(Result.success(path))
                else         -> callback(Result.failure(
                    FlutterError(ERR_ASSET_LOAD_FAILED, "资源加载失败：$assetId", null)
                ))
            }
        }
    }

    // ──────────────────────────────────────────────
    // exportAsset
    // ──────────────────────────────────────────────

    override fun exportAsset(
        assetId: String,
        format: PgExportFormat,
        callback: (Result<String?>) -> Unit
    ) {
        val ctx = context ?: run {
            callback(Result.failure(FlutterError(ERR_INVALID_ARGS, "Context 未就绪", null)))
            return
        }

        scope.launch {
            val filePath = withContext(Dispatchers.IO) {
                runCatching {
                    val asset = MediaStoreHelper.fetchById(ctx, assetId) ?: return@withContext null
                    when (format) {
                        PgExportFormat.VIDEO            -> ExportHelper.exportVideo(ctx, asset)
                        PgExportFormat.LIVE_PHOTO_VIDEO -> ExportHelper.exportMotionPhotoVideo(ctx, asset)
                        PgExportFormat.IMAGE            -> ExportHelper.exportImage(ctx, asset)
                    }
                }.getOrNull()
            }
            when {
                filePath != null -> callback(Result.success(filePath))
                format == PgExportFormat.LIVE_PHOTO_VIDEO -> callback(Result.failure(
                    FlutterError(ERR_LIVE_PHOTO_ERROR, "Live Photo 视频提取失败：$assetId", null)
                ))
                else -> callback(Result.failure(
                    FlutterError(ERR_EXPORT_FAILED, "导出失败：$assetId (format=${format.wire})", null)
                ))
            }
        }
    }

    // ──────────────────────────────────────────────
    // requestPermission：供 Flutter 侧主动查询/申请
    // ──────────────────────────────────────────────

    override fun requestPermission(callback: PermissionCallback) {
        val act = activity ?: run {
            callback(Result.failure(FlutterError(ERR_INVALID_ARGS, "Activity 未就绪", null)))
            return
        }
        val status = currentPermissionStatus()
        if (status == PgPermissionStatus.AUTHORIZED || status == PgPermissionStatus.LIMITED) {
            callback(Result.success(status))
            return
        }
        // 标记为"已请求过"，供后续 currentPermissionStatus 区分 notDetermined / denied
        context?.getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
            ?.edit()?.putBoolean(PREF_KEY_PERMISSION_REQUESTED, true)?.apply()

        pendingPermissionRef.getAndSet(callback)?.invoke(Result.success(PgPermissionStatus.DENIED))
        ActivityCompat.requestPermissions(act, requiredPermissions(), REQUEST_PERMISSION)
    }

    // ──────────────────────────────────────────────
    // cleanupTempFiles
    // ──────────────────────────────────────────────

    override fun cleanupTempFiles(callback: (Result<Unit>) -> Unit) {
        val ctx = context ?: run { callback(Result.success(Unit)); return }
        scope.launch {
            withContext(Dispatchers.IO) { ExportHelper.cleanup(ctx) }
            callback(Result.success(Unit))
        }
    }

    // ──────────────────────────────────────────────
    // Activity result 回调
    // ──────────────────────────────────────────────

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        return when (requestCode) {
            REQUEST_PICK    -> { handleActivityResult(pendingPickRef,    resultCode, data, "选图"); true }
            REQUEST_PREVIEW -> { handleActivityResult(pendingPreviewRef, resultCode, data, "预览"); true }
            else            -> false
        }
    }

    private fun handleActivityResult(
        ref: AtomicReference<PickCallback?>,
        resultCode: Int,
        data: Intent?,
        tag: String
    ) {
        val pending = ref.getAndSet(null) ?: return

        if (resultCode != Activity.RESULT_OK || data == null) {
            pending(Result.success(null))
            return
        }

        try {
            val itemsJson = data.getStringExtra(MediaPickerActivity.RESULT_ITEMS) ?: "[]"
            val isOriginal = data.getBooleanExtra(MediaPickerActivity.RESULT_IS_ORIGINAL, false)
            pending(Result.success(
                PgPickResult(items = parseItemsJson(itemsJson), isOriginalPhoto = isOriginal)
            ))
        } catch (e: Exception) {
            pending(Result.failure(
                FlutterError(ERR_EXPORT_FAILED, "解析${tag}结果失败：${e.message}", null)
            ))
        }
    }

    // ──────────────────────────────────────────────
    // 权限请求回调
    // ──────────────────────────────────────────────

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        // 用实际权限状态判断「是否可用」，而非要求所有请求项全部授予：
        // Android 14「仅选择照片」只会授予 VISUAL_USER_SELECTED，grantResults.all{} 会误判为拒绝，
        // 导致 picker 打不开。hasMediaPermission() 已把「部分访问」也算作可用。
        val granted = hasMediaPermission()

        return when (requestCode) {

            // pickAssets 触发的权限申请
            REQUEST_PERMISSION_FOR_PICK -> {
                val config = pendingPickConfig
                pendingPickConfig = null

                if (granted && config != null) {
                    val act = activity
                    val capturedCallback = pendingPickRef.getAndSet(null)   // 原子取出，清空 ref
                    if (act != null && capturedCallback != null) {
                        launchPicker(config, act, capturedCallback)  // launchPicker 内部会重新存入
                    } else {
                        capturedCallback?.invoke(Result.success(null))
                    }
                } else {
                    pendingPickRef.getAndSet(null)?.invoke(Result.failure(
                        FlutterError(ERR_PERMISSION_DENIED, "用户拒绝了相册权限，请前往设置开启", null)
                    ))
                }
                true
            }

            // requestPermission 主动调用
            REQUEST_PERMISSION -> {
                val pending = pendingPermissionRef.getAndSet(null) ?: return true
                // 标记已请求
                context?.getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
                    ?.edit()?.putBoolean(PREF_KEY_PERMISSION_REQUESTED, true)?.apply()
                // 授权成功时再查一次，可能是 authorized 或 limited
                pending(Result.success(
                    if (granted) currentPermissionStatus() else PgPermissionStatus.DENIED
                ))
                true
            }

            else -> false
        }
    }

    // ──────────────────────────────────────────────
    // 工具方法
    // ──────────────────────────────────────────────

    /**
     * 查询当前相册权限状态，对齐 iOS 的四种返回值：
     *   AUTHORIZED     — 完整权限
     *   LIMITED        — 部分权限（Android 14+ READ_MEDIA_VISUAL_USER_SELECTED）
     *   DENIED         — 拒绝
     *   NOT_DETERMINED — 首次尚未弹框（Android 近似：权限从未被请求过）
     */
    private fun currentPermissionStatus(): PgPermissionStatus {
        val ctx = context ?: return PgPermissionStatus.DENIED

        // Android 14+（API 34）：先判「完整访问」，再判「部分/仅选择的照片」。
        // 顺序不能反——完整访问时系统也可能报告 VISUAL_USER_SELECTED 为已授予，
        // 若先判部分会把完整权限误判为 limited。
        if (Build.VERSION.SDK_INT >= 34) {
            val fullAccess =
                ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.READ_MEDIA_VIDEO) == PackageManager.PERMISSION_GRANTED
            if (fullAccess) return PgPermissionStatus.AUTHORIZED
            val visualUserSelected = ContextCompat.checkSelfPermission(
                ctx, android.Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
            )
            if (visualUserSelected == PackageManager.PERMISSION_GRANTED) return PgPermissionStatus.LIMITED
        } else if (hasMediaPermission()) {
            return PgPermissionStatus.AUTHORIZED
        }

        // 区分 NOT_DETERMINED（从未请求）与 DENIED（拒绝过）
        // shouldShowRequestPermissionRationale = false 且无权限 → 两种可能：
        //   1. 从未请求（首次）  2. 永久拒绝（Don't ask again）
        // Android 无法精确区分，采用近似：用 SharedPreferences 记录是否已请求过
        val prefs = ctx.getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
        val hasRequested = prefs.getBoolean(PREF_KEY_PERMISSION_REQUESTED, false)
        return if (hasRequested) PgPermissionStatus.DENIED else PgPermissionStatus.NOT_DETERMINED
    }

    /**
     * 是否已获得「可用的」相册访问权限。
     * Android 14+：完整（IMAGES + VIDEO）**或** 部分（仅选择的照片 VISUAL_USER_SELECTED）
     * 都视为可用；否则「仅选择照片」模式会因这里返回 false 而反复弹窗、picker 永远打不开。
     */
    private fun hasMediaPermission(): Boolean {
        val ctx = context ?: return false
        fun granted(p: String) =
            ContextCompat.checkSelfPermission(ctx, p) == PackageManager.PERMISSION_GRANTED
        return when {
            Build.VERSION.SDK_INT >= 34 ->
                (granted(Manifest.permission.READ_MEDIA_IMAGES) &&
                    granted(Manifest.permission.READ_MEDIA_VIDEO)) ||
                    granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
            else ->
                requiredPermissions().all { granted(it) }
        }
    }

    private fun requiredPermissions(): Array<String> = when {
        Build.VERSION.SDK_INT >= 34 ->                             // Android 14+：支持「仅选择的照片」部分访问
            arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VIDEO,
                Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            )
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->  // API 33
            arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ->          // API 29-32
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        else ->                                                     // API 21-28：写 MediaStore 也需要 WRITE
            arrayOf(
                Manifest.permission.READ_EXTERNAL_STORAGE,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
            )
    }

    private fun cancelAllPending() {
        // Engine 销毁时以 success(null) 结束挂起请求（对齐 iOS 取消语义，null = 用户取消/无结果）
        // 注意：此时 Engine 已 detach，回传 failure 存在 crash 风险，故保留 success(null)
        pendingPickRef.getAndSet(null)?.invoke(Result.success(null))
        pendingPreviewRef.getAndSet(null)?.invoke(Result.success(null))
        pendingPermissionRef.getAndSet(null)?.invoke(Result.success(PgPermissionStatus.DENIED))
    }

    /** 逻辑像素 → 物理像素；宽高非正（如 Rect.zero）视为「无转场锚点」返回 null */
    private fun toRectF(frame: PgRect): RectF? {
        val density = (activity ?: context)?.resources?.displayMetrics?.density ?: 1f
        val x = frame.x.toFloat() * density
        val y = frame.y.toFloat() * density
        val width = frame.width.toFloat() * density
        val height = frame.height.toFloat() * density
        if (width <= 0f || height <= 0f) return null
        return RectF(x, y, x + width, y + height)
    }

    private fun parseItemsJson(json: String): List<PgMediaItem> {
        val arr = JSONArray(json)
        return (0 until arr.length()).map { i ->
            val obj = arr.getJSONObject(i)
            val mediaType = obj.optString("mediaType")
            PgMediaItem(
                assetId       = obj.optString("assetId"),
                mediaType     = pgMediaTypeOf(mediaType),
                thumbnailPath = obj.optString("thumbnailPath"),
                duration      = if (mediaType == "video" && obj.has("duration") && !obj.isNull("duration")) {
                    obj.optDouble("duration", 0.0)
                } else null,
                width         = obj.optInt("width", 0).toLong(),
                height        = obj.optInt("height", 0).toLong(),
            )
        }
    }

    // ──────────────────────────────────────────────
    // 常量
    // ──────────────────────────────────────────────

    companion object {
        private const val REQUEST_PICK                = 2001
        private const val REQUEST_PREVIEW             = 2002
        private const val REQUEST_PERMISSION          = 2003  // requestPermission 主动调用
        private const val REQUEST_PERMISSION_FOR_PICK = 2004  // pickAssets 触发的自动申请

        // 错误码对齐 iOS，Flutter 侧可统一 catch
        const val ERR_PERMISSION_DENIED  = "PERMISSION_DENIED"
        const val ERR_ASSET_NOT_FOUND    = "ASSET_NOT_FOUND"
        const val ERR_EXPORT_FAILED      = "EXPORT_FAILED"
        const val ERR_INVALID_ARGS       = "INVALID_ARGS"
        const val ERR_ASSET_LOAD_FAILED  = "ASSET_LOAD_FAILED"  // 对齐 iOS
        const val ERR_LIVE_PHOTO_ERROR   = "LIVE_PHOTO_ERROR"   // 对齐 iOS
        const val ERR_SAVE_FAILED        = "SAVE_FAILED"        // 对齐 iOS

        // 权限状态持久化（区分 notDetermined / denied）
        private const val PREFS_NAME                    = "live_photo_gallery_prefs"
        private const val PREF_KEY_PERMISSION_REQUESTED = "permission_requested"

        // ── 多引擎安全的回调通道注册表 ─────────────────────────────
        // 每个插件实例以 UUID engineKey 注册自己的 LivePhotoGalleryFlutterApi
        //（WeakReference 防止泄漏，强引用由插件实例持有）。
        // PreviewActivity / MediaPickerActivity 启动时通过 EXTRA_ENGINE_KEY 携带 key，
        // 回调时精确查找对应实例，彻底避免多 FlutterEngine 场景下被后续 Engine 覆盖的问题。
        private val flutterApiRegistry =
            java.util.concurrent.ConcurrentHashMap<String, java.lang.ref.WeakReference<LivePhotoGalleryFlutterApi>>()

        internal fun registerFlutterApi(key: String, api: LivePhotoGalleryFlutterApi) {
            flutterApiRegistry[key] = java.lang.ref.WeakReference(api)
        }

        internal fun unregisterFlutterApi(key: String) {
            flutterApiRegistry.remove(key)
        }

        /** Activity 通过此方法获取对应 engine 的事件通道进行回调（须在主线程调用） */
        internal fun getFlutterApi(key: String): LivePhotoGalleryFlutterApi? =
            flutterApiRegistry[key]?.get()
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// pigeon 生成类型 ↔ 既有 native 模型的边界转换
// （生成类型只在插件入口出现，Activity / UI 层保持原有 map / JSON 形状不变）
// ──────────────────────────────────────────────────────────────────────────────

/** [LivePhotoGalleryHostApi.pickAssets] / [LivePhotoGalleryHostApi.previewAssets] 的回调类型别名 */
internal typealias PickCallback = (Result<PgPickResult?>) -> Unit

/** [LivePhotoGalleryHostApi.requestPermission] 的回调类型别名 */
internal typealias PermissionCallback = (Result<PgPermissionStatus>) -> Unit

/** 契约枚举 → 既有 native 代码消费的字符串（两端字面量此前靠人工对齐，现由枚举收口） */
internal val PgMediaFilter.wire: String get() = when (this) {
    PgMediaFilter.ALL             -> "all"
    PgMediaFilter.IMAGE_ONLY      -> "imageOnly"
    PgMediaFilter.VIDEO_ONLY      -> "videoOnly"
    PgMediaFilter.LIVE_PHOTO_ONLY -> "livePhotoOnly"
}

internal val PgMediaType.wire: String get() = when (this) {
    PgMediaType.IMAGE      -> "image"
    PgMediaType.VIDEO      -> "video"
    PgMediaType.LIVE_PHOTO -> "livePhoto"
}

internal val PgAssetSource.wire: String get() = when (this) {
    PgAssetSource.LOCAL   -> "local"
    PgAssetSource.NETWORK -> "network"
}

internal val PgExportFormat.wire: String get() = when (this) {
    PgExportFormat.IMAGE            -> "image"
    PgExportFormat.VIDEO            -> "video"
    PgExportFormat.LIVE_PHOTO_VIDEO -> "livePhotoVideo"
}

/** 结果 JSON 中的 mediaType 字符串 → 契约枚举；未知值归一到 IMAGE（对齐 Dart 侧原有默认） */
internal fun pgMediaTypeOf(raw: String?): PgMediaType = when (raw) {
    "video"     -> PgMediaType.VIDEO
    "livePhoto" -> PgMediaType.LIVE_PHOTO
    else        -> PgMediaType.IMAGE
}

/** 下载失败码字符串 → 契约枚举；未知值归一到 UNKNOWN（保持此前 Dart 侧 fromString 的兜底语义） */
internal fun pgDownloadErrorCodeOf(raw: String?): PgDownloadErrorCode = when (raw) {
    "PERMISSION_DENIED" -> PgDownloadErrorCode.PERMISSION_DENIED
    "NETWORK_ERROR"     -> PgDownloadErrorCode.NETWORK_ERROR
    "SAVE_FAILED"       -> PgDownloadErrorCode.SAVE_FAILED
    else                -> PgDownloadErrorCode.UNKNOWN
}

/** 契约配置 → 既有的 [PickerConfig]（沿用其归一化逻辑，Activity 侧完全不变） */
internal fun PgPickerConfig.toPickerConfig(): PickerConfig = PickerConfig.from(
    mapOf(
        "maxCount"         to maxCount.toInt(),
        "enableVideo"      to enableVideo,
        "enableLivePhoto"  to enableLivePhoto,
        "showRadio"        to showRadio,
        "isDarkMode"       to isDarkMode,
        "maxVideoCount"    to maxVideoCount.toInt(),
        "videoMaxDuration" to videoMaxDuration,
        "filterConfig"     to filterConfig.wire,
    )
)
