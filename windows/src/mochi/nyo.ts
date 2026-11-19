/**
 * Nyo, Nyeko's cat — the same drawing as the Mac (NotchBuddy/Sources/CoucouKit/NyoPainter.swift)
 * and Android (android/.../nyeko/NyoGeo.kt): change one, change all three.
 *
 * Drawn in "design units" of the 120-unit character sheet: the head's centre is (60, 65), 38 units to
 * each side and 35 up and down, mapped onto the engine's rx and ry.
 * © 2026 Rohil Sagar — Nyo's look is Nyeko's own (LICENSE-ASSETS.md).
 */
import type { BotStateName } from "../core/layout";
import type { EyeShape, RGB } from "./engine";

export const NyoColors = {
  fur: "rgb(255,226,188)", // #FFE2BC
  ink: "rgb(43,29,18)", // #2B1D12
  cream: "rgb(255,246,233)", // #FFF6E9
  earPink: "rgb(255,143,177)", // #FF8FB1
  nose: "rgb(255,111,145)", // #FF6F91
  mint: "rgb(46,196,182)", // #2EC4B6
  tangerine: "rgb(255,122,47)", // #FF7A2F
};

/** Nyo's eyes sit higher than Mochi's, above the muzzle (fraction of ry). */
export const NYO_EYE_LIFT = 0.12;

type Cmd = ["M" | "L", number, number] | ["C", number, number, number, number, number, number] | ["Z"];

const CX = 60, CY = 65, HW = 38, HH = 35;

const HEAD: Cmd[] = [
  ["M", 60, 30], ["C", 76, 30, 88, 36, 94, 48], ["C", 98, 56, 99, 63, 98, 69],
  ["L", 105, 73], ["L", 97, 77], ["L", 102, 83], ["L", 93, 85],
  ["C", 86, 95, 74, 100, 60, 100], ["C", 46, 100, 34, 95, 27, 85],
  ["L", 18, 83], ["L", 23, 77], ["L", 15, 73], ["L", 22, 69],
  ["C", 21, 63, 22, 56, 26, 48], ["C", 32, 36, 44, 30, 60, 30], ["Z"],
];
const EAR_OUTER: Cmd[] = [["M", 31, 50], ["C", 28, 36, 29, 24, 33, 14], ["C", 42, 19, 50, 27, 55, 37], ["Z"]];
const EAR_INNER: Cmd[] = [["M", 35, 42], ["C", 34, 33, 35, 27, 37, 22], ["C", 42, 26, 46, 31, 48, 36], ["Z"]];
const EAR_TUFT: Cmd[] = [["M", 33, 15], ["L", 30, 8], ["M", 33, 15], ["L", 36, 9]];
const EAR_PIVOT = { x: 40, y: 44 };

export const TAIL = {
  rest: [86, 96, 104, 98, 114, 88, 112, 74, 111, 66, 104, 64, 102, 70],
  up: [88, 92, 106, 88, 112, 70, 106, 52, 103, 44, 96, 42, 96, 50],
  puff: [86, 94, 106, 96, 116, 82, 112, 64, 110, 54, 102, 50, 100, 58],
  wrap: [84, 98, 70, 108, 46, 108, 34, 100, 30, 97, 32, 92, 37, 94],
  curl: [88, 92, 108, 90, 114, 70, 104, 58, 99, 52, 93, 56, 96, 62],
};

function mirrored(cmds: Cmd[]): Cmd[] {
  return cmds.map((c): Cmd => {
    if (c[0] === "Z") return c;
    if (c[0] === "C") return ["C", 120 - c[1], c[2], 120 - c[3], c[4], 120 - c[5], c[6]];
    return [c[0], 120 - c[1], c[2]];
  });
}

type Pt = { x: number; y: number };

