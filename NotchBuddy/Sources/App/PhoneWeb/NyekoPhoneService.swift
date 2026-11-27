#if !APPSTORE
import AppKit
import Combine
import CryptoKit
import Foundation

// MARK: - Nyeko on the phone: pairing, what the phone sees, what it may do (Nyeko)
//
// Off by default. On (Settings → Phone): the Mac opens one outbound WebSocket to the user's own relay and waits for
// the paired web app. While the phone is connected it gets, inside the encrypted channel:
//   • the sessions, the pending approval and Claude Code's questions (the Android link's hub, same rules);
//   • Nyeko's "mac" status: what is playing, the next event, the focus timer, the Notetaker, the battery, the apps;
// and it may send: a decision or an answer (the hub checks them), a control (play/pause, timer, record, open an app…),
// a message to Nyo, and its Web Push subscription. It can also open a coding session: its conversation, kept current
// while the screen is open, and messages to it (SessionChat.swift), and start a new Claude Code session in one of the
// recent project folders the notch's launcher knows (never any other folder).
//
// Lock-screen alerts: when an approval or a question starts waiting and no phone is connected, the Mac sends a Web
// Push with NO payload (nothing about the command leaves the Mac) to the phone's push endpoint, signed with this Mac's
// VAPID key (CryptoKit, P-256). The web app's service worker shows "Nyo needs you".
//
// Two phones can be paired at once, each in its own relay room: the web app (iPhone) and the native Nyeko app for
// Android (android/), which pairs with a nyeko://pair link that carries only the relay fields.
//
// Secrets (pairing key K, access key, token, VAPID key, push endpoint) live in the Keychain.

/// Which paired phone: the web app, or the native Android app.
enum NyekoPhoneKind: String, CaseIterable, Sendable {
    case web, android
}

@MainActor
final class NyekoPhoneService: ObservableObject {
    static let shared = NyekoPhoneService()

    // Settings
    static let enabledKey = "nyeko.phone.enabled"
    static let relayKey = "nyeko.phone.relay"
    static let webAppKey = "nyeko.phone.webapp"
    static let defaultWebApp = "https://nyeko-phone.pages.dev"
    // Keychain
    private static let accessKC = "nyeko-phone-access"
    private static let pairingKC = "nyeko-phone-pairing"      // JSON {room, key, token}: the web app
    private static let androidPairingKC = "nyeko-phone-pairing-android"   // the same, for the Android app
    private static let vapidKC = "nyeko-phone-vapid"          // P-256 private key, raw, base64
    private static let pushKC = "nyeko-phone-push"            // the phone's Web Push endpoint

    enum Status: Equatable {
        case off
        case notConfigured
        case connecting
        case waiting
        case connected(String)
        case refused(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var hasPush = false
    /// Each phone's own state (the page shows both).
    @Published private(set) var links: [NyekoPhoneKind: Status] = [:]

    private var clients: [NyekoPhoneKind: NyekoRelayClient] = [:]
    private var hub: AndroidLinkHub?
    private var cancellables = Set<AnyCancellable>()
    private var macCancellable: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?
    private var watchingNowPlaying = false
    private var lastAlert: String?

    private init() {
        hasPush = Keychain.load(key: Self.pushKC) != nil
    }

    nonisolated static func log(_ message: String) { appendAppLog("phone.log", message) }

    // MARK: Settings

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    var relayURL: String {
        get { UserDefaults.standard.string(forKey: Self.relayKey) ?? "" }
        set {
            let v = Self.normalizedRelay(newValue)
            guard v != relayURL else { return }
            UserDefaults.standard.set(v, forKey: Self.relayKey)
            objectWillChange.send()
            settingsChanged()
        }
    }

    var webAppURL: String {
        get { UserDefaults.standard.string(forKey: Self.webAppKey) ?? Self.defaultWebApp }
        set {
            var v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            while v.hasSuffix("/") { v.removeLast() }
            UserDefaults.standard.set(v, forKey: Self.webAppKey); objectWillChange.send()
        }
    }

    var hasAccessKey: Bool { Keychain.load(key: Self.accessKC) != nil }

    func setAccessKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { Keychain.delete(key: Self.accessKC) } else { Keychain.save(key: Self.accessKC, value: k) }
        objectWillChange.send()
        settingsChanged()
    }

