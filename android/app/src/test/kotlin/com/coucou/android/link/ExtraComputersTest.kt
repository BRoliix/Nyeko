package com.coucou.android.link

import com.coucou.android.core.ComputerTag
import com.coucou.android.core.NyekoData
import com.coucou.android.core.Pills
import com.coucou.android.mochi.BotState
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Nyeko: one phone, several computers. Ids are tagged per computer and everything goes back to the right one. */
class ExtraComputersTest {
    private fun pairing(room: String, name: String) = PairingPayload(
        "", 0, "", "t".repeat(32), name, RelayPairing("wss://r.example.workers.dev", room, "B".repeat(42) + "A", "C".repeat(42) + "A"),
    )

    /** A link that records what the app asks of it and lets the test speak for the computer. */
    private class Fake(val listener: LinkListener) : DesktopLink {
        override val approvals = ApprovalBook { 0L }
        val sent = ArrayList<JSONObject>()
        val decided = ArrayList<String>()
        val known = HashSet<String>()
        var started = false
        var stopped = false
        override fun start() { started = true }
        override fun stop() { stopped = true }
        override fun decide(fingerprint: String, allow: Boolean): Boolean = (fingerprint in known).also { if (it) decided.add(fingerprint) }
        override fun getDiff(pillId: String, fileId: Long): Boolean { sent.add(JSONObject().put("diff", pillId)); return true }
        override fun nyeko(body: JSONObject): Boolean { sent.add(body); return true }
    }

    private class Sink : ExtraComputers.Sink {
        val sessions = HashMap<String, List<SessionInfo>>()
        val approvals = ArrayList<ApprovalRequest>()
        val nyeko = ArrayList<Pair<String, JSONObject>>()
        override fun extraSessions(key: String, sessions: List<SessionInfo>) { this.sessions[key] = sessions }
        override fun extraApproval(key: String, request: ApprovalRequest) { approvals.add(request) }
        override fun extraNyeko(key: String, type: String, body: JSONObject) { nyeko.add(key to body) }
    }

    @Test fun tagsGoOnAndComeOffAndTheFirstComputerHasNone() {
        val key = ComputerTag.keyFor(pairing("ROOM1", "Work Mac"))
        assertTrue(Regex("c[0-9a-f]{8}").matches(key))
        val id = ComputerTag.tag("claude|abc-123", key)
        assertEquals(key, ComputerTag.keyOf(id))
        assertEquals("claude|abc-123", ComputerTag.untag(id))
        assertEquals("claude|abc-123", ComputerTag.tag("claude|abc-123", ComputerTag.PRIMARY))
        assertEquals(ComputerTag.PRIMARY, ComputerTag.keyOf("claude|abc-123"))
        // An address in a session id is not a tag.
        assertEquals("x|me@example.com", ComputerTag.untag("x|me@example.com"))
        // The pill still reads from a tagged id.
        assertEquals("Claude Code", Pills.byId(ComputerTag.tag("integration_claude|s9", key))?.name)
    }

    @Test fun theSameComputerPairedAgainIsRecognisedByItsIdNeverByItsName() {
        val work = pairing("ROOM1", "MacBook Pro").copy(computerId = "workAccount01")
        assertTrue(ComputerTag.sameComputer(work, pairing("ROOM2", "MacBook Pro · work").copy(computerId = "workAccount01")))
        // Two accounts on one Mac share its name: two computers.
        assertFalse(ComputerTag.sameComputer(work, pairing("ROOM2", "MacBook Pro").copy(computerId = "homeAccount02")))
        assertFalse(ComputerTag.sameComputer(pairing("ROOM1", "MacBook Pro"), pairing("ROOM2", "MacBook Pro")))
        assertTrue(ComputerTag.sameComputer(pairing("ROOM1", "A"), pairing("ROOM1", "B")))
        assertNotEquals(ComputerTag.keyFor(pairing("ROOM1", "A")), ComputerTag.keyFor(pairing("ROOM2", "A")))
    }

