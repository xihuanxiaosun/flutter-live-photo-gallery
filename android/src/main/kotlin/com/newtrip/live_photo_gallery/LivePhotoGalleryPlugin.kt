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
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
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
 * 权限策略：
 * - pickAssets / previewAssets 调用时若无权限，自动弹系统权限框
 * - 用户授权后自动继续执行（对齐 iOS PHPhotoLibrary 行为，Flutter 侧无需手动 requestPermission）
 * - 用户拒绝后返回 PERMISSION_DENIED，Flutter 侧可引导去设置
 * - requestPermission 方法保留，供 Flutter 侧主动查询/申请使用
 */
class LivePhotoGalleryPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel

    private var context: Context? = null
    private var activity: Activity? = null
    private var activityPluginBinding: ActivityPluginBinding? = null

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    /** 每个插件实例拥有唯一 key，用于在 channel 注册表中精确索引自己的 MethodChannel */
    private val engineKey = java.util.UUID.randomUUID().toString()

    // 挂起的 Flutter 回调（AtomicReference 保证原子替换，防止竞争条件）
    private val pendingPickRef       = AtomicReference<MethodChannel.Result?>(null)
    private val pendingPreviewRef    = AtomicReference<MethodChannel.Result?>(null)
    private val pendingPermissionRef = AtomicReference<MethodChannel.Result?>(null)

    // pickAssets 触发权限申请时，暂存 args 以便权限授予后继续执行
    @Volatile private var pendingPickArgs: Map<String, Any>? = null

    // ──────────────────────────────────────────────
    // FlutterPlugin 生命周期
    // ──────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        // 以 engineKey 为索引注册 channel，多引擎场景下各实例互不干扰
        registerChannel(engineKey, channel)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        unregisterChannel(engineKey)
        scope.cancel()
        cancelAllPending()
        pendingPickArgs = null
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
    // MethodChannel 分发
    // ──────────────────────────────────────────────

    @Suppress("UNCHECKED_CAST")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickAssets"        -> pickAssets(call.arguments as? Map<String, Any> ?: emptyMap(), result)
            "previewAssets"     -> previewAssets(call.arguments as? Map<String, Any> ?: emptyMap(), result)
            "getThumbnail"      -> getThumbnail(call.arguments as? Map<String, Any> ?: emptyMap(), result)
            "exportAsset"       -> exportAsset(call.arguments as? Map<String, Any> ?: emptyMap(), result)
            "requestPermission" -> requestPermission(result)
            "cleanupTempFiles"  -> cleanupTempFiles(result)
            else                -> result.notImplemented()
        }
    }

    // ──────────────────────────────────────────────
    // pickAssets：启动宫格选图
    // 若无权限：自动弹框申请，授予后继续（对齐 iOS 行为）
    // ──────────────────────────────────────────────

    private fun pickAssets(args: Map<String, Any>, result: MethodChannel.Result) {
        val act = activity ?: run {
            result.error(ERR_INVALID_ARGS, "Activity 未就绪", null)
            return
        }

        if (!hasMediaPermission()) {
            // 暂存 result 和 args，权限回调后继续执行
            pendingPickRef.getAndSet(result)?.success(null)
            pendingPickArgs = args
            ActivityCompat.requestPermissions(act, requiredPermissions(), REQUEST_PERMISSION_FOR_PICK)
            return
        }

        launchPicker(args, act, result)
    }

    /** 真正启动 MediaPickerActivity（权限已确认） */
    private fun launchPicker(args: Map<String, Any>, act: Activity, result: MethodChannel.Result) {
        pendingPickRef.getAndSet(result)?.success(null)
        val config = PickerConfig.from(args)
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

    private fun previewAssets(args: Map<String, Any>, result: MethodChannel.Result) {
        val act = activity ?: run {
            result.error(ERR_INVALID_ARGS, "Activity 未就绪", null)
            return
        }

        pendingPreviewRef.getAndSet(result)?.success(null)

        val assetsRaw = args["assets"] as? List<*> ?: emptyList<Any>()
        val assetsArray = JSONArray()
        assetsRaw.forEach { item ->
            if (item is Map<*, *>) {
                val obj = JSONObject()
                item.forEach { (k, v) -> if (v != null) obj.put(k.toString(), v) }
                assetsArray.put(obj)
            }
        }

        val selectedRaw = args["selectedAssetIds"] as? List<*> ?: emptyList<Any>()
        val selectedArray = JSONArray().also { arr ->
            selectedRaw.forEach { arr.put(it.toString()) }
        }
        val sourceFrame = parseSourceFrame(args["sourceFrame"] as? Map<*, *>)

        act.startActivityForResult(
            Intent(act, PreviewActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
                putExtra(PreviewActivity.EXTRA_ASSETS, assetsArray.toString())
                putExtra(PreviewActivity.EXTRA_INITIAL_INDEX, (args["initialIndex"] as? Int) ?: 0)
                putExtra(PreviewActivity.EXTRA_SELECTED_IDS, selectedArray.toString())
                putExtra(PreviewActivity.EXTRA_SHOW_RADIO,      (args["showRadio"]      as? Boolean) ?: true)
                putExtra(PreviewActivity.EXTRA_DARK_MODE,       (args["isDarkMode"]     as? Boolean) ?: false)
                putExtra(PreviewActivity.EXTRA_MAX_COUNT,       (args["maxCount"]       as? Int)     ?: 9)
                putExtra(PreviewActivity.EXTRA_MAX_VIDEO_COUNT, (args["maxVideoCount"]  as? Int)     ?: -1)
                putExtra(PreviewActivity.EXTRA_AUTO_PLAY_VIDEO,      (args["autoPlayVideo"]      as? Boolean) ?: false)
                putExtra(PreviewActivity.EXTRA_SHOW_DOWNLOAD_BUTTON, (args["showDownloadButton"] as? Boolean) ?: false)
                putExtra(PreviewActivity.EXTRA_ENGINE_KEY,           engineKey)
                putExtra(PreviewActivity.EXTRA_SAVE_ALBUM_NAME,      (args["saveAlbumName"]      as? String)  ?: "")
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

    private fun getThumbnail(args: Map<String, Any>, result: MethodChannel.Result) {
        val ctx = context ?: run { result.error(ERR_INVALID_ARGS, "Context 未就绪", null); return }
        val assetId = args["assetId"] as? String ?: run { result.error(ERR_INVALID_ARGS, "缺少 assetId", null); return }
        // 对齐 iOS 默认值 200×200（iOS getThumbnail 默认 size = 200）
        val width  = (args["width"]  as? Double)?.toInt() ?: 200
        val height = (args["height"] as? Double)?.toInt() ?: 200

        scope.launch {
            val path = withContext(Dispatchers.IO) {
                runCatching {
                    val asset = MediaStoreHelper.fetchById(ctx, assetId) ?: return@withContext null
                    ExportHelper.saveThumbnail(ctx, asset, width, height)
                }.getOrNull()
            }
            when {
                path != null -> result.success(mapOf("thumbnailPath" to path))
                else         -> result.error(ERR_ASSET_LOAD_FAILED, "资源加载失败：$assetId", null)
            }
        }
    }

    // ──────────────────────────────────────────────
    // exportAsset
    // ──────────────────────────────────────────────

    private fun exportAsset(args: Map<String, Any>, result: MethodChannel.Result) {
        val ctx = context ?: run { result.error(ERR_INVALID_ARGS, "Context 未就绪", null); return }
        val assetId = args["assetId"] as? String ?: run { result.error(ERR_INVALID_ARGS, "缺少 assetId", null); return }
        val format = args["format"] as? String ?: "image"

        scope.launch {
            val filePath = withContext(Dispatchers.IO) {
                runCatching {
                    val asset = MediaStoreHelper.fetchById(ctx, assetId) ?: return@withContext null
                    when (format) {
                        "video"          -> ExportHelper.exportVideo(ctx, asset)
                        "livePhotoVideo" -> ExportHelper.exportMotionPhotoVideo(ctx, asset)
                        else             -> ExportHelper.exportImage(ctx, asset)
                    }
                }.getOrNull()
            }
            when {
                filePath != null -> result.success(mapOf("filePath" to filePath))
                format == "livePhotoVideo" ->
                    result.error(ERR_LIVE_PHOTO_ERROR, "Live Photo 视频提取失败：$assetId", null)
                else ->
                    result.error(ERR_EXPORT_FAILED, "导出失败：$assetId (format=$format)", null)
            }
        }
    }

    // ──────────────────────────────────────────────
    // requestPermission：供 Flutter 侧主动查询/申请
    // ──────────────────────────────────────────────

    private fun requestPermission(result: MethodChannel.Result) {
        val act = activity ?: run { result.error(ERR_INVALID_ARGS, "Activity 未就绪", null); return }
        val status = currentPermissionStatus()
        if (status == "authorized" || status == "limited") {
            result.success(status)
            return
        }
        // 标记为"已请求过"，供后续 currentPermissionStatus 区分 notDetermined / denied
        context?.getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
            ?.edit()?.putBoolean(PREF_KEY_PERMISSION_REQUESTED, true)?.apply()

        pendingPermissionRef.getAndSet(result)?.success("denied")
        ActivityCompat.requestPermissions(act, requiredPermissions(), REQUEST_PERMISSION)
    }

    // ──────────────────────────────────────────────
    // cleanupTempFiles
    // ──────────────────────────────────────────────

    private fun cleanupTempFiles(result: MethodChannel.Result) {
        val ctx = context ?: run { result.success(null); return }
        scope.launch {
            withContext(Dispatchers.IO) { ExportHelper.cleanup(ctx) }
            result.success(null)
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
        ref: AtomicReference<MethodChannel.Result?>,
        resultCode: Int,
        data: Intent?,
        tag: String
    ) {
        val pending = ref.getAndSet(null) ?: return

        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.success(null)
            return
        }

        try {
            val itemsJson = data.getStringExtra(MediaPickerActivity.RESULT_ITEMS) ?: "[]"
            val isOriginal = data.getBooleanExtra(MediaPickerActivity.RESULT_IS_ORIGINAL, false)
            pending.success(mapOf("items" to parseItemsJson(itemsJson), "isOriginalPhoto" to isOriginal))
        } catch (e: Exception) {
            pending.error(ERR_EXPORT_FAILED, "解析${tag}结果失败：${e.message}", null)
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
        val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }

        return when (requestCode) {

            // pickAssets 触发的权限申请
            REQUEST_PERMISSION_FOR_PICK -> {
                val args = pendingPickArgs
                pendingPickArgs = null

                if (granted && args != null) {
                    val act = activity
                    val capturedResult = pendingPickRef.getAndSet(null)   // 原子取出，清空 ref
                    if (act != null && capturedResult != null) {
                        launchPicker(args, act, capturedResult)  // launchPicker 内部会重新存入
                    } else {
                        capturedResult?.success(null)
                    }
                } else {
                    pendingPickRef.getAndSet(null)?.error(
                        ERR_PERMISSION_DENIED, "用户拒绝了相册权限，请前往设置开启", null
                    )
                }
                true
            }

            // requestPermission 主动调用
            REQUEST_PERMISSION -> {
                val pending = pendingPermissionRef.getAndSet(null) ?: return true
                // 标记已请求
                context?.getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
                    ?.edit()?.putBoolean(PREF_KEY_PERMISSION_REQUESTED, true)?.apply()
                // 授权成功时再查一次，可能是 "authorized" 或 "limited"
                pending.success(if (granted) currentPermissionStatus() else "denied")
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
     *   "authorized"    — 完整权限
     *   "limited"       — 部分权限（Android 14+ READ_MEDIA_VISUAL_USER_SELECTED）
     *   "denied"        — 拒绝
     *   "notDetermined" — 首次尚未弹框（Android 近似：权限从未被请求过）
     */
    private fun currentPermissionStatus(): String {
        val ctx = context ?: return "denied"

        // Android 14+（API 34）：检查部分访问权限
        if (Build.VERSION.SDK_INT >= 34) {
            val visualUserSelected = ContextCompat.checkSelfPermission(
                ctx, android.Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
            )
            if (visualUserSelected == PackageManager.PERMISSION_GRANTED) return "limited"
        }

        // 完整权限
        if (hasMediaPermission()) return "authorized"

        // 区分 "notDetermined"（从未请求）与 "denied"（拒绝过）
        // shouldShowRequestPermissionRationale = false 且无权限 → 两种可能：
        //   1. 从未请求（首次）  2. 永久拒绝（Don't ask again）
        // Android 无法精确区分，采用近似：用 SharedPreferences 记录是否已请求过
        val prefs = ctx.getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
        val hasRequested = prefs.getBoolean(PREF_KEY_PERMISSION_REQUESTED, false)
        return if (hasRequested) "denied" else "notDetermined"
    }

    private fun hasMediaPermission(): Boolean {
        val ctx = context ?: return false
        return requiredPermissions().all {
            ContextCompat.checkSelfPermission(ctx, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requiredPermissions(): Array<String> = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->  // API 33+
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
        // 注意：此时 Engine 已 detach，调用 error() 存在 crash 风险，故保留 success(null)
        pendingPickRef.getAndSet(null)?.success(null)
        pendingPreviewRef.getAndSet(null)?.success(null)
        pendingPermissionRef.getAndSet(null)?.success(null)
    }

    private fun parseSourceFrame(dict: Map<*, *>?): RectF? {
        dict ?: return null
        val density = (activity ?: context)?.resources?.displayMetrics?.density ?: 1f
        val x = ((dict["x"] as? Number)?.toFloat() ?: return null) * density
        val y = ((dict["y"] as? Number)?.toFloat() ?: return null) * density
        val width = ((dict["width"] as? Number)?.toFloat() ?: return null) * density
        val height = ((dict["height"] as? Number)?.toFloat() ?: return null) * density
        if (width <= 0f || height <= 0f) return null
        return RectF(x, y, x + width, y + height)
    }

    private fun parseItemsJson(json: String): List<Map<String, Any>> {
        val arr = JSONArray(json)
        return (0 until arr.length()).map { i ->
            val obj = arr.getJSONObject(i)
            buildMap {
                val mediaType = obj.optString("mediaType")
                put("assetId",       obj.optString("assetId"))
                put("mediaType",     mediaType)
                put("thumbnailPath", obj.optString("thumbnailPath"))
                if (mediaType == "video" && obj.has("duration") && !obj.isNull("duration")) {
                    put("duration", obj.optDouble("duration", 0.0))
                }
                put("width",         obj.optInt("width", 0))
                put("height",        obj.optInt("height", 0))
            }
        }
    }

    // ──────────────────────────────────────────────
    // 常量
    // ──────────────────────────────────────────────

    companion object {
        const val CHANNEL_NAME = "com.newtrip.yingYbirds/live_photo"

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

        // ── 多引擎安全的 channel 注册表 ─────────────────────────────
        // 每个插件实例以 UUID engineKey 注册自己的 MethodChannel（WeakReference 防止泄漏）。
        // PreviewActivity 启动时通过 EXTRA_ENGINE_KEY 携带 key，回调时精确查找对应 channel，
        // 彻底避免多 FlutterEngine 场景下 activeChannel 被后续 Engine 覆盖的问题。
        private val channelRegistry =
            java.util.concurrent.ConcurrentHashMap<String, java.lang.ref.WeakReference<MethodChannel>>()

        internal fun registerChannel(key: String, channel: MethodChannel) {
            channelRegistry[key] = java.lang.ref.WeakReference(channel)
        }

        internal fun unregisterChannel(key: String) {
            channelRegistry.remove(key)
        }

        /** PreviewActivity 通过此方法获取对应 engine 的 MethodChannel 进行回调 */
        internal fun getChannel(key: String): MethodChannel? = channelRegistry[key]?.get()
    }
}
