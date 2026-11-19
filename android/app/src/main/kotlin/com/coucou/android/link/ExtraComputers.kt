package com.coucou.android.link

import com.coucou.android.core.ComputerTag

/**
 * Nyeko: the computers this phone is paired with besides the first one (which keeps its own link in AppModel, with the
 * local-network search and the rest). One [LinkClient] each, through the relay when the pairing has one. Everything they say
 * reaches [Sink] with their key, and their session ids already tagged ([ComputerTag]), so the app merges them with the first
 * computer's. Calls come from any thread; the sink is called on the link threads.
 */
class ExtraComputers(
    private val deviceName: String,
    private val sink: Sink,
    private val connectorFor: (PairingPayload) -> Connector = { p ->
        val r = p.relay
        if (r != null) RelayConnector(r) else PinnedTls.connector(p)
    },
    private val clientFor: (PairingPayload, LinkListener, Connector) -> DesktopLink = { p, l, c -> LinkClient(p, deviceName, l, connector = c) },
) {
    interface Sink {
        fun extraState(key: String, state: LinkState) {}
        fun extraWelcome(key: String, name: String, os: String) {}
        fun extraCaps(key: String, caps: Set<String>) {}
        fun extraSessions(key: String, sessions: List<SessionInfo>) {}
        fun extraApproval(key: String, request: ApprovalRequest) {}
        fun extraQuestion(key: String, request: QuestionRequest) {}
        fun extraResolved(key: String, fingerprint: String) {}
        fun extraDiff(key: String, part: ServerMsg.Diff) {}
        fun extraNyeko(key: String, type: String, body: org.json.JSONObject) {}
        fun extraRelayAccess(key: String, access: String) {}
        fun extraError(key: String, code: String, message: String) {}
    }

    private class Entry(val key: String, val pairing: PairingPayload, val client: DesktopLink, val listener: Tagger)

    private val entries = LinkedHashMap<String, Entry>()

    @Synchronized fun keys(): List<String> = entries.keys.toList()
    @Synchronized fun pairing(key: String): PairingPayload? = entries[key]?.pairing
    @Synchronized fun pairings(): List<PairingPayload> = entries.values.map { it.pairing }
    @Synchronized fun isEmpty() = entries.isEmpty()

    /** Starts (or restarts, with the new pairing) this computer's link. Returns its key. */
    fun start(p: PairingPayload): String {
        val key = ComputerTag.keyFor(p)
        val old: Entry?
        val entry: Entry
        synchronized(this) {
            old = entries.remove(key)
            val tagger = Tagger(key)
            entry = Entry(key, p, clientFor(p, tagger, connectorFor(p)), tagger)
            entries[key] = entry
        }
        old?.let { it.listener.alive = false; it.client.stop() }
        entry.client.start()
        return key
    }

    fun stop(key: String) {
        val e = synchronized(this) { entries.remove(key) } ?: return
        e.listener.alive = false
        e.client.stop()
    }

    fun stopAll() {
        val all = synchronized(this) { entries.values.toList().also { entries.clear() } }
        all.forEach { it.listener.alive = false; it.client.stop() }
    }

    private fun clients() = synchronized(this) { entries.values.map { it.client } }

    fun retryNow() = clients().forEach { it.retryNow() }
    fun checkNow() = clients().forEach { it.checkNow() }

    /** Only the computer that holds the approval knows its fingerprint: the others say no and change nothing. */
    fun decide(fingerprint: String, allow: Boolean): Boolean = clients().any { it.decide(fingerprint, allow) }
    fun answer(fingerprint: String, picks: List<List<String>>): Boolean = clients().any { it.answer(fingerprint, picks) }

    fun getDiff(taggedPill: String, fileId: Long): Boolean {
        val e = synchronized(this) { entries[ComputerTag.keyOf(taggedPill)] } ?: return false
        return e.client.getDiff(ComputerTag.untag(taggedPill), fileId)
    }

    fun nyeko(key: String, body: org.json.JSONObject): Boolean {
        val e = synchronized(this) { entries[key] } ?: return false
        return e.client.nyeko(body)
    }

    /** Puts this computer's key on what it says, and drops what a stopped link still says. */
    private inner class Tagger(val key: String) : LinkListener {
        @Volatile var alive = true

        private fun t(id: String) = ComputerTag.tag(id, key)

        override fun onState(state: LinkState) { if (alive) sink.extraState(key, state) }
        override fun onWelcome(desktopName: String, os: String) { if (alive) sink.extraWelcome(key, desktopName, os) }
        override fun onCaps(caps: Set<String>) { if (alive) sink.extraCaps(key, caps) }
        override fun onSessions(sessions: List<SessionInfo>) { if (alive) sink.extraSessions(key, sessions.map { it.copy(pillId = t(it.pillId)) }) }
        override fun onApproval(request: ApprovalRequest) { if (alive) sink.extraApproval(key, request.copy(pillId = t(request.pillId))) }
        override fun onApprovalResolved(fingerprint: String) { if (alive) sink.extraResolved(key, fingerprint) }
        override fun onQuestion(request: QuestionRequest) { if (alive) sink.extraQuestion(key, request.copy(pillId = t(request.pillId))) }
        override fun onDiff(part: ServerMsg.Diff) { if (alive) sink.extraDiff(key, part.copy(pillId = t(part.pillId))) }
        override fun onRelayAccess(access: String) { if (alive) sink.extraRelayAccess(key, access) }
        override fun onError(code: String, message: String) { if (alive) sink.extraError(key, code, message) }
        override fun onNyeko(type: String, body: org.json.JSONObject) {
            if (!alive) return
            // The session a conversation or a new session is about, as the merged list names it.
            body.optString("session").takeIf { it.isNotEmpty() }?.let { body.put("session", t(it)) }
            sink.extraNyeko(key, type, body)
        }
    }
}
