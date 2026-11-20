#if !APPSTORE
import CryptoKit
import Security
import Foundation

// MARK: - Nyeko on the phone: the Mac's side of the relay link (docs/RELAY_LINK.md)
//
// The phone is Nyeko's web app (phone/ in this repo, on Cloudflare Pages). It cannot open a TLS socket to the Mac, so
// both sides open an outbound WebSocket to the user's own relay (android/relay, deployed on his Cloudflare account) and
// talk protocol v1 (docs/ANDROID_LINK.md) inside an end-to-end encrypted channel: HKDF-SHA-256, HMAC-SHA-256 and
// AES-256-GCM, exactly as the Windows computer (`phone_link/relay_client.rs`) and Coucou for Android do. The relay
// forwards opaque frames; it never sees the pairing key, the token, a session, a command or a chat.
//
// This file: the crypto (checked against android/relay/test-vectors.json by the web app's tests, same functions), the
// WebSocket client in the `pc` role, and one v1 conversation on top of it. Decisions go through `AndroidLinkHub`, the
// same rules as the Android link: only the request still pending, once, not after 115 s, deny-only when cut.

enum NyekoRelayCrypto {
    static let label = "coucou-relay/v1"
    static let version: UInt8 = 1
    enum FrameType: UInt8 { case initFrame = 1, accept = 2, data = 3 }
    enum Direction: UInt8 { case p2h = 1, h2p = 2 }
    static let maxLine = 65_536
    static let lastCounter: UInt64 = 0xFFFF_FFFF

    static func hkdf(_ ikm: Data, salt: Data, info: String, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                                         info: Data(info.utf8), outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }

    static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func kAuth(_ K: Data) -> Data { hkdf(K, salt: Data(), info: label + " auth", length: 32) }
    static func kJoin(_ K: Data) -> Data { hkdf(K, salt: Data(), info: label + " join", length: 32) }

    /// (phone → computer, computer → phone)
    static func session(_ K: Data, nPhone: Data, nPc: Data) -> (p2h: Data, h2p: Data) {
        let s = hkdf(K, salt: nPhone + nPc, info: label + " session", length: 64)
        return (s.prefix(32), s.suffix(32))
    }

    static func u64(_ v: UInt64) -> Data {
        withUnsafeBytes(of: v.bigEndian) { Data($0) }
    }

    static func frame(_ type: FrameType, counter: UInt64, body: Data) -> Data {
        Data([version, type.rawValue]) + u64(counter) + body
    }

    struct Parsed {
        let type: UInt8
        let counter: UInt64
        let body: Data
    }

    static func parse(_ data: Data) -> Parsed? {
        let b = [UInt8](data)
        guard b.count >= 10, b[0] == version else { return nil }
        var counter: UInt64 = 0
        for i in 2..<10 { counter = (counter << 8) | UInt64(b[i]) }
        return Parsed(type: b[1], counter: counter, body: Data(b[10...]))
    }

    static func nonce(_ dir: Direction, _ counter: UInt64) -> Data {
        Data([dir.rawValue, 0, 0, 0]) + u64(counter)
    }

    static func aad(room: String, _ dir: Direction, _ counter: UInt64) -> Data {
        Data(label.utf8) + Data(room.utf8) + Data([dir.rawValue, version, FrameType.data.rawValue]) + u64(counter)
    }

    static func pad(_ line: Data) -> Data? {
        guard line.count <= maxLine else { return nil }
        let size = max(128, Int((Double(4 + line.count) / 128).rounded(.up)) * 128)
        var out = withUnsafeBytes(of: UInt32(line.count).bigEndian) { Data($0) }
        out += line
        out += Data(count: size - out.count)
        return out
    }

    static func unpad(_ plain: Data) -> Data? {
        let b = [UInt8](plain)
        guard b.count >= 128, b.count % 128 == 0 else { return nil }
        let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        guard n <= maxLine, 4 + n <= b.count else { return nil }
        guard b[(4 + n)...].allSatisfy({ $0 == 0 }) else { return nil }
        return Data(b[4..<(4 + n)])
    }

