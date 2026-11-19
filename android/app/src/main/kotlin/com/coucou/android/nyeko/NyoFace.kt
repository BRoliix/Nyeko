package com.coucou.android.nyeko

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import com.coucou.android.core.NyoMood
import com.coucou.android.mochi.BotState
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/** Nyeko's Sticker Pop palette (the Mac and the web app use the same). */
object NyoColors {
    val cream = Color(0xFFFFF6E9)
    val ink = Color(0xFF2B1D12)
    val tangerine = Color(0xFFFF7A2F)
    val mint = Color(0xFF2EC4B6)
    val bubblegum = Color(0xFFFF8FB1)
    val sun = Color(0xFFFFC23D)
    val fur = Color(0xFFFFE2BC)
    val nose = Color(0xFFFF6F91)
}

/** How Nyo holds himself: a mood ([NyoMood]) or one agent's state, which can say a little more. */
enum class NyoLook {
    IDLE, WORKING, THINKING, NEEDS, QUESTION, DONE, ERROR, SLEEP;

    companion object {
        fun of(mood: NyoMood): NyoLook = when (mood) {
            NyoMood.SLEEPING -> SLEEP
            NyoMood.IDLE -> IDLE
            NyoMood.WORKING -> WORKING
            NyoMood.NEEDS_YOU -> NEEDS
            NyoMood.DONE -> DONE
        }

        fun of(state: BotState): NyoLook = when (state) {
            BotState.APPROVAL -> NEEDS
            BotState.QUESTION -> QUESTION
            BotState.ERROR, BotState.RATELIMIT -> ERROR
            BotState.WORKING, BotState.SEARCHING -> WORKING
            BotState.THINKING -> THINKING
            BotState.FINISHED -> DONE
            BotState.SLEEPING -> SLEEP
            BotState.IDLE, BotState.DIZZY -> IDLE
        }
    }
}

/**
 * Nyo, the tabby cat, drawn in code (no image), the same drawing as the Mac (NyoPainter.swift) and Windows (nyo.ts): a fluffy head
 * with chunky ink outlines, mint cat eyes, three tangerine stripes, a cream muzzle, paws over the edge and a tail that tells the
 * mood. Animates only while on screen (blinks, an ear twitch, the tail, kneading while he works); [still] draws one frame (the
 * reduced-motion setting, widgets).
 */
@Composable
fun NyoFace(mood: NyoMood, modifier: Modifier = Modifier, still: Boolean = false) {
    // A still Nyo runs no animation at all (no frame loop): the floating Nyo is still when nothing is going on.
    if (still) {
        Canvas(modifier) { drawNyo(NyoLook.of(mood), NyoMotion.STILL) }
        return
    }
    val anim = rememberInfiniteTransition(label = "nyo")
    val clock by anim.animateFloat(0f, 36f, infiniteRepeatable(tween(36_000, easing = LinearEasing), RepeatMode.Restart), label = "clock")
    Canvas(modifier) { drawNyo(NyoLook.of(mood), NyoMotion.at(clock.toDouble())) }
}

/**
 * One frame of Nyo for a canvas that has its own clock (MochiView's frame loop, which also drives the island): blink, twitch, tail and
 * kneading come from [timeS]. [still] for reduced motion.
 */
fun DrawScope.drawNyoFrame(mood: NyoMood, timeS: Double, still: Boolean = false) =
    drawNyoFrame(NyoLook.of(mood), timeS, still)

fun DrawScope.drawNyoFrame(look: NyoLook, timeS: Double, still: Boolean = false) =
    drawNyo(look, if (still) NyoMotion.STILL else NyoMotion.at(timeS))