function build(cmds: Cmd[], f: (x: number, y: number) => Pt, p = new Path2D()): Path2D {
  for (const c of cmds) {
    if (c[0] === "M") { const q = f(c[1], c[2]); p.moveTo(q.x, q.y); }
    else if (c[0] === "L") { const q = f(c[1], c[2]); p.lineTo(q.x, q.y); }
    else if (c[0] === "C") {
      const a = f(c[1], c[2]), b = f(c[3], c[4]), e = f(c[5], c[6]);
      p.bezierCurveTo(a.x, a.y, b.x, b.y, e.x, e.y);
    } else p.closePath();
  }
  return p;
}

/** The head outline around its centre, in units of (HW, HH), for the file-box morph. */
export const HEAD_UNIT: Pt[] = (() => {
  const out: Pt[] = [];
  let cur = { x: 0, y: 0 };
  const unit = (x: number, y: number) => ({ x: (x - CX) / HW, y: (y - CY) / HH });
  for (const c of HEAD) {
    if (c[0] === "M" || c[0] === "L") { cur = { x: c[1], y: c[2] }; out.push(unit(c[1], c[2])); }
    else if (c[0] === "C") {
      for (let i = 1; i <= 10; i++) {
        const t = i / 10, s = 1 - t;
        out.push(unit(
          s * s * s * cur.x + 3 * s * s * t * c[1] + 3 * s * t * t * c[3] + t * t * t * c[5],
          s * s * s * cur.y + 3 * s * s * t * c[2] + 3 * s * t * t * c[4] + t * t * t * c[6],
        ));
      }
      cur = { x: c[5], y: c[6] };
    }
  }
  return out;
})();

/** What Nyo's ears and tail are doing, eased every frame. */
export class NyoPose {
  earL = 0; // radians; negative turns the left ear out and down
  earR = 0;
  earUp = 1;
  tail = [...TAIL.rest];
  tailW = 9;
  private twitchSide = 1;
  private twitchStart = -10;
  private nextTwitch = performance.now() / 1000 + 3 + Math.random() * 4;

  twitch(side = 1) {
    this.twitchSide = side;
    this.twitchStart = performance.now() / 1000;
  }

  update(dt: number, state: BotStateName, n: number) {
    const k = 1 - Math.pow(0.0005, dt);
    let tL = 0, tR = 0, up = 1, tail = TAIL.rest, tailW = 9;
    switch (state) {
      case "working": tail = TAIL.up; tL = -0.05; tR = 0.05; break;
      case "thinking": tL = -0.18; tR = 0.07; break;
      case "searching": tail = TAIL.up; tL = 0.08; tR = -0.08; break;
      case "approval": tail = TAIL.up; up = 1.1; break;
      case "question": tail = TAIL.curl; tR = 0.25; break;
      case "error": tail = TAIL.puff; tailW = 13; tL = -0.66; tR = 0.66; break;
      case "finished": tail = TAIL.curl; break;
      case "ratelimit": tail = TAIL.wrap; tL = -0.35; tR = 0.35; break;
      case "sleeping": tail = TAIL.wrap; tL = -0.2; tR = 0.2; break;
      case "dizzy": tail = TAIL.puff; tailW = 12; tL = -0.45; tR = 0.18; break;
      default: break;
    }
    if (n > this.nextTwitch) {
      if (["idle", "working", "thinking", "finished", "searching"].includes(state)) {
        this.twitchSide = Math.random() < 0.5 ? -1 : 1;
        this.twitchStart = n;
      }
      this.nextTwitch = n + 4 + Math.random() * 5;
    }
    const tw = n - this.twitchStart;
    if (tw >= 0 && tw < 0.32) {
      const a = Math.sin(Math.min(1, tw / 0.32) * Math.PI) * 0.28;
      if (this.twitchSide < 0) tL -= a; else tR += a;
    }
    const ke = Math.min(1, k * 2.2);
    this.earL += (tL - this.earL) * ke;
    this.earR += (tR - this.earR) * ke;
    this.earUp += (up - this.earUp) * k;
    for (let i = 0; i < this.tail.length; i++) this.tail[i] += (tail[i] - this.tail[i]) * k;
    this.tailW += (tailW - this.tailW) * k;
  }
}