    /// "https://x.workers.dev/" → "wss://x.workers.dev"
    static func normalizedRelay(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("https://") { v = "wss://" + v.dropFirst(8) }
        if v.hasPrefix("http://") { v = "ws://" + v.dropFirst(7) }
        if !v.isEmpty && !v.hasPrefix("wss://") && !v.hasPrefix("ws://") { v = "wss://" + v }
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
        objectWillChange.send()
    }

    func startIfEnabled() {
        // The shared mouse works without the phone link; the phone only sets it up.
        MacShare.shared.onChange = { NyekoPhoneService.shared.sendMacStatus() }
        MacShare.shared.start()
        if Self.isEnabled { start() }
    }

    private func restartIfRunning() {
        guard Self.isEnabled else { return }
        stop(); start()
    }

    /// The relay or the key changed: when the switch is on, connect with the new values (or for the first time, once
    /// both are there). Waits a moment so typing the address does not reconnect on every key.
    private var settingsWork: DispatchWorkItem?
    private func settingsChanged() {
        settingsWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let me = NyekoPhoneService.shared
                guard NyekoPhoneService.isEnabled else { return }
                me.stop(); me.start()
            }
        }
        settingsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    // MARK: Pairing (room, K, token)

    private struct Stored: Codable {
        var room: String
        var key: String
        var token: String
    }

    private static func pairingKey(_ kind: NyekoPhoneKind) -> String { kind == .web ? pairingKC : androidPairingKC }

    private func storedPairing(_ kind: NyekoPhoneKind = .web, create: Bool) -> Stored? {
        if let raw = Keychain.load(key: Self.pairingKey(kind)), let data = raw.data(using: .utf8),
           let s = try? JSONDecoder().decode(Stored.self, from: data) { return s }
        guard create else { return nil }
        let s = Stored(room: NyekoRelayCrypto.random(16).base64url,
                       key: NyekoRelayCrypto.random(32).base64url,
                       token: NyekoRelayCrypto.random(24).base64url)
        if let data = try? JSONEncoder().encode(s), let raw = String(data: data, encoding: .utf8) {
            Keychain.save(key: Self.pairingKey(kind), value: raw)
        }
        return s
    }

    /// New room, key and token: the phone paired before is cut off (and its push endpoint forgotten).
    func pairAgain(_ kind: NyekoPhoneKind = .web) {
        Keychain.delete(key: Self.pairingKey(kind))
        if kind == .web {
            Keychain.delete(key: Self.pushKC)
            hasPush = false
        }
        _ = storedPairing(kind, create: true)
        Self.log("paired again (\(kind.rawValue))")
        restartIfRunning()
        objectWillChange.send()
    }

    /// What the web app needs, as one base64url string (it goes after `#pair=` in the link: a fragment never reaches
    /// any server). Nil until the relay URL and the access key are set.
    func pairingCode() -> String? {
        guard !relayURL.isEmpty, let access = Keychain.load(key: Self.accessKC),
              let p = storedPairing(create: true) else { return nil }
        var object: [String: Any] = [
            "v": 1, "relay": relayURL, "room": p.room, "key": p.key, "access": access, "token": p.token,
            "name": NyekoIdentity.name(), "cid": NyekoIdentity.id, "vapid": Self.vapidPublicKey(),
        ]
        // The same QR serves an Android phone: the page offers to open the Nyeko app with its own pairing (or to
        // download the app first). The web app ignores this field otherwise.
        if let android = androidPairingLink() { object["android"] = android }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return data.base64url
    }

