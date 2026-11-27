#if !APPSTORE
import AppKit
import ApplicationServices

/// Nyeko: the phone as this Mac's trackpad and keyboard (docs/REMOTE_INPUT.md). The phone sends small batches of events
/// ({type:"input", e:[…]}); they are posted like a real mouse and keyboard would be. Needs Accessibility, the permission
/// that typing into a session already uses. The phone asks for Face ID before it opens the trackpad.
/// The same events, and later the shared mouse between computers, are handled by Windows' remote_input.rs.
@MainActor
enum MacRemoteInput {
    /// Whether the Mac lets Nyeko post events. When `ask`, macOS shows its Accessibility prompt on the Mac.
    static func ready(ask: Bool = false) -> Bool {
        if ask {
            return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        return AXIsProcessTrusted()
    }

    /// Marks the events Nyeko posts, so the shared mouse's event tap (MacShare) lets them through untouched.
    nonisolated static let marker: Int64 = 0x4E59_454B

    private static var leftDown = false
    private static var rightDown = false
    private static var middleDown = false
    /// Keys held by the shared mouse's keyboard (kd/ku), and its modifiers.
    private static var held: Set<CGKeyCode> = []
    private static var heldFlags: CGEventFlags = []
    private static var scrollCarry = CGPoint.zero
    private static let source = CGEventSource(stateID: .hidSystemState)

    /// Where the pointer is, kept on the screens (the union of all displays).
    private static func clamp(_ p: CGPoint) -> CGPoint {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let rects = ids.prefix(Int(n)).map { CGDisplayBounds($0) }
        if rects.contains(where: { $0.contains(p) }) { return p }
        // Outside every screen: the nearest point on the nearest screen.
        var best = p, dist = CGFloat.infinity
        for r in rects {
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < dist { dist = d; best = q }
        }
        return best
    }

    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private static func post(_ ev: CGEvent?) {
        ev?.setIntegerValueField(.eventSourceUserData, value: marker)
        ev?.post(tap: .cghidEventTap)
    }

    /// One event from the phone, checked.
    enum Event: Sendable {
        case move(CGPoint), down(String), up(String), click(right: Bool, n: Int)
        case scroll(dx: Double, dy: Double), text(String), key(String, mods: [String]), release
        /// A key pressed or let go on the shared keyboard (another computer's), by name.
        case keyDown(String), keyUp(String)
    }

    static func parse(_ e: [String: Any]) -> Event? {
        let right = e["b"] as? String == "right"
        let b = (e["b"] as? String).flatMap { ["right", "middle"].contains($0) ? $0 : nil } ?? "left"
        switch e["k"] as? String {
        case "move": return .move(CGPoint(x: num(e["dx"], limit: 4000), y: num(e["dy"], limit: 4000)))
        case "down": return .down(b)
        case "up": return .up(b)
        case "kd": return (e["key"] as? String).flatMap { $0.count <= 12 ? .keyDown($0) : nil }
        case "ku": return (e["key"] as? String).flatMap { $0.count <= 12 ? .keyUp($0) : nil }
        case "click": return .click(right: right, n: max(1, Int(num(e["n"], limit: 3))))
        case "scroll": return .scroll(dx: num(e["dx"], limit: 4000), dy: num(e["dy"], limit: 4000))
        case "text": return (e["t"] as? String).map { .text(String($0.prefix(500))) }
        case "key": return (e["key"] as? String).map { .key($0, mods: (e["mods"] as? [String] ?? []).filter { $0.count < 8 }) }
        case "release": return .release
        default: return nil
        }
    }

    /// Batches run one after another, in order.
    private static var chain: Task<Void, Never>?

    /// One batch from the phone (it sends about 25 a second: the relay's own limit is 30). A move is spread over a few
    /// steps 8 ms apart so the pointer glides instead of jumping; what follows it in the batch waits its turn.
    /// Unknown or malformed events are skipped.
    static func handle(_ raw: [[String: Any]]) {
        guard ready() else { return }
        var plan: [(delay: UInt64, event: Event)] = []
        for e in raw.prefix(200) {
            guard let ev = parse(e) else { continue }
            if case .move(let d) = ev {
                let steps = min(4, max(1, Int(hypot(d.x, d.y) / 6)))
                for i in 0 ..< steps {
                    plan.append((i == 0 ? 0 : 8_000_000, .move(CGPoint(x: d.x / Double(steps), y: d.y / Double(steps)))))
                }
            } else {
                plan.append((0, ev))
            }
        }
        guard !plan.isEmpty else { return }
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            for (delay, ev) in plan {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                apply(ev)
            }
        }
    }

