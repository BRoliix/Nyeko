import Foundation

// MARK: - A coding session's conversation, for the phone (Nyeko)
//
// Claude Code writes each session to a transcript (one JSON object per line, under ~/.claude/projects). The phone's
// session screen shows its end: what you asked, what Claude answered, and one short line per tool it used. Thinking,
// tool output, subagents and Claude Code's own bookkeeping are left out. Pure (Foundation only).

struct SessionTranscriptItem: Equatable, Sendable {
    enum Role: String, Sendable { case you, claude, tools }
    var role: Role
    var text: String
    /// A message you sent from the phone (it reached Claude through the Stop hook).
    var fromPhone = false
}

enum SessionTranscript {
    /// How a message from the phone is put to Claude (the Stop hook's reason); recognised again when read back.
    static let phonePrefix = "The user sent this from their phone:"

    static func reason(for text: String) -> String { "\(phonePrefix)\n\n\(text)" }

    /// The end of a transcript (its last `tailBytes`). Nil when the file can't be opened.
    static func read(path: String, tailBytes: Int = 600_000) -> [SessionTranscriptItem]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        return items(fromJSONL: data, partialFirstLine: start > 0)
    }

    static func items(fromJSONL data: Data, partialFirstLine: Bool = false) -> [SessionTranscriptItem] {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if partialFirstLine, !lines.isEmpty { lines.removeFirst() }
        var out: [SessionTranscriptItem] = []

        func add(_ role: SessionTranscriptItem.Role, _ raw: String, fromPhone: Bool = false) {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            // Claude's text and tool lines run together until you speak.
            if role != .you, let last = out.last, last.role == role {
                out[out.count - 1].text += (role == .tools ? "\n" : "\n\n") + text
            } else {
                out.append(SessionTranscriptItem(role: role, text: text, fromPhone: fromPhone))
            }
        }

        for line in lines {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let type = entry["type"] as? String ?? ""
            let message = entry["message"] as? [String: Any]
            if entry["isSidechain"] as? Bool == true { continue }

            // A message from the phone, wherever Claude Code recorded the Stop hook's reason.
            if type != "assistant", let phone = phoneText(in: entry) {
                add(.you, phone, fromPhone: true)
                continue
            }
            if entry["isMeta"] as? Bool == true { continue }

            switch type {
            case "user":
                for text in userTexts(message?["content"]) {
                    if text.hasPrefix("[Request interrupted") { add(.tools, "Stopped") } else { add(.you, text) }
                }
            case "assistant":
                guard let blocks = message?["content"] as? [[String: Any]] else {
                    if let text = message?["content"] as? String { add(.claude, text) }
                    continue
                }
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        add(.claude, block["text"] as? String ?? "")
                    case "tool_use":
                        let name = block["name"] as? String ?? ""
                        let input = block["input"] as? [String: Any] ?? [:]
                        if name == "ExitPlanMode", let plan = input["plan"] as? String {
                            add(.claude, "Plan:\n" + plan)
                        } else {
                            add(.tools, toolLine(name: name, input: input))
                        }
                    default:
                        break   // thinking, redacted thinking
                    }
                }
            default:
                break
            }
        }
        return out
    }

    /// What you typed, without Claude Code's tags (slash commands and shell lines are kept short).
    static func userTexts(_ content: Any?) -> [String] {
        var raw: [String] = []
        if let s = content as? String { raw = [s] }
        else if let blocks = content as? [[String: Any]] {
            for b in blocks {
                switch b["type"] as? String {
                case "text": raw.append(b["text"] as? String ?? "")
                case "image": raw.append("[image]")
                default: break   // tool results
                }
            }
        }
        return raw.compactMap { s -> String? in
            let t = stripReminders(s).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            if t.hasPrefix("<command-name>") {
                let name = between(t, "<command-name>", "</command-name>") ?? ""
                let args = between(t, "<command-args>", "</command-args>") ?? ""
                let cmd = name.hasPrefix("/") ? name : "/" + name
                return args.isEmpty ? cmd : "\(cmd) \(args)"
            }
            if t.hasPrefix("<bash-input>") { return "! " + (between(t, "<bash-input>", "</bash-input>") ?? "") }
            if t.hasPrefix("<local-command-") || t.hasPrefix("<bash-stdout>") || t.hasPrefix("<bash-stderr>")
                || t.hasPrefix("<command-message>") || t.hasPrefix("Caveat: ") { return nil }
            return t
        }
    }

    static func toolLine(name: String, input: [String: Any]) -> String {
        func str(_ key: String) -> String { input[key] as? String ?? "" }
        func file(_ key: String) -> String { str(key).isEmpty ? "" : URL(fileURLWithPath: str(key)).lastPathComponent }
        func short(_ s: String, _ n: Int = 80) -> String {
            let first = s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? s
            return first.count > n ? String(first.prefix(n)) + "…" : first
        }
        switch name {
        case "Bash": return "Ran " + short(str("command"))
        case "Read": return "Read " + file("file_path")
        case "Edit", "MultiEdit": return "Edited " + file("file_path")
        case "Write": return "Wrote " + file("file_path")
        case "NotebookEdit": return "Edited " + file("notebook_path")
        case "Grep": return "Searched for " + short(str("pattern"), 50)
        case "Glob": return "Looked for " + short(str("pattern"), 50)
        case "WebFetch": return "Opened " + (URL(string: str("url"))?.host ?? "a web page")
        case "WebSearch": return "Searched the web for " + short(str("query"), 60)
        case "Task", "Agent": return "Agent: " + short(str("description"), 60)
        case "TodoWrite": return "Updated its to-do list"
        case "AskUserQuestion": return "Asked you a question"
        default:
            // mcp__server__tool → "tool (server)"
            let parts = name.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" { return "\(parts.dropFirst(2).joined(separator: "__")) (\(parts[1]))" }
            return name
        }
    }

    /// The items the phone gets: the last ones, each cut to a readable length, the whole under `maxBytes` of JSON.
    static func forPhone(_ items: [SessionTranscriptItem], maxItems: Int = 60, maxBytes: Int = 44_000) -> [[String: Any]] {
        var list = Array(items.suffix(maxItems)).map { item -> [String: Any] in
            var text = item.text
            if item.role == .tools {
                let lines = text.split(separator: "\n")
                if lines.count > 12 { text = "… \(lines.count - 12) more\n" + lines.suffix(12).joined(separator: "\n") }
            } else if text.count > 4000 {
                text = String(text.prefix(4000)) + "…"
            }
            var d: [String: Any] = ["r": item.role.rawValue, "t": text]
            if item.fromPhone { d["p"] = true }
            return d
        }
        func size(_ d: [String: Any]) -> Int { ((d["t"] as? String)?.utf8.count ?? 0) + 24 }
        var total = list.reduce(0) { $0 + size($1) }
        while total > maxBytes, list.count > 1 {
            total -= size(list.removeFirst())
        }
        return list
    }

    // MARK: Helpers

    private static func phoneText(in entry: [String: Any]) -> String? {
        var candidates: [String] = []
        if let s = entry["content"] as? String { candidates.append(s) }
        if let m = entry["message"] as? [String: Any] {
            if let s = m["content"] as? String { candidates.append(s) }
            if let blocks = m["content"] as? [[String: Any]] {
                candidates += blocks.compactMap { $0["text"] as? String }
            }
        }
        if let a = entry["attachment"] as? [String: Any] {
            candidates += a.values.compactMap { $0 as? String }
        }
        for c in candidates {
            guard let r = c.range(of: phonePrefix) else { continue }
            let rest = c[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    private static func stripReminders(_ s: String) -> String {
        var t = s
        while let open = t.range(of: "<system-reminder>") {
            guard let close = t.range(of: "</system-reminder>", range: open.upperBound..<t.endIndex) else {
                t.removeSubrange(open.lowerBound..<t.endIndex)
                break
            }
            t.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return t
    }

    private static func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let ra = s.range(of: a), let rb = s.range(of: b, range: ra.upperBound..<s.endIndex) else { return nil }
        return s[ra.upperBound..<rb.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
