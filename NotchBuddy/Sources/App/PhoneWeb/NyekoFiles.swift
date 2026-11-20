#if !APPSTORE
import Foundation

/// Nyeko: the phone looks through the folders in your home folder, previews a file, and starts a session in a folder
/// (docs/PHONE_FILES.md). Read-only: nothing here writes, moves or opens a file. Only inside the home folder, after
/// symbolic links are followed; hidden files (dotfiles, so .env and .ssh too) and ~/Library are never listed or read.
/// The same rules as Windows (windows/src-tauri/src/phone_link/files.rs) and the same messages.
enum NyekoFiles {
    /// Entries in one listing, at most.
    static let maxEntries = 300
    /// A text file is sent up to this size (the rest is cut); an image or a PDF up to the other.
    static let maxText = 256 * 1024
    static let maxBinary = 4 * 1024 * 1024
    /// Bytes per chunk line: 48 KB of base64 in a line of at most 64 KB.
    static let chunk = 36_000

    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL }

    /// The real path the phone may use, or nil: empty means the home folder; "~" is expanded; links are followed; the
    /// result must be the home folder or inside it, with no hidden part and not ~/Library.
    static func resolve(_ asked: String?) -> URL? {
        let raw = (asked ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count <= 4096, !raw.contains("\0") else { return nil }
        let home = Self.home
        if raw.isEmpty || raw == "~" { return home }
        let expanded = raw.hasPrefix("~/") ? home.path + raw.dropFirst(1) : raw
        guard expanded.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL
        return allowed(url, home: home) ? url : nil
    }

    static func allowed(_ url: URL, home: URL) -> Bool {
        let path = url.path, root = home.path
        if path == root { return true }
        guard path.hasPrefix(root + "/") else { return false }
        let parts = path.dropFirst(root.count + 1).split(separator: "/")
        if parts.first == "Library" { return false }
        return !parts.contains { $0.hasPrefix(".") }
    }

    /// "~/Projects/app" for the phone.
    static func display(_ url: URL) -> String {
        let root = home.path
        return url.path == root ? "~" : url.path.hasPrefix(root + "/") ? "~" + url.path.dropFirst(root.count) : url.path
    }

    static let textTypes: Set<String> = ["txt", "md", "markdown", "json", "jsonc", "yml", "yaml", "toml", "xml", "csv", "tsv", "log", "ini", "cfg",
        "conf", "swift", "rs", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "java", "kt", "kts", "c", "h", "cc", "cpp", "hpp",
        "m", "mm", "cs", "php", "sh", "bash", "zsh", "fish", "ps1", "sql", "html", "htm", "css", "scss", "less", "vue", "svelte", "lua",
        "r", "dart", "gradle", "properties", "plist", "env.example", "gitignore", "dockerfile", "makefile", "tex", "srt", "vtt"]
    static let imageTypes: [String: String] = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "heic": "image/heic", "bmp": "image/bmp", "svg": "image/svg+xml"]

    /// text, image or other: by the name, and for an unknown name by a look at the first bytes.
    static func kind(of url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if imageTypes[ext] != nil { return "image" }
        if textTypes.contains(ext) || ["Makefile", "Dockerfile", "README", "LICENSE"].contains(url.lastPathComponent) { return "text" }
        if !ext.isEmpty { return "other" }
        guard let h = try? FileHandle(forReadingFrom: url) else { return "other" }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 4096)) ?? Data()
        return !head.contains(0) && String(data: head, encoding: .utf8) != nil ? "text" : "other"
    }

    /// One folder for the phone: folders first, then files, by name. Hidden entries and ~/Library are left out.
    static func listing(_ url: URL) -> [String: Any] {
        let home = Self.home
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey, .isSymbolicLinkKey]
        guard let names = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return ["ok": false, "note": "Nyeko can't read this folder. If macOS asked on the Mac, allow it there and try again."]
        }
        var entries: [[String: Any]] = []
        for item in names {
            let v = try? item.resourceValues(forKeys: Set(keys))
            if v?.isHidden == true || item.lastPathComponent.hasPrefix(".") { continue }
            let real = item.resolvingSymlinksInPath().standardizedFileURL
            guard allowed(real, home: home) else { continue }
            let dir = (try? real.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            var e: [String: Any] = ["name": String(item.lastPathComponent.prefix(200)), "dir": dir]
            if !dir {
                e["size"] = (try? real.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                e["kind"] = imageTypes[real.pathExtension.lowercased()] != nil ? "image"
                    : textTypes.contains(real.pathExtension.lowercased()) ? "text" : "other"
            }
            if let m = v?.contentModificationDate { e["mtime"] = Int(m.timeIntervalSince1970) }
            entries.append(e)
        }
        entries.sort { a, b in
            let (da, db) = (a["dir"] as? Bool ?? false, b["dir"] as? Bool ?? false)
            if da != db { return da }
            return (a["name"] as? String ?? "").localizedStandardCompare(b["name"] as? String ?? "") == .orderedAscending
        }
        let parent = url.path == home.path ? nil : url.deletingLastPathComponent()
        var out: [String: Any] = ["ok": true, "path": url.path, "display": display(url),
                                  "entries": Array(entries.prefix(maxEntries)), "truncated": entries.count > maxEntries]
        if let parent { out["parent"] = parent.path }
        return out
    }

    /// A file for the phone: the header, then its bytes in chunks (base64). Text is cut at maxText; a binary over
    /// maxBinary isn't sent (the header says so).
    static func preview(_ url: URL) -> (header: [String: Any], chunks: [String]) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return (["ok": false, "note": "That file isn't there any more."], [])
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        let kind = kind(of: url)
        var header: [String: Any] = ["ok": true, "path": url.path, "display": display(url), "name": url.lastPathComponent,
                                     "size": size, "kind": kind]
        let limit = kind == "text" ? maxText : maxBinary
        if kind == "other" || (kind == "image" && size > maxBinary) {
            header["chunks"] = 0
            if kind == "image" { header["note"] = "Too big to preview on the phone." }
            return (header, [])
        }
        guard let h = try? FileHandle(forReadingFrom: url) else {
            return (["ok": false, "note": "Nyeko can't read this file. If macOS asked on the Mac, allow it there and try again."], [])
        }
        defer { try? h.close() }
        var data = (try? h.read(upToCount: limit)) ?? Data()
        if kind == "text" {
            // Cut on a whole character.
            while !data.isEmpty, String(data: data, encoding: .utf8) == nil, size > data.count { data.removeLast() }
            header["truncated"] = size > data.count
        } else {
            header["mime"] = imageTypes[url.pathExtension.lowercased()] ?? "application/octet-stream"
        }
        let chunks = stride(from: 0, to: data.count, by: chunk).map { data[$0 ..< min($0 + chunk, data.count)].base64EncodedString() }
        header["chunks"] = chunks.count
        return (header, chunks)
    }

    /// A folder a new session may start in: inside the home folder, not hidden, and really a folder.
    static func launchFolder(_ asked: String) -> String? {
        guard let url = resolve(asked) else { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url.path : nil
    }
}
#endif
