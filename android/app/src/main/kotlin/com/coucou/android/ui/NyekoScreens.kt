package com.coucou.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.coucou.android.app.AppModel
import com.coucou.android.app.NyekoModel
import com.coucou.android.core.NyekoData
import com.coucou.android.core.Spacing
import com.coucou.android.core.TypeScale
import com.coucou.android.nyeko.NyoColors
import kotlinx.coroutines.delay

// Nyeko's screens: the Mac card on Home, a coding session's conversation, a new session, and Nyo's chat.
// Their words are English only (Nyeko is a private build); the rest of the app keeps its translations.

/** Asks for the screen lock (once every 10 minutes) and then runs the action. Given by MainActivity. */
typealias Unlock = (then: () -> Unit) -> Unit

// ── Home: your Mac ──────────────────────────────────────────────────────────────────────────────────────────────────

/** Asks for the screen lock every time, then runs a power action (restart, shut down). Given by MainActivity. */
typealias ConfirmPower = (what: String, then: () -> Unit) -> Unit

/** "Mac" or "PC", for the computer Nyeko talks to now. */
fun kindWord(model: AppModel): String = NyekoData.kindWord(model.nyeko.mac?.os.orEmpty())

/** The computers that speak Nyeko, to pick the one the card, Nyo and a new session talk to (shown with two or more). */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ComputerPicker(model: AppModel) {
    val n = model.nyeko
    if (n.offeredBy.size < 2) return
    val t = tokens()
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        n.offeredBy.forEach { key ->
            val on = key == n.target
            val name = n.macOf(key)?.name?.takeIf { it.isNotEmpty() } ?: model.computerName(key).ifBlank { "Computer" }
            Text(
                name,
                Modifier.heightIn(min = Spacing.MIN_TOUCH.dp).clip(RoundedCornerShape(50))
                    .background(if (on) NyoColors.mint else t.panel.c())
                    .border(2.dp, if (on) NyoColors.ink else t.line.c(), RoundedCornerShape(50))
                    .clickable(role = Role.RadioButton) { n.use(key) }
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                style = TypeScale.BODY.style(if (on) NyoColors.ink else t.text.c()).copy(fontWeight = FontWeight.SemiBold),
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun MacPanel(model: AppModel, onNewSession: () -> Unit, confirmPower: ConfirmPower = { _, then -> then() }) {
    val n = model.nyeko
    if (!n.available) return
    val t = tokens()
    val m = n.mac
    val kind = kindWord(model)
    val isMac = kind == "Mac"
    val title = m?.name?.takeIf { it.isNotEmpty() } ?: model.computerName(n.target).ifBlank { "Your $kind" }
    var armed by remember { mutableStateOf<String?>(null) }
    var findApp by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(Gap)) {
        PillButton("+ New session", onNewSession, Modifier.fillMaxWidth(), kind = PillKind.PRIMARY)
        ComputerPicker(model)
        SectionHeading(title)
        Panel {
            if (m == null) {
                Text("Loading your $kind…", Modifier.padding(Gutter), style = TypeScale.SECONDARY.style(t.textDim.c()))
                return@Panel
            }
            // Now playing
            val np = m.nowPlaying
            Column(Modifier.padding(Gutter), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (np != null) {
                    Text(np.title, style = TypeScale.BODY.style(t.text.c()).copy(fontWeight = FontWeight.SemiBold), maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text(listOf(np.artist, np.source).filter { it.isNotEmpty() }.joinToString(" · "), style = TypeScale.SECONDARY.style(t.textDim.c()), maxLines = 1, overflow = TextOverflow.Ellipsis)
                } else {
                    Text("Nothing is playing on your $kind.", style = TypeScale.SECONDARY.style(t.textDim.c()))
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    PillButton("⏮", { n.control("previous") })
                    PillButton(if (np?.playing == true) "Pause" else "Play", { n.control("playPause") }, kind = PillKind.PRIMARY)
                    PillButton("⏭", { n.control("next") })
                }
            }
            RowDivider()
            m.next?.let { e ->
                ListRow(e.title, hint = "Next up · ${e.whenText}")
                RowDivider()
            }
            if (isMac) {
                val timer = m.timer
                ListRow(
                    "Focus timer",
                    hint = if (timer != null) "${if (timer.work) "Work" else "Break"}${timer.remainingS?.let { " · ${NyekoData.mmss(it.toDouble())} left" } ?: ""}"
                    else "25 min of work, 5 of rest",
                    trailing = { PillButton(if (timer != null) "Stop" else "Start", { n.control("timer") }) },
                )
                RowDivider()
                ListRow(
                    "Notetaker", hint = if (m.recording) "Recording a meeting" else "Record and transcribe a call",
                    trailing = { PillButton(if (m.recording) "Stop" else "Record", { n.control("record") }, kind = if (m.recording) PillKind.DANGER else PillKind.SECONDARY) },
                )
                RowDivider()
            }
            ListRow(
                "Screenshot", hint = "Of the $kind's screen, kept on the $kind",
                trailing = { PillButton("Take", { if (n.control("screenshot")) n.notice = "Screenshot taken on your $kind." }) },
            )
            m.batteryPercent?.let {
                RowDivider()
                ListRow("Battery", hint = "$it%${if (m.charging) " · charging" else ""}")
            }
        }
        if (m != null) {
            SectionHeading("Sound")
            Panel {
                ListRow(
                    if (m.muted) "Muted" else m.volume?.let { "Volume $it%" } ?: "Volume",
                    trailing = {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            PillButton("−", { n.control("volumeDown") })
                            PillButton(if (m.muted) "Unmute" else "Mute", { n.control("mute") })
                            PillButton("+", { n.control("volumeUp") })
                        }
                    },
                )
            }
            SectionHeading("Lock and power")
            Panel {
                Column(Modifier.padding(Gutter), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        PillButton("Lock", { if (n.control("lock")) n.notice = "Locking your $kind." })
                        PillButton("Screen off", { if (n.control("displaySleep")) n.notice = "Turning the screen off." })
                        PillButton("Sleep", { if (n.control("sleep")) n.notice = "Your $kind is going to sleep." })
                        // Restart and shut down: tap, tap again, then the screen lock. Open apps may ask to save first.
                        for ((action, label) in listOf("restart" to "Restart", "shutdown" to "Shut down")) {
                            PillButton(
                                if (armed == action) "$label now?" else label,
                                {
                                    if (armed != action) armed = action
                                    else {
                                        armed = null
                                        confirmPower("$label your $kind") { if (n.control(action)) n.notice = "$label in a few seconds." }
                                    }
                                },
                                kind = if (armed == action) PillKind.DANGER else PillKind.SECONDARY,
                            )
                        }
                    }
                    if (armed != null) Text(
                        "Tap again to ${if (armed == "restart") "restart" else "shut down"}. Unsaved work in open apps may be lost.",
                        style = TypeScale.SECONDARY.style(t.textDim.c()),
                    )
                }
            }
        }
        if (m != null && m.apps.isNotEmpty()) {
            SectionHeading("Quick launch")
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                m.apps.forEach { a -> PillButton(a.name, { if (n.control("open", a.id)) n.notice = "Opening ${a.name}…" }) }
            }
        }
        if (m != null) {
            SectionHeading("Open any app")
            if (!findApp) PillButton("Find an app on your $kind", { findApp = true; n.listApps() }, Modifier.fillMaxWidth())
            else AppFinder(model, kind)
        }
    }
}

