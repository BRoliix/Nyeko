#if !APPSTORE
import AppKit
import CryptoKit
import Foundation

// MARK: - The Mac's own controls, from the phone (Nyeko)
//
// Volume and mute, lock, display sleep, sleep, restart and shut down, and opening any installed app. The phone asks for
// restart and shut down behind a confirmation and the screen lock; here they wait a few seconds so the answer reaches the
// phone first, and macOS still asks apps with unsaved work, as it does from the Apple menu. Apps are opened only from the
// list this Mac sends (the usual Applications folders), by id: the phone can't name a path.

@MainActor
enum MacSystemControl {
    // Volume

    static func volume(by delta: Int) {
        if let v = SystemVolume.get() { SystemVolume.set(v + delta) }
        if delta > 0, muted == true { setMuted(false) }
    }

    static var muted: Bool? {
        var error: NSDictionary?
        let r = NSAppleScript(source: "output muted of (get volume settings)")?.executeAndReturnError(&error)
        return error == nil ? r?.booleanValue : nil
    }

    static func toggleMute() { setMuted(!(muted ?? false)) }

    private static func setMuted(_ on: Bool) {
        var error: NSDictionary?
        NSAppleScript(source: "set volume output muted \(on)")?.executeAndReturnError(&error)
    }

    // Lock and sleep

    /// ⌃⌘Q, the system's own Lock Screen shortcut (needs Accessibility, like typing into a session).
    static func lock() {
        // What the Apple menu's Lock Screen does (login.framework), with no permission to ask for. ⌃⌘Q below needs
        // Accessibility, which a new unsigned build loses until it is granted again.
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockNow = @convention(c) () -> Int32
            let lockNow = unsafeBitCast(symbol, to: LockNow.self)
            let result = lockNow()
            if result == 0 { return }
            NyekoPhoneService.log("lock: SACLockScreenImmediate returned \(result), trying the shortcut")
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let q: CGKeyCode = 12
        let down = CGEvent(keyboardEventSource: src, virtualKey: q, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: q, keyDown: false)
        down?.flags = [.maskCommand, .maskControl]
        up?.flags = [.maskCommand, .maskControl]
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func displaySleep() { run("/usr/bin/pmset", ["displaysleepnow"]) }
    static func sleep() { run("/usr/bin/pmset", ["sleepnow"]) }

    /// Restart or shut down, as from the Apple menu without its dialog (apps with unsaved work still ask), after [delay] seconds.
    static func power(restart: Bool, delay: TimeInterval = 4) {
        NyekoPhoneService.log(restart ? "restart from the phone" : "shut down from the phone")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var error: NSDictionary?
            let code = restart ? "rrst" : "rsdn"
            NSAppleScript(source: "tell application \"loginwindow\" to «event aevt\(code)»")?.executeAndReturnError(&error)
            if let error { NyekoPhoneService.log("power: \(error[NSAppleScript.errorNumber] ?? "?")") }
        }
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    // Any installed app

    struct App { let id: String; let name: String; let url: URL }

    private static var cached: (at: Date, apps: [App])?

    /// The apps in /Applications (and Utilities), /System/Applications (and Utilities) and ~/Applications, by name.
    static func installedApps() -> [App] {
        if let c = cached, Date().timeIntervalSince(c.at) < 300 { return c.apps }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       "\(home)/Applications"]
        var seen = Set<String>()
        var apps: [App] = []
        for folder in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for n in names where n.hasSuffix(".app") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(n)
                let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                guard seen.insert(name.lowercased()).inserted else { continue }
                let id = SHA256.hash(data: Data(url.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                apps.append(App(id: id, name: name, url: url))
            }
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cached = (Date(), apps)
        return apps
    }

    static func open(appId: String) -> String? {
        guard let app = installedApps().first(where: { $0.id == appId }) else { return nil }
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        return app.name
    }
}
#endif