/** What the painter needs from the engine. */
export interface NyoHost {
  state: BotStateName;
  yaw: number;
  pitch: number;
  morph: number;
  open: number;
  bodyColor: RGB | null;
  nyoSticker: boolean;
  /** Seconds, with this engine's own phase. */
  clock: number;
  /** The right paw is up (waving). */
  rightPawBusy: boolean;
  eyeOverride: EyeShape | null;
  pose: NyoPose;
}

const rgb = (c: RGB) => `rgb(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)})`;
const furOf = (e: NyoHost) => (e.bodyColor ? rgb(e.bodyColor) : NyoColors.fur);

const mapper = (rx: number, ry: number) => (x: number, y: number): Pt => ({
  x: ((x - CX) / HW) * rx,
  y: ((y - CY) / HH) * ry,
});

export function nyoHeadPath(
  rx: number, ry: number, R: number, morph: number,
  rrPoint: (ca: number, sa: number, W: number, H: number, cr: number) => Pt,
): Path2D {
  const p = new Path2D();
  HEAD_UNIT.forEach((u, i) => {
    let x = u.x * rx, y = u.y * ry;
    if (morph > 0.005) {
      const a = Math.atan2(y, x);
      const b = rrPoint(Math.cos(a), Math.sin(a), R, R * 0.94, R * 0.42);
      x += (b.x - x) * morph;
      y += (b.y - y) * morph;
    }
    if (i === 0) p.moveTo(x, y); else p.lineTo(x, y);
  });
  p.closePath();
  return p;
}

function earPaths(e: NyoHost, sd: number, rx: number, ry: number) {
  const lift = 1 - e.morph;
  const rot = sd < 0 ? e.pose.earL : e.pose.earR;
  const pivot = { x: sd < 0 ? EAR_PIVOT.x : 120 - EAR_PIVOT.x, y: EAR_PIVOT.y };
  const shift = Math.sin(e.yaw) * rx * 0.35;
  const map = mapper(rx, ry);
  const c = Math.cos(rot), s = Math.sin(rot);
  const f = (x: number, y: number) => {
    const dx = x - pivot.x, dy = (y - pivot.y) * lift * e.pose.earUp;
    const q = map(pivot.x + dx * c - dy * s, pivot.y + dx * s + dy * c);
    return { x: q.x + shift, y: q.y };
  };
  const pick = (cmds: Cmd[]) => (sd < 0 ? cmds : mirrored(cmds));
  return { outer: build(pick(EAR_OUTER), f), inner: build(pick(EAR_INNER), f), tuft: build(pick(EAR_TUFT), f) };
}

function swish(state: BotStateName): [number, number] {
  switch (state) {
    case "working": return [5.0, 0.1];
    case "thinking": return [1.2, 0.06];
    case "searching": return [4.0, 0.12];
    case "approval": return [7.0, 0.07];
    case "question": return [2.2, 0.08];
    case "error": return [11, 0.04];
    case "finished": return [3.0, 0.14];
    case "ratelimit": return [1.0, 0.04];
    case "sleeping": return [0.6, 0.02];
    case "dizzy": return [8.0, 0.1];
    default: return [1.7, 0.1];
  }
}