    static func seal(key: Data, _ dir: Direction, room: String, counter: UInt64, line: Data) -> Data? {
        guard let plain = pad(line),
              let n = try? AES.GCM.Nonce(data: nonce(dir, counter)),
              let box = try? AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: n,
                                          authenticating: aad(room: room, dir, counter)) else { return nil }
        return frame(.data, counter: counter, body: box.ciphertext + box.tag)
    }

    static func open(key: Data, _ dir: Direction, room: String, _ p: Parsed) -> Data? {
        guard p.body.count >= 16 + 128,
              let n = try? AES.GCM.Nonce(data: nonce(dir, p.counter)),
              let box = try? AES.GCM.SealedBox(nonce: n, ciphertext: p.body.prefix(p.body.count - 16),
                                               tag: p.body.suffix(16)),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key),
                                            authenticating: aad(room: room, dir, p.counter)) else { return nil }
        return unpad(plain)
    }

    static func constantEq(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var d: UInt8 = 0
        for (x, y) in zip(a, b) { d |= x ^ y }
        return d == 0
    }

    static func random(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }
}

extension Data {
    var base64url: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64url: String) {
        var s = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}

// MARK: - The WebSocket, role `pc`

/// What the relay client tells the service.
enum NyekoRelayEvent: Sendable {
    case connecting
    /// Connected to the relay, no phone (or no handshake yet).
    case waiting
    /// A phone completed the handshake and said a valid hello.
    case phoneConnected(device: String)
    case phoneGone
    /// The relay refused us (401: wrong access key, 404: wrong URL…).
    case refused(Int)
}

