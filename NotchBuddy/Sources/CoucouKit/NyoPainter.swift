import SwiftUI
import QuartzCore

// MARK: - Nyo, Nyeko's cat
//
// Nyo is drawn in "design units" of the 120-unit character sheet: the head's centre is
// (60, 65), 38 units to each side and 35 up and down, mapped onto the engine's rx and ry.
// The same numbers drive Windows/Linux (windows/src/mochi/nyo.ts) and Android
// (android/.../nyeko/NyoGeo.kt): change one, change all three.
// © 2026 Rohil Sagar — Nyo's look is Nyeko's own (LICENSE-ASSETS.md).

enum NyoGeo {
    enum Cmd {
        case m(CGFloat, CGFloat)
        case l(CGFloat, CGFloat)
        case c(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        case z
    }

    static let mint      = Color(red: 0.180, green: 0.769, blue: 0.714)   // #2EC4B6
    static let tangerine = Color(red: 1.000, green: 0.478, blue: 0.184)   // #FF7A2F

    static let centre = CGPoint(x: 60, y: 65)
    static let halfW: CGFloat = 38
    static let halfH: CGFloat = 35

    /// The head, with zig-zag cheek fluff on both sides.
    static let head: [Cmd] = [
        .m(60, 30), .c(76, 30, 88, 36, 94, 48), .c(98, 56, 99, 63, 98, 69),
        .l(105, 73), .l(97, 77), .l(102, 83), .l(93, 85),
        .c(86, 95, 74, 100, 60, 100), .c(46, 100, 34, 95, 27, 85),
        .l(18, 83), .l(23, 77), .l(15, 73), .l(22, 69),
        .c(21, 63, 22, 56, 26, 48), .c(32, 36, 44, 30, 60, 30), .z,
    ]
    /// Left ear; the right one is its mirror (x → 120 − x).
    static let earOuter: [Cmd] = [.m(31, 50), .c(28, 36, 29, 24, 33, 14), .c(42, 19, 50, 27, 55, 37), .z]
    static let earInner: [Cmd] = [.m(35, 42), .c(34, 33, 35, 27, 37, 22), .c(42, 26, 46, 31, 48, 36), .z]
    static let earTuft:  [Cmd] = [.m(33, 15), .l(30, 8), .m(33, 15), .l(36, 9)]
    static let earPivot = CGPoint(x: 40, y: 44)

    /// Tail poses: a start and two curves (14 numbers), so one blends into the next.
    static let tailRest: [CGFloat] = [86, 96, 104, 98, 114, 88, 112, 74, 111, 66, 104, 64, 102, 70]
    static let tailUp:   [CGFloat] = [88, 92, 106, 88, 112, 70, 106, 52, 103, 44, 96, 42, 96, 50]
    static let tailPuff: [CGFloat] = [86, 94, 106, 96, 116, 82, 112, 64, 110, 54, 102, 50, 100, 58]
    static let tailWrap: [CGFloat] = [84, 98, 70, 108, 46, 108, 34, 100, 30, 97, 32, 92, 37, 94]
    static let tailCurl: [CGFloat] = [88, 92, 108, 90, 114, 70, 104, 58, 99, 52, 93, 56, 96, 62]

    static func mirrored(_ cmds: [Cmd]) -> [Cmd] {
        cmds.map {
            switch $0 {
            case let .m(x, y): return .m(120 - x, y)
            case let .l(x, y): return .l(120 - x, y)
            case let .c(a, b, c, d, e, f): return .c(120 - a, b, 120 - c, d, 120 - e, f)
            case .z: return .z
            }
        }
    }

    /// Builds a path, passing every point (control points too) through `f`.
    static func build(_ cmds: [Cmd], _ f: (CGFloat, CGFloat) -> CGPoint) -> Path {
        var p = Path()
        for cmd in cmds {
            switch cmd {
            case let .m(x, y): p.move(to: f(x, y))
            case let .l(x, y): p.addLine(to: f(x, y))
            case let .c(a, b, c, d, e, g): p.addCurve(to: f(e, g), control1: f(a, b), control2: f(c, d))
            case .z: p.closeSubpath()
            }
        }
        return p
    }

    /// The head outline as points around the centre, in units of (halfW, halfH): the
    /// file-box morph blends each one towards the box along its own direction.
    static let headUnit: [CGPoint] = {
        var out: [CGPoint] = []
        var cur = CGPoint.zero
        func unit(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (x - centre.x) / halfW, y: (y - centre.y) / halfH)
        }
        for cmd in head {
            switch cmd {
            case let .m(x, y):
                cur = CGPoint(x: x, y: y); out.append(unit(x, y))
            case let .l(x, y):
                cur = CGPoint(x: x, y: y); out.append(unit(x, y))
            case let .c(a, b, c, d, e, g):
                for i in 1...10 {
                    let t = CGFloat(i) / 10, s = 1 - t
                    let x = s*s*s*cur.x + 3*s*s*t*a + 3*s*t*t*c + t*t*t*e
                    let y = s*s*s*cur.y + 3*s*s*t*b + 3*s*t*t*d + t*t*t*g
                    out.append(unit(x, y))
                }
                cur = CGPoint(x: e, y: g)
            case .z:
                break
            }
        }
        return out
    }()

