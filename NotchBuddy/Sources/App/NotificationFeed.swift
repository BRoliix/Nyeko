#if !APPSTORE
import AppKit
import Combine
import SQLite3
import SwiftUI

// MARK: - Notifications (Nyeko)
//
// What reached you lately, in one list for the island and the window:
//  • WhatsApp and Mail, from Nyeko's own integrations (when they are on);
//  • an event in Calendar starting soon;
//  • optionally, every app's notifications. macOS has no API for other apps' notifications:
//    Nyeko reads the Notification Center's own database, read-only, on this Mac. That needs
//    Full Disk Access, is off by default, and may break when Apple changes the database.
// Nothing polls: the list is read when the island or the window opens.

struct NyekoNotice: Identifiable {
    let id: String
    /// "WhatsApp", "Mail", "Slack"…
    let app: String
    /// For the app's icon, when it is an installed app.
    let bundleId: String?
    /// SF Symbol when there is no app icon.
    let symbol: String
    let title: String
    let body: String
    let date: Date
}

@MainActor
final class NotificationFeed: ObservableObject {
    static let shared = NotificationFeed()

    static let allAppsKey = "nyeko.allNotifications"
    static var allAppsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: allAppsKey) }
        set { UserDefaults.standard.set(newValue, forKey: allAppsKey) }
    }

    enum AllApps: Equatable { case off, needsAccess, on }

    @Published private(set) var allApps: AllApps = .off
    @Published private(set) var system: [NyekoNotice] = []
    /// Notices opened or cleared before this instant are not counted as new.
    @Published private(set) var seenUntil: Date

    private static let seenKey = "nyeko.notificationsSeenUntil"
    private var iconCache: [String: NSImage] = [:]

    private init() {
        let saved = UserDefaults.standard.double(forKey: Self.seenKey)
        seenUntil = saved > 0 ? Date(timeIntervalSince1970: saved) : Date()
    }

    // MARK: The list

    /// Newest first, the last day only.
    var items: [NyekoNotice] {
        var out: [NyekoNotice] = []
        let dayAgo = Date().addingTimeInterval(-86_400)

        // WhatsApp: the last message of each unread conversation.
        for convo in WhatsAppController.shared.inbox.sorted where convo.unread > 0 {
            guard let last = convo.messages.last(where: { !$0.fromMe }) else { continue }
            let preview = last.previewKey
            let text = preview.key.isEmpty ? preview.value
                : (preview.value.isEmpty ? String(localized: String.LocalizationValue(preview.key))
                   : "\(String(localized: String.LocalizationValue(preview.key))) · \(preview.value)")
            out.append(NyekoNotice(id: "wa/\(last.id)", app: "WhatsApp", bundleId: "net.whatsapp.WhatsApp",
                                   symbol: "message.fill",
                                   title: convo.isGroup ? "\(convo.name) · \(last.senderName)" : convo.name,
                                   body: text, date: last.date))
        }

        // Mail: unread messages.
        for mail in MailController.shared.messages where !mail.isRead {
            out.append(NyekoNotice(id: "mail/\(mail.id)", app: "Mail", bundleId: "com.apple.mail",
                                   symbol: "envelope.fill", title: mail.senderName, body: mail.subject,
                                   date: mail.date))
        }

        // Calendar: the next event, when it starts within 30 minutes.
        if let e = CalendarPeek.shared.next, e.start.timeIntervalSinceNow < 30 * 60 {
            out.append(NyekoNotice(id: "cal/\(e.title)/\(e.start.timeIntervalSince1970)", app: "Calendar",
                                   bundleId: "com.apple.iCal", symbol: "calendar",
                                   title: e.title, body: CalendarPeek.when(e), date: min(Date(), e.start)))
        }

        // Every other app (opt-in).
        let skip: Set<String> = ["net.whatsapp.WhatsApp", "com.apple.mail", "com.apple.iCal",
                                 Bundle.main.bundleIdentifier ?? ""]
        out += system.filter { !skip.contains($0.bundleId ?? "") }

        return out.filter { $0.date > dayAgo }.sorted { $0.date > $1.date }
    }

    var newCount: Int { items.filter { $0.date > seenUntil }.count }

    func markSeen() {
        seenUntil = Date()
        UserDefaults.standard.set(seenUntil.timeIntervalSince1970, forKey: Self.seenKey)
    }

    func open(_ notice: NyekoNotice) {
        if notice.id.hasPrefix("wa/"), let chat = WhatsAppController.shared.inbox.sorted
            .first(where: { convo in convo.messages.contains { msg in "wa/\(msg.id)" == notice.id } })?.id {
            WhatsAppController.shared.open(chat)
            return
        }
        if notice.id.hasPrefix("mail/") { MailController.shared.openMail(); return }
        if let id = notice.bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(),
                                               completionHandler: nil)
        }
    }

    func icon(for notice: NyekoNotice) -> NSImage? {
        guard let id = notice.bundleId else { return nil }
        if let cached = iconCache[id] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 64, height: 64)
        iconCache[id] = image
        return image
    }

    // MARK: Every app's notifications (opt-in)

    /// Called when the island or the window opens.
    func refresh() {
        CalendarPeek.shared.refresh()
        guard Self.allAppsEnabled else {
            if allApps != .off { allApps = .off }
            if !system.isEmpty { system = [] }
            return
        }
        guard let path = Self.databasePath(), FileManager.default.isReadableFile(atPath: path) else {
            allApps = .needsAccess
            system = []
            return
        }
        Task.detached(priority: .utility) {
            let rows = NotificationFeed.readDatabase(at: path)
            await MainActor.run {
                let feed = NotificationFeed.shared
                if let rows {
                    feed.allApps = .on
                    feed.system = rows.map { row in
                        NyekoNotice(id: "nc/\(row.id)", app: NotificationFeed.appName(row.bundle),
                                    bundleId: row.bundle, symbol: "bell.fill",
                                    title: row.title, body: row.body, date: row.date)
                    }
                } else {
                    feed.allApps = .needsAccess
                    feed.system = []
                }
            }
        }
    }

    func turnOnAllApps() {
        Self.allAppsEnabled = true
        refresh()
    }

    func turnOffAllApps() {
        Self.allAppsEnabled = false
        refresh()
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func appName(_ bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleId.split(separator: ".").last.map(String.init) ?? bundleId
    }

    /// macOS 15 keeps it in the usernoted group container; older systems in the per-user folder.
    nonisolated private static func databasePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let modern = "\(home)/Library/Group Containers/group.com.apple.usernoted/db2/db"
        if FileManager.default.fileExists(atPath: modern) { return modern }
        var buffer = [CChar](repeating: 0, count: 1024)
        guard confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 else { return modern }
        let legacy = String(cString: buffer) + "com.apple.notificationcenter/db2/db"
        return FileManager.default.fileExists(atPath: legacy) ? legacy : modern
    }

    struct Row: Sendable {
        let id: Int64
        let bundle: String
        let title: String
        let body: String
        let date: Date
    }

    /// The last 30 notifications, read-only. Nil when the database cannot be opened.
    nonisolated private static func readDatabase(at path: String) -> [Row]? {
        var db: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT r.rec_id, a.identifier, r.data, r.delivered_date
            FROM record r JOIN app a ON a.app_id = r.app_id
            ORDER BY r.delivered_date DESC LIMIT 30
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            guard let idText = sqlite3_column_text(stmt, 1) else { continue }
            let bundle = String(cString: idText)
            // System entries ("_system_center_:…") are not apps.
            if bundle.hasPrefix("_") { continue }
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
            var title = "", body = ""
            if let blob = sqlite3_column_blob(stmt, 2) {
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
                if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let req = plist["req"] as? [String: Any] {
                    title = (req["titl"] as? String) ?? ""
                    let sub = (req["subt"] as? String) ?? ""
                    body = (req["body"] as? String) ?? ""
                    if !sub.isEmpty { body = body.isEmpty ? sub : "\(sub) · \(body)" }
                }
            }
            if title.isEmpty && body.isEmpty { continue }
            rows.append(Row(id: id, bundle: bundle, title: title, body: body, date: date))
        }
        return rows
    }
}
#endif
