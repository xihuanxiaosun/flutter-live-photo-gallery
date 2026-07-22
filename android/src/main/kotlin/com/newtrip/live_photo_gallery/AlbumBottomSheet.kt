package com.newtrip.live_photo_gallery

import android.app.Activity
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.bumptech.glide.Glide
import com.bumptech.glide.load.engine.DiskCacheStrategy
import com.google.android.material.bottomsheet.BottomSheetDialog

/**
 * 相册选择底部弹层（BottomSheet + 相册列表 + 列表 adapter）。从 MediaPickerActivity 抽出。
 * 选择相册后的副作用（切相册、重置筛选/选中、重新加载）由调用方经 [onAlbumSelected] 处理；
 * 弹层关闭时经 [onDismiss] 通知调用方（例如收起标题箭头）。
 */
internal class AlbumBottomSheet(private val activity: Activity) {

    private var dialog: BottomSheetDialog? = null

    fun show(
        albums: List<AlbumItem>,
        currentBucketId: Long,
        onAlbumSelected: (AlbumItem) -> Unit,
        onDismiss: () -> Unit,
    ) {
        dialog?.dismiss()

        val sheetHeight = minOf(dp(420), albums.size * dp(72) + dp(32))
        val list = RecyclerView(activity).apply {
            layoutManager = LinearLayoutManager(activity)
            overScrollMode = View.OVER_SCROLL_NEVER
            setPadding(0, dp(8), 0, dp(16))
            clipToPadding = false
            adapter = AlbumAdapter(albums, currentBucketId) { selected ->
                dialog?.dismiss()
                onAlbumSelected(selected)
            }
        }

        val container = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(24).toFloat()
                setColor(resolveThemeColor(com.google.android.material.R.attr.colorSurface))
            }
            addView(
                list,
                LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, sheetHeight),
            )
        }

        dialog = BottomSheetDialog(activity).apply {
            setContentView(container)
            setCanceledOnTouchOutside(true)
            setOnDismissListener {
                this@AlbumBottomSheet.dialog = null
                onDismiss()
            }
            show()
        }
    }

    fun dismiss() {
        dialog?.dismiss()
    }

    private fun dp(value: Int): Int =
        (value * activity.resources.displayMetrics.density).toInt()

    private fun resolveThemeColor(attr: Int): Int {
        val tv = TypedValue()
        activity.theme.resolveAttribute(attr, tv, true)
        return tv.data
    }

    private class AlbumAdapter(
        private val items: List<AlbumItem>,
        private val activeBucketId: Long,
        val onSelect: (AlbumItem) -> Unit,
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

    private class AlbumViewHolder(itemView: View) : RecyclerView.ViewHolder(itemView) {
        private val cover: ImageView = itemView.findViewById(R.id.iv_album_cover)
        private val name: TextView = itemView.findViewById(R.id.tv_album_name)
        private val count: TextView = itemView.findViewById(R.id.tv_album_count)
        private val check: ImageView = itemView.findViewById(R.id.iv_album_check)

        fun bind(item: AlbumItem, activeBucketId: Long) {
            name.text = item.displayName
            count.text = item.count.toString()
            check.visibility = if (item.bucketId == activeBucketId) View.VISIBLE else View.GONE
            Glide.with(cover.context)
                .load(item.coverUri)
                .override(56, 56)
                .centerCrop()
                .diskCacheStrategy(DiskCacheStrategy.RESOURCE)
                .into(cover)
            itemView.setOnClickListener {
                (bindingAdapter as? AlbumAdapter)?.let { it.onSelect(item) }
            }
        }
    }
}
