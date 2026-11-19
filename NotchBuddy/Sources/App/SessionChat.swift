#if !APPSTORE
import AppKit
import Foundation

// MARK: - Talking to a coding session from the phone (Nyeko)
//
// The phone opens a session: the Mac sends it the session's conversation (its Claude Code transcript, read while the
// screen is open) and keeps it current. A message typed on the phone reaches the session in one of two ways:
//   • Claude is working, or the session can't be typed into: the message waits here, and the session's Stop hook
//     hands it to Claude when the turn ends (the hook's "block" reason: Claude reads it and goes on). Nothing on the
//     Mac moves.
//   • Claude is idle: Nyeko types it into the session like you would (Accessibility): a Terminal or iTerm tab is found
//     by its tty or session id and brought forward; another app (VS Code, Warp…) is brought forward and the message is
//     typed where its cursor is. Never while the Mac is locked (that would type into the lock screen).
// Only Claude Code sessions (their Stop hook and transcript): other agents can be opened on the Mac, not messaged.

/// Where a session runs, from its hook events.
struct SessionTarget: Sendable, Equatable {
    var transcriptPath = ""
    var cwd = ""
    var tty = ""            // /dev/ttys003
    var itermSession = ""   // the UUID part of ITERM_SESSION_ID
    var termProgram = ""
    var bundleId = ""
    var entrypoint = ""     // CLAUDE_CODE_ENTRYPOINT: cli, claude-vscode…
}

/// Messages from the phone waiting for their session's turn to end. Read on the hook server's own thread.
final class SessionInbox: @unchecked Sendable {
    static let shared = SessionInbox()
    private let lock = NSLock()
    private var waiting: [String: [String]] = [:]

    func add(_ text: String, session: String) {
        lock.withLock { waiting[session, default: []].append(text) }
    }

    func pending(_ session: String) -> [String] { lock.withLock { waiting[session] ?? [] } }

    func cancel(_ session: String) { lock.withLock { waiting[session] = nil } }

    /// Everything waiting for the session, taken at once: the Stop hook gives it to Claude.
    func take(_ session: String) -> String? {
        lock.withLock {
            guard let list = waiting.removeValue(forKey: session), !list.isEmpty else { return nil }
            return list.joined(separator: "\n\n")
        }
    }
}

@MainActor
final class SessionChat {
    static let shared = SessionChat()

    /// Sends a line to the phone (set by NyekoPhoneService).
    var sink: (([String: Any]) -> Void)?

    private var targets: [String: SessionTarget] = [:]
    /// The session the phone has open ("pill|session", as in the session list).
    private var watched: String?
    private var lastSent = ""
    private var refreshQueued = false
    private var timer: Timer?

    enum Delivery: String { case tab, front, wait }

    static func sessionId(_ listedId: String) -> String {
        guard let bar = listedId.firstIndex(of: "|") else { return listedId }
        return String(listedId[listedId.index(after: bar)...])
    }

    // MARK: From the hooks

    func note(event: String, session: String, payload: [String: Any]) {
        guard !session.isEmpty, session != "unknown" else { return }
        if event == "SessionEnd" {
            targets[session] = nil
            SessionInbox.shared.cancel(session)
        } else {
            var t = targets[session] ?? SessionTarget()
            if let v = payload["transcript_path"] as? String, v.hasSuffix(".jsonl") { t.transcriptPath = v }
            if let v = payload["cwd"] as? String, !v.isEmpty { t.cwd = v }
            if let v = payload["tty"] as? String, Self.validTTY(v) { t.tty = v }
            if let v = payload["iterm_session_id"] as? String, let u = Self.itermUUID(v) { t.itermSession = u }
            if let v = payload["term_program"] as? String, !v.isEmpty { t.termProgram = v }
            if let v = payload["bundle_id"] as? String, !v.isEmpty { t.bundleId = v }
            if let v = payload["entrypoint"] as? String, !v.isEmpty { t.entrypoint = v }
            targets[session] = t
            if targets.count > 300, let oldest = targets.keys.first { targets[oldest] = nil }
        }
        if let w = watched, Self.sessionId(w) == session { refreshSoon() }
    }

    /// The Stop hook just handed the phone's message to Claude.
    func delivered(_ session: String) {
        NyekoPhoneService.log("phone message delivered at the end of a turn")
        if let w = watched, Self.sessionId(w) == session { refreshSoon() }
    }

    // MARK: The phone's session screen

