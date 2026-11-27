#if !APPSTORE
import AppKit
import ApplicationServices
import CryptoKit
import Network

/// What the event tap hands over, read on the spot: the CGEvent itself never leaves the callback.
struct ShareTapEvent: Sendable {
    var type: UInt32
    var location: CGPoint
    var dx: Double
    var dy: Double
    var button: Int64
    var keyCode: Int64
    var flags: UInt64
    var scrollX: Double
    var scrollY: Double
    var ours: Bool
}

/// The event tap's callback (a C function: no context). It runs on the main run loop, where the tap is added.
private func shareTap(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let e = ShareTapEvent(
        type: type.rawValue, location: event.location,
        dx: Double(event.getIntegerValueField(.mouseEventDeltaX)), dy: Double(event.getIntegerValueField(.mouseEventDeltaY)),
        button: event.getIntegerValueField(.mouseEventButtonNumber), keyCode: event.getIntegerValueField(.keyboardEventKeycode),
        flags: event.flags.rawValue,
        scrollX: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
        scrollY: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
        ours: event.getIntegerValueField(.eventSourceUserData) == MacRemoteInput.marker)
    let swallow = MainActor.assumeIsolated { MacShare.shared.tapped(e) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// Nyeko: one mouse and keyboard for this Mac and a Windows PC beside it (docs/SHARED_MOUSE.md).
///
/// The Mac connects to the PC's phone link on the local network (TLS, the PC's certificate pinned, its pairing token),
/// the way the Android app does, and asks for `share`. The phone sets it up: it asks the PC for its link and hands it to
/// the Mac with the side the PC is on. Then:
///   * away: the Mac's pointer is pushed off the edge facing the PC. The Mac sends `shareEnter`, keeps its own pointer
///     still, swallows its mouse and keyboard and sends them to the PC as `input` lines, until the PC says `shareLeave`
///     (its pointer came back across that edge);
///   * guest: the PC's pointer came across. The PC sends `shareEnter` and its mouse and keyboard as `input`; the Mac posts
///     them (MacRemoteInput) until its pointer is pushed back off the edge facing the PC, and says `shareLeave`.
///     Touching the Mac's own mouse meanwhile takes the Mac back.
/// Both sides ping every 2 s while connected; 7 s of silence gives the mouse and keyboard back to their own computer.
/// Needs Accessibility (the same permission the phone's trackpad uses).
@MainActor
final class MacShare {
    static let shared = MacShare()

    /// The PC this Mac shares with. `side` is where the PC stands: "left" or "right" of the Mac.
    struct Peer: Codable, Equatable {
        var host: String
        var port: UInt16
        var fp: String
        var name: String
        var cid: String
        var side: String
    }

    private static let peerKey = "nyeko.share.peer"
    static let tokenKey = "nyeko-share-token"

    private(set) var peer: Peer?
    private enum Link: Equatable { case off, connecting, connected, refused }
    private var link: Link = .off
    private var note = ""
    /// Told whenever what the phone shows changes.
    var onChange: (() -> Void)?

    private enum Mode { case local, away, guest }
    private var mode: Mode = .local

    private var connection: NWConnection?
    private var buffer = Data()
    private var lastHeard = Date.distantPast
    private var heartbeat: Timer?
    private var retry: Task<Void, Never>?
    private var attempt = 0

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var flushTimer: Timer?
    private var pendingMove = CGPoint.zero
    private var pending: [[String: Any]] = []
    /// Where the pointer left (away) and when the last switch happened (no bouncing straight back).
    private var anchor = CGPoint.zero
    private var lastSwitch = Date.distantPast
    private var flags: UInt64 = 0

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.peerKey), let p = try? JSONDecoder().decode(Peer.self, from: data) {
            peer = p
        }
    }

    // MARK: Setup (from the phone)

    /// At launch: reconnects to the PC it was sharing with.
    func start() {
        guard peer != nil, KeychainStore.shared.get(Self.tokenKey) != nil, connection == nil else { return }
        connect()
    }

    /// `{type:"share", action:"setup"|"side"|"off", link?, side?}` from the phone. Returns what to tell it.
    func command(_ object: [String: Any]) -> [String: Any] {
        let side = (object["side"] as? String).flatMap { ["left", "right"].contains($0) ? $0 : nil }
        switch object["action"] as? String {
        case "setup":
            guard let text = object["link"] as? String, let side, var p = Self.parse(text) else {
                return ["ok": false, "note": "The PC's link did not come through: try again."]
            }
            guard let token = Self.token(in: text) else { return ["ok": false, "note": "The PC's link has no usable token."] }
            p.side = side
            stop()
            KeychainStore.shared.set(Self.tokenKey, value: token)
            save(p)
            _ = MacRemoteInput.ready(ask: true)
            connect()
            return ["ok": true, "note": ""]
        case "side":
            guard let side, var p = peer else { return ["ok": false, "note": "Set it up first."] }
            p.side = side
            save(p)
            send(["type": "share", "side": side])
            changed()
            return ["ok": true, "note": ""]
        case "off":
            stop()
            peer = nil
            UserDefaults.standard.removeObject(forKey: Self.peerKey)
            KeychainStore.shared.remove(Self.tokenKey)
            changed()
            return ["ok": true, "note": ""]
        default:
            return ["ok": false, "note": ""]
        }
    }

    /// For the phone's view of the Mac (`mac` status).
    var status: [String: Any]? {
        guard let peer else { return nil }
        let state: String
        switch link {
        case .off: state = "off"
        case .connecting: state = "connecting"
        case .connected: state = tap == nil ? "permission" : "on"
        case .refused: state = "refused"
        }
        var s: [String: Any] = ["name": peer.name, "cid": peer.cid, "side": peer.side, "state": state]
        if !note.isEmpty { s["note"] = note }
        return s
    }

    private func save(_ p: Peer) {
        peer = p
        if let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: Self.peerKey) }
    }

    private func changed() { onChange?() }

    /// `nyeko://pair?v=1&host=…&port=…&fp=…&token=…&name=…&cid=…` (the PC's own pairing link for phones on its Wi-Fi).
    static func parse(_ text: String) -> Peer? {
        guard let q = query(text), let host = q["host"], !host.isEmpty, host.count <= 64,
              let port = q["port"].flatMap({ UInt16($0) }), port > 0,
              let fp = q["fp"]?.lowercased(), fp.count == 64, fp.allSatisfy(\.isHexDigit) else { return nil }
        let name = String((q["name"] ?? "PC").prefix(64))
        let cid = q["cid"].flatMap { $0.count <= 64 ? $0 : nil } ?? ""
        return Peer(host: host, port: port, fp: fp, name: name, cid: cid, side: "left")
    }

    static func token(in text: String) -> String? {
        guard let t = query(text)?["token"], (16...128).contains(t.count),
              t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return t
    }

    private static func query(_ text: String) -> [String: String]? {
        guard let range = text.range(of: #"(?:nyeko|coucou)://pair\?[^\s"'<>]+"#, options: .regularExpression),
              let comps = URLComponents(string: String(text[range])) else { return nil }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
        return q
    }

    // MARK: The connection to the PC

    private func connect() {
        guard let peer, let token = KeychainStore.shared.get(Self.tokenKey) else { return }
        retry?.cancel(); retry = nil
        link = .connecting
        changed()
        let tls = Self.pinned(peer.fp)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = false
        guard let port = NWEndpoint.Port(rawValue: peer.port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(peer.host), port: port, using: params)
        connection = conn
        buffer = Data()
        let id = ObjectIdentifier(conn)
        conn.stateUpdateHandler = { state in
            MainActor.assumeIsolated { MacShare.shared.state(state, of: id, token: token) }
        }
        conn.start(queue: .main)
    }

    /// TLS that trusts exactly the PC's own (self-signed) certificate: the one whose fingerprint is in its link.
    /// Built outside the main actor: the check runs on another queue.
    nonisolated private static func pinned(_ expected: String) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let t = sec_trust_copy_ref(trust).takeRetainedValue()
            var ok = false
            if let chain = SecTrustCopyCertificateChain(t) as? [SecCertificate], let leaf = chain.first {
                let der = SecCertificateCopyData(leaf) as Data
                ok = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined() == expected
            }
            complete(ok)
        }, DispatchQueue.global(qos: .userInitiated))
        return tls
    }

    private func state(_ state: NWConnection.State, of id: ObjectIdentifier, token: String) {
        guard let conn = connection, ObjectIdentifier(conn) == id else { return }
        switch state {
        case .ready:
            lastHeard = Date()
            send(["type": "hello", "v": 1, "token": token, "caps": ["share"], "name": NyekoIdentity.name()])
            receive(conn)
        case .failed, .cancelled:
            lost(retrying: link != .refused)
        case .waiting:
            // No route (the PC is off, or another network): try again later rather than wait here.
            lost(retrying: true)
        default:
            break
        }
    }

    private func receive(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
            MainActor.assumeIsolated { MacShare.shared.received(data, done: done || error != nil, from: id) }
        }
    }

    private func received(_ data: Data?, done: Bool, from id: ObjectIdentifier) {
        guard let conn = connection, ObjectIdentifier(conn) == id else { return }
        if let data { buffer.append(data) }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< nl]
            buffer.removeSubrange(buffer.startIndex ... nl)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(object) }
        }
        if buffer.count > 128 * 1024 { conn.cancel(); return }
        if done { conn.cancel() } else { receive(conn) }
    }

    private func handle(_ object: [String: Any]) {
        lastHeard = Date()
        switch object["type"] as? String {
        case "welcome":
            guard (object["caps"] as? [String])?.contains("share") == true else {
                note = "This PC's Nyeko is too old to share its mouse: update it."
                link = .refused
                connection?.cancel()
                return
            }
            attempt = 0
            link = .connected
            note = ""
            if let p = peer { send(["type": "share", "side": p.side]) }
            startTap()
            startHeartbeat()
            changed()
        case "error":
            if object["code"] as? String == "auth" {
                link = .refused
                note = "The PC did not accept the pairing: set it up again from the phone."
                changed()
            }
            connection?.cancel()
        case "shareState":
            let n = object["note"] as? String ?? ""
            if n != note { note = n; changed() }
        case "shareEnter":
            guestEnter(y: Self.fraction(object["y"]))
        case "shareLeave":
            if mode == .away { comeBack(y: Self.fraction(object["y"])) }
        case "input":
            if mode == .guest { guestInput((object["e"] as? [[String: Any]]) ?? []) }
        case "ping":
            send(["type": "pong"])
        default:
            break
        }
    }

    private func send(_ object: [String: Any]) {
        guard let conn = connection, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        conn.send(content: data + Data([0x0A]), completion: .contentProcessed { _ in })
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Self.timer(2) {
            let s = MacShare.shared
            if Date().timeIntervalSince(s.lastHeard) > 7 { s.connection?.cancel(); return }
            s.send(["type": "ping"])
        }
    }

    /// The connection ended: the mouse and keyboard are this Mac's again, and it tries again a little later.
    private func lost(retrying: Bool) {
        if mode == .away { comeBack(y: nil) }
        if mode == .guest { guestLeave(tellPC: false) }
        heartbeat?.invalidate(); heartbeat = nil
        stopTap()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        if link != .refused { link = retrying ? .connecting : .off }
        changed()
        guard retrying, link != .refused, peer != nil else { return }
        attempt += 1
        let wait = UInt64(min(30, 1 << min(attempt, 5)))
        retry?.cancel()
        retry = Task { @MainActor in
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            guard !Task.isCancelled, MacShare.shared.connection == nil else { return }
            MacShare.shared.connect()
        }
    }

    /// A repeating timer on the main run loop that keeps firing while a menu is open or a window is dragged.
    private static func timer(_ interval: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { fire() } }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func stop() {
        retry?.cancel(); retry = nil
        link = .off
        if connection != nil { send(["type": "bye"]) }
        lost(retrying: false)
        link = .off
    }

    // MARK: The event tap

    private func startTap() {
        guard tap == nil else { return }
        guard MacRemoteInput.ready(ask: true) else {
            note = "Allow Nyeko in System Settings › Privacy & Security › Accessibility on the Mac."
            return
        }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                    .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: shareTap, userInfo: nil) else {
            note = "Allow Nyeko in System Settings › Privacy & Security › Accessibility on the Mac."
            return
        }
        tap = port
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
    }

    /// One event of this Mac's own mouse or keyboard. True: swallowed (it went to the PC).
    func tapped(_ e: ShareTapEvent) -> Bool {
        guard let type = CGEventType(rawValue: e.type) else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if e.ours { return false }
        switch mode {
        case .local:
            if type == .flagsChanged { flags = e.flags }
            guard type == .mouseMoved, link == .connected, let side = peer?.side,
                  Date().timeIntervalSince(lastSwitch) > 0.3, let y = crossing(at: e.location, dx: e.dx, side: side) else { return false }
            goAway(y: y, at: e.location)
            return true
        case .guest:
            // The Mac's own mouse moved or clicked: the Mac takes itself back.
            if [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel].contains(type) { guestLeave(tellPC: true) }
            return false
        case .away:
            forward(type, e)
            return true
        }
    }

    private static var screens: [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).map { CGDisplayBounds($0) }
    }

    /// The height (0…1) where the pointer is pushed off the edge facing the PC, or nil if it is not.
    private func crossing(at p: CGPoint, dx: Double, side: String) -> Double? {
        let all = Self.screens
        guard let r = all.first(where: { $0.contains(p) }) else { return nil }
        let left = side == "left"
        guard left ? (dx < 0 && p.x <= r.minX + 0.5) : (dx > 0 && p.x >= r.maxX - 1.5) else { return nil }
        let beyond = CGPoint(x: left ? r.minX - 1 : r.maxX + 1, y: p.y)
        guard !all.contains(where: { $0.contains(beyond) }) else { return nil }
        return Double((p.y - r.minY) / max(1, r.height))
    }

    private static func fraction(_ v: Any?) -> Double? {
        guard let d = (v as? NSNumber)?.doubleValue, d.isFinite else { return nil }
        return min(max(d, 0), 1)
    }

    // MARK: Away: this Mac's mouse and keyboard drive the PC

    private func goAway(y: Double, at p: CGPoint) {
        mode = .away
        anchor = p
        lastSwitch = Date()
        pendingMove = .zero
        pending = []
        send(["type": "shareEnter", "y": y])
        // The pointer stays where it left; the mouse still reports how it moves.
        CGAssociateMouseAndMouseCursorPosition(0)
        // Keys already held (a shortcut in progress) go across with it.
        for (mask, name) in Self.modifierMasks where flags & mask != 0 { pending.append(["k": "kd", "key": name]) }
        flushTimer?.invalidate()
        flushTimer = Self.timer(0.008) { MacShare.shared.flush() }
    }

    /// The Mac's modifiers as the PC's: ⌘ is Ctrl there (⌘C copies), ⌃ is Ctrl too, ⌥ is Alt.
    private static let modifierMasks: [(UInt64, String)] = [
        (CGEventFlags.maskCommand.rawValue, "ctrl"), (CGEventFlags.maskControl.rawValue, "ctrl"),
        (CGEventFlags.maskAlternate.rawValue, "alt"), (CGEventFlags.maskShift.rawValue, "shift"),
    ]

    private static let modifierKeys: [Int64: (UInt64, String)] = [
        55: (CGEventFlags.maskCommand.rawValue, "ctrl"), 54: (CGEventFlags.maskCommand.rawValue, "ctrl"),
        59: (CGEventFlags.maskControl.rawValue, "ctrl"), 62: (CGEventFlags.maskControl.rawValue, "ctrl"),
        58: (CGEventFlags.maskAlternate.rawValue, "alt"), 61: (CGEventFlags.maskAlternate.rawValue, "alt"),
        56: (CGEventFlags.maskShift.rawValue, "shift"), 60: (CGEventFlags.maskShift.rawValue, "shift"),
    ]

    private func forward(_ type: CGEventType, _ e: ShareTapEvent) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            pendingMove.x += e.dx
            pendingMove.y += e.dy
            return
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
            let b: String
            switch type {
            case .leftMouseDown, .leftMouseUp: b = "left"
            case .rightMouseDown, .rightMouseUp: b = "right"
            default:
                guard e.button == 2 else { return }
                b = "middle"
            }
            takeMove()
            pending.append(["k": down ? "down" : "up", "b": b])
        case .scrollWheel:
            takeMove()
            // dy > 0 shows what is further down (a negative wheel delta on the Mac).
            pending.append(["k": "scroll", "dx": -e.scrollX, "dy": -e.scrollY])
            return
        case .keyDown, .keyUp:
            guard let name = MacRemoteInput.keyName(e.keyCode) else { return }
            takeMove()
            pending.append(["k": type == .keyDown ? "kd" : "ku", "key": name])
        case .flagsChanged:
            let before = flags
            flags = e.flags
            if e.keyCode == 57 {
                // Caps Lock: one press on the PC whichever way it turned.
                pending.append(["k": "kd", "key": "capslock"]); pending.append(["k": "ku", "key": "capslock"])
            } else if let m = Self.modifierKeys[e.keyCode], (before & m.0) != (e.flags & m.0) {
                pending.append(["k": e.flags & m.0 != 0 ? "kd" : "ku", "key": m.1])
            }
        default:
            return
        }
        flush()
    }

    private func takeMove() {
        guard pendingMove != .zero else { return }
        pending.append(["k": "move", "dx": pendingMove.x, "dy": pendingMove.y])
        pendingMove = .zero
    }

    private func flush() {
        guard mode == .away else { return }
        takeMove()
        guard !pending.isEmpty else { return }
        send(["type": "input", "raw": true, "e": pending])
        pending = []
    }

    /// The PC's pointer came back across (y: where), or the link ended (nil): the pointer comes back on this Mac.
    private func comeBack(y: Double?) {
        flushTimer?.invalidate(); flushTimer = nil
        pending = []; pendingMove = .zero
        mode = .local
        lastSwitch = Date()
        CGAssociateMouseAndMouseCursorPosition(1)
        guard let y, let side = peer?.side else { return }
        let r = Self.screens.first(where: { $0.contains(anchor) }) ?? CGDisplayBounds(CGMainDisplayID())
        let x = side == "left" ? r.minX + 3 : r.maxX - 4
        MacRemoteInput.moveTo(CGPoint(x: x, y: r.minY + CGFloat(y) * (r.height - 1)))
    }

    // MARK: Guest: the PC's mouse and keyboard drive this Mac

    private func guestEnter(y: Double?) {
        guard let side = peer?.side, MacRemoteInput.ready() else { return }
        if mode == .away { comeBack(y: nil) }
        mode = .guest
        lastSwitch = Date()
        // The outermost screen on the PC's side; the pointer comes in at the same height it left the PC.
        let all = Self.screens
        let r = (side == "left" ? all.min(by: { $0.minX < $1.minX }) : all.max(by: { $0.maxX < $1.maxX })) ?? CGDisplayBounds(CGMainDisplayID())
        let x = side == "left" ? r.minX + 2 : r.maxX - 3
        MacRemoteInput.moveTo(CGPoint(x: x, y: r.minY + CGFloat(y ?? 0.5) * (r.height - 1)))
    }

    private func guestInput(_ events: [[String: Any]]) {
        guard let side = peer?.side else { return }
        for e in events.prefix(400) {
            if e["k"] as? String == "move" {
                let d = CGPoint(x: Self.number(e["dx"]), y: Self.number(e["dy"]))
                let at = MacRemoteInput.location
                let all = Self.screens
                guard let r = all.first(where: { $0.contains(at) }) else { MacRemoteInput.move(by: d); continue }
                let to = CGPoint(x: at.x + d.x, y: at.y)
                let off = side == "left" ? (d.x < 0 && to.x < r.minX) : (d.x > 0 && to.x >= r.maxX)
                if off && !all.contains(where: { $0.contains(to) }) {
                    guestLeave(tellPC: true, y: Double((at.y - r.minY) / max(1, r.height)))
                    return
                }
                MacRemoteInput.move(by: d)
            } else if let ev = MacRemoteInput.parse(e) {
                MacRemoteInput.apply(ev)
            }
        }
    }

    /// The Mac is the Mac's again: anything the PC held is let go.
    private func guestLeave(tellPC: Bool, y: Double? = nil) {
        guard mode == .guest else { return }
        mode = .local
        lastSwitch = Date()
        MacRemoteInput.release()
        if tellPC {
            var y = y
            if y == nil {
                let at = MacRemoteInput.location
                if let r = Self.screens.first(where: { $0.contains(at) }) { y = Double((at.y - r.minY) / max(1, r.height)) }
            }
            send(["type": "shareLeave", "y": y ?? 0.5])
        }
    }

    private static func number(_ v: Any?) -> Double {
        let d = (v as? NSNumber)?.doubleValue ?? 0
        return d.isFinite ? min(max(d, -4000), 4000) : 0
    }
}
#endif