/** Every installed app of the computer, with a search box; a tap opens it there. */
@Composable
private fun AppFinder(model: AppModel, kind: String) {
    val n = model.nyeko
    val t = tokens()
    var query by rememberSaveable { mutableStateOf("") }
    val all = n.allApps
    Panel {
        Column(Modifier.padding(Gutter), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = query, onValueChange = { query = it.take(60) }, modifier = Modifier.fillMaxWidth(), singleLine = true,
                placeholder = { Text("Search apps", color = t.textFaint.c()) }, shape = RoundedCornerShape(24.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedContainerColor = t.panel.c(), unfocusedContainerColor = t.panel.c(),
                    focusedBorderColor = NyoColors.tangerine, unfocusedBorderColor = t.line.c(),
                    focusedTextColor = t.text.c(), unfocusedTextColor = t.text.c(), cursorColor = t.text.c(),
                ),
            )
            when {
                all == null -> Text("Asking your $kind for its apps…", style = TypeScale.SECONDARY.style(t.textDim.c()))
                all.isEmpty() -> Text("No apps found.", style = TypeScale.SECONDARY.style(t.textDim.c()))
                else -> {
                    val q = query.trim().lowercase()
                    val shown = all.filter { q.isEmpty() || it.name.lowercase().contains(q) }
                    shown.take(30).forEach { a ->
                        ListRow(a.name, onClick = { if (n.control("openAny", a.id)) n.notice = "Opening ${a.name}…" })
                    }
                    if (shown.size > 30) Text("${shown.size - 30} more: type to narrow it down.", style = TypeScale.SECONDARY.style(t.textDim.c()))
                    if (shown.isEmpty()) Text("No app matches.", style = TypeScale.SECONDARY.style(t.textDim.c()))
                }
            }
        }
    }
}