    func open(_ id: String) {
        watched = id
        lastSent = ""
        refresh()
        timer?.invalidate()
        // Hook events refresh it as Claude works; this catches the rest (text written between events).
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            MainActor.assumeIsolated { SessionChat.shared.refresh() }
        }
    }

    func close() {
        watched = nil
        timer?.invalidate()
        timer = nil
    }

    func unqueue(_ id: String) {
        SessionInbox.shared.cancel(Self.sessionId(id))
        if watched == id { lastSent = ""; refresh() }
    }

    private func refreshSoon() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                SessionChat.shared.refreshQueued = false
                SessionChat.shared.refresh()
            }
        }
    }

    func refresh() {
        guard let id = watched else { return }
        let session = Self.sessionId(id)
        let live = AppState.shared.liveSessions.first { $0.id == id }
        let path = transcriptPath(session: session, cwd: live?.cwd ?? targets[session]?.cwd ?? "")
        Task.detached(priority: .utility) {
            let items = path.flatMap { SessionTranscript.read(path: $0) }
            await SessionChat.shared.send(id: id, items: items)
        }
    }

    private func send(id: String, items: [SessionTranscriptItem]?) {
        guard watched == id else { return }
        let session = Self.sessionId(id)
        let live = AppState.shared.liveSessions.first { $0.id == id }
        let target = targets[session]
        var line: [String: Any] = ["type": "chat", "session": id, "canMessage": canMessage(live)]
        if let live {
            let status = SessionJump.status(live)
            line["title"] = live.projectName
            line["host"] = SessionJump.hostName(live)
            line["folder"] = SessionJump.folder(live)
            line["state"] = status == .needsYou ? "needsYou" : status == .working ? "working" : "idle"
            let how = delivery(live, target)
            line["delivery"] = how.rawValue
            line["note"] = note(how, host: SessionJump.hostName(live))
        } else {
            line["state"] = "gone"
        }
        line["readable"] = items != nil
        line["queued"] = SessionInbox.shared.pending(session).map { String($0.prefix(2000)) }
        // One line through the relay is at most 64 KB: older items go first until it fits (escaping can make the
        // JSON larger than the text it carries).
        var list = items.map { SessionTranscript.forPhone($0) } ?? []
        var json = ""
        while true {
            line["items"] = list
            json = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            if json.utf8.count <= 60_000 || list.isEmpty { break }
            list.removeFirst(max(1, list.count / 4))
        }
        guard json.utf8.count <= 60_000, json != lastSent else { return }
        lastSent = json
        sink?(line)
    }

    // MARK: A message from the phone

    struct Said { let result: String; let note: String }

    func say(_ id: String, text: String) async -> Said {
        let session = Self.sessionId(id)
        guard let live = AppState.shared.liveSessions.first(where: { $0.id == id }) else {
            return Said(result: "failed", note: "This session has ended.")
        }
        guard canMessage(live) else {
            return Said(result: "failed", note: "Only Claude Code sessions take messages from the phone.")
        }
        let status = SessionJump.status(live)
        let target = targets[session] ?? SessionTarget()
        let how = delivery(live, target)
        func wait(_ why: String) -> Said {
            SessionInbox.shared.add(text, session: session)
            lastSent = ""
            refreshSoon()
            NyekoPhoneService.log("phone message waiting for the end of a turn")
            return Said(result: "queued", note: why)
        }
        if status == .needsYou { return wait("It goes to Claude once you've answered it and it finishes this turn.") }
        if status == .working { return wait("Claude is working: it reads your message when it finishes this turn.") }
        if how == .wait { return wait("This session can't be typed into: Claude reads it when it next finishes a turn.") }

        let host = SessionJump.hostName(live)
        switch await SessionTyper.type(text, live: live, target: target, inTab: how == .tab) {
        case .typed:
            NyekoPhoneService.log("phone message typed into \(host)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { SessionChat.shared.refresh() }
            }
            return Said(result: "typed", note: "")
        case .locked:
            return wait("Your Mac is locked, so Nyeko can't type. Claude reads it when it next finishes a turn.")
        case .noAccessibility:
            return wait("Nyeko needs Accessibility (System Settings → Privacy & Security) to type into \(host).")
        case .notFound:
            return wait("Nyeko couldn't bring the session's \(host) window forward. Claude reads it when it next finishes a turn.")
        }
    }

    // MARK: Helpers

    /// Claude Code sessions (in a terminal, VS Code or Cursor): the ones with a Stop hook and a transcript.
    private func canMessage(_ live: LiveSession?) -> Bool {
        guard let live else { return false }
        return live.pill == "integration_claude" || live.pill.hasPrefix("integration_claude#") || live.pill == "agent_cursor"
            || live.pill.hasPrefix("agent_cursor#")
    }

    private func delivery(_ live: LiveSession, _ target: SessionTarget?) -> Delivery {
        guard let t = target else { return .wait }
        let host = live.hostApp ?? t.bundleId
        if host == "com.apple.Terminal", !t.tty.isEmpty { return .tab }
        if host == "com.googlecode.iterm2", !t.itermSession.isEmpty { return .tab }
        if t.entrypoint == "claude-desktop" || host.isEmpty { return .wait }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: host) == nil ? .wait : .front
    }

    private func note(_ how: Delivery, host: String) -> String {
        switch how {
        case .tab: return "When Claude is idle, Nyeko types your message into its \(host) tab."
        case .front: return "When Claude is idle, Nyeko brings \(host) forward and types where its cursor is: keep Claude's box selected there."
        case .wait: return "Claude reads your message when it next finishes a turn."
        }
    }

    private func transcriptPath(session: String, cwd: String) -> String? {
        if let p = targets[session]?.transcriptPath, !p.isEmpty, FileManager.default.fileExists(atPath: p) { return p }
        // Claude Code's own layout: ~/.claude/projects/<cwd, every other character a dash>/<session>.jsonl
        guard !cwd.isEmpty, session.range(of: "^[A-Za-z0-9_-]{8,80}$", options: .regularExpression) != nil else { return nil }
        let folder = String(cwd.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" })
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        let path = "\(base)/projects/\(folder)/\(session).jsonl"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func validTTY(_ s: String) -> Bool {
        s.range(of: "^/dev/ttys[0-9]{1,4}$", options: .regularExpression) != nil
    }

    /// "w0t1p0:6F1A…" → "6F1A…" (letters, digits and dashes only: it goes into an AppleScript).
    static func itermUUID(_ s: String) -> String? {
        let id = s.split(separator: ":").last.map(String.init) ?? s
        return id.range(of: "^[A-Fa-f0-9-]{16,64}$", options: .regularExpression) != nil ? id : nil
    }
}

// MARK: - Typing into a session

@MainActor
enum SessionTyper {
    enum Outcome { case typed, locked, noAccessibility, notFound }

    static func type(_ text: String, live: LiveSession, target: SessionTarget, inTab: Bool) async -> Outcome {
        if screenLocked() { return .locked }
        guard AXIsProcessTrusted() else { return .noAccessibility }
        let host = live.hostApp ?? target.bundleId
        let previous = NSWorkspace.shared.frontmostApplication
        if inTab {
            guard bringTab(host: host, target: target) else { return .notFound }
        } else {
            SessionJump.open(live)
        }
        // Wait for the window to come forward (an editor reopening a folder takes longer).
        for _ in 0..<(inTab ? 6 : 12) {
            try? await Task.sleep(for: .milliseconds(100))
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == host { break }
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == host else { return .notFound }
        try? await Task.sleep(for: .milliseconds(inTab ? 150 : 400))
        if screenLocked() { return .locked }
        guard SessionDrop.paste(text) else { return .noAccessibility }
        try? await Task.sleep(for: .milliseconds(300))
        pressReturn()
        // Give the front back to what you were using, if you are at the Mac.
        if let previous, previous.bundleIdentifier != host, previous.bundleIdentifier != Bundle.main.bundleIdentifier {
            try? await Task.sleep(for: .milliseconds(500))
            previous.activate()
        }
        return .typed
    }

    static func screenLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let b = d["CGSSessionScreenIsLocked"] as? Bool { return b }
        return (d["CGSSessionScreenIsLocked"] as? Int ?? 0) != 0
    }

    private static func pressReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Finds the session's own Terminal or iTerm tab (by tty, or iTerm's session id) and brings it forward.
    private static func bringTab(host: String, target: SessionTarget) -> Bool {
        let source: String
        if host == "com.apple.Terminal", SessionChat.validTTY(target.tty) {
            source = """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(target.tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "none"
            """
        } else if host == "com.googlecode.iterm2", SessionChat.itermUUID(target.itermSession) != nil {
            source = """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique id of s is "\(target.itermSession)" then
                                tell w to select
                                tell t to select
                                tell s to select
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "none"
            """
        } else {
            return false
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NyekoPhoneService.log("finding the session's tab failed: \(error[NSAppleScript.errorNumber] ?? "?")") }
        return result?.stringValue == "ok"
    }
}
#endif