/** The tail as points along it, for the band near the tip and the round stroke. */
function tailPath(e: NyoHost, rx: number, ry: number, from = 0, to = 1): Path2D {
  const [speed, amp] = swish(e.state);
  const a = Math.sin(e.clock * speed) * amp;
  const p = e.pose.tail;
  const bx = p[0], by = p[1];
  const c = Math.cos(a), s = Math.sin(a);
  const map = mapper(rx, ry);
  const f = (x: number, y: number) => {
    // Smaller than the sheet and tucked in a little, so the tip stays inside the canvas.
    const dx = (x - bx) * 0.72, dy = (y - by) * 0.72;
    return map(bx - 4 + dx * c - dy * s, by + dx * s + dy * c);
  };
  if (from === 0 && to === 1) {
    return build([["M", p[0], p[1]], ["C", p[2], p[3], p[4], p[5], p[6], p[7]], ["C", p[8], p[9], p[10], p[11], p[12], p[13]]], f);
  }
  // A stretch of the tail (by parameter, across both curves).
  const out = new Path2D();
  const segs = [p.slice(0, 8), [p[6], p[7], ...p.slice(8, 14)]];
  const steps = 24;
  for (let i = 0; i <= steps; i++) {
    const g = from + ((to - from) * i) / steps;
    const si = g < 0.5 ? 0 : 1;
    const t = si === 0 ? g * 2 : (g - 0.5) * 2;
    const q = segs[si], u = 1 - t;
    const x = u * u * u * q[0] + 3 * u * u * t * q[2] + 3 * u * t * t * q[4] + t * t * t * q[6];
    const y = u * u * u * q[1] + 3 * u * u * t * q[3] + 3 * u * t * t * q[5] + t * t * t * q[7];
    const m = f(x, y);
    if (i === 0) out.moveTo(m.x, m.y); else out.lineTo(m.x, m.y);
  }
  return out;
}

/** Behind the head: the tail, the ears, and the cream sticker edge around them. */
export function drawNyoBack(x: CanvasRenderingContext2D, e: NyoHost, body: Path2D, R: number, rx: number, ry: number) {
  const u = rx / HW;
  const line = Math.max(1, 3.5 * u);
  const edgeW = Math.max(2, R * 0.16);
  const ears = e.morph < 0.98 ? [earPaths(e, -1, rx, ry), earPaths(e, 1, rx, ry)] : [];
  const tailAlpha = Math.max(0, 1 - e.morph * 2.5);
  const showTail = e.nyoSticker && tailAlpha > 0.01 && R > 9;
  const tail = showTail ? tailPath(e, rx, ry) : null;
  const tailW = e.pose.tailW * u;
  x.save();
  x.lineJoin = "round";
  x.lineCap = "round";
  if (e.nyoSticker) {
    x.strokeStyle = NyoColors.cream;
    x.fillStyle = NyoColors.cream;
    if (tail) {
      x.globalAlpha = tailAlpha;
      x.lineWidth = tailW + 2 * line + edgeW;
      x.stroke(tail);
      x.globalAlpha = 1;
    }
    x.lineWidth = line + edgeW;
    for (const ear of ears) { x.fill(ear.outer); x.stroke(ear.outer); }
    x.stroke(body);
  }
  if (tail) {
    x.globalAlpha = tailAlpha;
    x.strokeStyle = NyoColors.ink;
    x.lineWidth = tailW + 2 * line * 0.72;
    x.stroke(tail);
    x.strokeStyle = furOf(e);
    x.lineWidth = tailW;
    x.stroke(tail);
    x.strokeStyle = NyoColors.tangerine;
    x.lineCap = "butt";
    x.stroke(tailPath(e, rx, ry, 0.64, 0.8));
    x.lineCap = "round";
    x.globalAlpha = 1;
  }
  for (const ear of ears) {
    x.fillStyle = furOf(e);
    x.fill(ear.outer);
    if (e.nyoSticker) {
      x.fillStyle = NyoColors.earPink;
      x.fill(ear.inner);
      x.strokeStyle = NyoColors.ink;
      x.lineWidth = line;
      x.stroke(ear.outer);
      if (R > 14) {
        x.lineWidth = Math.max(0.8, 2.2 * u);
        x.stroke(ear.tuft);
      }
    }
  }
  x.restore();
}

/** Where the face hangs: the middle of the eyes as drawEyes places them. */
export type FaceAnchor = { x: number; y: number; squash: number };

