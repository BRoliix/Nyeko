#if !APPSTORE
import AppKit
import Combine
import ApplicationServices

// MARK: - What any app is playing (Nyeko)
//
// macOS 15.4 closed the MediaRemote framework to third-party apps. Apple's own script runner
// still has it: a short JavaScript-for-Automation script, run by /usr/bin/osascript, asks
// MediaRemote for the system's Now Playing (the same thing Control Center shows: YouTube in
// Chrome, podcasts, Spotify, anything). The same idea as ungive/mediaremote-adapter, which
// uses /usr/bin/perl.
//
// It is read only while the island or the window shows it (every 2 s), never while hidden.
// Reading works on macOS 26; sending commands through MediaRemote does not, so the buttons
// press the keyboard's media keys instead (needs Accessibility, which Nyeko already asks for).

@MainActor
final class SystemNowPlaying: ObservableObject {
    static let shared = SystemNowPlaying()

    @Published private(set) var title: String?
    @Published private(set) var artist: String?
    @Published private(set) var album: String?
    @Published private(set) var appName: String?
    @Published private(set) var bundleId: String?
    @Published private(set) var duration: Double?
    @Published private(set) var playing = false
    @Published private(set) var artwork: NSImage?
    /// Elapsed seconds at `anchorDate`; while playing, the real position runs on from there.
    @Published private(set) var elapsedAnchor: Double = 0
    @Published private(set) var anchorDate = Date()

    private var watchers = 0
    private var timer: Timer?
    private var reading = false
    private var artworkKey: String?

    private init() {}

    var hasTrack: Bool { !(title ?? "").isEmpty }

    func position(at date: Date) -> Double {
        let p = elapsedAnchor + (playing ? max(0, date.timeIntervalSince(anchorDate)) : 0)
        if let duration, duration > 0 { return min(p, duration) }
        return p
    }

    // MARK: Watching (only while something on screen shows it)

