package com.coucou.android.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.coucou.android.core.ComputerTag
import com.coucou.android.core.NyekoData
import java.security.SecureRandom
import org.json.JSONObject

/**
 * What the app knows of Nyeko on the paired computers, for the screens (main thread only): each computer's status and controls,
 * Nyo's chat, the coding session open on the phone (its conversation, messages to it) and a new session being started.
 * [send] puts a message on a computer's link (by key, see [ComputerTag]); it is false when that link is down or the computer
 * does not speak Nyeko.
 */
class NyekoModel(private val send: (key: String, body: JSONObject) -> Boolean) {
    /** The computers that offered `nyeko` on their connection (keys, see [ComputerTag]; the first computer is ""). */
    val offeredBy = mutableStateListOf<String>()
    /** Some computer offered `nyeko`. */
    val available: Boolean get() = offeredBy.isNotEmpty()
    /** Each computer's status card. */
    private val macs = mutableStateMapOf<String, NyekoData.MacStatus>()
    /** The computer the Mac card, Nyo and a new session talk to (picked on Home when there are several). */
    var current by mutableStateOf(ComputerTag.PRIMARY); private set
    /** The computer in use: [current] when it speaks Nyeko, else the first one that does. */
    val target: String get() = current.takeIf { it in offeredBy } ?: offeredBy.firstOrNull() ?: ComputerTag.PRIMARY
    val mac: NyekoData.MacStatus? get() = macs[target]
    fun macOf(key: String): NyekoData.MacStatus? = macs[key]

    /** Every installed app of the computer in use, once asked for ("Open any app"). */
    var allApps by mutableStateOf<List<NyekoData.NamedId>?>(null); private set
    private var allAppsOf = ""

    // Nyo's chat (a message to Nyo runs a command on the computer, or goes to Claude there).
    data class ChatLine(val me: Boolean, val text: String)
    val nyoChat = mutableStateListOf<ChatLine>()
    private val waitingReplies = HashSet<String>()
    var nyoThinking by mutableStateOf(false); private set

    // The coding session open on the phone (its id as the merged list names it).
    var openSession by mutableStateOf<String?>(null); private set
    var thread by mutableStateOf<NyekoData.Thread?>(null); private set
    data class Sending(val id: String, val text: String)
    val sending = mutableStateListOf<Sending>()

    // A new session: the folder picked, and the one being started.
    data class Starting(val id: String, val name: String, val atMs: Long, val launched: Boolean = false, val on: String = ComputerTag.PRIMARY)
    var starting by mutableStateOf<Starting?>(null); private set
    /** Set when the started session is known: the UI opens it once and clears this. */
    var openWhenReady by mutableStateOf<String?>(null)

    /** A short line for the user (a toast or the message panel); the UI shows it and clears it. */
    var notice by mutableStateOf<String?>(null)

    /** Messages to a session and new sessions ask for the screen lock, then not again for this long. */
    private var unlockedUntilMs = 0L
    fun unlocked(nowMs: Long = System.currentTimeMillis()) = nowMs < unlockedUntilMs
    fun markUnlocked(nowMs: Long = System.currentTimeMillis()) { unlockedUntilMs = nowMs + UNLOCK_MS }

    fun use(key: String) {
        if (current == key) return
        current = key
        allApps = null
        if (key in offeredBy) send(key, NyekoData.status())
    }

    fun offered(key: String, on: Boolean) {
        if (!on) { linkLost(key); return }
        if (key !in offeredBy) offeredBy.add(key)
        send(key, NyekoData.status())
        openSession?.let { s -> if (ComputerTag.keyOf(s) == key) send(key, NyekoData.open(ComputerTag.untag(s))) }
    }

    fun linkLost(key: String) {
        offeredBy.remove(key)
        if (key == allAppsOf) allApps = null
        if (offeredBy.isEmpty()) {
            nyoThinking = false
            waitingReplies.clear()
        }
        openSession?.let { s -> if (ComputerTag.keyOf(s) == key) sending.clear() }
    }

    /** The computer was removed from this phone. */
    fun forget(key: String) {
        linkLost(key)
        macs.remove(key)
        if (current == key) current = ComputerTag.PRIMARY
    }