export function drawNyoMuzzle(x: CanvasRenderingContext2D, e: NyoHost, a: FaceAnchor | null, R: number, rx: number, ry: number) {
  if (!a || !e.nyoSticker || e.morph >= 0.6 || R <= 9) return;
  const u = rx / HW, v = (ry / HH) * a.squash;
  const pt = (px: number, py: number) => [a.x + px * u, a.y + py * v] as const;
  x.save();
  x.globalAlpha = 1 - e.morph / 0.6;
  x.fillStyle = NyoColors.cream;
  x.beginPath();
  x.ellipse(a.x, a.y + 17 * v, 16 * u, 11 * v, 0, 0, Math.PI * 2);
  x.fill();
  x.strokeStyle = NyoColors.tangerine;
  x.lineCap = "round";
  x.lineWidth = Math.max(1, 3.4 * u);
  x.beginPath();
  for (const [p0, p1] of [[[-7, -29], [-5, -21]], [[0, -31], [0, -22]], [[7, -29], [5, -21]]] as const) {
    x.moveTo(...pt(p0[0], p0[1]));
    x.lineTo(...pt(p1[0], p1[1]));
  }
  x.stroke();
  x.restore();
}

function mouthOf(e: NyoHost): "w" | "o" | "flat" | "open" {
  if (e.eyeOverride === "heart" || e.eyeOverride === "star" || e.eyeOverride === "happy") return "open";
  switch (e.state) {
    case "approval": return "o";
    case "finished": return "open";
    case "thinking": case "error": case "ratelimit": case "dizzy": return "flat";
    default: return "w";
  }
}

export function drawNyoFace(x: CanvasRenderingContext2D, e: NyoHost, a: FaceAnchor | null, R: number, rx: number, ry: number) {
  if (!a || !e.nyoSticker || e.morph >= 0.6 || R <= 9) return;
  const u = rx / HW, v = (ry / HH) * a.squash;
  const pt = (px: number, py: number) => [a.x + px * u, a.y + py * v] as const;
  x.save();
  x.globalAlpha = 1 - e.morph / 0.6;
  x.lineJoin = "round";
  x.lineCap = "round";
  x.strokeStyle = NyoColors.ink;
  x.beginPath();
  x.moveTo(...pt(-4, 11)); x.lineTo(...pt(4, 11)); x.lineTo(...pt(0, 15.5)); x.closePath();
  x.fillStyle = NyoColors.nose;
  x.fill();
  x.lineWidth = Math.max(0.7, 1.6 * u);
  x.stroke();
  x.lineWidth = Math.max(0.8, 2 * u);
  x.beginPath();
  switch (mouthOf(e)) {
    case "o":
      x.ellipse(a.x, a.y + 21 * v, 2.6 * u, 3.2 * v, 0, 0, Math.PI * 2);
      x.fillStyle = NyoColors.ink;
      x.fill();
      break;
    case "flat":
      x.moveTo(...pt(-5, 20)); x.quadraticCurveTo(...pt(0, 18), ...pt(5, 20));
      x.stroke();
      break;
    case "open":
      x.moveTo(...pt(-6, 17.5)); x.quadraticCurveTo(...pt(0, 26), ...pt(6, 17.5)); x.closePath();
      x.fillStyle = NyoColors.nose;
      x.fill();
      x.stroke();
      break;
    default:
      x.moveTo(...pt(0, 15.5)); x.quadraticCurveTo(...pt(-3, 21), ...pt(-7, 18.5));
      x.moveTo(...pt(0, 15.5)); x.quadraticCurveTo(...pt(3, 21), ...pt(7, 18.5));
      x.stroke();
  }
  if (R > 14) {
    x.beginPath();
    for (const sd of [-1, 1]) {
      x.moveTo(...pt(sd * 14, 16)); x.lineTo(...pt(sd * 30, 14));
      x.moveTo(...pt(sd * 14, 20)); x.lineTo(...pt(sd * 29, 23));
    }
    x.lineWidth = Math.max(0.7, 1.6 * u);
    x.stroke();
  }
  x.restore();
}

