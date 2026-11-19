package com.coucou.android.core

import com.coucou.android.link.PairingPayload
import java.security.MessageDigest

/**
 * Nyeko: one phone, several computers. The first computer paired keeps its session ids as they are; the others' are tagged
 * with the computer's key ("claude|abc@c1a2b3c4d") so every session, approval and question in the merged lists is unique and
 * goes back to the computer it came from. Pure: tested on the JVM.
 */
object ComputerTag {
    /** The key of the first computer (its ids carry no tag). */
    const val PRIMARY = ""

    private val TAG = Regex("@(c[0-9a-f]{8})$")

    fun tag(id: String, key: String): String = if (key.isEmpty()) id else "$id@$key"

    /** The computer an id belongs to: [PRIMARY] when it carries no tag. */
    fun keyOf(id: String): String = TAG.find(id)?.groupValues?.get(1) ?: PRIMARY

    /** The id as its own computer knows it. */
    fun untag(id: String): String = TAG.find(id)?.let { id.substring(0, it.range.first) } ?: id

    /**
     * A stable key for a computer: its relay room when it has one (a Nyeko pairing), else its pinned certificate.
     * Pairing the same computer again in a new room gives a new key: [sameComputer] also looks at the computer's id.
     */
    fun keyFor(p: PairingPayload): String {
        val basis = p.relay?.room?.takeIf { it.isNotEmpty() } ?: (p.certSha256 + "|" + p.host)
        val d = MessageDigest.getInstance("SHA-256").digest(basis.toByteArray(Charsets.UTF_8))
        return "c" + d.take(4).joinToString("") { "%02x".format(it) }
    }

    /**
     * The same computer, paired again (a new room or token): same key, or the same id the computer gave itself. Never the
     * name: two accounts on one Mac (or two computers called "MacBook Pro") are two computers.
     */
    fun sameComputer(a: PairingPayload, b: PairingPayload): Boolean =
        keyFor(a) == keyFor(b) || (a.computerId.isNotEmpty() && a.computerId == b.computerId)
}
