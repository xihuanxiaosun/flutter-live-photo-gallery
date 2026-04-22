package com.newtrip.live_photo_gallery

import android.animation.ObjectAnimator
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Rect
import android.graphics.drawable.ColorDrawable
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import java.io.File
import androidx.recyclerview.widget.AsyncListDiffer
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.RecyclerView
import com.bumptech.glide.Glide
import com.bumptech.glide.load.engine.DiskCacheStrategy
import com.bumptech.glide.load.resource.drawable.DrawableTransitionOptions

/**
 * 媒体网格适配器
 *
 * 性能优化：
 * - DiffUtil 替代 notifyDataSetChanged，仅刷新变化的 item
 * - PAYLOAD_SELECTION：选中状态局部刷新，不重载图片（防闪烁）
 * - Glide crossFade(100ms) 替代 dontAnimate：初次加载有淡入，滚动复用无动画
 * - onViewRecycled 及时取消 Glide 请求，防止图片错位
 * - ObjectAnimator 驱动选中遮罩 alpha，与 iOS crossDissolve 体验对齐
 */
class MediaGridAdapter : RecyclerView.Adapter<MediaGridAdapter.MediaViewHolder>() {

    private val differ = AsyncListDiffer(this, AssetDiffCallback)
    var selectedAssets: List<MediaAsset> = emptyList()
        set(value) {
            field = value
            selectedIndexById = value.mapIndexed { index, asset -> asset.id to index }.toMap()
        }
    var editedPathByAssetId: Map<String, String> = emptyMap()
        set(value) {
            field = value
            notifyDataSetChanged()
        }
    var showSelectionControls: Boolean = true
    var onItemClick:     ((MediaAsset, Int) -> Unit)? = null
    var onItemLongClick: ((MediaAsset, Int) -> Unit)? = null  // 长按预览
    var onSelectionClick: ((MediaAsset, Int) -> Unit)? = null
    private var selectedIndexById: Map<Long, Int> = emptyMap()

    init {
        setHasStableIds(true)
    }

    // ──────────────────────────────────────────────
    // 数据更新（DiffUtil）
    // ──────────────────────────────────────────────

    /**
     * 提交新数据列表，AsyncListDiffer 在后台线程异步计算 diff，主线程无阻塞。
     * 首次加载（从空列表到全量）时 AsyncListDiffer 内部自动使用 notifyDataSetChanged，
     * 增量更新时使用 DiffUtil 的精细 dispatch，无需手动区分。
     */
    fun submitList(newAssets: List<MediaAsset>) {
        differ.submitList(newAssets)
    }

    // ──────────────────────────────────────────────
    // Adapter 标准实现
    // ──────────────────────────────────────────────

    override fun getItemCount(): Int = differ.currentList.size