/** Front paws over the bottom edge; they knead while he works. */
export function drawNyoPaws(x: CanvasRenderingContext2D, e: NyoHost, R: number, rx: number, ry: number) {
  if (!e.nyoSticker || e.morph >= 0.5 || R <= 9) return;
  const u = rx / HW, v = ry / HH;
  const line = Math.max(1, 3 * u);
  x.save();
  x.globalAlpha = 1 - e.morph * 2;
  x.lineCap = "round";
  [-1, 1].forEach((sd, i) => {
    if (sd > 0 && e.rightPawBusy) return;
    const lift = e.state === "working" ? Math.max(0, Math.sin(e.clock * 7 + i * Math.PI)) * 5 : 0;
    const cx = sd * 14 * u, cy = (37 - lift) * v;
    x.beginPath();
    x.ellipse(cx, cy, 9 * u, 6 * v, 0, 0, Math.PI * 2);
    x.strokeStyle = NyoColors.cream;
    x.lineWidth = line + Math.max(2, R * 0.16);
    x.stroke();
    x.fillStyle = furOf(e);
    x.fill();
    x.strokeStyle = NyoColors.ink;
    x.lineWidth = line;
    x.stroke();
    if (R > 14) {
      x.beginPath();
      x.moveTo(cx - 3 * u, cy + v); x.lineTo(cx - 3 * u, cy + 4 * v);
      x.moveTo(cx + 3 * u, cy + v); x.lineTo(cx + 3 * u, cy + 4 * v);
      x.lineWidth = Math.max(0.7, 1.6 * u);
      x.stroke();
    }
  });
  x.restore();
}

/** Toe lines on a raised paw (the waving one), centred on the context's origin. */
export function drawNyoToes(x: CanvasRenderingContext2D, hew: number, heh: number, R: number) {
  x.beginPath();
  x.moveTo(-hew * 0.33, heh * 0.15); x.lineTo(-hew * 0.33, heh * 0.65);
  x.moveTo(hew * 0.33, heh * 0.15); x.lineTo(hew * 0.33, heh * 0.65);
  x.strokeStyle = NyoColors.ink;
  x.lineCap = "round";
  x.lineWidth = Math.max(0.7, R * 0.04);
  x.stroke();
}

/** Shapes the shared eye code draws (BotEngine.drawEyeShape). */
export const SHARED_EYES: ReadonlySet<EyeShape> = new Set<EyeShape>(["spiral", "heart", "star", "cup"]);

/** One cat eye centred on the context's origin; r is the iris radius. */
export function drawNyoEye(x: CanvasRenderingContext2D, e: NyoHost, shape: EyeShape, r: number, sd: number) {
  const ink = NyoColors.ink;
  const line = Math.max(0.8, r * 0.3);
  const look = { x: Math.sin(e.yaw) * r * 0.35, y: -Math.sin(e.pitch) * r * 0.35 };

  const arc = (up: boolean) => {
    x.beginPath();
    if (up) { x.moveTo(-r * 0.78, r * 0.22); x.quadraticCurveTo(0, -r * 0.78, r * 0.78, r * 0.22); }
    else { x.moveTo(-r * 0.78, -r * 0.1); x.quadraticCurveTo(0, r * 0.68, r * 0.78, -r * 0.1); }
    x.strokeStyle = ink;
    x.lineWidth = Math.max(1, r * 0.4);
    x.lineCap = "round";
    x.stroke();
  };

  const iris = (pw: number, ph: number, scale = 1, lid = 0) => {
    const rr = r * scale;
    const o = Math.max(0.06, e.open);
    if (o < 0.28) { arc(false); return; }
    const eye = new Path2D();
    eye.ellipse(0, 0, rr, rr * o, 0, 0, Math.PI * 2);
    x.save();
    x.fillStyle = NyoColors.mint;
    x.fill(eye);
    x.clip(eye);
    const pcx = look.x, pcy = look.y * o;
    x.fillStyle = ink;
    x.beginPath();
    x.ellipse(pcx, pcy, pw, ph * o, 0, 0, Math.PI * 2);
    x.fill();
    if (pw > r * 0.2) {
      x.fillStyle = "#FFFFFF";
      x.beginPath();
      x.arc(pcx + rr * 0.29, pcy - rr * 0.36 * o, rr * 0.22, 0, Math.PI * 2);
      x.fill();
    }
    if (lid > 0) {
      const ly = (-rr + lid * 2 * rr) * o;
      x.fillStyle = furOf(e);
      x.fillRect(-rr * 1.2, -rr * 1.2, rr * 2.4, ly + rr * 1.2);
      x.strokeStyle = ink;
      x.lineWidth = line;
      x.beginPath();
      x.moveTo(-rr, ly); x.lineTo(rr, ly);
      x.stroke();
    }
    x.restore();
    x.strokeStyle = ink;
    x.lineWidth = line;
    x.stroke(eye);
  };

  switch (shape) {
    case "pill": {
      const slit = e.state === "working" || e.state === "searching";
      if (slit) iris(r * 0.21, r * 0.74); else iris(r * 0.37, r * 0.71);
      break;
    }
    case "wide": iris(r * 0.66, r * 0.66, 1.1); break;
    case "dot": iris(r * 0.29, r * 0.29); break;
    case "flat": iris(r * 0.29, r * 0.29, 1, 0.32); break;
    case "tired": iris(r * 0.37, r * 0.6, 1, 0.5); break;
    case "happy": arc(true); break;
    case "closed": arc(false); break;
    case "line": {
      const k = -sd;
      x.beginPath();
      x.moveTo(-k * r * 0.7, -r * 0.5); x.lineTo(k * r * 0.5, 0); x.lineTo(-k * r * 0.7, r * 0.5);
      x.strokeStyle = ink;
      x.lineWidth = Math.max(1, r * 0.36);
      x.lineCap = "round";
      x.lineJoin = "round";
      x.stroke();
      break;
    }
    case "wink":
      if (sd < 0) iris(r * 0.37, r * 0.71); else arc(true);
      break;
    default: break;
  }
}

