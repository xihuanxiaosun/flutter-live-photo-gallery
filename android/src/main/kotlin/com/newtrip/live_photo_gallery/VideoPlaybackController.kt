package com.newtrip.live_photo_gallery

import android.content.Context
import android.net.Uri
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView

/**
 * 可承载 ExoPlayer [PlayerView] 的表面（由 PreviewViewHolder 实现）。
 * 用接口解耦「播放控制器」与「具体 holder」——控制器无需知道 inner-class holder 的存在。
 */
internal interface VideoSurface {
    fun attachPlayerView(pv: PlayerView)
    fun releasePlayerView()
}

/**
 * 内联视频播放（ExoPlayer）的生命周期管理。从 PreviewActivity 抽出。
 * 单一 ExoPlayer + 单一 PlayerView 复用；切换 surface 时自动从旧 surface 撤离。
 */
internal class VideoPlaybackController(private val context: Context) {

    private var player: ExoPlayer? = null
    private var playerView: PlayerView? = null
    private var currentSurface: VideoSurface? = null

    private fun getOrCreatePlayer(): ExoPlayer =
        player ?: ExoPlayer.Builder(context).build().also { player = it }

    private fun getOrCreatePlayerView(): PlayerView =
        playerView ?: PlayerView(context).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            useController = true
        }.also { playerView = it }

    /** 在 [surface] 上播放 [uri]；切换 surface 时自动从旧 surface 撤离 PlayerView。 */
    fun play(surface: VideoSurface, uri: Uri) {
        val p = getOrCreatePlayer()
        val pv = getOrCreatePlayerView()
        currentSurface?.takeIf { it !== surface }?.releasePlayerView()
        pv.player = p
        surface.attachPlayerView(pv)
        currentSurface = surface
        p.setMediaItem(MediaItem.fromUri(uri))
        p.prepare()
        p.playWhenReady = true
    }

    fun pause() {
        player?.pause()
    }

    /** surface（holder）被回收时：若正是当前承载表面，撤离并暂停。 */
    fun onSurfaceRecycled(surface: VideoSurface) {
        if (currentSurface === surface) {
            surface.releasePlayerView()
            player?.pause()
            currentSurface = null
        }
    }

    fun release() {
        currentSurface?.releasePlayerView()
        currentSurface = null
        player?.release()
        player = null
        playerView = null
    }
}