    fun receive(key: String, type: String, body: JSONObject) {
        when (type) {
            "mac" -> macs[key] = NyekoData.mac(body, System.currentTimeMillis())
            "apps" -> if (key == target) { allApps = NyekoData.appList(body); allAppsOf = key }
            "reply" -> {
                val id = body.optString("id")
                if (waitingReplies.remove(id)) {
                    nyoChat.add(ChatLine(false, NyekoData.clean(body.optString("text"), 20_000)))
                    nyoThinking = waitingReplies.isNotEmpty()
                }
            }
            "chat" -> NyekoData.thread(body)?.let { if (it.session == openSession) thread = it }
            "said" -> {
                val s = NyekoData.said(body)
                sending.removeAll { it.id == s.id }
                notice = when (s.result) {
                    "typed" -> "Sent to Claude."
                    else -> s.note.ifEmpty { if (s.result == "queued") "It goes to Claude when it finishes this turn." else "Not sent." }
                }
            }
            "launched" -> {
                val st = starting ?: return
                if (body.optString("id") != st.id) return
                if (body.optBoolean("ok")) starting = st.copy(launched = true)
                else { starting = null; notice = NyekoData.clean(body.optString("note"), 300).ifEmpty { "The session could not start." } }
            }
            "started" -> {
                val st = starting ?: return
                if (body.optString("id") != st.id) return
                starting = null
                openWhenReady = NyekoData.clean(body.optString("session"), 260).takeIf { it.isNotEmpty() }
            }
        }
    }

    // ── From the screens ───────────────────────────────────────────────────────────────────────────────────────────

    fun refresh() { offeredBy.toList().forEach { send(it, NyekoData.status()) } }

    /** An action on the computer in use. */
    fun control(action: String, app: String? = null): Boolean = send(target, NyekoData.control(action, app)).also {
        if (!it) notice = NOT_CONNECTED
    }

    /** Brings a session's window forward on the computer it runs on. */
    fun focus(session: String): Boolean =
        send(ComputerTag.keyOf(session), NyekoData.control("focus", ComputerTag.untag(session))).also { if (!it) notice = NOT_CONNECTED }

    /** Asks the computer in use for every installed app (the answer fills [allApps]). */
    fun listApps() { allApps = null; allAppsOf = target; send(target, NyekoData.listApps()) }

    fun askNyo(text: String) {
        val t = text.trim().take(4000)
        if (t.isEmpty()) return
        val id = newId()
        if (!send(target, NyekoData.ask(id, t))) { notice = NOT_CONNECTED; return }
        nyoChat.add(ChatLine(true, t))
        waitingReplies.add(id)
        nyoThinking = true
    }

    fun open(session: String) {
        if (openSession == session) return
        openSession = session
        thread = null
        sending.clear()
        send(ComputerTag.keyOf(session), NyekoData.open(ComputerTag.untag(session)))
    }

    fun close() {
        val s = openSession ?: return
        openSession = null
        thread = null
        sending.clear()
        send(ComputerTag.keyOf(s), NyekoData.close())
    }

    /** Call only after the screen lock (see [unlocked]). */
    fun say(text: String): Boolean {
        val session = openSession ?: return false
        val t = text.trim()
        if (t.isEmpty()) return false
        val id = newId()
        if (!send(ComputerTag.keyOf(session), NyekoData.say(ComputerTag.untag(session), id, t))) { notice = NOT_CONNECTED; return false }
        sending.add(Sending(id, t))
        return true
    }

    fun unqueue() { openSession?.let { send(ComputerTag.keyOf(it), NyekoData.unqueue(ComputerTag.untag(it))) } }

    /** Call only after the screen lock. */
    fun launch(project: NyekoData.NamedId, prompt: String): Boolean {
        if (starting != null) return false
        val id = newId()
        val on = target
        if (!send(on, NyekoData.launch(id, project.id, prompt.trim()))) { notice = NOT_CONNECTED; return false }
        starting = Starting(id, project.name, System.currentTimeMillis(), on = on)
        return true
    }

    fun cancelStarting() { starting = null }

    private fun newId(): String {
        val b = ByteArray(9).also { SecureRandom().nextBytes(it) }
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(b)
    }

    companion object {
        const val UNLOCK_MS = 10 * 60_000L
        const val NOT_CONNECTED = "That computer is not connected."
    }
}