// ── A coding session: its conversation, and a message to Claude ───────────────────────────────────────────────────

/** Shown inside the session screen when Nyeko is on the Mac. Opens the session's conversation while on screen. */
@Composable
fun SessionConversation(model: AppModel, pillId: String, unlock: Unlock) {
    val n = model.nyeko
    if (!n.available) return
    DisposableEffect(pillId) {
        n.open(pillId)
        onDispose { n.close() }
    }
    val t = tokens()
    val th = n.thread
    Column(verticalArrangement = Arrangement.spacedBy(Gap)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionHeading("Conversation", Modifier.weight(1f))
            PillButton("Show on computer", { if (n.focus(pillId)) n.notice = "Opening it on the computer…" })
        }
        Panel {
            Column(Modifier.padding(Gutter), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                when {
                    th == null -> Text("Loading the session…", style = TypeScale.SECONDARY.style(t.textDim.c()))
                    !th.readable -> Text("Nyeko can't read this session's conversation.", style = TypeScale.SECONDARY.style(t.textDim.c()))
                    th.lines.isEmpty() -> Text("Nothing said yet.", style = TypeScale.SECONDARY.style(t.textDim.c()))
                }
                // The end of the conversation, newest last (the screen opens at the top: the newest is above the box).
                th?.lines?.takeLast(40)?.forEach { line -> ConversationLine(line) }
                th?.queued?.forEach { q -> Bubble(q, me = true, label = "Waiting for Claude", dashed = true) }
                if (!th?.queued.isNullOrEmpty()) {
                    Text(
                        "Cancel the waiting message", Modifier.align(Alignment.End).heightIn(min = Spacing.MIN_TOUCH.dp).clickable(role = Role.Button) { n.unqueue() }.padding(8.dp),
                        style = TypeScale.LABEL.style(t.textDim.c()),
                    )
                }
                n.sending.forEach { s -> Bubble(s.text, me = true, label = "Sending…", dashed = true) }
                if (th?.state == "working") Text("Claude is working…", style = TypeScale.SECONDARY.style(t.textDim.c()))
            }
        }
        if (th != null) {
            val hint = NyekoData.hint(th)
            if (hint.isNotEmpty()) Text(hint, Modifier.padding(horizontal = 4.dp), style = TypeScale.SECONDARY.style(t.textDim.c()))
            if (th.canMessage && th.state != "gone") Composer("Message Claude", maxLines = 6) { text, clear ->
                unlock { if (n.say(text)) clear() }
            }
        }
    }
}

@Composable
private fun ConversationLine(line: NyekoData.Line) {
    val t = tokens()
    when (line.role) {
        NyekoData.Role.TOOLS -> Text(
            line.text, Modifier.padding(start = 4.dp), maxLines = 14, overflow = TextOverflow.Ellipsis,
            style = TypeScale.LABEL.style(t.textDim.c()).copy(fontFamily = FontFamily.Monospace),
        )
        NyekoData.Role.YOU -> Bubble(line.text, me = true, label = if (line.fromPhone) "From your phone" else null)
        NyekoData.Role.CLAUDE -> Bubble(line.text, me = false)
    }
}