    override fun getItemId(position: Int): Long =
        differ.currentList.getOrNull(position)?.id ?: RecyclerView.NO_ID.toLong()

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): MediaViewHolder {
        val nightMode = parent.context.resources.configuration.uiMode and
            Configuration.UI_MODE_NIGHT_MASK
        val placeholder = ColorDrawable(
            if (nightMode == Configuration.UI_MODE_NIGHT_YES)
                Color.parseColor("#2C2C2E") else Color.parseColor("#F2F2F7")
        )
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_media_cell, parent, false)
        val holder = MediaViewHolder(view, placeholder)
        // 移到这里：一次性设置，避免每次 bind 时重建 lambda
        holder.itemView.setOnClickListener {
            val pos = holder.bindingAdapterPosition
            if (pos != RecyclerView.NO_POSITION) {
                val asset = differ.currentList.getOrNull(pos) ?: return@setOnClickListener
                onItemClick?.invoke(asset, pos)
            }
        }
        holder.itemView.setOnLongClickListener {
            val pos = holder.bindingAdapterPosition
            if (pos != RecyclerView.NO_POSITION) {
                val asset = differ.currentList.getOrNull(pos) ?: return@setOnLongClickListener false
                onItemLongClick?.invoke(asset, pos)
                true
            } else false
        }
        holder.selectionCircle.setOnClickListener {
            val pos = holder.bindingAdapterPosition
            if (pos != RecyclerView.NO_POSITION) {
                val asset = differ.currentList.getOrNull(pos) ?: return@setOnClickListener
                onSelectionClick?.invoke(asset, pos)
            }
        }
        return holder
    }

    override fun onBindViewHolder(holder: MediaViewHolder, position: Int) {
        val asset = differ.currentList.getOrNull(position) ?: return
        holder.bind(asset)
    }

    /** Payload 局部刷新：仅更新选中状态，不重载图片 */
    override fun onBindViewHolder(
        holder: MediaViewHolder,
        position: Int,
        payloads: MutableList<Any>
    ) {
        if (payloads.contains(PAYLOAD_SELECTION)) {
            val asset = differ.currentList.getOrNull(position) ?: return
            holder.updateSelectionOnly(asset, animated = true)
        } else {
            super.onBindViewHolder(holder, position, payloads)
        }
    }

    override fun onViewRecycled(holder: MediaViewHolder) {
        super.onViewRecycled(holder)
        Glide.with(holder.itemView.context).clear(holder.imageView)
    }

    /** 外部调用：仅触发选中状态局部刷新（不重绘图片） */
    fun updateSelectionState(position: Int) {
        notifyItemChanged(position, PAYLOAD_SELECTION)
    }

    // ──────────────────────────────────────────────
    // ViewHolder
    // ──────────────────────────────────────────────

    inner class MediaViewHolder(itemView: View, private val placeholder: ColorDrawable) : RecyclerView.ViewHolder(itemView) {
        val imageView: ImageView      = itemView.findViewById(R.id.iv_thumbnail)
        private val selectedOverlay: View    = itemView.findViewById(R.id.v_selected_overlay)
        private val durationBadge: TextView  = itemView.findViewById(R.id.tv_duration)
        private val motionBadge: TextView    = itemView.findViewById(R.id.tv_live_badge)
        val selectionCircle: TextView = itemView.findViewById(R.id.tv_selection_number)
        private val playIcon: View           = itemView.findViewById(R.id.iv_play_icon)

        // 记录上一次 alpha，避免重复触发动画
        private var lastOverlayAlpha = 0f

        fun bind(asset: MediaAsset) {
            val editedPath = editedPathByAssetId[asset.uri.toString()]
            val loadTarget: Any = if (!editedPath.isNullOrBlank()) File(editedPath) else asset.uri
            // crossFade(100ms)：首次加载（placeholder→图片）有淡入，缓存命中时无动画（防滚动闪烁）
            Glide.with(itemView.context)
                .load(loadTarget)
                .centerCrop()
                .placeholder(placeholder)  // 在 onCreateViewHolder 里按主题缓存，此处直接复用
                .diskCacheStrategy(DiskCacheStrategy.RESOURCE)
                .transition(DrawableTransitionOptions.withCrossFade(100))
                .into(imageView)

            // 视频时长 + 播放图标
            if (asset.mediaType == "video" && asset.duration > 0) {
                durationBadge.visibility = View.VISIBLE
                durationBadge.text = formatDuration(asset.duration)
                playIcon.visibility = View.VISIBLE
            } else {
                durationBadge.visibility = View.GONE
                playIcon.visibility = View.GONE
            }

            // 动态照片标签
            motionBadge.visibility = if (asset.isMotionPhoto) View.VISIBLE else View.GONE
            selectionCircle.visibility = if (showSelectionControls) View.VISIBLE else View.GONE

            updateSelectionOnly(asset, animated = false)
        }

        /** 仅刷新选中状态相关视图，不重载图片 */
        fun updateSelectionOnly(asset: MediaAsset, animated: Boolean) {
            val selIndex = selectedIndexById[asset.id] ?: -1
            val isSelected = showSelectionControls && selIndex >= 0
            val targetAlpha = if (isSelected) 0.35f else 0f

            // 序号圆圈
            selectionCircle.isSelected = isSelected
            selectionCircle.text = if (isSelected) (selIndex + 1).toString() else ""

            // 遮罩 alpha：用 ObjectAnimator 动画，对齐 iOS crossDissolve
            if (animated && targetAlpha != lastOverlayAlpha) {
                ObjectAnimator.ofFloat(selectedOverlay, "alpha", lastOverlayAlpha, targetAlpha)
                    .apply {
                        duration = 150
                        start()
                    }
            } else {
                selectedOverlay.alpha = targetAlpha
            }
            lastOverlayAlpha = targetAlpha
        }

        private fun formatDuration(ms: Long): String {
            val s = ms / 1000
            return "%d:%02d".format(s / 60, s % 60)
        }
    }

    // ──────────────────────────────────────────────
    // DiffUtil Callback
    // ──────────────────────────────────────────────

    companion object {
        const val GRID_COLUMNS = 3                    // 宫格列数（供 Activity 引用保持一致）
        const val PAYLOAD_SELECTION = "selection"     // 选中状态局部刷新 payload key

        private val AssetDiffCallback = object : DiffUtil.ItemCallback<MediaAsset>() {
            override fun areItemsTheSame(oldItem: MediaAsset, newItem: MediaAsset): Boolean =
                oldItem.id == newItem.id

            override fun areContentsTheSame(oldItem: MediaAsset, newItem: MediaAsset): Boolean =
                oldItem == newItem
        }
    }
}

/**
 * 宫格等间距装饰器（对齐 iOS Photos 1pt 间距）
 *
 * 原理：每个 item 在四个方向各贡献 spacing/2，
 * RecyclerView 自身补 padding=spacing/2 确保边缘与内部间距一致。
 *
 * 使用：
 *   recyclerView.addItemDecoration(GridSpacingItemDecoration(columns=3, spacingPx=2))
 *   recyclerView.setPadding(1, …, 1, …)  // spacing/2
 */
class GridSpacingItemDecoration(
    private val columns: Int,
    private val spacingPx: Int          // 每条缝隙的总宽度（px）
) : RecyclerView.ItemDecoration() {

    override fun getItemOffsets(
        outRect: Rect,
        view: View,
        parent: RecyclerView,
        state: RecyclerView.State
    ) {
        val position = parent.getChildAdapterPosition(view)
        val col = position % columns
        val half = spacingPx / 2

        // 左：col * (spacing - spacing/columns)
        outRect.left  = col * spacingPx / columns
        // 右：spacing - (col+1) * spacing/columns
        outRect.right = spacingPx - (col + 1) * spacingPx / columns
        // 顶部（非第一行加间距）
        outRect.top   = if (position < columns) 0 else half
        // 底部
        outRect.bottom = half
    }
}