    func pairingLink() -> String? {
        pairingCode().map { "\(webAppURL)/#pair=\($0)" }
    }

    /// The native Android app's link (docs/RELAY_LINK.md section 2, relay fields only: Nyeko pairs it through the relay,
    /// never on the local network). Creates the Android pairing the first time, and connects its room.
    func androidPairingLink() -> String? {
        guard !relayURL.isEmpty, let access = Keychain.load(key: Self.accessKC) else { return nil }
        let isNew = storedPairing(.android, create: false) == nil
        guard let p = storedPairing(.android, create: true) else { return nil }
        if isNew { DispatchQueue.main.async { MainActor.assumeIsolated { NyekoPhoneService.shared.restartIfRunning() } } }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let fields = [("v", "1"), ("relay", relayURL), ("room", p.room), ("key", p.key), ("access", access),
                      ("token", p.token), ("name", NyekoIdentity.name()), ("cid", NyekoIdentity.id)]
        return "nyeko://pair?" + fields.map { "\($0.0)=\(enc($0.1))" }.joined(separator: "&")
    }

    var androidPaired: Bool { storedPairing(.android, create: false) != nil }

    // MARK: Start, stop

    private func start() {
        guard clients.isEmpty else { return }
        guard !relayURL.isEmpty, let access = Keychain.load(key: Self.accessKC) else {
            status = .notConfigured
            return
        }
        let hub = AndroidLinkHub(host: AndroidLinkAppHost())
        // The web app's room always; the Android app's once it has a pairing (made when its link is first shown).
        for kind in NyekoPhoneKind.allCases {
            guard let p = storedPairing(kind, create: kind == .web), let K = Data(base64url: p.key) else { continue }
            let pairing = NyekoRelayClient.Pairing(relay: relayURL, room: p.room, K: K, access: access, token: p.token)
            let client = NyekoRelayClient(
                pairing: pairing, hub: hub,
                onEvent: { event in Task { @MainActor in NyekoPhoneService.shared.relayEvent(event, from: kind) } },
                onNyeko: { object in
                    // Only what the controls need crosses (strings and numbers), as JSON again.
                    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
                    Task { @MainActor in NyekoPhoneService.shared.nyeko(data, from: kind) }
                })
            clients[kind] = client
            links[kind] = .connecting
        }
        guard !clients.isEmpty else { status = .notConfigured; return }
        self.hub = hub
        SessionChat.shared.sink = { line in NyekoPhoneService.shared.sendAll(line) }
        status = .connecting
        observe()
        for client in clients.values { client.start() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NyekoPhoneService.shared.clients.values.forEach { $0.reconnectNow() } }
        }
        Self.log("starting (relay \(URL(string: relayURL)?.host ?? "?"), \(clients.count) phone room(s))")
    }

    /// A line for every connected phone (the Mac status, a session's conversation).
    private func sendAll(_ line: [String: Any]) {
        for client in clients.values { client.sendNyeko(line) }
    }

    private var anyPhoneConnected: Bool {
        links.values.contains { if case .connected = $0 { return true } else { return false } }
    }

    private func stop() {
        SessionChat.shared.close()
        clients.values.forEach { $0.stop() }
        clients = [:]
        links = [:]
        hub = nil
        cancellables.removeAll()
        macCancellable = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        setWatching(false)
        status = .off
        Self.log("stopped")
    }

    private func relayEvent(_ event: NyekoRelayEvent, from kind: NyekoPhoneKind) {
        guard clients[kind] != nil else { return }
        switch event {
        case .connecting:
            if case .refused = links[kind] { return }   // keep the reason on screen until it connects
            links[kind] = .connecting
        case .waiting:
            links[kind] = .waiting
            phoneLeft()
        case .phoneConnected(let device):
            links[kind] = .connected(device)
            Self.log("phone connected (\(kind.rawValue))")
            publish()
            setWatching(true)
            sendMacStatus()
        case .phoneGone:
            links[kind] = .waiting
            phoneLeft()
            Self.log("phone left (\(kind.rawValue))")
        case .refused(let code):
            let why: String
            switch code {
            case 401: why = String(localized: "The relay refused the access key.")
            case 404: why = String(localized: "The relay address looks wrong.")
            case 429: why = String(localized: "The relay is rate-limiting this Mac. Trying again soon.")
            default: why = String(localized: "The relay answered \(code).")
            }
            links[kind] = .refused(why)
            Self.log("relay refused: \(code)")
        }
        status = Self.overall(links)
    }

    /// What the page's top line says: a connected phone first, then a refusal, then waiting.
    private static func overall(_ links: [NyekoPhoneKind: Status]) -> Status {
        let names = NyekoPhoneKind.allCases.compactMap { k -> String? in
            if case .connected(let d) = links[k] { return d } else { return nil }
        }
        if !names.isEmpty { return .connected(names.joined(separator: " + ")) }
        for k in NyekoPhoneKind.allCases { if case .refused(let why) = links[k] { return .refused(why) } }
        if links.values.contains(.waiting) { return .waiting }
        return links.isEmpty ? .off : .connecting
    }

    private func phoneLeft() {
        guard !anyPhoneConnected else { return }
        setWatching(false)
        SessionChat.shared.close()
    }

    // MARK: From the island to the phone (the hub), event driven

    private func observe() {
        let s = AppState.shared
        let sources: [AnyPublisher<Void, Never>] = [
            s.$tasks.map { _ in () }.eraseToAnyPublisher(),
            s.$liveSessions.map { _ in () }.eraseToAnyPublisher(),
            s.$pendingApproval.map { _ in () }.eraseToAnyPublisher(),
            s.$waitingQuestions.map { _ in () }.eraseToAnyPublisher(),
            s.$claudePlanUsage.map { _ in () }.eraseToAnyPublisher(),
            s.$codexPlanUsage.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(sources)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated { NyekoPhoneService.shared.publish() } }
            .store(in: &cancellables)

        // What the Mac card shows: sent to a connected phone when it changes.
        let mac: [AnyPublisher<Void, Never>] = [
            SpotifyController.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            MusicController.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SystemNowPlaying.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            CoucoudoroController.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            NoteTaker.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            CalendarPeek.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SessionLauncher.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        macCancellable = Publishers.MergeMany(mac)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated { NyekoPhoneService.shared.sendMacStatus() } }
    }

    private func publish() {
        guard let hub else { return }
        let state = AppState.shared
        let now = AndroidLinkProtocol.nowMs()
        let demo = DemoEngine.shared.isActive
        // One row per live session (several can share a pill in the notch), not one per pill.
        let sessions = demo ? [] : state.liveSessions.map { s -> AndroidSessionIn in
            let status = SessionJump.status(s)
            let step = SessionJump.currentStep(s)
            return AndroidSessionIn(
                pillId: s.id, agent: s.projectName,
                state: status == .needsYou ? (state.pendingApproval?.sessionId == s.session ? "approval" : "question")
                    : status == .working ? "working" : "idle",
                statusText: step.map { "\(SessionJump.hostName(s)) · \($0)" } ?? SessionJump.hostName(s),
                project: s.cwd, color: SessionJump.color(s))
        }
        let approval = demo ? nil : state.pendingApproval.flatMap(AndroidLinkService.approval(from:))
        let question = demo ? nil : AndroidLinkService.question(from: state.waitingQuestions)
        hub.publish(sessions: sessions, approval: approval, now: now)
        hub.publishQuestion(question, now: now)
        hub.publishUsage(AndroidLinkService.usage(claude: state.claudePlanUsage, codex: state.codexPlanUsage))

        // Lock-screen alert: a new approval or question, and the web app is not open.
        let alertKey = approval?.requestId ?? question?.requestId
        if let alertKey, alertKey != lastAlert, clients[.web]?.phoneIsConnected != true {
            WebPush.alert()
        }
        lastAlert = alertKey
    }

    /// Any app's Now Playing is read only while a phone is connected (and the island or window shows it).
    private func setWatching(_ on: Bool) {
        guard on != watchingNowPlaying else { return }
        watchingNowPlaying = on
        if on { SystemNowPlaying.shared.startWatching() } else { SystemNowPlaying.shared.stopWatching() }
    }

    // MARK: Nyeko's "mac" status

    private func sendMacStatus() {
        guard anyPhoneConnected else { return }
        var mac: [String: Any] = ["type": "mac"]
        if let np = NowPlayingDisplay.current() {
            var n: [String: Any] = ["title": np.title, "artist": np.artist, "source": np.source, "playing": np.playing]
            if let d = np.duration, d > 0 {
                n["duration"] = d
                n["position"] = np.position(Date())
            }
            mac["nowPlaying"] = n
        }
        if let e = CalendarPeek.shared.next {
            mac["next"] = ["title": e.title, "when": CalendarPeek.when(e),
                           "start": Int(e.start.timeIntervalSince1970 * 1000)] as [String: Any]
        }
        let doro = CoucoudoroController.shared
        if doro.phase != .idle {
            var t: [String: Any] = ["phase": doro.phase == .work ? "work" : "rest", "paused": doro.paused]
            if let left = doro.remaining(at: Date()) { t["remaining"] = Int(left) }
            mac["timer"] = t
        }
        mac["recording"] = NoteTaker.shared.isRecording
        if let b = BatteryReading.read() { mac["battery"] = ["percent": b.percent, "charging": b.charging] as [String: Any] }
        mac["apps"] = QuickLaunch.shared.apps.map { ["id": $0.id, "name": $0.name] }
        // Which computer this is (a phone can be paired with several), and its sound.
        mac["name"] = NyekoIdentity.name()
        mac["cid"] = NyekoIdentity.id
        mac["os"] = "macos"
        if let share = MacShare.shared.status { mac["share"] = share }
        if let v = SystemVolume.get() { mac["volume"] = v }
        if let m = MacSystemControl.muted { mac["muted"] = m }
        // The folders a new session can start in (the notch launcher's recent projects). The phone names one by id.
        mac["projects"] = SessionLauncher.shared.projects.prefix(10).map { path -> [String: Any] in
            ["id": Self.projectId(path), "name": SessionLauncher.name(of: path),
             "where": ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath]
        }
        sendAll(mac)
    }

    // MARK: From the phone

    /// Lines made off the main thread (file listings and previews), in order.
    func sendLines(_ lines: [String], to kind: NyekoPhoneKind) {
        guard let client = clients[kind] else { return }
        for line in lines { client.sendNyekoLine(line) }
    }

    private func nyeko(_ data: Data, from kind: NyekoPhoneKind) {
        let client = clients[kind]
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "status":
            sendMacStatus()
        case "listApps":
            // Every installed app (names and ids only), for "Open any app" on the phone.
            client?.sendNyeko(["type": "apps", "apps": MacSystemControl.installedApps().prefix(400).map { ["id": $0.id, "name": $0.name] }])
        case "control":
            control(object["action"] as? String ?? "", app: object["app"] as? String)
        case "ask":
            let id = object["id"] as? String ?? ""
            let text = String((object["text"] as? String ?? "").prefix(4000))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { @MainActor in await self.ask(id: id, text: text, from: kind) }
        case "open":
            if let id = object["session"] as? String, id.count <= 200 { SessionChat.shared.open(id) }
        case "close":
            SessionChat.shared.close()
        case "unqueue":
            if let id = object["session"] as? String { SessionChat.shared.unqueue(id) }
        case "say":
            // A message to a coding session (SessionChat decides: typed now, or given to Claude when its turn ends).
            let id = object["session"] as? String ?? ""
            let messageId = object["id"] as? String ?? ""
            let text = String((object["text"] as? String ?? "").prefix(8000))
            guard !id.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { @MainActor in
                let said = await SessionChat.shared.say(id, text: text)
                client?.sendNyeko(["type": "said", "id": messageId, "session": id,
                                        "result": said.result, "note": said.note])
            }
        case "launch":
            let id = object["id"] as? String ?? ""
            let project = object["project"] as? String ?? ""
            let prompt = String((object["prompt"] as? String ?? "").prefix(8000))
            launch(id: id, project: project, folder: object["folder"] as? String, prompt: prompt, from: kind)
        case "browse":
            // A folder in the home folder, read-only (NyekoFiles; docs/PHONE_FILES.md). Read off the main thread; only
            // the encoded line crosses back.
            let id = String((object["id"] as? String ?? "").prefix(64))
            let asked = object["path"] as? String
            Task.detached {
                var out: [String: Any] = ["type": "folder", "id": id]
                if let url = NyekoFiles.resolve(asked) { out.merge(NyekoFiles.listing(url)) { _, new in new } }
                else { out["ok"] = false; out["note"] = "Nyeko only shows what is in your home folder." }
                let line = AndroidLinkProtocol.json(out)
                await NyekoPhoneService.shared.sendLines([line], to: kind)
            }
        case "preview":
            let id = String((object["id"] as? String ?? "").prefix(64))
            let asked = object["path"] as? String
            Task.detached {
                var lines: [String] = []
                if let url = NyekoFiles.resolve(asked), url != NyekoFiles.home {
                    let (header, chunks) = NyekoFiles.preview(url)
                    lines.append(AndroidLinkProtocol.json(["type": "file", "id": id].merging(header) { _, new in new }))
                    for (i, d) in chunks.enumerated() { lines.append(AndroidLinkProtocol.json(["type": "chunk", "id": id, "i": i, "d": d])) }
                } else {
                    lines.append(AndroidLinkProtocol.json(["type": "file", "id": id, "ok": false, "note": "Nyeko only shows what is in your home folder."]))
                }
                await NyekoPhoneService.shared.sendLines(lines, to: kind)
            }
        case "input":
            // The phone as trackpad and keyboard (MacRemoteInput; docs/REMOTE_INPUT.md).
            let events = (object["e"] as? [[String: Any]]) ?? []
            if events.contains(where: { $0["k"] as? String == "hello" }) {
                let ok = MacRemoteInput.ready(ask: true)
                client?.sendNyeko(["type": "inputState", "ok": ok,
                    "note": ok ? "" : "Allow Nyeko in System Settings › Privacy & Security › Accessibility on the Mac, then try again."])
            }
            MacRemoteInput.handle(events)
        case "share":
            // One mouse and keyboard for this Mac and a PC (MacShare; docs/SHARED_MOUSE.md): set up from the phone.
            var reply = MacShare.shared.command(object)
            reply["type"] = "shareState"
            client?.sendNyeko(reply)
            sendMacStatus()
        case "reveal":
            // Shows a file or folder in the Finder: selected, never opened.
            if let url = NyekoFiles.resolve(object["path"] as? String) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case "pushSub":
            guard let endpoint = object["endpoint"] as? String, let url = URL(string: endpoint),
                  url.scheme == "https", WebPush.allowedHost(url.host ?? "") else {
                Self.log("push subscription refused (not a known push service)")
                return
            }
            Keychain.save(key: Self.pushKC, value: endpoint)
            hasPush = true
            Self.log("push turned on (\(url.host ?? ""))")
        default:
            break
        }
    }

    private func control(_ action: String, app: String?) {
        Self.log("control: \(action)")
        switch action {
        case "playPause": NowPlayingDisplay.current()?.toggle()
        case "next": NowPlayingDisplay.current()?.next()
        case "previous": NowPlayingDisplay.current()?.previous()
        case "timer":
            let doro = CoucoudoroController.shared
            if doro.phase != .idle { doro.end() } else {
                let id = CoucoudoroController.pillId
                if !AppState.shared.activeIntegrations.contains(id) { AppState.shared.toggleIntegration(id) }
                doro.begin()
            }
        case "record":
            NoteTaker.shared.toggleFromPill()
        case "screenshot":
            QuickScreenshot.shared.take()
        case "focus":
            // A live session's own window (editor folder or terminal): nothing else can be named.
            if let app, let s = AppState.shared.liveSessions.first(where: { $0.id == app }) { SessionJump.open(s) }
        case "open":
            // Only an app of the Quick launch list: the phone cannot open anything else on the Mac.
            if let app, let item = QuickLaunch.shared.apps.first(where: { $0.id == app }) {
                NSWorkspace.shared.openApplication(at: item.url, configuration: NSWorkspace.OpenConfiguration(),
                                                   completionHandler: nil)
            }
        // The Mac itself (MacSystemControl.swift). Restart and shut down are confirmed on the phone, behind its lock.
        case "openAny":
            if let app { _ = MacSystemControl.open(appId: app) }
        case "volumeUp": MacSystemControl.volume(by: 6)
        case "volumeDown": MacSystemControl.volume(by: -6)
        case "mute": MacSystemControl.toggleMute()
        case "lock": MacSystemControl.lock()
        case "displaySleep": MacSystemControl.displaySleep()
        case "sleep": MacSystemControl.sleep()
        case "restart": MacSystemControl.power(restart: true)
        case "shutdown": MacSystemControl.power(restart: false)
        default:
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated { NyekoPhoneService.shared.sendMacStatus() }
        }
    }

    // MARK: A new coding session, from the phone

    static func projectId(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Starts Claude Code in one of the launcher's recent folders, like the notch's New session card. Then waits for the
    /// session's first hook event (up to a minute) and tells the phone which session it is, so it can open it.
    private func launch(id: String, project: String, folder asked: String?, prompt: String, from kind: NyekoPhoneKind) {
        let launcher = SessionLauncher.shared
        let client = clients[kind]
        func answer(_ fields: [String: Any]) {
            let base: [String: Any] = ["type": "launched", "id": id]
            client?.sendNyeko(base.merging(fields) { _, new in new })
        }
        // A recent project by its id, or (Nyeko) a folder the phone browsed to, inside the home folder.
        let picked = asked.flatMap { NyekoFiles.launchFolder($0) } ?? launcher.projects.first(where: { Self.projectId($0) == project })
        guard let folder = picked else {
            return answer(["ok": false, "note": asked == nil ? String(localized: "That folder isn't in Nyeko's recent projects any more.")
                                                             : "Nyeko only starts sessions in a folder inside your home folder."])
        }
        let before = Set(AppState.shared.liveSessions.map(\.id))
        launcher.choose(folder)
        guard launcher.launch(prompt: prompt) else {
            return answer(["ok": false, "note": String(localized: "Nyeko couldn't open a terminal in that folder.")])
        }
        Self.log("new session started from the phone")
        answer(["ok": true, "name": SessionLauncher.name(of: folder)])
        let wanted = URL(fileURLWithPath: folder).standardizedFileURL.path
        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard let client = NyekoPhoneService.shared.clients[kind] else { return }
                let fresh = AppState.shared.liveSessions.filter { !before.contains($0.id) }
                if let s = fresh.first(where: { URL(fileURLWithPath: $0.cwd).standardizedFileURL.path == wanted }) {
                    client.sendNyeko([
                        "type": "started", "id": id, "session": s.id, "title": s.projectName,
                        "host": SessionJump.hostName(s)])
                    return
                }
            }
        }
    }

    /// A message to Nyo from the phone: a Mac command is done here; anything else goes to Claude (your plan, on the
    /// Mac), in the same conversation as the island's chat.
    private func ask(id: String, text: String, from kind: NyekoPhoneKind) async {
        let reply: String
        if let done = await NyoActions.handle(text) {
            reply = done
        } else {
            let state = AppState.shared
            state.chatHistory.append(ChatMessage(role: .user, content: text))
            state.stateOverride = .thinking
            await ClaudeService.shared.chat(query: text, context: nil, state: state)
            reply = state.chatHistory.last(where: { $0.role == .assistant })?.content
                ?? String(localized: "Nyo could not answer right now.")
        }
        clients[kind]?.sendNyeko(["type": "reply", "id": id, "text": String(reply.prefix(20_000))])
    }

    // MARK: VAPID key (Web Push)

    static func vapidKey() -> P256.Signing.PrivateKey {
        if let raw = Keychain.load(key: vapidKC), let data = Data(base64Encoded: raw),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: data) { return key }
        let key = P256.Signing.PrivateKey()
        Keychain.save(key: vapidKC, value: key.rawRepresentation.base64EncodedString())
        return key
    }

    /// The uncompressed public key, base64url: the web app's `applicationServerKey`.
    static func vapidPublicKey() -> String {
        vapidKey().publicKey.x963Representation.base64url
    }

    static var pushEndpoint: String? { Keychain.load(key: pushKC) }

    func forgetPush() {
        Keychain.delete(key: Self.pushKC)
        hasPush = false
    }
}

