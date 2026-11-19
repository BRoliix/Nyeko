#if !APPSTORE
import AppKit

// MARK: - Ask Nyo: do it, don't just answer (Nyeko)
//
// A typed message to Nyo (in the island's chat or the window's Ask Nyo) is first checked for a
// command Nyeko can carry out on this Mac: open an app, play / pause / skip music, change the
// volume, start the focus timer, record a meeting, take a screenshot, say what's next or what
// came in. Done → Nyo replies with what it did. Anything else (or a command that fails) goes
// to Claude as before. Short messages only: a question about code is never taken for a command.

@MainActor
enum NyoActions {
    /// The reply when the message was a command Nyeko carried out; nil → ask Claude.
    static func handle(_ text: String) async -> String? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = raw.split(whereSeparator: { $0.isWhitespace })
        guard !raw.isEmpty, words.count <= 9 else { return nil }
        let lower = raw.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        func has(_ any: [String]) -> Bool { any.contains { lower.contains($0) } }

        // ── Nyeko's own actions ────────────────────────────────────────────────
        if has(["stop timer", "stop the timer", "stop nyodoro", "stop pomodoro", "end timer", "cancel timer"]) {
            let doro = CoucoudoroController.shared
            guard doro.phase != .idle else { return String(localized: "No timer is running.") }
            doro.end()
            return String(localized: "Timer stopped.")
        }
        if has(["nyodoro", "pomodoro", "focus timer", "start a timer", "start timer", "start focus", "focus mode"]) {
            return startNyodoro()
        }
        if has(["stop recording", "stop the recording", "stop notetaker", "stop taking notes"]) {
            guard NoteTaker.shared.isRecording else { return String(localized: "Nothing is being recorded.") }
            NoteTaker.shared.stop()
            return String(localized: "Recording stopped. Your notes are being written.")
        }
        if has(["record this meeting", "record the meeting", "record a meeting", "start recording",
                "start notetaker", "take notes", "record this call", "record the call"]) {
            guard !NoteTaker.shared.isRecording else { return String(localized: "Already recording.") }
            NoteTaker.shared.toggleFromPill()
            return String(localized: "Recording. Say “stop recording” when the meeting ends.")
        }
        if has(["screenshot", "screen shot", "capture my screen", "capture the screen"]) {
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
            try? await Task.sleep(for: .milliseconds(350))
            QuickScreenshot.shared.take()
            return String(localized: "Screenshot taken.")
        }
        if has(["what's next", "whats next", "next event", "next meeting", "my calendar", "my schedule",
                "my day", "what do i have"]) {
            return calendarAnswer()
        }
        if has(["notification", "what did i miss", "anything new", "any messages", "new messages"]) {
            return notificationsAnswer()
        }
        if has(["what's playing", "whats playing", "what song", "which song", "now playing"]) {
            guard let np = NowPlayingDisplay.current() else { return String(localized: "Nothing is playing.") }
            return String(localized: "\(np.title) by \(np.artist), in \(np.source).")
        }

        // ── The voice commands (music, apps, pills…), typed ───────────────────
        let intent = IntentParser.parse(raw, pills: PillCatalog.available)
        switch intent {
        case .unknown, .mail, .webSearch:
            return nil
        case .musicPause, .musicNext, .musicPrevious, .musicPlay(target: nil):
            // Whatever plays (YouTube in a browser too), not only Music and Spotify.
            if let np = NowPlayingDisplay.current() {
                switch intent {
                case .musicPause:
                    if np.playing { np.toggle() }
                    return String(localized: "Paused.")
                case .musicNext:
                    np.next()
                    return String(localized: "Next track.")
                case .musicPrevious:
                    np.previous()
                    return String(localized: "Previous track.")
                default:
                    if !np.playing { np.toggle() }
                    return String(localized: "Playing \(np.title).")
                }
            }
            return await runVoice(intent, raw)
        default:
            return await runVoice(intent, raw)
        }
    }

    /// The voice command runner, as if spoken. Only a success counts: a failure goes to Claude.
    private static func runVoice(_ intent: VoiceIntent, _ raw: String) async -> String? {
        let result = await VoiceActionRunner.shared.run(intent, availablePills: PillCatalog.available,
                                                        rawTranscript: raw)
        guard result.outcome == .success else { return nil }
        if case .openApp = intent {
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
        return result.message.isEmpty ? String(localized: "Done.") : result.message
    }

    private static func startNyodoro() -> String {
        let doro = CoucoudoroController.shared
        if doro.phase != .idle { return String(localized: "The timer is already running.") }
        let state = AppState.shared
        let id = CoucoudoroController.pillId
        if !state.activeIntegrations.contains(id) {
            guard state.activeIntegrations.count < 4 else {
                return String(localized: "Turn off a pill first: the notch shows 4 at most, and the timer needs one.")
            }
            state.toggleIntegration(id)
        }
        doro.begin()
        return String(localized: "Focus timer started: \(CoucoudoroSettings.workMinutes) minutes of work, then a \(CoucoudoroSettings.restMinutes)-minute break.")
    }

    private static func calendarAnswer() -> String {
        let cal = CalendarPeek.shared
        cal.refresh()
        switch cal.access {
        case .unknown:
            cal.requestAccess()
            return String(localized: "I need Calendar access first: macOS is asking you now.")
        case .denied:
            return String(localized: "Calendar access is off for Nyeko (System Settings → Privacy & Security → Calendars).")
        case .granted:
            guard !cal.upcoming.isEmpty else { return String(localized: "Nothing else today or tomorrow.") }
            return cal.upcoming.prefix(3)
                .map { "• \($0.title) — \(CalendarPeek.when($0))" }
                .joined(separator: "\n")
        }
    }

    private static func notificationsAnswer() -> String {
        let feed = NotificationFeed.shared
        feed.refresh()
        let items = feed.items.prefix(5)
        guard !items.isEmpty else { return String(localized: "Nothing new.") }
        return items.map { n in
            n.body.isEmpty ? "• \(n.app): \(n.title)" : "• \(n.app): \(n.title) — \(n.body)"
        }.joined(separator: "\n")
    }
}
#endif
