#if !APPSTORE
import CryptoKit
import Foundation

/// A new Mac set up from the phone (docs/RELAY_SETUP.md; the same protocol as phone/web/setup.js).
///
/// While this Mac has no relay, Settings → Phone shows a QR code: the relay's address, a one-time setup room and a
/// P-256 public key. The phone, which already knows the relay's access key, scans it and meets the Mac in that room
/// (the relay opens setup rooms without the key, for a few small frames). It sends the address and the key, encrypted
/// to this Mac's key; the Mac saves them, turns the phone link on and answers with its pairing code, which the phone
/// adds. Nothing is typed here.
@MainActor
final class NyekoSetupOffer: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    static let shared = NyekoSetupOffer()

    /// Nyeko's relay. Its address is public (the access key is what protects it), so a new Mac can meet the phone there
    /// before it knows anything else.
    static let defaultRelay = "wss://coucou-link.broliix.workers.dev"
    static let protocolName = "nyeko-setup/v1"
    private static let ttl: TimeInterval = 14 * 60

    enum State: Equatable {
        case idle
        case waiting
        case done(String)        // the phone that set it up
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var link: String?

    private var key = P256.KeyAgreement.PrivateKey()
    private var room = ""
    private var relay = defaultRelay
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var timers: [Timer] = []

    /// Shows a fresh code and waits for the phone (a code already showing is replaced).
    func start(relay: String = NyekoSetupOffer.defaultRelay) {
        stop()
        self.relay = NyekoPhoneService.normalizedRelay(relay)
        key = P256.KeyAgreement.PrivateKey()
        room = NyekoRelayCrypto.random(16).base64url
        let pub = key.publicKey.x963Representation.base64url
        let offer: [String: Any] = ["v": 1, "relay": self.relay, "room": room, "pub": pub,
                                    "name": NyekoIdentity.name(), "cid": NyekoIdentity.id]
        guard let json = try? JSONSerialization.data(withJSONObject: offer, options: [.sortedKeys]),
              let url = URL(string: "\(self.relay)/v1/setup/\(room)?role=pc") else {
            state = .failed(String(localized: "The relay address is not valid."))
            return
        }
        link = "\(NyekoPhoneService.shared.webAppURL)/#setup=\(json.base64url)"
        let proof = Data(SHA256.hash(data: Data("\(Self.protocolName) join \(room) \(pub)".utf8))).base64url
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        let t = s.webSocketTask(with: url, protocols: ["coucou.v1", "coucou.join.\(proof)"])
        session = s
        task = t
        state = .waiting
        t.resume()
        receive(on: t)
        // The relay answers a text "ping" itself; it keeps the socket alive while the code is on screen.
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak t] _ in
            t?.send(.string("ping")) { _ in }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: Self.ttl, repeats: false) { _ in
            MainActor.assumeIsolated { NyekoSetupOffer.shared.expire() }
        })
    }

    func stop() {
        timers.forEach { $0.invalidate() }
        timers = []
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        link = nil
        if state == .waiting { state = .idle }
    }

    private func expire() {
        guard state == .waiting else { return }
        stop()
        state = .failed(String(localized: "The code expired. Show a new one."))
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { result in
            // Plain values across the hop to the main actor.
            var frame: Data?
            var failed = false
            switch result {
            case .failure: failed = true
            case .success(.data(let d)): frame = d
            case .success: break                     // {"peer":…} notices and "pong"
            }
            let received = frame, broke = failed
            Task { @MainActor in
                let me = NyekoSetupOffer.shared
                guard t === me.task else { return }
                if broke {
                    if me.state == .waiting {
                        me.stop()
                        me.state = .failed(String(localized: "The relay could not be reached. Check the Mac is online, then show a new code."))
                    }
                    return
                }
                if let received { me.handle(received) }
                if me.task === t { me.receive(on: t) }
            }
        }
    }

    /// The phone's frame: 0x01 ‖ its public key (65) ‖ nonce (12) ‖ AES-GCM(relay, access, phone name).
    private func handle(_ frame: Data) {
        let f = Data(frame)
        guard f.count >= 1 + 65 + 12 + 16, f[f.startIndex] == 1 else { return }
        let base = f.startIndex
        guard let theirs = try? P256.KeyAgreement.PublicKey(x963Representation: f[(base + 1)..<(base + 66)]),
              let shared = try? key.sharedSecretFromKeyAgreement(with: theirs) else { return }
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(room.utf8),
                                                        sharedInfo: Data(Self.protocolName.utf8), outputByteCount: 32)
        guard let plain = Self.open(f[(base + 66)...], key: symmetric, aad: "\(Self.protocolName) hello \(room)"),
              let hello = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return }   // not for this code

        let relay = NyekoPhoneService.normalizedRelay(hello["relay"] as? String ?? "")
        let access = (hello["access"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let phoneName = String((hello["phone"] as? String ?? "Phone").prefix(64))
        var reply: [String: Any]
        if URL(string: relay)?.host == nil || !(relay.hasPrefix("wss://") || relay.hasPrefix("ws://")) {
            reply = ["error": String(localized: "The relay address sent by the phone is not valid.")]
        } else if access.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) == nil {
            reply = ["error": String(localized: "The access key sent by the phone is not valid.")]
        } else {
            let phone = NyekoPhoneService.shared
            phone.relayURL = relay
            phone.setAccessKey(access)
            phone.setEnabled(true)
            if let code = phone.pairingLink() {
                reply = ["code": code, "name": NyekoIdentity.name()]
            } else {
                reply = ["error": String(localized: "The Mac saved the settings but could not make its pairing code.")]
            }
        }
        if let body = try? JSONSerialization.data(withJSONObject: reply),
           let sealed = Self.seal(body, key: symmetric, aad: "\(Self.protocolName) done \(room)") {
            task?.send(.data(Data([2]) + sealed)) { _ in }
        }
        guard reply["code"] != nil else { return }
        NyekoPhoneService.log("set up from \(phoneName) through the relay")
        state = .done(phoneName)
        // Let the answer leave before the socket closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                let me = NyekoSetupOffer.shared
                if case .done = me.state { me.stop(); me.state = .done(phoneName) }
            }
        }
    }

    /// nonce (12) ‖ ciphertext ‖ tag (16), as WebCrypto's AES-GCM writes it.
    private static func seal(_ plain: Data, key: SymmetricKey, aad: String) -> Data? {
        guard let box = try? AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(), authenticating: Data(aad.utf8)) else { return nil }
        return Data(box.nonce) + box.ciphertext + box.tag
    }

    private static func open(_ bytes: Data, key: SymmetricKey, aad: String) -> Data? {
        let b = Data(bytes)
        guard b.count >= 28, let nonce = try? AES.GCM.Nonce(data: b.prefix(12)),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: b.dropFirst(12).dropLast(16), tag: b.suffix(16))
        else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: Data(aad.utf8))
    }

    // Closed by the relay (expired, limit) while the code is showing.
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            let me = NyekoSetupOffer.shared
            guard webSocketTask === me.task, me.state == .waiting else { return }
            me.stop()
            me.state = .failed(String(localized: "The code expired. Show a new one."))
        }
    }
}
#endif
