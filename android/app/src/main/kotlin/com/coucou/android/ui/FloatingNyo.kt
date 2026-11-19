package com.coucou.android.ui

import android.content.Context
import android.content.SharedPreferences
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import com.coucou.android.core.NyoMood
import com.coucou.android.nyeko.NyoColors
import com.coucou.android.nyeko.NyoFace
import kotlin.math.roundToInt

/**
 * Nyeko: Nyo, a small cat that lives on the edge of the screen over your other apps (like a chat head). It shows how your
 * coding sessions are (asleep, calm, working, needs you, done), says it in a few words when something needs you, and opens
 * the app when tapped. Drag it anywhere: it snaps to the nearest side and stays there.
 *
 * Needs the same "display over other apps" permission as the island. Nothing runs while it is hidden (the window is removed),
 * and while nothing is going on Nyo is drawn still, with no frame loop.
 */
class FloatingNyo(
    private val context: Context,
    private val prefs: SharedPreferences,
    private val onOpen: () -> Unit,
) {
    private val wm = context.getSystemService(WindowManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var view: ComposeView? = null
    private var owner: OverlayOwner? = null
    private var params: WindowManager.LayoutParams? = null

    private var mood by mutableStateOf(NyoMood.IDLE)
    private var words by mutableStateOf("")
    private var label by mutableStateOf(false)
    private var onRight by mutableStateOf(prefs.getBoolean(KEY_RIGHT, true))
    private var lastMood: NyoMood? = null
    private val hideLabel = Runnable { label = false }

    fun permitted(): Boolean = Settings.canDrawOverlays(context)

    /** Shows Nyo (or updates it). A change to "needs you" or "done" says so in a bubble for a few seconds. */
    fun show(next: NyoMood, text: String) = safely {
        if (!permitted()) { hide(); return@safely }
        if (!ensureView()) return@safely
        if (next != lastMood && (next == NyoMood.NEEDS_YOU || next == NyoMood.DONE)) {
            label = true
            main.removeCallbacks(hideLabel)
            main.postDelayed(hideLabel, LABEL_MS)
        }
        lastMood = next
        mood = next
        words = text
    }

    fun hide() = safely {
        main.removeCallbacks(hideLabel)
        label = false
        lastMood = null
        view?.let { runCatching { wm.removeView(it) } }
        owner?.destroy()
        view = null
        owner = null
        params = null
    }

    private inline fun safely(block: () -> Unit) {
        try { block() } catch (e: Exception) { Log.w(TAG, "floating Nyo: ${e.javaClass.simpleName}") }
    }

    private fun ensureView(): Boolean {
        if (view != null) return true
        val p = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // Touches outside Nyo go to the app underneath; Nyo never takes the keyboard.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or (if (onRight) Gravity.END else Gravity.START)
            x = margin()
            y = prefs.getInt(KEY_Y, (screenHeight() * 0.42).roundToInt())
        }
        val o = OverlayOwner()
        val v = ComposeView(context).apply {
            setViewTreeLifecycleOwner(o)
            setViewTreeSavedStateRegistryOwner(o)
            setViewTreeViewModelStoreOwner(o)
            setContent { Nyo() }
        }
        return try {
            wm.addView(v, p)
            view = v
            owner = o
            params = p
            true
        } catch (e: Exception) {
            Log.w(TAG, "cannot add the window: ${e.javaClass.simpleName}")
            o.destroy()
            false
        }
    }

    @androidx.compose.runtime.Composable
    private fun Nyo() {
        val m = mood
        Column(
            Modifier.padding(4.dp),
            horizontalAlignment = if (onRight) Alignment.End else Alignment.Start,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Box(
                Modifier.size(SIZE_DP.dp)
                    .semantics { contentDescription = "Nyo: $words. Tap to open Nyeko." }
                    .pointerInput(Unit) { detectTapGestures(onTap = { onOpen() }) }
                    .pointerInput(Unit) {
                        detectDragGestures(onDragStart = { startDrag() }, onDragEnd = { endDrag() }, onDragCancel = { endDrag() }) { change, drag ->
                            change.consume()
                            moveBy(drag.x, drag.y)
                        }
                    },
            ) {
                NyoFace(m, Modifier.size(SIZE_DP.dp), still = m != NyoMood.WORKING && m != NyoMood.NEEDS_YOU)
            }
            if (label && words.isNotEmpty()) {
                Text(
                    words,
                    Modifier.widthIn(max = 180.dp).clip(RoundedCornerShape(12.dp)).background(NyoColors.cream)
                        .border(2.dp, NyoColors.ink, RoundedCornerShape(12.dp)).padding(horizontal = 10.dp, vertical = 6.dp),
                    color = NyoColors.ink, fontSize = 13.sp, fontWeight = FontWeight.Bold, maxLines = 2,
                )
            }
        }
    }

    // ── Dragging: absolute from the left while moving, docked to a side when let go ──

    private fun startDrag() = safely {
        val p = params ?: return@safely
        val v = view ?: return@safely
        if (p.gravity and Gravity.END == Gravity.END) {
            p.gravity = Gravity.TOP or Gravity.START
            p.x = screenWidth() - v.width - p.x
            wm.updateViewLayout(v, p)
        }
    }

    private fun moveBy(dx: Float, dy: Float) = safely {
        val p = params ?: return@safely
        val v = view ?: return@safely
        p.x = (p.x + dx.roundToInt()).coerceIn(0, maxOf(0, screenWidth() - v.width))
        p.y = (p.y + dy.roundToInt()).coerceIn(0, maxOf(0, screenHeight() - v.height))
        wm.updateViewLayout(v, p)
    }

    private fun endDrag() = safely {
        val p = params ?: return@safely
        val v = view ?: return@safely
        val right = p.x + v.width / 2 > screenWidth() / 2
        onRight = right
        p.gravity = Gravity.TOP or (if (right) Gravity.END else Gravity.START)
        p.x = margin()
        wm.updateViewLayout(v, p)
        prefs.edit().putBoolean(KEY_RIGHT, right).putInt(KEY_Y, p.y).apply()
    }

    private fun screenWidth() = wm.currentWindowMetrics.bounds.width()
    private fun screenHeight() = wm.currentWindowMetrics.bounds.height()
    private fun margin() = (context.resources.displayMetrics.density * 6).roundToInt()

    /** A window outside any activity has no lifecycle of its own: Compose needs one to run. */
    private class OverlayOwner : LifecycleOwner, SavedStateRegistryOwner, ViewModelStoreOwner {
        override val viewModelStore = ViewModelStore()
        private val registry = LifecycleRegistry(this)
        private val controller = SavedStateRegistryController.create(this)
        override val lifecycle: Lifecycle get() = registry
        override val savedStateRegistry: SavedStateRegistry get() = controller.savedStateRegistry

        init {
            controller.performAttach()
            controller.performRestore(null)
            registry.currentState = Lifecycle.State.RESUMED
        }

        fun destroy() {
            registry.currentState = Lifecycle.State.DESTROYED
            viewModelStore.clear()
        }
    }

    private companion object {
        const val TAG = "CoucouOverlay" // one of the tags the release build checks are gone (build.gradle.kts)
        const val SIZE_DP = 64
        const val LABEL_MS = 6_000L
        const val KEY_RIGHT = "floating_nyo_right"
        const val KEY_Y = "floating_nyo_y"
    }
}