// ── Nyo outside the engine (greeting, file drop) ───────────────────────────────

export type NyoStillEye = "open" | "happy" | "content" | "closed";

export interface NyoStill {
  rx: number;
  ry: number;
  /** 0 = Nyo, 1 = the file box. */
  morph?: number;
  /** Where he looks, −1…1 each way. */
  lookX?: number;
  lookY?: number;
  eye?: NyoStillEye;
  /** Eye openness for blinks, 0…1. */
  open?: number;
  /** Cream rim around him, for the black notch. */
  sticker?: boolean;
}

/** The head (morphing towards the rounded box) for callers without the engine's rrPoint. */
export function nyoStillHead(rx: number, ry: number, morph = 0): Path2D {
  // The box fills the head's own width and height.
  return nyoHeadPath(rx, ry, rx / 1.14, morph, (ca, sa, _W, _H, cr) => boxPoint(ca, sa, rx, ry, cr));
}

function boxPoint(ca: number, sa: number, W: number, H: number, cr: number): Pt {
  // Ray from the centre to a rounded rectangle of half-size W × H and corner radius cr.
  const ax = Math.abs(ca) < 1e-9 ? 1e9 : W / Math.abs(ca);
  const ay = Math.abs(sa) < 1e-9 ? 1e9 : H / Math.abs(sa);
  const t = Math.min(ax, ay);
  let x = ca * t, y = sa * t;
  const kx = Math.sign(x) || 1, ky = Math.sign(y) || 1;
  const ccx = kx * (W - cr), ccy = ky * (H - cr);
  if (Math.abs(x) > W - cr && Math.abs(y) > H - cr) {
    const dot = ca * ccx + sa * ccy;
    const disc = dot * dot - (ccx * ccx + ccy * ccy - cr * cr);
    if (disc >= 0) { const s = dot + Math.sqrt(disc); x = ca * s; y = sa * s; }
  }
  return { x, y };
}

/**
 * Draws Nyo centred on the context's origin, without the engine: ears, head, muzzle, stripes, cat eyes,
 * nose, mouth and whiskers. Returns the head path (callers clip to it).
 */
