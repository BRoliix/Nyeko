#if !APPSTORE
import AppKit
import Combine
@preconcurrency import EventKit
import IOKit.ps
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Mac home (Nyeko)
//
// The island's home for the Mac itself: what is playing, the next event, the Notetaker, the apps
// you open most and a few quick actions. It opens when no coding agent needs the island.
// Nothing here runs on a timer: everything is read when the island opens (0 % CPU while hidden).

enum MacHome {
    /// On by default. Off: the island opens on the agents' overview, as Coucou does.
    static let enabledKey = "nyeko.macHome"
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

// MARK: - Next calendar event

/// The next event in Calendar (today or tomorrow), read with EventKit.
/// Access is asked only when you click "Show my next event", never on launch.
@MainActor
final class CalendarPeek: ObservableObject {
    static let shared = CalendarPeek()

    enum Access { case unknown, granted, denied }

    struct Event: Equatable {
        let title: String
        let start: Date
        let end: Date
        let color: NSColor?
        let location: String?
    }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var next: Event?
    /// The next few events, today and tomorrow (the window's Today card).
    @Published private(set) var upcoming: [Event] = []

    private var store: EKEventStore?
    private var changeObserver: NSObjectProtocol?

    private init() {
        access = Self.currentAccess()
        if access == .granted { makeStore() }
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }

    private func makeStore() {
        guard store == nil else { return }
        store = EKEventStore()
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CalendarPeek.shared.refresh() }
        }
    }

    /// Asks macOS for Calendar access (once), then reads the next event.
    func requestAccess() {
        if access == .denied { openPrivacySettings(); return }
        let asking = EKEventStore()
        store = asking
        asking.requestFullAccessToEvents { _, _ in
            Task { @MainActor in
                let peek = CalendarPeek.shared
                peek.access = CalendarPeek.currentAccess()
                if peek.access == .granted {
                    peek.store = nil
                    peek.makeStore()
                }
                peek.refresh()
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reads the next timed event that has not ended, from now to the end of tomorrow.
    func refresh() {
        access = Self.currentAccess()
        guard access == .granted, let store else { next = nil; upcoming = []; return }
        let now = Date()
        let cal = Calendar.current
        guard let end = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)) else { return }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        let events = upcoming.prefix(4).map { e in
            Event(title: e.title ?? String(localized: "Event"),
                  start: e.startDate, end: e.endDate,
                  color: e.calendar?.color,
                  location: e.location?.isEmpty == false ? e.location : nil)
        }
        if events != self.upcoming { self.upcoming = Array(events) }
        if events.first != next { next = events.first }
    }

    /// "10:30 · in 25 min", "Now · until 11:30", "Tomorrow 09:00".
    static func when(_ e: Event, now: Date = Date()) -> String {
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        if e.start <= now {
            return String(localized: "Now · until \(time.string(from: e.end))")
        }
        let minutes = Int((e.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 {
            return String(localized: "\(time.string(from: e.start)) · in \(minutes) min")
        }
        if Calendar.current.isDateInTomorrow(e.start) {
            return String(localized: "Tomorrow \(time.string(from: e.start))")
        }
        return time.string(from: e.start)
    }
}

// MARK: - Quick launch

/// The apps in the island's launch row. Bundle IDs in UserDefaults; apps that are not
/// installed are skipped. Right-click an app to remove it, + to add one.
@MainActor
final class QuickLaunch: ObservableObject {
    static let shared = QuickLaunch()
    static let key = "nyeko.quickLaunch"
    static let maxApps = 8

    struct Item: Identifiable {
        let id: String      // bundle ID
        let url: URL
        let name: String
    }

    /// Used when nothing is saved yet: the first ones that are installed.
    private static let defaults = [
        "com.apple.finder", "com.apple.Safari", "com.google.Chrome", "com.apple.mail",
        "com.microsoft.Outlook", "com.apple.Notes", "com.apple.iCal", "com.microsoft.Excel",
        "com.apple.Terminal", "com.microsoft.VSCode", "net.whatsapp.WhatsApp", "com.apple.systempreferences",
    ]

    @Published private(set) var ids: [String]
    private var iconCache: [String: NSImage] = [:]

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.key) {
            ids = saved
        } else {
            ids = Array(Self.defaults.filter {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
            }.prefix(7))
        }
    }

    var apps: [Item] {
        ids.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            return Item(id: id, url: url, name: name)
        }
    }

    var canAdd: Bool { apps.count < Self.maxApps }

    func icon(for app: Item) -> NSImage {
        if let cached = iconCache[app.id] { return cached }
        let image = NSWorkspace.shared.icon(forFile: app.url.path)
        image.size = NSSize(width: 64, height: 64)
        iconCache[app.id] = image
        return image
    }

    func open(_ app: Item) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration(),
                                           completionHandler: nil)
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }

    func remove(_ id: String) {
        ids.removeAll { $0 == id }
        save()
    }

    /// Pick an app in /Applications.
    func addWithPanel() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add an app to the island")
        panel.prompt = String(localized: "Add")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier, !ids.contains(id) else { return }
        ids.append(id)
        if ids.count > Self.maxApps { ids.removeFirst(ids.count - Self.maxApps) }
        save()
    }

    private func save() {
        UserDefaults.standard.set(ids, forKey: Self.key)
    }
}

