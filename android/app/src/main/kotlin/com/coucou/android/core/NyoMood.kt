package com.coucou.android.core

import com.coucou.android.mochi.BotState

/** How Nyo looks, from every session at once: the most urgent one wins. Pure, tested. */
enum class NyoMood {
    SLEEPING, IDLE, WORKING, NEEDS_YOU, DONE;

    companion object {
        fun of(states: List<BotState>, connected: Boolean): NyoMood = when {
            !connected -> SLEEPING
            states.any { it == BotState.APPROVAL || it == BotState.QUESTION || it == BotState.ERROR || it == BotState.RATELIMIT } -> NEEDS_YOU
            states.any { it == BotState.WORKING || it == BotState.THINKING || it == BotState.SEARCHING } -> WORKING
            states.any { it == BotState.FINISHED } -> DONE
            states.isEmpty() -> SLEEPING
            else -> IDLE
        }

        /** One agent's state as Nyo's face (Nyo stands in for Mochi everywhere he was drawn). */
        fun of(state: BotState): NyoMood = when (state) {
            BotState.APPROVAL, BotState.QUESTION, BotState.ERROR, BotState.RATELIMIT -> NEEDS_YOU
            BotState.WORKING, BotState.THINKING, BotState.SEARCHING -> WORKING
            BotState.FINISHED -> DONE
            BotState.SLEEPING -> SLEEPING
            BotState.IDLE, BotState.DIZZY -> IDLE
        }

        /** Words for the floating Nyo's label and TalkBack. */
        fun words(mood: NyoMood, waiting: Int): String = when (mood) {
            NyoMood.NEEDS_YOU -> if (waiting > 1) "$waiting sessions need you" else "Claude needs you"
            NyoMood.WORKING -> "Claude is working"
            NyoMood.DONE -> "Done"
            NyoMood.IDLE -> "All calm"
            NyoMood.SLEEPING -> "Nyo is asleep"
        }
    }
}