@Composable
private fun Bubble(text: String, me: Boolean, label: String? = null, dashed: Boolean = false) {
    val t = tokens()
    val shape = RoundedCornerShape(18.dp, 18.dp, if (me) 6.dp else 18.dp, if (me) 18.dp else 6.dp)
    Box(Modifier.fillMaxWidth(), contentAlignment = if (me) Alignment.CenterEnd else Alignment.CenterStart) {
        Column(
            Modifier.widthIn(max = 520.dp).clip(shape)
                .background(if (me) NyoColors.tangerine.copy(alpha = if (dashed) 0.45f else 0.9f) else t.panel2.c())
                .border(1.5.dp, if (dashed) t.textDim.c() else t.line.c(), shape)
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            if (label != null) Text(label.uppercase(), style = TypeScale.LABEL.style(if (me) NyoColors.ink else t.textDim.c()))
            SelectionContainer { Text(text, style = TypeScale.BODY.style(if (me) NyoColors.ink else t.text.c())) }
        }
    }
}

/** A text box and a Send button. [onSend] gets the text and a way to clear the box once it was sent. */
@Composable
fun Composer(placeholder: String, maxLines: Int = 4, enabled: Boolean = true, onSend: (String, () -> Unit) -> Unit) {
    val t = tokens()
    var text by rememberSaveable { mutableStateOf("") }
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            value = text, onValueChange = { text = it.take(NyekoData.MAX_TEXT) }, modifier = Modifier.weight(1f),
            placeholder = { Text(placeholder, color = t.textFaint.c()) }, maxLines = maxLines, enabled = enabled,
            shape = RoundedCornerShape(24.dp),
            colors = OutlinedTextFieldDefaults.colors(
                focusedContainerColor = t.panel.c(), unfocusedContainerColor = t.panel.c(), disabledContainerColor = t.panel.c(),
                focusedBorderColor = NyoColors.tangerine, unfocusedBorderColor = t.line.c(), disabledBorderColor = t.line.c(),
                focusedTextColor = t.text.c(), unfocusedTextColor = t.text.c(), cursorColor = t.text.c(),
            ),
        )
        PillButton("Send", { if (text.isNotBlank()) onSend(text) { text = "" } }, Modifier.height(56.dp), kind = PillKind.PRIMARY, enabled = enabled && text.isNotBlank())
    }
}