// MARK: - Battery

struct BatteryReading: Equatable {
    let percent: Int
    let charging: Bool

    /// Read once, when the island opens. Nil on a Mac without a battery.
    static func read() -> BatteryReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else { return nil }
        for source in list as Array {
            guard let desc = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onPower = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return BatteryReading(percent: Int((Double(current) / Double(max) * 100).rounded()), charging: onPower)
        }
        return nil
    }

    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - What is playing (Spotify, Apple Music or any other app)

/// What the Now Playing cards show, whoever plays it. Spotify and Music come from their own
/// controllers (artwork, real controls); anything else comes from the system's Now Playing
/// (SystemNowPlaying), driven with the keyboard's media keys.
@MainActor
struct NowPlayingDisplay {
    let title: String
    let artist: String
    let album: String
    /// "Spotify", "Apple Music", "Google Chrome"…
    let source: String
    let artwork: NSImage?
    let playing: Bool
    let duration: Double?
    let position: (Date) -> Double
    let previous: () -> Void
    let toggle: () -> Void
    let next: () -> Void
    let open: () -> Void

    static func current() -> NowPlayingDisplay? {
        let spotify = SpotifyController.shared
        let music = MusicController.shared
        let system = SystemNowPlaying.shared

        func fromSpotify() -> NowPlayingDisplay? {
            guard let t = spotify.track else { return nil }
            return NowPlayingDisplay(title: t.title, artist: t.artist, album: t.album, source: "Spotify",
                                     artwork: spotify.artwork, playing: spotify.isPlaying,
                                     duration: t.duration > 0 ? t.duration : nil,
                                     position: { spotify.position(at: $0) },
                                     previous: { spotify.previousTrack() }, toggle: { spotify.playPause() },
                                     next: { spotify.nextTrack() }, open: { spotify.openSpotify() })
        }
        func fromMusic() -> NowPlayingDisplay? {
            guard let t = music.trackTitle else { return nil }
            return NowPlayingDisplay(title: t, artist: music.artist ?? "", album: music.album ?? "",
                                     source: "Apple Music", artwork: nil,
                                     playing: AppState.shared.musicPlaying, duration: nil,
                                     position: { _ in 0 },
                                     previous: { music.previousTrack() }, toggle: { music.playPause() },
                                     next: { music.nextTrack() }, open: { music.openMusic() })
        }
        func fromSystem() -> NowPlayingDisplay? {
            guard system.hasTrack else { return nil }
            return NowPlayingDisplay(title: system.title ?? "", artist: system.artist ?? "",
                                     album: system.album ?? "",
                                     source: system.appName ?? String(localized: "Now playing"),
                                     artwork: system.artwork, playing: system.playing,
                                     duration: system.duration,
                                     position: { system.position(at: $0) },
                                     previous: { system.previous() }, toggle: { system.playPause() },
                                     next: { system.next() }, open: { system.openApp() })
        }

        // What macOS itself shows as Now Playing comes first: the media started last (a YouTube
        // video over a song still running in Spotify). When it is Spotify or Music, their own
        // controller has the artwork and real controls.
        func fromSystemOrPlayer() -> NowPlayingDisplay? {
            if system.bundleId == SpotifyController.bundleId, let d = fromSpotify() { return d }
            if system.bundleId == "com.apple.Music", let d = fromMusic() { return d }
            return fromSystem()
        }
        if system.hasTrack, system.playing, let d = fromSystemOrPlayer() { return d }
        // Then whatever else plays, then whatever is paused.
        if spotify.isPlaying, let d = fromSpotify() { return d }
        if AppState.shared.musicPlaying, let d = fromMusic() { return d }
        if system.hasTrack, let d = fromSystemOrPlayer() { return d }
        return fromSpotify() ?? fromMusic()
    }
}

// MARK: - Output volume

/// The Mac's output volume, through Standard Additions (no permission needed).
enum SystemVolume {
    @MainActor static func get() -> Int? {
        var error: NSDictionary?
        let result = NSAppleScript(source: "output volume of (get volume settings)")?.executeAndReturnError(&error)
        guard error == nil, let value = result?.int32Value else { return nil }
        return Int(value)
    }

    @MainActor static func set(_ percent: Int) {
        let v = max(0, min(100, percent))
        var error: NSDictionary?
        NSAppleScript(source: "set volume output volume \(v)")?.executeAndReturnError(&error)
    }
}

// MARK: - Sticker Pop accents on the black island

enum NyekoIsland {
    static let tangerine = Color(hex: "#FF7A2F")
    static let mint      = Color(hex: "#2EC4B6")
    static let pink      = Color(hex: "#FF8FB1")
    static let sun       = Color(hex: "#FFC23D")
    static let cream     = Color(hex: "#FFF6E9")
    static let ink       = Color(hex: "#2B1D12")
    static let text      = Color(hex: "#F5F6F8")
    static let secondary = Color(hex: "#9A9FA8")
}
#endif
