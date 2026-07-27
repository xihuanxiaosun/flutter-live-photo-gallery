package com.newtrip.live_photo_gallery

import android.content.Context
import android.net.Uri
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
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

    /**
     * 播放失败回调：坏 URL / 解码失败等由 [Player.Listener.onPlayerError] 触发，
     * 携带出错时正在承载播放的 [VideoSurface]，供 UI（holder）展示重试遮罩。
     * 单一 ExoPlayer 复用，故监听器只在 player 创建时注册一次（见 getOrCreatePlayer）。
     */
    var onError: ((VideoSurface) -> Unit)? = null

    // 复用 player 上的唯一监听器实例；release() 时按同一引用移除，杜绝泄漏与重复注册。
    private val playerListener = object : Player.Listener {
        override fun onPlayerError(error: PlaybackException) {
            // 路由到出错时的当前承载表面；已翻页/回收（currentSurface=null）则忽略。
            currentSurface?.let { surface -> onError?.invoke(surface) }
        }
    }

    private fun getOrCreatePlayer(): ExoPlayer =
        player ?: ExoPlayer.Builder(context).build().also {
            it.addListener(playerListener)  // 仅注册一次，随 player 生命周期存续
            player = it
        }

    private fun getOrCreatePlayerView(): PlayerView =
        playerView ?: PlayerView(context).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            useController = true
            // 中途卡顿（STATE_BUFFERING）时显示 ExoPlayer 内置缓冲 spinner
            setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
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

    /**
     * 无条件停止当前承载表面的播放（翻页离开正在播放的视频时调用）。
     * 撤离 PlayerView 恢复该页封面帧 + 播放按钮，暂停播放器并清空当前表面。
     * 与 onSurfaceRecycled 逻辑一致，但不校验具体 surface。
     */
    fun stopCurrent() {
        currentSurface?.releasePlayerView()
        player?.pause()
        currentSurface = null
    }

    fun release() {
        currentSurface?.releasePlayerView()
        currentSurface = null
        player?.removeListener(playerListener)  // 先摘监听器再释放，避免泄漏
        player?.release()
        player = null
        playerView = null
    }
}
