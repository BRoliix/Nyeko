package com.coucou.android.core

import com.coucou.android.link.PairingPayload

/** What to do with text that came out of the camera. */
sealed interface ScanDecision {
    /** A well-formed Coucou pairing link: ask the user to confirm, then pair like a pasted link. */
    data class Pairing(val link: String) : ScanDecision

    /** Anything else (a website, a Wi-Fi code, a shop's QR): ignored, with a short hint. */
    data object NotPairing : ScanDecision
}

object PairingScan {
    /**
     * Uses the very parser that pasting uses, so a scanned code and a pasted link are accepted and refused
     * for the same reasons. The text is returned untouched (apart from trimming) and never logged.
     */
    fun decide(text: String?): ScanDecision {
        val raw = text?.trim().orEmpty()
        if (raw.isEmpty() || raw.length > MAX_LINK) return ScanDecision.NotPairing
        // Nyeko: the Mac's big QR (the web app's link, https://…/#pair=…) carries this app's own link too.
        val t = fromNyekoWebLink(raw) ?: raw
        return if (PairingPayload.parse(t) != null) ScanDecision.Pairing(t) else ScanDecision.NotPairing
    }

    /**
     * Nyeko's web pairing link is `https://<site>/#pair=<base64url JSON>`; its `android` field is the coucou://pair link of
     * this app. Null for anything else.
     */
    fun fromNyekoWebLink(text: String): String? {
        if (!text.startsWith("https://") || !text.contains("#pair=")) return null
        return try {
            val json = String(java.util.Base64.getUrlDecoder().decode(text.substringAfter("#pair=").trim()), Charsets.UTF_8)
            org.json.JSONObject(json).optString("android", "").takeIf { (it.startsWith("nyeko://pair?") || it.startsWith("coucou://pair?")) && it.length <= MAX_LINK }
        } catch (_: Exception) {
            null
        }
    }

    /** A real pairing link is a few hundred characters (up to about 900 with the relay fields and a long, accented name); anything far longer is not one. */
    const val MAX_LINK = 2_048
}

/** Where the camera permission stands, for the scan screen. */
object ScanPermission {
    enum class State {
        /** The camera may be used. */
        GRANTED,
        /** Show the one-line reason and the "Allow camera" button. */
        ASK,
        /** Refused for good: Android will not ask again, so point to its settings or to pasting. */
        BLOCKED,
    }

    /**
     * [askedBefore]: we have shown Android's prompt at least once. [canExplain]: Android says the prompt can
     * still be shown (it was refused once, not for good).
     */
    fun state(granted: Boolean, askedBefore: Boolean, canExplain: Boolean): State = when {
        granted -> State.GRANTED
        !askedBefore -> State.ASK
        canExplain -> State.ASK
        else -> State.BLOCKED
    }
}