    /// The tail as a path (in design units), from a 14-number pose.
    static func tailCmds(_ p: [CGFloat]) -> [Cmd] {
        [.m(p[0], p[1]), .c(p[2], p[3], p[4], p[5], p[6], p[7]), .c(p[8], p[9], p[10], p[11], p[12], p[13])]
    }
}

/// What Nyo's ears and tail are doing, eased every frame.
struct NyoPose {
    var earL: CGFloat = 0          // radians; negative turns the left ear out and down
    var earR: CGFloat = 0
    var earUp: CGFloat = 1         // ears pricked up when he needs you
    var tail: [CGFloat] = NyoGeo.tailRest
    var tailW: CGFloat = 9
    var twitchSide: CGFloat = 1
    var twitchStart: Double = 0
    var nextTwitch: Double = CACurrentMediaTime() + 3 + Double.random(in: 0...4)
}

extension BotEngine {

    // MARK: Pose

    /// Ears, tail and the occasional ear twitch follow the state.
    func updateNyo(dt: Double, now: Double) {
        guard NyoStyle.enabled else { return }
        let k = CGFloat(1 - pow(0.0005, dt))   // ~0.25 s to settle
        var tL: CGFloat = 0, tR: CGFloat = 0, up: CGFloat = 1
        var tail = NyoGeo.tailRest
        var tailW: CGFloat = 9
        switch state {
        case .idle:      break
        case .working:   tail = NyoGeo.tailUp; tL = -0.05; tR = 0.05
        case .thinking:  tL = -0.18; tR = 0.07
        case .searching: tail = NyoGeo.tailUp; tL = 0.08; tR = -0.08
        case .approval:  tail = NyoGeo.tailUp; up = 1.1
        case .question:  tail = NyoGeo.tailCurl; tR = 0.25
        case .error:     tail = NyoGeo.tailPuff; tailW = 13; tL = -0.66; tR = 0.66
        case .finished:  tail = NyoGeo.tailCurl
        case .ratelimit: tail = NyoGeo.tailWrap; tL = -0.35; tR = 0.35
        case .sleeping:  tail = NyoGeo.tailWrap; tL = -0.2; tR = 0.2
        case .dizzy:     tail = NyoGeo.tailPuff; tailW = 12; tL = -0.45; tR = 0.18
        }
        // A quick twitch of one ear now and then, outwards and back.
        if now > nyo.nextTwitch {
            if [.idle, .working, .thinking, .finished, .searching].contains(state) {
                nyo.twitchSide = Bool.random() ? 1 : -1
                nyo.twitchStart = now
            }
            nyo.nextTwitch = now + 4 + Double.random(in: 0...5)
        }
        let tw = now - nyo.twitchStart
        if tw < 0.32 {
            let a = CGFloat(sin(min(1, tw / 0.32) * .pi)) * 0.28
            if nyo.twitchSide < 0 { tL -= a } else { tR += a }
        }
        nyo.earL += (tL - nyo.earL) * min(1, k * 2.2)
        nyo.earR += (tR - nyo.earR) * min(1, k * 2.2)
        nyo.earUp += (up - nyo.earUp) * k
        for i in nyo.tail.indices { nyo.tail[i] += (tail[i] - nyo.tail[i]) * k }
        nyo.tailW += (tailW - nyo.tailW) * k
    }

    /// The slow, contented cat blink.
    func slowBlink() {
        guard !locks.contains("open") else { return }
        anim("open", keys: [
            TweenKey(target: 0.06, duration: 260, ease: Ease.inOut),
            TweenKey(target: 0.06, duration: 220, ease: Ease.lin),
            TweenKey(target: 1,    duration: 340, ease: Ease.out),
        ])
    }

    /// Nyo's little pounce where Mochi rolled.
    func nyoPounce() {
        guard !locks.contains("oy") else { return }
        anim("oy", keys: [
            TweenKey(target: 0.06,  duration: 140, ease: Ease.out),
            TweenKey(target: -0.26, duration: 150, ease: Ease.out),
            TweenKey(target: 0,     duration: 220, ease: Ease.back),
        ]) { [weak self] in self?.squash() }
        nyo.twitchSide = 1
        nyo.twitchStart = CACurrentMediaTime()
    }

    // MARK: Shapes

    /// Design units → body space (before the engine's own squash and tilt).
    private func nyoMap(_ rx: CGFloat, _ ry: CGFloat) -> (CGFloat, CGFloat) -> CGPoint {
        { x, y in
            CGPoint(x: (x - NyoGeo.centre.x) / NyoGeo.halfW * rx,
                    y: (y - NyoGeo.centre.y) / NyoGeo.halfH * ry)
        }
    }

