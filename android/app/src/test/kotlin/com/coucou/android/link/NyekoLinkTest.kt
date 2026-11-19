package com.coucou.android.link

import com.coucou.android.core.NyekoData
import com.coucou.android.core.NyoMood
import com.coucou.android.mochi.BotState
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Nyeko on the Mac: its relay-only pairing link, its messages, and Nyo's mood. */
class NyekoLinkTest {
    private val room = "AAAAAAAAAAAAAAAAAAAAAA"
    private val key = "B".repeat(42) + "A"

    @Test fun aRelayOnlyLinkPairsWithNoAddress() {
        val p = PairingPayload.parse("coucou://pair?v=1&relay=wss%3A%2F%2Fr.example.workers.dev&room=$room&key=$key&access=${"C".repeat(42)}A&token=${"t".repeat(32)}&name=Neko%27s%20Mac")
        assertNotNull(p)
        assertTrue(p!!.relayOnly)
        assertEquals("", p.host)
        assertEquals("Neko's Mac", p.desktopName)
        // Kept and read back unchanged.
        assertEquals(p, PairingCodec.decode(PairingCodec.encode(p)))
    }

    @Test fun aLinkWithNoAddressAndNoRelayIsRefused() {
        assertNull(PairingPayload.parse("coucou://pair?v=1&token=${"t".repeat(32)}&name=Mac"))
    }


    @Test fun nyekoMessagesAreKeptAsJsonAndOthersStayUnknown() {
        val m = Wire.decodeServer("""{"type":"mac","recording":true}""")
        assertTrue(m is ServerMsg.Nyeko && m.type == "mac")
        assertNull(Wire.decodeServer("""{"type":"whatever"}"""))
        assertEquals("""{"type":"status"}""", Wire.encode(ClientMsg.Nyeko(NyekoData.status())))
    }

    @Test fun theMacStatusAndAConversationAreRead() {
        val mac = NyekoData.mac(JSONObject("""{"nowPlaying":{"title":"Song","artist":"A","source":"Spotify","playing":true,"duration":200,"position":12},
            "timer":{"phase":"work","paused":false,"remaining":300},"battery":{"percent":80,"charging":true},
            "projects":[{"id":"ab12","name":"Kestrel","where":"~"},{"name":"no id"}],"apps":[]}"""), 1L)
        assertEquals("Song", mac.nowPlaying?.title)
        assertEquals(200.0, mac.nowPlaying?.durationS)
        assertEquals(listOf("ab12"), mac.projects.map { it.id })
        assertEquals(80, mac.batteryPercent)
        val th = NyekoData.thread(JSONObject("""{"session":"integration_claude|s1","state":"idle","readable":true,"canMessage":true,
            "delivery":"tab","note":"n","items":[{"r":"you","t":"hi\u0007"},{"r":"tools","t":"Read a.kt\nRan ls"},{"r":"claude","t":"ok"},{"r":"x","t":"?"}],"queued":["later"]}"""))!!
        assertEquals(3, th.lines.size)
        assertEquals("hi", th.lines[0].text)
        assertEquals(listOf("later"), th.queued)
        assertEquals("n", NyekoData.hint(th))
        assertEquals("Claude is working: it reads your message when it finishes this turn.", NyekoData.hint(th.copy(state = "working")))
    }

    @Test fun nyoShowsTheMostUrgentSession() {
        assertEquals(NyoMood.SLEEPING, NyoMood.of(listOf(BotState.WORKING), connected = false))
        assertEquals(NyoMood.NEEDS_YOU, NyoMood.of(listOf(BotState.WORKING, BotState.APPROVAL), connected = true))
        assertEquals(NyoMood.WORKING, NyoMood.of(listOf(BotState.IDLE, BotState.THINKING), connected = true))
        assertEquals(NyoMood.IDLE, NyoMood.of(listOf(BotState.IDLE), connected = true))
        assertFalse(NyoMood.words(NyoMood.NEEDS_YOU, 2).isEmpty())
    }

    @Test fun theMacsWebQrAlsoPairsTheApp() {
        val link = "coucou://pair?v=1&relay=wss%3A%2F%2Fr.example.workers.dev&room=$room&key=$key&access=${"C".repeat(42)}A&token=${"t".repeat(32)}&name=Mac"
        val json = """{"v":1,"relay":"wss://r.example.workers.dev","android":"$link"}"""
        val web = "https://nyeko-phone.pages.dev/#pair=" + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(json.toByteArray())
        val d = com.coucou.android.core.PairingScan.decide(web)
        assertTrue(d is com.coucou.android.core.ScanDecision.Pairing && d.link == link)
        assertTrue(com.coucou.android.core.PairingScan.decide("https://example.com/#pair=abc") is com.coucou.android.core.ScanDecision.NotPairing)
    }

    @Test fun anAccessKeyOfAnotherShapeIsAccepted() {
        assertNotNull(PairingPayload.parse("coucou://pair?v=1&relay=wss%3A%2F%2Fr.example&room=$room&key=$key&access=my-own_relay-key-2026&token=${"t".repeat(32)}"))
    }
}