export function drawNyoStill(x: CanvasRenderingContext2D, o: NyoStill): Path2D {
  const { rx, ry } = o;
  const morph = o.morph ?? 0;
  const R = rx / 1.14; // the engine's R (rx = 1.14 R)
  const pose = new NyoPose();
  const host: NyoHost = {
    state: "idle", yaw: (o.lookX ?? 0) * 0.42, pitch: -(o.lookY ?? 0) * 0.3, morph, open: o.open ?? 1,
    bodyColor: null, nyoSticker: true, clock: 0, rightPawBusy: true, eyeOverride: null, pose,
  };
  const head = nyoStillHead(rx, ry, morph);
  const u = rx / HW;
  const line = Math.max(1, 3.5 * u);
  // Ears (no tail or paws here: the callers draw their own hands).
  const ears = morph < 0.98 ? [earPaths(host, -1, rx, ry), earPaths(host, 1, rx, ry)] : [];
  x.save();
  x.lineJoin = "round";
  if (o.sticker) {
    x.strokeStyle = NyoColors.cream;
    x.fillStyle = NyoColors.cream;
    x.lineWidth = line + Math.max(2, R * 0.16);
    for (const ear of ears) { x.fill(ear.outer); x.stroke(ear.outer); }
    x.stroke(head);
  }
  for (const ear of ears) {
    x.fillStyle = NyoColors.fur;
    x.fill(ear.outer);
    x.fillStyle = NyoColors.earPink;
    x.fill(ear.inner);
    x.strokeStyle = NyoColors.ink;
    x.lineWidth = line;
    x.stroke(ear.outer);
    if (R > 14) { x.lineWidth = Math.max(0.8, 2.2 * u); x.stroke(ear.tuft); }
  }
  x.fillStyle = NyoColors.fur;
  x.fill(head);
  x.strokeStyle = NyoColors.ink;
  x.lineWidth = line;
  x.stroke(head);
  // Cheeks
  if (morph < 0.6) {
    x.save();
    x.clip(head);
    x.globalAlpha = 0.55 * (1 - morph / 0.6);
    x.fillStyle = "rgb(255,120,150)";
    const shift = Math.sin(host.yaw) * rx * 0.8;
    for (const sd of [-1, 1]) {
      x.beginPath();
      x.ellipse(sd * rx * 0.72 + shift, ry * 0.34, R * 0.17, R * 0.1, 0, 0, Math.PI * 2);
      x.fill();
    }
    x.restore();
  }
  x.restore();

  const anchor: FaceAnchor = {
    x: Math.sin(host.yaw) * Math.cos(-0.12 + host.pitch) * rx,
    y: -Math.sin(-0.12 + host.pitch) * ry - ry * NYO_EYE_LIFT,
    squash: Math.max(0.35, Math.cos(-0.12 + host.pitch)),
  };
  drawNyoMuzzle(x, host, anchor, R, rx, ry);
  if (morph < 0.6) {
    x.save();
    x.clip(head);
    x.globalAlpha = 1 - morph / 0.6;
    const shape: EyeShape = o.eye === "happy" ? "happy" : o.eye === "content" || o.eye === "closed" ? "closed" : "pill";
    for (const sd of [-1, 1]) {
      const eyeYaw = sd * 0.37 + host.yaw;
      if (Math.cos(eyeYaw) <= 0.04) continue;
      x.save();
      x.translate(Math.sin(eyeYaw) * Math.cos(-0.12 + host.pitch) * rx, anchor.y);
      x.scale(Math.max(0.18, Math.cos(eyeYaw)), anchor.squash);
      drawNyoEye(x, host, shape, R * 0.25, sd);
      x.restore();
    }
    x.restore();
  }
  drawNyoFace(x, host, anchor, R, rx, ry);
  return head;
}

/** Nyo's outline (head and ears) as one shape, for tiny silhouettes. */
export function nyoSilhouette(rx: number, ry: number): Path2D {
  const p = nyoStillHead(rx, ry);
  const map = mapper(rx, ry);
  build(EAR_OUTER, map, p);
  build(mirrored(EAR_OUTER), map, p);
  return p;
}