final class NyekoRelayClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    struct Pairing: Sendable {
        let relay: String       // wss://host
        let room: String        // 22 base64url characters
        let K: Data             // 32 bytes
        let access: String      // 43 base64url characters
        let token: String       // v1 hello token
    }

    private let queue = DispatchQueue(label: "com.broliix.nyeko.phoneweb", qos: .utility)
    private let pairing: Pairing
    private let kAuth: Data
    private let kJoin: Data
    private let hub: AndroidLinkHub
    let onEvent: @Sendable (NyekoRelayEvent) -> Void
    /// A Nyeko message from the phone (control, ask, pushSub…), already authenticated.
    let onNyeko: @Sendable ([String: Any]) -> Void

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var stopped = true
    private var backoff: TimeInterval = 1
    private var keepAlive: DispatchSourceTimer?
    private var badInits = 0
    private var quietUntil = Date.distantPast

    // One encrypted session at a time (the newest init wins).
    private var keys: (p2h: Data, h2p: Data)?
    private var outCounter: UInt64 = 0
    private var inCounter: UInt64 = 0
    private var conversation: NyekoWebConversation?

    init(pairing: Pairing, hub: AndroidLinkHub,
         onEvent: @escaping @Sendable (NyekoRelayEvent) -> Void,
         onNyeko: @escaping @Sendable ([String: Any]) -> Void) {
        self.pairing = pairing
        self.kAuth = NyekoRelayCrypto.kAuth(pairing.K)
        self.kJoin = NyekoRelayCrypto.kJoin(pairing.K)
        self.hub = hub
        self.onEvent = onEvent
        self.onNyeko = onNyeko
        super.init()
    }

    // MARK: Start, stop

    func start() {
        queue.async {
            self.stopped = false
            self.backoff = 1
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.endSession()
            self.keepAlive?.cancel(); self.keepAlive = nil
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.session?.invalidateAndCancel()
            self.session = nil
        }
    }

    /// Back from sleep, or the network changed: reconnect now.
    func reconnectNow() {
        queue.async {
            guard !self.stopped else { return }
            self.backoff = 1
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.connect()
        }
    }

    var phoneIsConnected: Bool { queue.sync { conversation?.authenticated == true } }

    private func connect() {
        guard !stopped, task == nil else { return }
        let base = pairing.relay.hasSuffix("/") ? String(pairing.relay.dropLast()) : pairing.relay
        guard let url = URL(string: "\(base)/v1/room/\(pairing.room)?role=pc") else {
            onEvent(.refused(404)); return
        }
        // The same sub-protocols the web app offers (the relay reads the access key from `coucou.access.`, as it must
        // for a browser): URLSession's own API sets them, no hand-written header needed.
        let protocols = ["coucou.v1", "coucou.join.\(kJoin.base64url)", "coucou.access.\(pairing.access)"]
        if session == nil {
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.underlyingQueue = queue
            session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        }
        onEvent(.connecting)
        let t = session!.webSocketTask(with: url, protocols: protocols)
        t.maximumMessageSize = 70_000
        task = t
        t.resume()
        receive(on: t)
    }

    private func retryLater() {
        guard !stopped else { return }
        task = nil
        endSession()
        onEvent(.connecting)
        let delay = backoff
        backoff = min(60, backoff * 2)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    // MARK: URLSession delegate (on `queue`)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        backoff = 1
        onEvent(.waiting)
        startKeepAlive()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        retryLater()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101, (400..<500).contains(http.statusCode) {
            onEvent(.refused(http.statusCode))
            // A wrong key or URL will not fix itself: wait longer before trying again.
            backoff = max(backoff, 30)
        }
        retryLater()
    }

    // MARK: Reading

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard t === self.task else { return }
                switch result {
                case .failure:
                    self.retryLater()
                case .success(let message):
                    switch message {
                    case .string(let text): self.hint(text)
                    case .data(let data): self.frame(data)
                    @unknown default: break
                    }
                    self.receive(on: t)
                }
            }
        }
    }

    private func hint(_ text: String) {
        // Not authenticated: a hint only ends a session (the phone starts again with a new init).
        if text == #"{"peer":"offline"}"# || text == #"{"peer":"online"}"# { endSession() }
    }

    private func frame(_ data: Data) {
        guard let p = NyekoRelayCrypto.parse(data) else { return faultSession() }
        switch p.type {
        case NyekoRelayCrypto.FrameType.initFrame.rawValue:
            handleInit(p)
        case NyekoRelayCrypto.FrameType.data.rawValue:
            guard let keys else { return }
            guard p.counter == inCounter,
                  let line = NyekoRelayCrypto.open(key: keys.p2h, .p2h, room: pairing.room, p) else { return faultSession() }
            inCounter += 1
            conversation?.handle(line)
        default:
            break
        }
    }

    private func handleInit(_ p: NyekoRelayCrypto.Parsed) {
        guard Date() >= quietUntil else { return }
        guard p.counter == 0, p.body.count == 48 else { return badInit() }
        let nPhone = p.body.prefix(16)
        let mac = NyekoRelayCrypto.hmac(kAuth, Data("init".utf8) + Data(pairing.room.utf8) + nPhone)
        guard NyekoRelayCrypto.constantEq(mac, p.body.suffix(32)) else { return badInit() }
        badInits = 0
        // The newest init wins: the previous session (if any) ends.
        endSession()
        let nPc = NyekoRelayCrypto.random(16)
        let acceptMac = NyekoRelayCrypto.hmac(kAuth, Data("accept".utf8) + Data(pairing.room.utf8) + nPhone + nPc)
        keys = NyekoRelayCrypto.session(pairing.K, nPhone: Data(nPhone), nPc: nPc)
        outCounter = 0
        inCounter = 0
        let convo = NyekoWebConversation(token: pairing.token, hub: hub, queue: queue,
                                         send: { [weak self] line in self?.sendLine(line) },
                                         end: { [weak self] in self?.endSession() },
                                         onHello: { [weak self] device in self?.onEvent(.phoneConnected(device: device)) },
                                         onNyeko: onNyeko)
        conversation = convo
        task?.send(.data(NyekoRelayCrypto.frame(.accept, counter: 0, body: nPc + acceptMac))) { _ in }
    }

    private func badInit() {
        badInits += 1
        if badInits >= 3 { quietUntil = Date().addingTimeInterval(10); badInits = 0 }
    }

    // MARK: Writing (on `queue`)

    /// One v1 line to the phone. Dropped when no session is open.
    func sendLine(_ line: String) {
        queue.async {
            guard let keys = self.keys, let t = self.task else { return }
            guard self.outCounter < NyekoRelayCrypto.lastCounter else { return self.endSession() }
            let counter = self.outCounter
            self.outCounter += 1
            guard let frame = NyekoRelayCrypto.seal(key: keys.h2p, .h2p, room: self.pairing.room,
                                                     counter: counter, line: Data(line.utf8)) else { return }
            t.send(.data(frame)) { _ in }
        }
    }

    /// A Nyeko line (status, reply) to the phone, only when it said a valid hello.
    func sendNyeko(_ object: [String: Any]) {
        sendNyekoLine(AndroidLinkProtocol.json(object))
    }

    /// A line already encoded (made off the main thread, as file previews are).
    func sendNyekoLine(_ line: String) {
        queue.async {
            guard self.conversation?.authenticated == true else { return }
            self.sendLine(line)
        }
    }

    private func faultSession() {
        // Any fault drops the keys; the phone starts again with a new init. Nothing is said to the peer.
        endSession()
    }

    private func endSession() {
        let had = conversation?.authenticated == true
        conversation?.close()
        conversation = nil
        keys = nil
        if had { onEvent(.phoneGone) }
    }

    private func startKeepAlive() {
        keepAlive?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Cloudflare answers a text "ping" itself, without waking the room: it keeps NAT paths open.
        timer.schedule(deadline: .now() + 45, repeating: 45, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.task?.send(.string("ping")) { _ in } }
        timer.resume()
        keepAlive = timer
    }
}

