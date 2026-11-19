package com.coucou.android.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Nyeko's own messages from the Mac (cap `nyeko`, see NyekoPhoneService.swift and SessionChat.swift on the Mac), read into
 * plain values. Pure Kotlin plus org.json: tested on the JVM. Anything malformed becomes null or an empty list, never a crash.
 * Text from the Mac is shown as text only, cut to a sane length and stripped of control characters (new lines kept).
 */
object NyekoData {
    data class NowPlaying(
        val title: String, val artist: String, val source: String, val playing: Boolean,
        val durationS: Double?, val positionS: Double?,
    )

    data class NextEvent(val title: String, val whenText: String)
    data class FocusTimer(val work: Boolean, val paused: Boolean, val remainingS: Int?)
    data class NamedId(val id: String, val name: String, val where: String = "")

    /** The Mac's status card ("mac"). */
    data class MacStatus(
        val nowPlaying: NowPlaying?, val next: NextEvent?, val timer: FocusTimer?, val recording: Boolean,
        val batteryPercent: Int?, val charging: Boolean, val apps: List<NamedId>, val projects: List<NamedId>,
        val receivedAtMs: Long,
        /** 0–100, null when the computer did not say; [os] is "macos" or "windows" (empty: an older build). */
        val volume: Int? = null, val muted: Boolean = false, val os: String = "", val name: String = "",
    )

    enum class Role { YOU, CLAUDE, TOOLS }
    data class Line(val role: Role, val text: String, val fromPhone: Boolean = false)

    /** A coding session's conversation and how a message reaches it ("chat"). */
    data class Thread(
        val session: String, val title: String, val host: String, val folder: String,
        /** needsYou, working, idle or gone. */
        val state: String,
        val readable: Boolean, val canMessage: Boolean,
        /** tab, front or wait (see SessionChat.Delivery on the Mac). */
        val delivery: String, val note: String,
        val lines: List<Line>, val queued: List<String>,
    )

    /** "said": what became of a message to a session. [result] is typed, queued or failed. */
    data class Said(val id: String, val result: String, val note: String)

    const val MAX_TEXT = 8000
    const val MAX_SHORT = 200
    const val MAX_APPS = 400

    /** What the computer is called on the phone's controls: "Mac" or "PC". */
    fun kindWord(os: String): String = if (os.startsWith("win") || os == "linux") "PC" else "Mac"

    fun clean(raw: String?, max: Int = MAX_SHORT): String =
        (raw ?: "").filter { it == '\n' || it == '\t' || !it.isISOControl() }.trim().take(max)

    fun mac(o: JSONObject, nowMs: Long): MacStatus {
        val np = o.optJSONObject("nowPlaying")?.let {
            NowPlaying(
                clean(it.optString("title")), clean(it.optString("artist")), clean(it.optString("source")),
                it.optBoolean("playing"), it.optDouble("duration").takeIf { d -> !d.isNaN() && d > 0 },
                it.optDouble("position").takeIf { p -> !p.isNaN() && p >= 0 },
            )
        }?.takeIf { it.title.isNotEmpty() }
        val next = o.optJSONObject("next")?.let { NextEvent(clean(it.optString("title")), clean(it.optString("when"))) }
            ?.takeIf { it.title.isNotEmpty() }
        val timer = o.optJSONObject("timer")?.let {
            FocusTimer(it.optString("phase") == "work", it.optBoolean("paused"), if (it.has("remaining")) it.optInt("remaining") else null)
        }
        val battery = o.optJSONObject("battery")
        return MacStatus(
            nowPlaying = np, next = next, timer = timer, recording = o.optBoolean("recording"),
            batteryPercent = battery?.optInt("percent", -1)?.takeIf { it in 0..100 },
            charging = battery?.optBoolean("charging") == true,
            apps = named(o.optJSONArray("apps")), projects = named(o.optJSONArray("projects")),
            receivedAtMs = nowMs,
            volume = if (o.has("volume")) o.optInt("volume", -1).takeIf { it in 0..100 } else null,
            muted = o.optBoolean("muted"), os = clean(o.optString("os"), 20), name = clean(o.optString("name"), 80),
        )
    }