/** Where Nyo is in his little loops, from a clock in seconds. */
class NyoMotion(val t: Double, val blink: Float, val twitchL: Float, val twitchR: Float, val moving: Boolean) {
    companion object {
        val STILL = NyoMotion(0.0, 1f, 0f, 0f, false)

        fun at(t: Double): NyoMotion {
            // A blink every 3.6 s; every third one is the slow, contented cat blink.
            val cycle = (t / 3.6).toLong()
            val phase = t % 3.6
            val slow = cycle % 3 == 2L
            val blink = if (slow) (if (phase in 2.9..3.56) 0.1f else 1f) else (if (phase in 3.3..3.45) 0.1f else 1f)
            // An ear twitch every 6 s, one side then the other.
            val tw = t % 6.0
            val a = if (tw < 0.32) sin(tw / 0.32 * PI).toFloat() * 16f else 0f
            val left = (t / 6.0).toLong() % 2 == 0L
            return NyoMotion(t, blink, if (left) a else 0f, if (left) 0f else a, true)
        }
    }
}

// The design sheet: 120 units, head centre (60, 65). Same numbers as the Mac and Windows.
private object NyoGeo {
    val head = "M60 30 C76 30 88 36 94 48 C98 56 99 63 98 69 L105 73 L97 77 L102 83 L93 85 C86 95 74 100 60 100 " +
        "C46 100 34 95 27 85 L18 83 L23 77 L15 73 L22 69 C21 63 22 56 26 48 C32 36 44 30 60 30 Z"
    val earOuter = "M31 50 C28 36 29 24 33 14 C42 19 50 27 55 37 Z"
    val earInner = "M35 42 C34 33 35 27 37 22 C42 26 46 31 48 36 Z"
    val earTuft = "M33 15 L30 8 M33 15 L36 9"
    val tails = mapOf(
        "rest" to floatArrayOf(86f, 96f, 104f, 98f, 114f, 88f, 112f, 74f, 111f, 66f, 104f, 64f, 102f, 70f),
        "up" to floatArrayOf(88f, 92f, 106f, 88f, 112f, 70f, 106f, 52f, 103f, 44f, 96f, 42f, 96f, 50f),
        "puff" to floatArrayOf(86f, 94f, 106f, 96f, 116f, 82f, 112f, 64f, 110f, 54f, 102f, 50f, 100f, 58f),
        "wrap" to floatArrayOf(84f, 98f, 70f, 108f, 46f, 108f, 34f, 100f, 30f, 97f, 32f, 92f, 37f, 94f),
        "curl" to floatArrayOf(88f, 92f, 108f, 90f, 114f, 70f, 104f, 58f, 99f, 52f, 93f, 56f, 96f, 62f),
    )
}

/** A tiny SVG-path reader for the M, L, C, Z the sheet uses; [f] maps each point. */
private fun pathOf(d: String, mirror: Boolean = false, f: (Float, Float) -> Offset): Path {
    val p = Path()
    val tok = Regex("[MLCZ]|-?[0-9.]+").findAll(d).map { it.value }.toList()
    var i = 0
    fun num() = tok[i++].toFloat()
    fun pt(): Offset { val x = num(); val y = num(); return f(if (mirror) 120 - x else x, y) }
    while (i < tok.size) {
        when (tok[i++]) {
            "M" -> pt().let { p.moveTo(it.x, it.y) }
            "L" -> pt().let { p.lineTo(it.x, it.y) }
            "C" -> { val a = pt(); val b = pt(); val c = pt(); p.cubicTo(a.x, a.y, b.x, b.y, c.x, c.y) }
            "Z" -> p.close()
        }
    }
    return p
}