    func nyoHeadPath(rx: CGFloat, ry: CGFloat, morph: CGFloat, R: CGFloat) -> Path {
        var p = Path()
        for (i, u) in NyoGeo.headUnit.enumerated() {
            var pt = CGPoint(x: u.x * rx, y: u.y * ry)
            if morph > 0.005 {
                let a = atan2(pt.y, pt.x)
                let box = rrPoint(ca: cos(a), sa: sin(a), W: R * 1.0, H: R * 0.94, cr: R * 0.42)
                pt = CGPoint(x: lerp(pt.x, box.x, morph), y: lerp(pt.y, box.y, morph))
            }
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    private func nyoEarPaths(sd: CGFloat, rx: CGFloat, ry: CGFloat) -> (outer: Path, inner: Path, tuft: Path) {
        let lift = 1 - morph   // the ears fold down when Nyo becomes the file box
        let rot = sd < 0 ? nyo.earL : nyo.earR
        let pivot = CGPoint(x: sd < 0 ? NyoGeo.earPivot.x : 120 - NyoGeo.earPivot.x, y: NyoGeo.earPivot.y)
        let shift = sin(yaw) * rx * 0.35   // the ears turn a little with the head
        let map = nyoMap(rx, ry)
        let c = cos(rot), s = sin(rot)
        let f: (CGFloat, CGFloat) -> CGPoint = { x, y in
            let dx = x - pivot.x, dy = (y - pivot.y) * lift * self.nyo.earUp
            let p = map(pivot.x + dx * c - dy * s, pivot.y + dx * s + dy * c)
            return CGPoint(x: p.x + shift, y: p.y)
        }
        let pick: ([NyoGeo.Cmd]) -> [NyoGeo.Cmd] = { sd < 0 ? $0 : NyoGeo.mirrored($0) }
        return (NyoGeo.build(pick(NyoGeo.earOuter), f),
                NyoGeo.build(pick(NyoGeo.earInner), f),
                NyoGeo.build(pick(NyoGeo.earTuft), f))
    }

    private func nyoTailPath(rx: CGFloat, ry: CGFloat) -> Path {
        // Swish: the whole tail turns about its base, at a pace that says how he feels.
        let (speed, amp): (Double, CGFloat) = {
            switch state {
            case .working:   return (5.0, 0.10)
            case .thinking:  return (1.2, 0.06)
            case .searching: return (4.0, 0.12)
            case .approval:  return (7.0, 0.07)
            case .question:  return (2.2, 0.08)
            case .error:     return (11, 0.04)
            case .finished:  return (3.0, 0.14)
            case .ratelimit: return (1.0, 0.04)
            case .sleeping:  return (0.6, 0.02)
            case .dizzy:     return (8.0, 0.10)
            case .idle:      return (1.7, 0.10)
            }
        }()
        let a = CGFloat(sin((CACurrentMediaTime() - t0) * speed)) * amp
        let p = nyo.tail
        let bx = p[0], by = p[1]
        let c = cos(a), s = sin(a)
        let map = nyoMap(rx, ry)
        // Smaller than the sheet and tucked in a little, so the tip stays inside the canvas.
        return NyoGeo.build(NyoGeo.tailCmds(p)) { x, y in
            let dx = (x - bx) * 0.72, dy = (y - by) * 0.72
            return map(bx - 4 + dx * c - dy * s, by + dx * s + dy * c)
        }
    }

    // MARK: Drawing

    /// Behind the head: the tail, the ears, and the cream sticker edge around them.
    func drawNyoBack(ctx: GraphicsContext, bodyPath: Path, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        let u = rx / NyoGeo.halfW                  // one design unit
        let line = max(1, 3.5 * u)
        let edgeW = max(2, R * 0.16)
        let furColor: Color = bodyColor.map { Color(cgColor: $0) } ?? NyoStyle.fur
        let earsVisible = morph < 0.98
        let tailAlpha = Double(max(0, 1 - morph * 2.5))
        let ears: [(outer: Path, inner: Path, tuft: Path)] = earsVisible
            ? [nyoEarPaths(sd: -1, rx: rx, ry: ry), nyoEarPaths(sd: 1, rx: rx, ry: ry)] : []
        let tail: Path? = (nyoSticker && tailAlpha > 0.01 && R > 9) ? nyoTailPath(rx: rx, ry: ry) : nil
        let tailW = nyo.tailW * u

        if nyoSticker {
            // A cream rim around everything, so Nyo reads on the black notch.
            if let tail {
                ctx.stroke(tail, with: .color(NyoStyle.cream.opacity(tailAlpha)),
                           style: StrokeStyle(lineWidth: tailW + 2 * line + edgeW, lineCap: .round))
            }
            let edge = StrokeStyle(lineWidth: line + edgeW, lineJoin: .round)
            for ear in ears {
                ctx.fill(ear.outer, with: .color(NyoStyle.cream))
                ctx.stroke(ear.outer, with: .color(NyoStyle.cream), style: edge)
            }
            ctx.stroke(bodyPath, with: .color(NyoStyle.cream), style: edge)
        }
        if let tail {
            var t = ctx
            t.opacity = tailAlpha
            t.stroke(tail, with: .color(NyoStyle.ink), style: StrokeStyle(lineWidth: tailW + 2 * line * 0.72, lineCap: .round))
            t.stroke(tail, with: .color(furColor), style: StrokeStyle(lineWidth: tailW, lineCap: .round))
            t.stroke(tail.trimmedPath(from: 0.64, to: 0.80), with: .color(NyoGeo.tangerine),
                     style: StrokeStyle(lineWidth: tailW, lineCap: .butt))
        }
        for ear in ears {
            ctx.fill(ear.outer, with: .color(furColor))
            if nyoSticker {
                ctx.fill(ear.inner, with: .color(NyoStyle.earPink))
                ctx.stroke(ear.outer, with: .color(NyoStyle.ink), style: StrokeStyle(lineWidth: line, lineJoin: .round))
                if R > 14 {
                    ctx.stroke(ear.tuft, with: .color(NyoStyle.ink),
                               style: StrokeStyle(lineWidth: max(0.8, 2.2 * u), lineCap: .round))
                }
            }
        }
    }

    /// Where the face hangs: the middle of the two eyes, which turn and tilt with the head.
    private func nyoFaceAnchor(R: CGFloat, ry: CGFloat) -> (x: CGFloat, y: CGFloat, squash: CGFloat)? {
        let frames = mEyeFrames(MochiH(R: R, yaw: yaw, pitch: pitch))
        guard !frames.isEmpty else { return nil }
        let x = frames.map(\.x).reduce(0, +) / CGFloat(frames.count)
        let y = frames.map(\.y).reduce(0, +) / CGFloat(frames.count) - ry * NyoStyle.eyeLift
        let squash = max(0.35, frames.map(\.fy).reduce(0, +) / CGFloat(frames.count))
        return (x, y, squash)
    }

    /// Under the eyes: the cream muzzle and the three tangerine forehead stripes.
    func drawNyoMuzzle(ctx: GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        guard nyoSticker, morph < 0.6, R > 9, let a = nyoFaceAnchor(R: R, ry: ry) else { return }
        let fade = Double(1 - morph / 0.6)
        let u = rx / NyoGeo.halfW, v = ry / NyoGeo.halfH * a.squash
        let pt: (CGFloat, CGFloat) -> CGPoint = { x, y in CGPoint(x: a.x + x * u, y: a.y + y * v) }
        var muzzle = Path()
        muzzle.addEllipse(in: CGRect(x: a.x - 16 * u, y: a.y + 6 * v, width: 32 * u, height: 22 * v))
        ctx.fill(muzzle, with: .color(NyoStyle.cream.opacity(fade)))
        var stripes = Path()
        stripes.move(to: pt(-7, -29)); stripes.addLine(to: pt(-5, -21))
        stripes.move(to: pt(0, -31));  stripes.addLine(to: pt(0, -22))
        stripes.move(to: pt(7, -29));  stripes.addLine(to: pt(5, -21))
        ctx.stroke(stripes, with: .color(NyoGeo.tangerine.opacity(fade)),
                   style: StrokeStyle(lineWidth: max(1, 3.4 * u), lineCap: .round))
    }

    /// Over the eyes: nose, mouth and whiskers.
    func drawNyoFace(ctx: GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        guard nyoSticker, morph < 0.6, R > 9, let a = nyoFaceAnchor(R: R, ry: ry) else { return }
        let fade = Double(1 - morph / 0.6)
        let ink = NyoStyle.ink.opacity(fade)
        let u = rx / NyoGeo.halfW, v = ry / NyoGeo.halfH * a.squash
        let pt: (CGFloat, CGFloat) -> CGPoint = { x, y in CGPoint(x: a.x + x * u, y: a.y + y * v) }

        var nose = Path()
        nose.move(to: pt(-4, 11)); nose.addLine(to: pt(4, 11)); nose.addLine(to: pt(0, 15.5)); nose.closeSubpath()
        ctx.fill(nose, with: .color(NyoStyle.nose.opacity(fade)))
        ctx.stroke(nose, with: .color(ink), style: StrokeStyle(lineWidth: max(0.7, 1.6 * u), lineJoin: .round))

        let mouthLine = StrokeStyle(lineWidth: max(0.8, 2 * u), lineCap: .round, lineJoin: .round)
        switch nyoMouth {
        case .o:
            var o = Path()
            o.addEllipse(in: CGRect(x: a.x - 2.6 * u, y: a.y + 17.8 * v, width: 5.2 * u, height: 6.4 * v))
            ctx.fill(o, with: .color(ink))
        case .flat:
            var m = Path()
            m.move(to: pt(-5, 20)); m.addQuadCurve(to: pt(5, 20), control: pt(0, 18))
            ctx.stroke(m, with: .color(ink), style: mouthLine)
        case .open:
            var m = Path()
            m.move(to: pt(-6, 17.5)); m.addQuadCurve(to: pt(6, 17.5), control: pt(0, 26)); m.closeSubpath()
            ctx.fill(m, with: .color(NyoStyle.nose.opacity(fade)))
            ctx.stroke(m, with: .color(ink), style: mouthLine)
        case .w:
            var m = Path()
            m.move(to: pt(0, 15.5)); m.addQuadCurve(to: pt(-7, 18.5), control: pt(-3, 21))
            m.move(to: pt(0, 15.5)); m.addQuadCurve(to: pt(7, 18.5), control: pt(3, 21))
            ctx.stroke(m, with: .color(ink), style: mouthLine)
        }

        guard R > 14 else { return }
        var whiskers = Path()
        for sd: CGFloat in [-1, 1] {
            whiskers.move(to: pt(sd * 14, 16)); whiskers.addLine(to: pt(sd * 30, 14))
            whiskers.move(to: pt(sd * 14, 20)); whiskers.addLine(to: pt(sd * 29, 23))
        }
        ctx.stroke(whiskers, with: .color(ink), style: StrokeStyle(lineWidth: max(0.7, 1.6 * u), lineCap: .round))
    }

    enum NyoMouth { case w, o, flat, open }

    var nyoMouth: NyoMouth {
        if let e = eyeOverride, e == .heart || e == .star || e == .happy { return .open }
        switch state {
        case .approval: return .o
        case .finished: return .open
        case .thinking, .error, .ratelimit, .dizzy: return .flat
        default: return .w
        }
    }

    /// Front paws over the bottom edge; they knead while he works.
    func drawNyoPaws(ctx: GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        guard nyoSticker, morph < 0.5, R > 9 else { return }
        let alpha = Double(1 - morph * 2)
        let u = rx / NyoGeo.halfW, v = ry / NyoGeo.halfH
        let line = max(1, 3 * u)
        let t = CACurrentMediaTime() - t0
        let now = CACurrentMediaTime()
        let rightBusy = (now >= waveStart && waveStart > 0 && now < waveUntil) || listenHandRaise > 0.3
        let kneading = state == .working
        var c = ctx
        c.opacity = alpha
        for (i, sd) in [CGFloat(-1), 1].enumerated() {
            if sd > 0 && rightBusy { continue }   // that paw is up, waving or listening
            let lift: CGFloat = kneading ? max(0, CGFloat(sin(t * 7 + Double(i) * .pi))) * 5 : 0
            let cx = sd * 14 * u
            let cy = (37 - lift) * v
            let rect = CGRect(x: cx - 9 * u, y: cy - 6 * v, width: 18 * u, height: 12 * v)
            let paw = Path(ellipseIn: rect)
            c.stroke(paw, with: .color(NyoStyle.cream), style: StrokeStyle(lineWidth: line + max(2, R * 0.16)))
            c.fill(paw, with: .color(bodyColor.map { Color(cgColor: $0) } ?? NyoStyle.fur))
            c.stroke(paw, with: .color(NyoStyle.ink), style: StrokeStyle(lineWidth: line))
            if R > 14 {
                var toes = Path()
                toes.move(to: CGPoint(x: cx - 3 * u, y: cy + 1 * v)); toes.addLine(to: CGPoint(x: cx - 3 * u, y: cy + 4 * v))
                toes.move(to: CGPoint(x: cx + 3 * u, y: cy + 1 * v)); toes.addLine(to: CGPoint(x: cx + 3 * u, y: cy + 4 * v))
                c.stroke(toes, with: .color(NyoStyle.ink), style: StrokeStyle(lineWidth: max(0.7, 1.6 * u), lineCap: .round))
            }
        }
    }

    /// One cat eye, centred on the context's origin. r is the iris radius.
    func drawNyoEye(ctx: inout GraphicsContext, shape: EyeShape, r: CGFloat, open: CGFloat, sd: CGFloat) {
        let ink = NyoStyle.ink
        let line = max(0.8, r * 0.3)
        // Where the pupil points: with the head, a little further.
        let look = CGPoint(x: sin(yaw) * r * 0.35, y: -sin(pitch) * r * 0.35)

        func arc(up: Bool) {
            var p = Path()
            if up {
                p.move(to: CGPoint(x: -r * 0.78, y: r * 0.22))
                p.addQuadCurve(to: CGPoint(x: r * 0.78, y: r * 0.22), control: CGPoint(x: 0, y: -r * 0.78))
            } else {
                p.move(to: CGPoint(x: -r * 0.78, y: -r * 0.1))
                p.addQuadCurve(to: CGPoint(x: r * 0.78, y: -r * 0.1), control: CGPoint(x: 0, y: r * 0.68))
            }
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: max(1, r * 0.4), lineCap: .round))
        }

        /// The open eye: mint iris, a pupil, a glint; `lid` closes it from the top.
        func iris(scale: CGFloat = 1, pupil: CGSize, lid: CGFloat = 0) {
            let rr = r * scale
            let o = max(0.06, open)
            if o < 0.28 { arc(up: false); return }   // shut for the blink
            let shape = Path(ellipseIn: CGRect(x: -rr, y: -rr * o, width: rr * 2, height: rr * 2 * o))
            ctx.fill(shape, with: .color(NyoGeo.mint))
            var inner = ctx
            inner.clip(to: shape)
            let pc = CGPoint(x: look.x, y: look.y * o)
            inner.fill(Path(ellipseIn: CGRect(x: pc.x - pupil.width, y: pc.y - pupil.height * o,
                                               width: pupil.width * 2, height: pupil.height * 2 * o)),
                       with: .color(ink))
            if pupil.width > r * 0.2 {
                inner.fill(Path(ellipseIn: CGRect(x: pc.x + rr * 0.29 - rr * 0.22, y: pc.y - rr * 0.36 * o - rr * 0.22,
                                                   width: rr * 0.44, height: rr * 0.44)),
                           with: .color(.white))
            }
            if lid > 0 {
                inner.fill(Path(CGRect(x: -rr * 1.2, y: -rr * 1.2, width: rr * 2.4, height: rr * 1.2 + (-rr + lid * 2 * rr) * o)),
                           with: .color(bodyColor.map { Color(cgColor: $0) } ?? NyoStyle.fur))
                var lidLine = Path()
                lidLine.move(to: CGPoint(x: -rr, y: (-rr + lid * 2 * rr) * o))
                lidLine.addLine(to: CGPoint(x: rr, y: (-rr + lid * 2 * rr) * o))
                inner.stroke(lidLine, with: .color(ink), style: StrokeStyle(lineWidth: line))
            }
            ctx.stroke(shape, with: .color(ink), style: StrokeStyle(lineWidth: line))
        }

        switch shape {
        case .pill:
            let slit = state == .working || state == .searching
            iris(pupil: slit ? CGSize(width: r * 0.21, height: r * 0.74) : CGSize(width: r * 0.37, height: r * 0.71))
        case .wide:
            iris(scale: 1.1, pupil: CGSize(width: r * 0.66, height: r * 0.66))
        case .dot:
            iris(pupil: CGSize(width: r * 0.29, height: r * 0.29))
        case .flat:
            iris(pupil: CGSize(width: r * 0.29, height: r * 0.29), lid: 0.32)
        case .tired:
            iris(pupil: CGSize(width: r * 0.37, height: r * 0.6), lid: 0.5)
        case .happy:
            arc(up: true)
        case .closed:
            arc(up: false)
        case .line:
            // Squeezed shut, > <
            var p = Path()
            let k = -sd
            p.move(to: CGPoint(x: -k * r * 0.7, y: -r * 0.5))
            p.addLine(to: CGPoint(x: k * r * 0.5, y: 0))
            p.addLine(to: CGPoint(x: -k * r * 0.7, y: r * 0.5))
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: max(1, r * 0.36), lineCap: .round, lineJoin: .round))
        case .wink:
            if sd < 0 { iris(pupil: CGSize(width: r * 0.37, height: r * 0.71)) } else { arc(up: true) }
        case .spiral, .heart, .star, .cup:
            break   // drawn by the shared shapes (BotEngine.drawEyeShape)
        }
    }
}