// ── A new session ─────────────────────────────────────────────────────────────────────────────────────────────────

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun NewSessionScreen(model: AppModel, unlock: Unlock, onBack: () -> Unit, onOpen: (String) -> Unit) {
    val n = model.nyeko
    val t = tokens()
    LaunchedEffect(Unit) { n.refresh() }
    // The Mac said which session it is: open it once.
    LaunchedEffect(n.openWhenReady) {
        n.openWhenReady?.let { id -> n.openWhenReady = null; onOpen(id) }
    }
    val st = n.starting
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    if (st != null) LaunchedEffect(st.id) { while (true) { delay(1000); now = System.currentTimeMillis() } }
    val projects = n.mac?.projects.orEmpty()
    var picked by rememberSaveable { mutableStateOf<String?>(null) }
    if (picked == null && projects.isNotEmpty()) picked = projects.first().id
    var prompt by rememberSaveable { mutableStateOf("") }

    LazyColumn(Modifier.fillMaxSize().padding(horizontal = Gutter), verticalArrangement = Arrangement.spacedBy(Gap)) {
        item { ScreenTitle("New session", onBack = { n.cancelStarting(); onBack() }) }
        if (st == null) item { ComputerPicker(model) }
        when {
            st != null -> item {
                Panel {
                    Column(Modifier.padding(Gutter), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            if (st.launched) "Claude Code is starting in ${st.name}…" else "Asking ${model.computerName(st.on).ifBlank { "your computer" }} to start ${st.name}…",
                            style = TypeScale.HEADLINE.style(t.text.c()),
                        )
                        Text(
                            if (now - st.atMs > 60_000) "It is open in a terminal on the computer. It shows on Home once Claude Code is up."
                            else "This opens as soon as Claude Code says hello.",
                            style = TypeScale.SECONDARY.style(t.textDim.c()),
                        )
                    }
                }
            }
            !n.available || n.mac == null -> item {
                Panel { Text(if (n.available) "Loading your folders…" else NyekoModel.NOT_CONNECTED, Modifier.padding(Gutter), style = TypeScale.SECONDARY.style(t.textDim.c())) }
            }
            projects.isEmpty() -> item {
                Panel {
                    Text(
                        "Nyeko learns your project folders from the sessions you run on this computer. Start one there once, and it shows here.",
                        Modifier.padding(Gutter), style = TypeScale.SECONDARY.style(t.textDim.c()),
                    )
                }
            }
            else -> {
                item { SectionHeading("Folder") }
                item {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        projects.forEach { p ->
                            val on = p.id == picked
                            Column(
                                Modifier.heightIn(min = Spacing.MIN_TOUCH.dp).clip(RoundedCornerShape(14.dp))
                                    .background(if (on) NyoColors.mint else t.panel.c())
                                    .border(2.dp, if (on) NyoColors.ink else t.line.c(), RoundedCornerShape(14.dp))
                                    .clickable(role = Role.RadioButton) { picked = p.id }
                                    .padding(horizontal = 14.dp, vertical = 8.dp),
                            ) {
                                Text(p.name, style = TypeScale.BODY.style(if (on) NyoColors.ink else t.text.c()).copy(fontWeight = FontWeight.SemiBold))
                                if (p.where.isNotEmpty()) Text(p.where, style = TypeScale.LABEL.style(if (on) NyoColors.ink else t.textDim.c()))
                            }
                        }
                    }
                }
                item { SectionHeading("What should Claude do?") }
                item {
                    OutlinedTextField(
                        value = prompt, onValueChange = { prompt = it.take(NyekoData.MAX_TEXT) }, modifier = Modifier.fillMaxWidth().heightIn(min = 120.dp),
                        placeholder = { Text("Leave empty to just open Claude Code", color = t.textFaint.c()) },
                        shape = RoundedCornerShape(18.dp),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedContainerColor = t.panel.c(), unfocusedContainerColor = t.panel.c(),
                            focusedBorderColor = NyoColors.tangerine, unfocusedBorderColor = t.line.c(),
                            focusedTextColor = t.text.c(), unfocusedTextColor = t.text.c(), cursorColor = t.text.c(),
                        ),
                    )
                }
                item {
                    Text(
                        "The computer opens a terminal in that folder and starts Claude Code with this. You can follow it and talk to it from here.",
                        Modifier.padding(horizontal = 4.dp), style = TypeScale.SECONDARY.style(t.textDim.c()),
                    )
                }
                item {
                    PillButton("Start session", {
                        val p = projects.firstOrNull { it.id == picked } ?: return@PillButton
                        unlock { if (n.launch(p, prompt)) prompt = "" }
                    }, Modifier.fillMaxWidth(), kind = PillKind.PRIMARY)
                }
            }
        }
        item { Spacer(Modifier.height(Gutter)) }
    }
}

// ── Chat with Nyo ─────────────────────────────────────────────────────────────────────────────────────────────────

@Composable
fun NyoChatScreen(model: AppModel) {
    val n = model.nyeko
    val t = tokens()
    val list = rememberLazyListState()
    LaunchedEffect(n.nyoChat.size, n.nyoThinking) { if (n.nyoChat.isNotEmpty()) list.animateScrollToItem(n.nyoChat.size) }
    Column(Modifier.fillMaxSize().padding(horizontal = Gutter)) {
        ScreenTitle("Nyo", onBack = null)
        ComputerPicker(model)
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (n.nyoChat.isEmpty()) item {
                Text(
                    "Ask Nyo anything, or tell it what to do on your computer: “pause the music”, “start a timer”, “what's next?”.",
                    Modifier.padding(vertical = Gutter), style = TypeScale.SECONDARY.style(t.textDim.c()),
                )
            }
            items(n.nyoChat) { line -> Bubble(line.text, me = line.me) }
            if (n.nyoThinking) item { Text("Nyo is thinking…", style = TypeScale.SECONDARY.style(t.textDim.c())) }
        }
        Box(Modifier.padding(vertical = 10.dp)) {
            Composer("Message Nyo", enabled = n.available) { text, clear -> n.askNyo(text); clear() }
        }
    }
}

/** The small dot drawn next to a session's name: Nyo's mint when the session is idle, tangerine when it needs you. */
@Composable
fun NyoDot(needsYou: Boolean) {
    Box(Modifier.size(10.dp).clip(CircleShape).background(if (needsYou) NyoColors.tangerine else NyoColors.mint).border(1.5.dp, NyoColors.ink, CircleShape))
}