    func startWatching() {
        watchers += 1
        guard watchers == 1 else { return }
        read()
        let t = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { SystemNowPlaying.shared.read() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    /// One read now (when the island opens).
    func readOnce() { read() }

    private func read() {
        guard !reading else { return }
        reading = true
        let wantArt = artworkKey == nil || artworkKey != Self.key(title, artist)
        Task.detached(priority: .utility) {
            // Data is Sendable: parsed on the main actor.
            let (data, failure) = SystemNowPlaying.runScript(art: wantArt)
            await MainActor.run {
                let me = SystemNowPlaying.shared
                me.reading = false
                if let failure { me.logOnce("osascript failed: \(failure)") }
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                me.apply(json, askedArt: wantArt)
            }
        }
    }

    private static func key(_ title: String?, _ artist: String?) -> String {
        "\(title ?? "")\u{1F}\(artist ?? "")"
    }

    private func apply(_ json: [String: Any]?, askedArt: Bool) {
        guard let json else { return }
        if let error = json["error"] as? String {
            logOnce("error: \(error)")
            return
        }
        let newTitle = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let newTitle else {
            logOnce("nothing playing (MediaRemote answered without a title)")
            clear()
            return
        }
        let newArtist = json["artist"] as? String
        let changed = Self.key(newTitle, newArtist) != Self.key(title, artist)
        title = newTitle
        artist = newArtist
        album = json["album"] as? String
        appName = json["app"] as? String
        bundleId = json["bundle"] as? String
        duration = (json["duration"] as? NSNumber)?.doubleValue
        // No rate at all: some players (Safari, browsers) leave it out while playing.
        let rate = (json["rate"] as? NSNumber)?.doubleValue ?? 1
        playing = rate > 0
        if changed { logOnce("now playing: \(newTitle) · \(appName ?? bundleId ?? "?") · rate \(rate)") }
        if let elapsed = (json["elapsed"] as? NSNumber)?.doubleValue {
            // The elapsed time was taken at `timestamp`: carry it to now.
            if let ts = (json["timestamp"] as? NSNumber)?.doubleValue, ts > 0 {
                elapsedAnchor = elapsed
                anchorDate = Date(timeIntervalSince1970: ts)
            } else {
                elapsedAnchor = elapsed
                anchorDate = Date()
            }
        }
        if changed { artwork = nil }
        if askedArt {
            artworkKey = Self.key(newTitle, newArtist)
            if let b64 = json["artwork"] as? String, let data = Data(base64Encoded: b64) {
                artwork = NSImage(data: data)
            }
        }
    }

    /// ~/Library/Logs/NotchBuddy/nowplaying.log: what was read, without repeating the same line.
    private var lastLog: String?
    private func logOnce(_ line: String) {
        guard line != lastLog else { return }
        lastLog = line
        appendAppLog("nowplaying.log", line)
    }

    private func clear() {
        guard title != nil || playing else { return }
        title = nil; artist = nil; album = nil; appName = nil; bundleId = nil
        duration = nil; playing = false; artwork = nil; artworkKey = nil
        elapsedAnchor = 0
    }

    // MARK: Buttons (media keys)

    func playPause() { MediaKeys.press(.playPause); readSoon() }
    func next()      { MediaKeys.press(.next); readSoon() }
    func previous()  { MediaKeys.press(.previous); readSoon() }

    func openApp() {
        guard let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private func readSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated { SystemNowPlaying.shared.read() }
        }
    }

    // MARK: The script

    nonisolated private static let script = """
    ObjC.import('Foundation');
    function run(argv) {
      var out = {};
      try {
        var bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
        bundle.load;
        var Req = $.NSClassFromString('MRNowPlayingRequest');
        if (!Req || Req.isNil()) { return JSON.stringify({error: 'unavailable'}); }
        var item = Req.localNowPlayingItem;
        if (!item || item.isNil()) { return JSON.stringify({}); }
        var info = item.nowPlayingInfo;
        if (!info || info.isNil()) { return JSON.stringify({}); }
        var get = function (k) {
          try {
            var v = info.valueForKey(k);
            return (v && !v.isNil()) ? ObjC.unwrap(v) : null;
          } catch (e) { return null; }
        };
        out.title = get('kMRMediaRemoteNowPlayingInfoTitle');
        out.artist = get('kMRMediaRemoteNowPlayingInfoArtist');
        out.album = get('kMRMediaRemoteNowPlayingInfoAlbum');
        out.duration = get('kMRMediaRemoteNowPlayingInfoDuration');
        out.elapsed = get('kMRMediaRemoteNowPlayingInfoElapsedTime');
        out.rate = get('kMRMediaRemoteNowPlayingInfoPlaybackRate');
        try {
          var ts = info.valueForKey('kMRMediaRemoteNowPlayingInfoTimestamp');
          if (ts && !ts.isNil()) { out.timestamp = ts.timeIntervalSince1970; }
        } catch (e) {}
        try {
          var client = Req.localNowPlayingPlayerPath.client;
          out.app = ObjC.unwrap(client.displayName);
          out.bundle = ObjC.unwrap(client.bundleIdentifier);
        } catch (e) {}
        if (argv.length > 0 && argv[0] === 'art') {
          try {
            var data = info.valueForKey('kMRMediaRemoteNowPlayingInfoArtworkData');
            if (data && !data.isNil()) { out.artwork = ObjC.unwrap(data.base64EncodedStringWithOptions(0)); }
          } catch (e) {}
        }
      } catch (e) { if (!out.title) { out.error = String(e); } }
      return JSON.stringify(out);
    }
    """

    /// Runs the script with /usr/bin/osascript (off the main thread); its JSON output.
    /// Its output, or why it failed (for the log).
    nonisolated private static func runScript(art: Bool) -> (Data?, String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script] + (art ? ["art"] : [])
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        do { try process.run() } catch { return (nil, "launch: \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else {
            let message = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (nil, "status \(process.terminationStatus) \(message.prefix(300))")
        }
        return (data, nil)
    }
}

// MARK: - Media keys

/// Presses the keyboard's play/pause, next and previous keys: macOS sends them to whatever is
/// playing (Chrome, Safari, Spotify, Music, podcasts…). Needs Accessibility.
enum MediaKeys {
    enum Key: Int32 {
        case playPause = 16   // NX_KEYTYPE_PLAY
        case next = 17        // NX_KEYTYPE_NEXT
        case previous = 18    // NX_KEYTYPE_PREVIOUS
    }

    @MainActor static func press(_ key: Key) {
        guard AXIsProcessTrusted() else {
            // Ask once, the system way; the next click works.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        post(key, down: true)
        post(key, down: false)
    }

    @MainActor private static func post(_ key: Key, down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
        let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
        let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       subtype: 8, data1: data1, data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
#endif