private fun DrawScope.drawNyo(look: NyoLook, m: NyoMotion) {
    val s = min(size.width, size.height)
    val k = s / 128f
    val ox = (size.width - s) / 2 + 4 * k
    val oy = (size.height - s) / 2 + 4 * k
    val ink = NyoColors.ink
    fun p(x: Float, y: Float) = Offset(ox + x * k, oy + y * k)
    fun stroke(w: Float, cap: StrokeCap = StrokeCap.Round) = Stroke(width = w * k, cap = cap, join = StrokeJoin.Round)

    // Pose for the look.
    val tail = when (look) {
        NyoLook.WORKING, NyoLook.NEEDS -> "up"
        NyoLook.QUESTION, NyoLook.DONE -> "curl"
        NyoLook.ERROR -> "puff"
        NyoLook.SLEEP -> "wrap"
        else -> "rest"
    }
    var earL = when (look) { NyoLook.THINKING -> -10f; NyoLook.ERROR -> -38f; NyoLook.SLEEP -> -8f; else -> 0f }
    var earR = when (look) { NyoLook.QUESTION -> 14f; NyoLook.ERROR -> 38f; NyoLook.SLEEP -> 8f; else -> 0f }
    if (look == NyoLook.IDLE || look == NyoLook.WORKING || look == NyoLook.THINKING || look == NyoLook.DONE) {
        earL -= m.twitchL; earR += m.twitchR
    }
    val (swishSpeed, swishAmp) = when (look) {
        NyoLook.WORKING -> 5.0 to 6.0
        NyoLook.NEEDS -> 7.0 to 4.0
        NyoLook.ERROR -> 11.0 to 2.5
        NyoLook.DONE -> 3.0 to 8.0
        NyoLook.SLEEP -> 0.6 to 1.0
        else -> 1.7 to 6.0
    }
    val swish = if (m.moving) (sin(m.t * swishSpeed) * swishAmp).toFloat() else 0f
    val headTilt = if (look == NyoLook.QUESTION) -7f else 0f

    rotate(headTilt, pivot = p(60f, 70f)) {
        // Tail (behind): a fur stroke inside an ink one, with a tangerine band near the tip.
        val tp = NyoGeo.tails.getValue(tail)
        val tw = if (tail == "puff") 13f else 9f
        val tailPath = Path().apply {
            moveTo(p(tp[0], tp[1]).x, p(tp[0], tp[1]).y)
            cubicTo(p(tp[2], tp[3]).x, p(tp[2], tp[3]).y, p(tp[4], tp[5]).x, p(tp[4], tp[5]).y, p(tp[6], tp[7]).x, p(tp[6], tp[7]).y)
            cubicTo(p(tp[8], tp[9]).x, p(tp[8], tp[9]).y, p(tp[10], tp[11]).x, p(tp[10], tp[11]).y, p(tp[12], tp[13]).x, p(tp[12], tp[13]).y)
        }
        rotate(swish, pivot = p(tp[0], tp[1])) {
            drawPath(tailPath, ink, style = stroke(tw + 5))
            drawPath(tailPath, NyoColors.fur, style = stroke(tw))
            val measure = PathMeasure().apply { setPath(tailPath, false) }
            val band = Path()
            if (measure.getSegment(measure.length * 0.64f, measure.length * 0.8f, band, true)) {
                drawPath(band, NyoColors.tangerine, style = stroke(tw, StrokeCap.Butt))
            }
        }

        // Ears (behind the head), each turning about its base.
        for (left in listOf(true, false)) {
            val pivot = if (left) p(40f, 44f) else p(80f, 44f)
            rotate(if (left) earL else earR, pivot = pivot) {
                drawPath(pathOf(NyoGeo.earOuter, !left, ::p), NyoColors.fur)
                drawPath(pathOf(NyoGeo.earInner, !left, ::p), NyoColors.bubblegum)
                drawPath(pathOf(NyoGeo.earOuter, !left, ::p), ink, style = stroke(3.5f))
                if (s > 40) drawPath(pathOf(NyoGeo.earTuft, !left, ::p), ink, style = stroke(2.2f))
            }
        }

        // Head, with cheek fluff.
        val head = pathOf(NyoGeo.head, f = ::p)
        drawPath(head, NyoColors.fur)
        drawPath(head, ink, style = stroke(3.5f))
        clipPath(head) {
            drawOval(NyoColors.cream, p(44f, 70f), Size(32f * k, 22f * k))
            drawCircle(NyoColors.bubblegum.copy(alpha = 0.7f), 5f * k, p(31f, 77f))
            drawCircle(NyoColors.bubblegum.copy(alpha = 0.7f), 5f * k, p(89f, 77f))
        }
        // Stripes.
        for ((a, b) in listOf(p(53f, 35f) to p(55f, 43f), p(60f, 33f) to p(60f, 42f), p(67f, 35f) to p(65f, 43f))) {
            drawLine(NyoColors.tangerine, a, b, 3.4f * k, StrokeCap.Round)
        }

        // Eyes.
        val (dx, dy) = when (look) {
            NyoLook.WORKING -> 2.5f to 1f
            NyoLook.THINKING -> 1.5f to -3f
            NyoLook.QUESTION -> -1.5f to -1f
            NyoLook.ERROR -> 0f to 1f
            else -> 0f to 0f
        }
        for (cx in listOf(45f, 75f)) {
            val closed = look == NyoLook.DONE || look == NyoLook.SLEEP || m.blink < 0.3f
            if (closed) {
                val up = look == NyoLook.DONE
                val arc = Path().apply {
                    if (up) { moveTo(p(cx - 7, 66f).x, p(0f, 66f).y); quadraticTo(p(cx, 57f).x, p(0f, 57f).y, p(cx + 7, 0f).x, p(0f, 66f).y) }
                    else { moveTo(p(cx - 7, 63f).x, p(0f, 63f).y); quadraticTo(p(cx, 70f).x, p(0f, 70f).y, p(cx + 7, 0f).x, p(0f, 63f).y) }
                }
                drawPath(arc, ink, style = stroke(3.6f))
                continue
            }
            drawCircle(NyoColors.mint, 9f * k, p(cx, 64f))
            val pupil = p(cx + dx, 64f + dy)
            when (look) {
                NyoLook.WORKING -> drawOval(ink, Offset(pupil.x - 1.9f * k, pupil.y - 6.6f * k), Size(3.8f * k, 13.2f * k))
                NyoLook.NEEDS -> drawCircle(ink, 6f * k, pupil)
                NyoLook.ERROR -> drawCircle(ink, 2.6f * k, pupil)
                else -> drawOval(ink, Offset(pupil.x - 3.3f * k, pupil.y - 6.4f * k), Size(6.6f * k, 12.8f * k))
            }
            if (look != NyoLook.ERROR) drawCircle(Color.White, 2f * k, Offset(pupil.x + 2.6f * k, pupil.y - 3.2f * k))
            drawCircle(ink, 9f * k, p(cx, 64f), style = stroke(2.8f))
        }

        // Nose, mouth, whiskers.
        val nose = Path().apply { moveTo(p(56f, 75f).x, p(56f, 75f).y); lineTo(p(64f, 75f).x, p(64f, 75f).y); lineTo(p(60f, 79.5f).x, p(60f, 79.5f).y); close() }
        drawPath(nose, NyoColors.nose)
        drawPath(nose, ink, style = stroke(1.6f))
        when (look) {
            NyoLook.NEEDS -> drawOval(ink, p(57.4f, 81.8f), Size(5.2f * k, 6.4f * k))
            NyoLook.THINKING, NyoLook.ERROR -> drawPath(
                Path().apply { moveTo(p(55f, 84f).x, p(55f, 84f).y); quadraticTo(p(60f, 82f).x, p(60f, 82f).y, p(65f, 84f).x, p(65f, 84f).y) },
                ink, style = stroke(2f),
            )
            NyoLook.DONE -> {
                val open = Path().apply { moveTo(p(54f, 81.5f).x, p(54f, 81.5f).y); quadraticTo(p(60f, 90f).x, p(60f, 90f).y, p(66f, 81.5f).x, p(66f, 81.5f).y); close() }
                drawPath(open, NyoColors.nose)
                drawPath(open, ink, style = stroke(2f))
            }
            else -> drawPath(
                Path().apply {
                    moveTo(p(60f, 79.5f).x, p(60f, 79.5f).y); quadraticTo(p(57f, 85f).x, p(57f, 85f).y, p(53f, 82.5f).x, p(53f, 82.5f).y)
                    moveTo(p(60f, 79.5f).x, p(60f, 79.5f).y); quadraticTo(p(63f, 85f).x, p(63f, 85f).y, p(67f, 82.5f).x, p(67f, 82.5f).y)
                },
                ink, style = stroke(2f),
            )
        }
        if (s > 40) {
            for ((a, b) in listOf(p(46f, 80f) to p(30f, 78f), p(46f, 84f) to p(31f, 87f), p(74f, 80f) to p(90f, 78f), p(74f, 84f) to p(89f, 87f))) {
                drawLine(ink, a, b, 1.6f * k, StrokeCap.Round)
            }
        }

        // Paws over the edge; they knead while he works.
        for ((i, cx) in listOf(46f, 74f).withIndex()) {
            val lift = if (look == NyoLook.WORKING && m.moving) max(0.0, sin(m.t * 7 + i * PI)).toFloat() * 5f else 0f
            val cy = 102f - lift
            drawOval(NyoColors.fur, p(cx - 9, cy - 6), Size(18f * k, 12f * k))
            drawOval(ink, p(cx - 9, cy - 6), Size(18f * k, 12f * k), style = stroke(3f))
            if (s > 40) {
                drawLine(ink, p(cx - 3, cy + 1), p(cx - 3, cy + 4), 1.6f * k, StrokeCap.Round)
                drawLine(ink, p(cx + 3, cy + 1), p(cx + 3, cy + 4), 1.6f * k, StrokeCap.Round)
            }
        }
    }

    // What he wants to tell you, top right.
    when (look) {
        NyoLook.NEEDS -> {
            drawCircle(NyoColors.sun, 12f * k, p(104f, 18f))
            drawCircle(ink, 12f * k, p(104f, 18f), style = stroke(3f))
            drawLine(ink, p(104f, 11f), p(104f, 19f), 3.4f * k, StrokeCap.Round)
            drawCircle(ink, 2f * k, p(104f, 25f))
        }
        NyoLook.QUESTION -> {
            drawCircle(NyoColors.mint, 12f * k, p(104f, 18f))
            drawCircle(ink, 12f * k, p(104f, 18f), style = stroke(3f))
            val q = Path().apply {
                moveTo(p(99.5f, 15f).x, p(99.5f, 15f).y)
                quadraticTo(p(100f, 9f).x, p(100f, 9f).y, p(104.5f, 9f).x, p(104.5f, 9f).y)
                quadraticTo(p(109f, 9.5f).x, p(109f, 9.5f).y, p(109f, 13.5f).x, p(109f, 13.5f).y)
                quadraticTo(p(109f, 17f).x, p(109f, 17f).y, p(104.5f, 18.5f).x, p(104.5f, 18.5f).y)
                lineTo(p(104.5f, 21f).x, p(104.5f, 21f).y)
            }
            drawPath(q, ink, style = stroke(3f))
            drawCircle(ink, 1.9f * k, p(104.5f, 26f))
        }
        NyoLook.WORKING -> for (i in 0..2) {
            val up = if (m.moving) ((sin(m.t * 6 - i) + 1) / 2).toFloat() * 3f else 0f
            drawCircle(NyoColors.mint, 3f * k, p(98f + i * 8f, 16f - up))
        }
        NyoLook.SLEEP -> {
            drawLine(ink, p(97f, 20f), p(105f, 20f), 2.4f * k, StrokeCap.Round)
            drawLine(ink, p(105f, 20f), p(97f, 28f), 2.4f * k, StrokeCap.Round)
            drawLine(ink, p(97f, 28f), p(105f, 28f), 2.4f * k, StrokeCap.Round)
        }
        NyoLook.DONE -> {
            val star = Path().apply {
                for (j in 0 until 8) {
                    val r = if (j % 2 == 0) 9f else 3f
                    val a = -PI / 2 + j * PI / 4
                    val pt = p(104f + (cos(a) * r).toFloat(), 18f + (sin(a) * r).toFloat())
                    if (j == 0) moveTo(pt.x, pt.y) else lineTo(pt.x, pt.y)
                }
                close()
            }
            drawPath(star, NyoColors.sun)
            drawPath(star, ink, style = stroke(2f))
        }
        else -> {}
    }
}