    @Test fun theComputersIdComesFromTheLinkAndIsKept() {
        val link = "coucou://pair?v=1&relay=wss%3A%2F%2Frelay.example.com&room=" + "R".repeat(21) + "A&key=" + "K".repeat(42) +
            "A&access=" + "a".repeat(20) + "&token=" + "t".repeat(32) + "&name=Mac&cid=abcDEF123_-x"
        val p = PairingPayload.parse(link)!!
        assertEquals("abcDEF123_-x", p.computerId)
        assertEquals(p, PairingCodec.decode(PairingCodec.encode(p)))
        val older = p.copy(computerId = "")
        assertEquals(older, PairingCodec.decode(PairingCodec.encode(older)))
        val lan = PairingPayload("192.168.1.2", 47821, "a".repeat(64), "t".repeat(32), "PC", null, "lanId12345")
        assertEquals(lan, PairingCodec.decode(PairingCodec.encode(lan)))
        assertEquals("", PairingPayload.parse(link.replace("cid=abcDEF123_-x", "cid=bad!id"))!!.computerId)
    }

    @Test fun eachComputerSpeaksWithItsTagAndIsAnsweredWithout() {
        val fakes = HashMap<String, Fake>()
        val sink = Sink()
        val hub = ExtraComputers("Phone", sink, connectorFor = { Connector { error("unused") } }, clientFor = { p, l, _ -> Fake(l).also { fakes[p.desktopName] = it } })
        val a = hub.start(pairing("ROOM1", "Work Mac"))
        val b = hub.start(pairing("ROOM2", "Home PC"))
        assertTrue(fakes.values.all { it.started })
        val pc = fakes.getValue("Home PC")

        pc.listener.onSessions(listOf(SessionInfo("claude|s1", "Claude Code", BotState.WORKING, "", 0, 0, 0L)))
        assertEquals(ComputerTag.tag("claude|s1", b), sink.sessions.getValue(b).single().pillId)

        pc.listener.onApproval(ApprovalRequest("claude|s1", "fp1", "Bash", "ls", 0L))
        assertEquals(b, ComputerTag.keyOf(sink.approvals.single().pillId))
        // Only the computer that holds the approval takes the decision.
        pc.known.add("fp1")
        assertTrue(hub.decide("fp1", true))
        assertEquals(listOf("fp1"), pc.decided)
        assertTrue(fakes.getValue("Work Mac").decided.isEmpty())
        assertFalse(hub.decide("nope", true))

        // A conversation comes back named as the merged list names it; a diff is asked with the computer's own id.
        pc.listener.onNyeko("chat", JSONObject().put("type", "chat").put("session", "claude|s1"))
        assertEquals(ComputerTag.tag("claude|s1", b), sink.nyeko.single().second.getString("session"))
        assertTrue(hub.getDiff(ComputerTag.tag("claude|s1", b), 3))
        assertEquals("claude|s1", pc.sent.last().getString("diff"))
        assertTrue(hub.nyeko(a, NyekoData.status()))
        assertEquals("status", fakes.getValue("Work Mac").sent.single().getString("type"))

        // Removed: its link stops, and what it still says is dropped.
        hub.stop(b)
        assertTrue(pc.stopped)
        pc.listener.onSessions(emptyList())
        assertEquals(1, sink.sessions.getValue(b).size)
        assertEquals(listOf(a), hub.keys())
        assertNull(hub.pairing(b))
    }

    @Test fun theAppListIsReadSortedAndCapped() {
        val arr = org.json.JSONArray()
        arr.put(JSONObject().put("id", "z").put("name", "Zoom"))
        arr.put(JSONObject().put("id", "a").put("name", "arc"))
        arr.put(JSONObject().put("name", "no id"))
        val apps = NyekoData.appList(JSONObject().put("type", "apps").put("apps", arr))
        assertEquals(listOf("arc", "Zoom"), apps.map { it.name })
        assertEquals("PC", NyekoData.kindWord("windows"))
        assertEquals("Mac", NyekoData.kindWord(""))
        val m = NyekoData.mac(JSONObject().put("volume", 40).put("muted", true).put("os", "windows").put("name", "Home PC"), 0L)
        assertEquals(40, m.volume)
        assertTrue(m.muted)
        assertEquals("Home PC", m.name)
    }
}