    /** "apps": every installed app of the computer, by name (for "Open any app"). */
    fun appList(o: JSONObject): List<NamedId> {
        val a = o.optJSONArray("apps") ?: return emptyList()
        return (0 until a.length()).mapNotNull { i ->
            val it = a.optJSONObject(i) ?: return@mapNotNull null
            val id = clean(it.optString("id"), 100).takeIf { s -> s.isNotEmpty() } ?: return@mapNotNull null
            NamedId(id, clean(it.optString("name"), 80).ifEmpty { id })
        }.take(MAX_APPS).sortedBy { it.name.lowercase() }
    }

    fun thread(o: JSONObject): Thread? {
        val session = clean(o.optString("session"), 200).takeIf { it.isNotEmpty() } ?: return null
        val lines = o.optJSONArray("items")?.let { a ->
            (0 until a.length()).mapNotNull { i ->
                val it = a.optJSONObject(i) ?: return@mapNotNull null
                val role = when (it.optString("r")) { "you" -> Role.YOU; "claude" -> Role.CLAUDE; "tools" -> Role.TOOLS; else -> return@mapNotNull null }
                Line(role, clean(it.optString("t"), MAX_TEXT), it.optBoolean("p"))
            }
        }.orEmpty()
        return Thread(
            session = session, title = clean(o.optString("title")), host = clean(o.optString("host")),
            folder = clean(o.optString("folder")), state = o.optString("state", "idle"),
            readable = o.optBoolean("readable"), canMessage = o.optBoolean("canMessage"),
            delivery = o.optString("delivery", "wait"), note = clean(o.optString("note"), 400),
            lines = lines, queued = strings(o.optJSONArray("queued"), MAX_TEXT),
        )
    }

    fun said(o: JSONObject) = Said(o.optString("id"), o.optString("result"), clean(o.optString("note"), 400))

    /** What a phone message waiting for its session looks like to the user, from the thread's state. */
    fun hint(t: Thread): String = when {
        t.state == "gone" -> "This session has ended."
        !t.canMessage -> "Only Claude Code sessions take messages from the phone. You can still open it on your Mac."
        t.state == "working" -> "Claude is working: it reads your message when it finishes this turn."
        t.state == "needsYou" -> "Claude is waiting for you: answer it first."
        else -> t.note
    }

    // ── Messages to the Mac ──────────────────────────────────────────────────────────────────────────────────────────

    fun status() = JSONObject().put("type", "status")
    fun listApps() = JSONObject().put("type", "listApps")
    fun control(action: String, app: String? = null): JSONObject =
        JSONObject().put("type", "control").put("action", action).apply { if (app != null) put("app", app) }
    fun ask(id: String, text: String) = JSONObject().put("type", "ask").put("id", id).put("text", text.take(4000))
    fun open(session: String) = JSONObject().put("type", "open").put("session", session)
    fun close() = JSONObject().put("type", "close")
    fun say(session: String, id: String, text: String) =
        JSONObject().put("type", "say").put("session", session).put("id", id).put("text", text.take(MAX_TEXT))
    fun unqueue(session: String) = JSONObject().put("type", "unqueue").put("session", session)
    fun launch(id: String, project: String, prompt: String) =
        JSONObject().put("type", "launch").put("id", id).put("project", project).put("prompt", prompt.take(MAX_TEXT))

    private fun named(a: JSONArray?): List<NamedId> = if (a == null) emptyList() else (0 until a.length()).mapNotNull { i ->
        val o = a.optJSONObject(i) ?: return@mapNotNull null
        val id = clean(o.optString("id"), 100).takeIf { it.isNotEmpty() } ?: return@mapNotNull null
        NamedId(id, clean(o.optString("name"), 80).ifEmpty { id }, clean(o.optString("where"), 120))
    }.take(20)

    private fun strings(a: JSONArray?, max: Int): List<String> =
        if (a == null) emptyList() else (0 until a.length()).mapNotNull { a.optString(it, null)?.let { s -> clean(s, max) } }

    /** m:ss for a duration in seconds. */
    fun mmss(seconds: Double): String {
        val s = seconds.toInt().coerceAtLeast(0)
        return "%d:%02d".format(s / 60, s % 60)
    }
}