// MARK: - One v1 conversation over the relay

/// The same rules as `AndroidLinkConnection`, without a socket of its own: the first line must be a valid hello with the
/// pairing's token, then decisions and answers go to the hub; Nyeko's own messages (control, ask, pushSub, and a session's chat: open, close, say,
/// unqueue) go to the app.
final class NyekoWebConversation: @unchecked Sendable {
    private let token: String
    private let hub: AndroidLinkHub
    private let queue: DispatchQueue
    private let send: @Sendable (String) -> Void
    private let end: @Sendable () -> Void
    private let onHello: @Sendable (String) -> Void
    private let onNyeko: @Sendable ([String: Any]) -> Void
    private(set) var authenticated = false
    private var subscription: UInt64?
    private var closed = false

    init(token: String, hub: AndroidLinkHub, queue: DispatchQueue,
         send: @escaping @Sendable (String) -> Void, end: @escaping @Sendable () -> Void,
         onHello: @escaping @Sendable (String) -> Void, onNyeko: @escaping @Sendable ([String: Any]) -> Void) {
        self.token = token
        self.hub = hub
        self.queue = queue
        self.send = send
        self.end = end
        self.onHello = onHello
        self.onNyeko = onNyeko
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let id = subscription { hub.unsubscribe(id); subscription = nil }
    }

    /// Called on the client's queue with one decrypted line.
    func handle(_ line: Data) {
        guard !closed, let message = AndroidLinkIncoming.parse(line) else { return end() }
        if !authenticated {
            guard case .hello(let sent, let version, let device, let asked) = message,
                  version == AndroidLinkProtocol.version, AndroidLinkProtocol.constantEq(sent, token) else {
                send(AndroidLinkProtocol.json(["type": "error", "code": "auth", "message": "bad token or version"]))
                return end()
            }
            authenticated = true
            // The web app shows everything the Android app can: the steps, Claude's questions (behind Face ID on the
            // phone), the plan usage, and Nyeko's own Mac controls.
            let caps = AndroidLinkCaps(details: asked.contains("details"), answers: asked.contains("answers"),
                                       usage: asked.contains("usage"))
            var offered = caps.offered
            if asked.contains("nyeko") { offered.append("nyeko") }
            var welcome: [String: Any] = ["type": "welcome", "v": AndroidLinkProtocol.version,
                                          "desktop": NyekoIdentity.name(), "cid": NyekoIdentity.id, "os": "macos"]
            if !offered.isEmpty { welcome["caps"] = offered }
            send(AndroidLinkProtocol.json(welcome))
            subscription = hub.subscribe(caps: caps, now: AndroidLinkProtocol.nowMs()) { [weak self] out in
                guard let self, !self.closed else { return false }
                switch out {
                case .line(let l): self.send(l)
                case .close(let code, let msg):
                    self.send(AndroidLinkProtocol.json(["type": "error", "code": code, "message": msg]))
                    self.queue.async { self.end() }
                }
                return true
            }
            onHello(device.isEmpty ? "phone" : device)
            return
        }
        switch message {
        case .ping:
            send(AndroidLinkProtocol.json(["type": "pong"]))
        case .decision(let fingerprint, let decision):
            _ = hub.decide(fingerprint: fingerprint, decision: decision, now: AndroidLinkProtocol.nowMs())
        case .answer(let fingerprint, let picks):
            _ = hub.answer(fingerprint: fingerprint, picks: picks, now: AndroidLinkProtocol.nowMs())
        case .bye:
            end()
        case .other(let type):
            guard ["control", "ask", "pushSub", "status", "open", "close", "say", "unqueue", "launch", "listApps", "browse", "preview", "reveal"].contains(type),
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
            onNyeko(object)
        case .hello:
            break
        }
    }
}
#endif
