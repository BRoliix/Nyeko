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
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return AXIsProcessTrusted()
    }

    private static var leftDown = false
    private static var rightDown = false
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

    private static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// One event from the phone, checked.
    enum Event: Sendable {
        case move(CGPoint), down(right: Bool), up(right: Bool), click(right: Bool, n: Int)
        case scroll(dx: Double, dy: Double), text(String), key(String, mods: [String]), release
    }

    static func parse(_ e: [String: Any]) -> Event? {
        let right = e["b"] as? String == "right"
        switch e["k"] as? String {
        case "move": return .move(CGPoint(x: num(e["dx"], limit: 4000), y: num(e["dy"], limit: 4000)))
        case "down": return .down(right: right)
        case "up": return .up(right: right)
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
        case .down(let right): button(right ? "right" : "left", down: true)
        case .up(let right): button(right ? "right" : "left", down: false)
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
        let type: CGEventType = leftDown ? .leftMouseDragged : rightDown ? .rightMouseDragged : .mouseMoved
        let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to, mouseButton: leftDown ? .left : .right)
        ev?.setIntegerValueField(.mouseEventDeltaX, value: Int64(d.x.rounded()))
        ev?.setIntegerValueField(.mouseEventDeltaY, value: Int64(d.y.rounded()))
        ev?.post(tap: .cghidEventTap)
    }

    private static func button(_ which: String?, down: Bool, clicks: Int = 1) {
        let right = which == "right"
        let type: CGEventType = right ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .leftMouseDown : .leftMouseUp)
        let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: right ? .right : .left)
        ev?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        ev?.post(tap: .cghidEventTap)
        if right { rightDown = down } else { leftDown = down }
    }

    /// Pixels the phone's two fingers moved; dy > 0 shows what is further down.
    private static func scroll(dx: Double, dy: Double) {
        scrollCarry.x += dx; scrollCarry.y += dy
        let x = Int32(scrollCarry.x.rounded(.towardZero)), y = Int32(scrollCarry.y.rounded(.towardZero))
        guard x != 0 || y != 0 else { return }
        scrollCarry.x -= Double(x); scrollCarry.y -= Double(y)
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: -y, wheel2: -x, wheel3: 0)?.post(tap: .cghidEventTap)
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
                ev?.post(tap: .cghidEventTap)
            }
            i += max(1, chunk.count)
        }
    }

    /// macOS virtual key codes (ANSI layout) for the keys the phone names.
    static let keyCodes: [String: CGKeyCode] = [
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
            ev?.post(tap: .cghidEventTap)
        }
    }

    /// The phone left the trackpad (or lost the link): no button stays held.
    static func release() {
        if leftDown { button("left", down: false) }
        if rightDown { button("right", down: false) }
        scrollCarry = .zero
    }
}
#endif