// MARK: - Web Push without a payload (RFC 8030 + VAPID, RFC 8292)

enum WebPush {
    /// The push services browsers use: anything else is refused (the phone cannot make the Mac call an arbitrary URL).
    static func allowedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "web.push.apple.com" || h.hasSuffix(".push.apple.com")
            || h == "fcm.googleapis.com" || h.hasSuffix(".push.services.mozilla.com")
            || h.hasSuffix(".notify.windows.com")
    }

    /// "Nyo needs you": an empty push. Nothing about the request leaves the Mac.
    @MainActor static func alert() {
        guard let endpoint = NyekoPhoneService.pushEndpoint, let url = URL(string: endpoint),
              let host = url.host, allowedHost(host), let scheme = url.scheme else { return }
        let key = NyekoPhoneService.vapidKey()
        let audience = "\(scheme)://\(host)"
        let subject = NyekoPhoneService.shared.webAppURL.hasPrefix("https://")
            ? NyekoPhoneService.shared.webAppURL : "mailto:nyeko@localhost"
        guard let jwt = jwt(key: key, audience: audience, subject: subject) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("vapid t=\(jwt), k=\(key.publicKey.x963Representation.base64url)", forHTTPHeaderField: "Authorization")
        request.setValue("120", forHTTPHeaderField: "TTL")
        request.setValue("high", forHTTPHeaderField: "Urgency")
        request.setValue("nyeko-alert", forHTTPHeaderField: "Topic")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.httpBody = Data()
        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 || code == 410 {
                // The phone unsubscribed (or the app was removed): forget the endpoint.
                Task { @MainActor in NyekoPhoneService.shared.forgetPush() }
            }
            NyekoPhoneService.log(error == nil ? "push sent (\(code))" : "push failed: \(error!.localizedDescription)")
        }.resume()
    }

    static func jwt(key: P256.Signing.PrivateKey, audience: String, subject: String) -> String? {
        let header = #"{"typ":"JWT","alg":"ES256"}"#
        let claims: [String: Any] = ["aud": audience, "exp": Int(Date().timeIntervalSince1970) + 12 * 3600, "sub": subject]
        guard let claimsData = try? JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]) else { return nil }
        let input = Data(header.utf8).base64url + "." + claimsData.base64url
        guard let signature = try? key.signature(for: Data(input.utf8)) else { return nil }
        // JOSE ES256: r ‖ s, 64 bytes, which is CryptoKit's raw representation.
        return input + "." + signature.rawRepresentation.base64url
    }
}
#endif