// MARK: - Nyo outside the engine (greeting, file drop), in Core Graphics, y down

enum NyoStill {
    enum Eye { case open, happy, content }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }
    // NyoStyle's and NyoGeo's colours, as CGColor.
    private static let ink = rgb(43, 29, 18), fur = rgb(255, 226, 188), cream = rgb(255, 246, 233)
    private static let earPink = rgb(255, 143, 177), nose = rgb(255, 111, 145)
    private static let mint = rgb(46, 196, 182), tangerine = rgb(255, 122, 47)

    static func build(_ cmds: [NyoGeo.Cmd], _ f: (CGFloat, CGFloat) -> CGPoint, into p: CGMutablePath = CGMutablePath()) -> CGMutablePath {
        for cmd in cmds {
            switch cmd {
            case let .m(x, y): p.move(to: f(x, y))
            case let .l(x, y): p.addLine(to: f(x, y))
            case let .c(a, b, c, d, e, g): p.addCurve(to: f(e, g), control1: f(a, b), control2: f(c, d))
            case .z: p.closeSubpath()
            }
        }
        return p
    }

    private static func map(_ rx: CGFloat, _ ry: CGFloat) -> (CGFloat, CGFloat) -> CGPoint {
        { x, y in CGPoint(x: (x - NyoGeo.centre.x) / NyoGeo.halfW * rx, y: (y - NyoGeo.centre.y) / NyoGeo.halfH * ry) }
    }

    /// The head, blending into a rounded box of the same width and height as `morph` goes to 1.
    static func headPath(rx: CGFloat, ry: CGFloat, morph: CGFloat = 0) -> CGMutablePath {
        let p = CGMutablePath()
        let cr = rx / 1.14 * 0.42
        for (i, u) in NyoGeo.headUnit.enumerated() {
            var pt = CGPoint(x: u.x * rx, y: u.y * ry)
            if morph > 0.005 {
                let a = atan2(pt.y, pt.x)
                let b = boxPoint(ca: cos(a), sa: sin(a), W: rx, H: ry, cr: cr)
                pt = CGPoint(x: pt.x + (b.x - pt.x) * morph, y: pt.y + (b.y - pt.y) * morph)
            }
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    private static func boxPoint(ca: CGFloat, sa: CGFloat, W: CGFloat, H: CGFloat, cr: CGFloat) -> CGPoint {
        let ax = abs(ca) < 1e-9 ? 1e9 : W / abs(ca)
        let ay = abs(sa) < 1e-9 ? 1e9 : H / abs(sa)
        let t = min(ax, ay)
        var x = ca * t, y = sa * t
        let ccx = (x < 0 ? -1 : 1) * (W - cr), ccy = (y < 0 ? -1 : 1) * (H - cr)
        if abs(x) > W - cr && abs(y) > H - cr {
            let dot = ca * ccx + sa * ccy
            let disc = dot * dot - (ccx * ccx + ccy * ccy - cr * cr)
            if disc >= 0 { let s = dot + sqrt(disc); x = ca * s; y = sa * s }
        }
        return CGPoint(x: x, y: y)
    }

    /// Head and ears as one shape, for tiny silhouettes.
    static func silhouette(rx: CGFloat, ry: CGFloat) -> CGPath {
        let p = headPath(rx: rx, ry: ry)
        _ = build(NyoGeo.earOuter, map(rx, ry), into: p)
        _ = build(NyoGeo.mirrored(NyoGeo.earOuter), map(rx, ry), into: p)
        return p
    }

    /// Draws Nyo centred on the context's origin: ears, head, cheeks, muzzle, stripes, cat eyes, nose,
    /// mouth and whiskers. Returns the head path (callers clip to it).
    @discardableResult
    static func draw(_ ctx: CGContext, rx: CGFloat, ry: CGFloat, morph: CGFloat = 0,
                     lookX: CGFloat = 0, lookY: CGFloat = 0, eye: Eye = .open, open: CGFloat = 1,
                     sticker: Bool = false) -> CGPath {
        let R = rx / 1.14
        let u = rx / NyoGeo.halfW
        let line = max(1, 3.5 * u)
        let head = headPath(rx: rx, ry: ry, morph: morph)
        let yaw = lookX * 0.42, pitch = -lookY * 0.3

        // Ears
        var ears: [(CGPath, CGPath, CGPath)] = []
        if morph < 0.98 {
            let lift = 1 - morph
            let shift = sin(yaw) * rx * 0.35
            let m = map(rx, ry)
            for sd: CGFloat in [-1, 1] {
                let f: (CGFloat, CGFloat) -> CGPoint = { x, y in
                    let p = m(x, NyoGeo.earPivot.y + (y - NyoGeo.earPivot.y) * lift)
                    return CGPoint(x: p.x + shift, y: p.y)
                }
                let pick: ([NyoGeo.Cmd]) -> [NyoGeo.Cmd] = { sd < 0 ? $0 : NyoGeo.mirrored($0) }
                ears.append((build(pick(NyoGeo.earOuter), f), build(pick(NyoGeo.earInner), f), build(pick(NyoGeo.earTuft), f)))
            }
        }
        ctx.saveGState()
        ctx.setLineJoin(.round); ctx.setLineCap(.round)
        if sticker {
            ctx.setStrokeColor(cream); ctx.setFillColor(cream)
            ctx.setLineWidth(line + max(2, R * 0.16))
            for e in ears { ctx.addPath(e.0); ctx.fillPath(); ctx.addPath(e.0); ctx.strokePath() }
            ctx.addPath(head); ctx.strokePath()
        }
        for e in ears {
            ctx.addPath(e.0); ctx.setFillColor(fur); ctx.fillPath()
            ctx.addPath(e.1); ctx.setFillColor(earPink); ctx.fillPath()
            ctx.addPath(e.0); ctx.setStrokeColor(ink); ctx.setLineWidth(line); ctx.strokePath()
            if R > 14 { ctx.addPath(e.2); ctx.setLineWidth(max(0.8, 2.2 * u)); ctx.strokePath() }
        }
        ctx.addPath(head); ctx.setFillColor(fur); ctx.fillPath()
        ctx.addPath(head); ctx.setStrokeColor(ink); ctx.setLineWidth(line); ctx.strokePath()
        ctx.restoreGState()

        guard morph < 0.6 else { return head }
        let fade = 1 - morph / 0.6
        let ep = -0.12 + pitch
        let ax = sin(yaw) * cos(ep) * rx
        let ay = -sin(ep) * ry - ry * NyoStyle.eyeLift
        let squash = max(0.35, cos(ep))
        let v = ry / NyoGeo.halfH * squash
        let pt: (CGFloat, CGFloat) -> CGPoint = { x, y in CGPoint(x: ax + x * u, y: ay + y * v) }

        ctx.saveGState()
        ctx.setAlpha(fade)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        // Cheeks, muzzle, stripes (inside the head)
        ctx.saveGState()
        ctx.addPath(head); ctx.clip()
        ctx.setFillColor(CGColor(red: 1, green: 0.471, blue: 0.588, alpha: 0.5))
        for sd: CGFloat in [-1, 1] {
            ctx.fillEllipse(in: CGRect(x: sd * rx * 0.72 + sin(yaw) * rx * 0.8 - R * 0.17, y: ry * 0.34 - R * 0.1,
                                       width: R * 0.34, height: R * 0.2))
        }
        ctx.restoreGState()
        ctx.setFillColor(cream)
        ctx.fillEllipse(in: CGRect(x: ax - 16 * u, y: ay + 6 * v, width: 32 * u, height: 22 * v))
        let stripes = CGMutablePath()
        stripes.move(to: pt(-7, -29)); stripes.addLine(to: pt(-5, -21))
        stripes.move(to: pt(0, -31));  stripes.addLine(to: pt(0, -22))
        stripes.move(to: pt(7, -29));  stripes.addLine(to: pt(5, -21))
        ctx.addPath(stripes); ctx.setStrokeColor(tangerine); ctx.setLineWidth(max(1, 3.4 * u)); ctx.strokePath()

        // Eyes
        let r = R * 0.25
        for sd: CGFloat in [-1, 1] {
            let eyeYaw = sd * 0.37 + yaw
            guard cos(eyeYaw) > 0.04 else { continue }
            ctx.saveGState()
            ctx.translateBy(x: sin(eyeYaw) * cos(ep) * rx, y: ay)
            ctx.scaleBy(x: max(0.18, cos(eyeYaw)), y: squash)
            switch eye {
            case .happy, .content:
                let p = CGMutablePath()
                if eye == .happy {
                    p.move(to: CGPoint(x: -r * 0.78, y: r * 0.22))
                    p.addQuadCurve(to: CGPoint(x: r * 0.78, y: r * 0.22), control: CGPoint(x: 0, y: -r * 0.78))
                } else {
                    p.move(to: CGPoint(x: -r * 0.78, y: -r * 0.1))
                    p.addQuadCurve(to: CGPoint(x: r * 0.78, y: -r * 0.1), control: CGPoint(x: 0, y: r * 0.68))
                }
                ctx.addPath(p); ctx.setStrokeColor(ink); ctx.setLineWidth(max(1, r * 0.4)); ctx.strokePath()
            case .open:
                let o = max(0.06, open)
                if o < 0.28 {
                    let p = CGMutablePath()
                    p.move(to: CGPoint(x: -r * 0.78, y: -r * 0.1))
                    p.addQuadCurve(to: CGPoint(x: r * 0.78, y: -r * 0.1), control: CGPoint(x: 0, y: r * 0.68))
                    ctx.addPath(p); ctx.setStrokeColor(ink); ctx.setLineWidth(max(1, r * 0.4)); ctx.strokePath()
                } else {
                    let iris = CGPath(ellipseIn: CGRect(x: -r, y: -r * o, width: r * 2, height: r * 2 * o), transform: nil)
                    ctx.addPath(iris); ctx.setFillColor(mint); ctx.fillPath()
                    ctx.saveGState()
                    ctx.addPath(iris); ctx.clip()
                    let pc = CGPoint(x: sin(yaw) * r * 0.35, y: -sin(pitch) * r * 0.35 * o)
                    ctx.setFillColor(ink)
                    ctx.fillEllipse(in: CGRect(x: pc.x - r * 0.37, y: pc.y - r * 0.71 * o, width: r * 0.74, height: r * 1.42 * o))
                    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    ctx.fillEllipse(in: CGRect(x: pc.x + r * 0.07, y: pc.y - r * 0.36 * o - r * 0.22, width: r * 0.44, height: r * 0.44))
                    ctx.restoreGState()
                    ctx.addPath(iris); ctx.setStrokeColor(ink); ctx.setLineWidth(max(0.8, r * 0.3)); ctx.strokePath()
                }
            }
            ctx.restoreGState()
        }

        // Nose, mouth, whiskers
        let nose = CGMutablePath()
        nose.move(to: pt(-4, 11)); nose.addLine(to: pt(4, 11)); nose.addLine(to: pt(0, 15.5)); nose.closeSubpath()
        ctx.addPath(nose); ctx.setFillColor(NyoStill.nose); ctx.fillPath()
        ctx.addPath(nose); ctx.setStrokeColor(ink); ctx.setLineWidth(max(0.7, 1.6 * u)); ctx.strokePath()
        let mouth = CGMutablePath()
        mouth.move(to: pt(0, 15.5)); mouth.addQuadCurve(to: pt(-7, 18.5), control: pt(-3, 21))
        mouth.move(to: pt(0, 15.5)); mouth.addQuadCurve(to: pt(7, 18.5), control: pt(3, 21))
        ctx.addPath(mouth); ctx.setLineWidth(max(0.8, 2 * u)); ctx.strokePath()
        if R > 14 {
            let w = CGMutablePath()
            for sd: CGFloat in [-1, 1] {
                w.move(to: pt(sd * 14, 16)); w.addLine(to: pt(sd * 30, 14))
                w.move(to: pt(sd * 14, 20)); w.addLine(to: pt(sd * 29, 23))
            }
            ctx.addPath(w); ctx.setLineWidth(max(0.7, 1.6 * u)); ctx.strokePath()
        }
        ctx.restoreGState()
        return head
    }
}