    static func apply(_ ev: Event) {
        switch ev {
        case .move(let d): move(by: d)
        case .down(let b): button(b, down: true)
        case .up(let b): button(b, down: false)
        case .keyDown(let k): transition(k, down: true)
        case .keyUp(let k): transition(k, down: false)
        case .click(let right, let n):
            button(right ? "right" : "left", down: true, clicks: n)
            button(right ? "right" : "left", down: false, clicks: n)
        case .scroll(let dx, let dy): scroll(dx: dx, dy: dy)
        case .text(let t): type(t)
        case .key(let k, let mods): key(k, mods: mods)
        case .release: release()
        }
    }

    private static func num(_ v: Any?, limit: Double) -> Double {
        let d = (v as? NSNumber)?.doubleValue ?? 0
        return d.isFinite ? min(max(d, -limit), limit) : 0
    }

    static func move(by d: CGPoint) {
        let to = clamp(CGPoint(x: location.x + d.x, y: location.y + d.y))
        let type: CGEventType = leftDown ? .leftMouseDragged : rightDown ? .rightMouseDragged : middleDown ? .otherMouseDragged : .mouseMoved
        let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to,
                         mouseButton: leftDown ? .left : rightDown ? .right : middleDown ? .center : .left)
        ev?.setIntegerValueField(.mouseEventDeltaX, value: Int64(d.x.rounded()))
        ev?.setIntegerValueField(.mouseEventDeltaY, value: Int64(d.y.rounded()))
        ev?.flags = heldFlags
        post(ev)
    }

    /// The pointer straight to a point (kept on the screens), as a move: no warp, so the mouse is not held still after it.
    static func moveTo(_ p: CGPoint) {
        let at = location
        move(by: CGPoint(x: p.x - at.x, y: p.y - at.y))
    }

    /// A click counts as a double click when it comes soon enough after the last one, close enough to it.
    private static var lastClick: (at: Date, point: CGPoint, button: String, count: Int) = (.distantPast, .zero, "", 0)

    private static func button(_ which: String, down: Bool, clicks: Int? = nil) {
        let type: CGEventType
        let button: CGMouseButton
        switch which {
        case "right": type = down ? .rightMouseDown : .rightMouseUp; button = .right; rightDown = down
        case "middle": type = down ? .otherMouseDown : .otherMouseUp; button = .center; middleDown = down
        default: type = down ? .leftMouseDown : .leftMouseUp; button = .left; leftDown = down
        }
        var count = clicks ?? 1
        if clicks == nil {
            // A separate down and up (a real mouse, or a press held on the phone): count the clicks like macOS would.
            let p = location
            if down {
                let near = hypot(p.x - lastClick.point.x, p.y - lastClick.point.y) < 6
                let soon = Date().timeIntervalSince(lastClick.at) < NSEvent.doubleClickInterval
                count = (near && soon && lastClick.button == which) ? min(lastClick.count + 1, 3) : 1
                lastClick = (Date(), p, which, count)
            } else {
                count = lastClick.button == which ? lastClick.count : 1
            }
        }
        let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button)
        ev?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        if which == "middle" { ev?.setIntegerValueField(.mouseEventButtonNumber, value: 2) }
        ev?.flags = heldFlags
        post(ev)
    }

    /// Pixels the phone's two fingers moved; dy > 0 shows what is further down.
    private static func scroll(dx: Double, dy: Double) {
        scrollCarry.x += dx; scrollCarry.y += dy
        let x = Int32(scrollCarry.x.rounded(.towardZero)), y = Int32(scrollCarry.y.rounded(.towardZero))
        guard x != 0 || y != 0 else { return }
        scrollCarry.x -= Double(x); scrollCarry.y -= Double(y)
        post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: -y, wheel2: -x, wheel3: 0))
    }

    /// Text as typed, in whatever app is in front (any language: the characters themselves, not keys).
    private static func type(_ text: String) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            var chunk = Array(units[i ..< min(i + 16, units.count)])
            // Don't split a surrogate pair.
            if chunk.count == 16, let last = chunk.last, UTF16.isLeadSurrogate(last) { chunk.removeLast() }
            for down in [true, false] {
                let ev = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                ev?.flags = []
                chunk.withUnsafeBufferPointer { ev?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                post(ev)
            }
            i += max(1, chunk.count)
        }
    }

    /// macOS virtual key codes (ANSI layout) for the keys the phone names.
    nonisolated static let keyCodes: [String: CGKeyCode] = [
        "enter": 36, "tab": 48, "space": 49, "backspace": 51, "esc": 53, "delete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45,
        "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "`": 50,
    ]

    private static func key(_ name: String, mods: [String]) {
        guard let code = keyCodes[name.lowercased()] else { return }
        var flags: CGEventFlags = []
        for m in mods {
            switch m {
            case "cmd", "meta", "win": flags.insert(.maskCommand)
            case "ctrl": flags.insert(.maskControl)
            case "alt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: break
            }
        }
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            ev?.flags = flags
            post(ev)
        }
    }

    /// The name of a macOS key code, for the shared keyboard (nil for keys it does not carry).
    nonisolated static func keyName(_ code: Int64) -> String? { keyNames[code] }

    nonisolated private static let keyNames: [Int64: String] = Dictionary(keyCodes.map { (Int64($0.value), $0.key) }, uniquingKeysWith: { a, _ in a })

    /// The modifiers as the other computer names them, and the Mac's: what Windows' Ctrl, Win and Alt become here is the
    /// PC's choice (remote_input.rs: Ctrl → ⌘ so Ctrl+C copies, Win → ⌃).
    private static let modifierCodes: [String: (code: CGKeyCode, flag: CGEventFlags)] = [
        "cmd": (55, .maskCommand), "ctrl": (59, .maskControl), "alt": (58, .maskAlternate), "shift": (56, .maskShift),
    ]

    /// A key of the shared keyboard pressed or let go. Keys held go down with the modifiers held.
    private static func transition(_ name: String, down: Bool) {
        let n = name.lowercased()
        if let m = modifierCodes[n] {
            if down { heldFlags.insert(m.flag) } else { heldFlags.remove(m.flag) }
            let ev = CGEvent(keyboardEventSource: source, virtualKey: m.code, keyDown: down)
            ev?.type = .flagsChanged
            ev?.flags = heldFlags
            post(ev)
            return
        }
        guard let code = keyCodes[n] else { return }
        if down { held.insert(code) } else { held.remove(code) }
        let ev = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        ev?.flags = heldFlags
        post(ev)
    }

    /// The phone left the trackpad (or lost the link): no button stays held.
    static func release() {
        if leftDown { button("left", down: false) }
        if rightDown { button("right", down: false) }
        if middleDown { button("middle", down: false) }
        for code in held { post(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)) }
        held = []
        for (name, m) in modifierCodes where heldFlags.contains(m.flag) { transition(name, down: false) }
        heldFlags = []
        scrollCarry = .zero
    }
}
#endif
