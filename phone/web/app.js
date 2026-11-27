// Nyeko phone web app. Talks to Nyeko on your computers through your own relay, end to end encrypted (relay.js).
// Several computers can be paired (your Macs, your Windows PC): one encrypted channel each, everything shown together.
// Untrusted text (commands, session lines, Nyo's replies) is only ever set as text, never as HTML.
import { PhoneChannel, b64url, fromB64url, random } from "./relay.js";
import { parseSetup, sendSetup } from "./setup.js";
import { drawNyoStill } from "./nyo.js";

const VERSION = "2026-11-27 · nyeko 12";   // shown in Settings: tells which web app the phone runs
const STORE = { computers: "nyeko.computers", current: "nyeko.current", cred: "nyeko.faceid", alerts: "nyeko.alerts", oldPairing: "nyeko.pairing" };
const APPROVAL_TTL = 115_000; // the computer dismisses a request after 115 s
const app = document.getElementById("app");
const PREVIEW = globalThis.NYEKO_PREVIEW || null;

/** One paired computer: its pairing (kept in this phone's storage) and what it last said (in memory). */
function newComputer(p) {
  return { id: p.room, p, channel: null, status: "closed", desktop: p.name || "Computer", os: "",
    sessions: [], approval: null, question: null, usage: null, mac: null, macAt: 0, apps: null };
}

const state = {
  computers: [],
  current: null,             // the computer the Computer and Nyo tabs and New session talk to (its id)
  chat: [], waiting: new Map(),   // Nyo's chat: { me, text, comp } and the replies awaited (id → computer id)
  launch: null,              // a new session being started: { comp, project, starting: { id, name, at, launched } }
  thread: null,              // the open coding session: { comp, id, title, data, sending: [{ id, text }] }
  tab: "now",
  appSearch: "",
  toast: "",
};
let ticker = null;
let unlockedUntil = 0;       // a message to a session, a new session or a power action asks for Face ID, then not for 10 minutes

// iPhone vs Android: install steps, the name of the lock, and how pairing reaches the installed app differ.
const isIOS = /iPhone|iPad|iPod/.test(navigator.userAgent)
  || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
const lockName = isIOS ? "Face ID" : "fingerprint or screen lock";
// Android (Chrome): the installed app shares this site's storage, and Chrome offers its own install prompt.
let installPrompt = null;
addEventListener("beforeinstallprompt", (e) => { e.preventDefault(); installPrompt = e; render(); });
addEventListener("appinstalled", () => { installPrompt = null; render(); });

// ── storage ──────────────────────────────────────────────────────────────────────────────────────────

function load(key) { try { return JSON.parse(localStorage.getItem(key) || "null"); } catch { return null; } }
function save(key, value) { value == null ? localStorage.removeItem(key) : localStorage.setItem(key, JSON.stringify(value)); }

// ── DOM helper: h("div.card", {onclick}, "text", child…), h("input#ask.wide") ─────────────────────────

function h(spec, attrs, ...children) {
  const [head, ...classes] = spec.split(".");
  const [tag, id] = head.split("#");
  const el = document.createElement(tag || "div");
  if (id) el.id = id;
  if (classes.length) el.className = classes.join(" ");
  if (attrs && (typeof attrs !== "object" || attrs instanceof Node || Array.isArray(attrs))) { children.unshift(attrs); attrs = null; }
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "style") el.style.cssText = v;   // CSSOM: allowed by the page's style-src 'self'
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

// Line icons, drawn for Nyeko (24-unit grid, 2-unit round strokes; the media keys are filled). No icon font, no emoji.
const ICONS = {
  gear: ["M12 9.2a2.8 2.8 0 100 5.6 2.8 2.8 0 000-5.6z", "M19.4 13.5l1.6 1.2-1.9 3.3-1.9-.7a7.5 7.5 0 01-2.1 1.2l-.3 2H11l-.3-2a7.5 7.5 0 01-2.1-1.2l-1.9.7-1.9-3.3 1.6-1.2a7.6 7.6 0 010-2.9L4.8 9.4l1.9-3.3 1.9.7a7.5 7.5 0 012.1-1.2L11 3.5h3.8l.3 2.1a7.5 7.5 0 012.1 1.2l1.9-.7 1.9 3.3-1.6 1.2a7.6 7.6 0 010 2.9z"],
  back: ["M15 5l-7 7 7 7"],
  chevron: ["M9 6l6 6-6 6"],
  down: ["M6 9l6 6 6-6"],
  plus: ["M12 5v14M5 12h14"],
  search: ["M10.5 4a6.5 6.5 0 110 13 6.5 6.5 0 010-13zM15.5 15.5L20 20"],
  send: ["M12 19V6M6 11.5L12 5.5l6 6"],
  now: ["M3 12h4l2.5-6 5 12 2.5-6h4"],
  laptop: ["M5 6.5A1.5 1.5 0 016.5 5h11A1.5 1.5 0 0119 6.5V15H5z", "M2.5 18.5h19"],
  desktop: ["M4 5.5A1.5 1.5 0 015.5 4h13A1.5 1.5 0 0120 5.5v9a1.5 1.5 0 01-1.5 1.5h-13A1.5 1.5 0 014 14.5z", "M9 20h6M12 16v4"],
  cat: ["M5 9.5L4.5 3.5l5 3.2a8 8 0 015 0l5-3.2-.5 6A7.5 7.5 0 0112 20.5 7.5 7.5 0 015 9.5z", "M9.3 12.2v.6M14.7 12.2v.6", "M11 15.5l1 .8 1-.8"],
  terminal: ["M4 6.5A1.5 1.5 0 015.5 5h13A1.5 1.5 0 0120 6.5v11a1.5 1.5 0 01-1.5 1.5h-13A1.5 1.5 0 014 17.5z", "M7.5 9.5l3 2.5-3 2.5M12.5 15h4"],
  volume: ["M4 9.5h3.5L12 5.5v13l-4.5-4H4z", "M15.5 9a4 4 0 010 6M18 6.5a7.5 7.5 0 010 11"],
  mute: ["M4 9.5h3.5L12 5.5v13l-4.5-4H4z", "M16 9.5l5 5M21 9.5l-5 5"],
  lock: ["M6 11h12v9H6z", "M8.5 11V8a3.5 3.5 0 017 0v3"],
  moon: ["M19.5 14.5A7.5 7.5 0 019.5 4.5a7.5 7.5 0 1010 10z"],
  screenOff: ["M4 5.5A1.5 1.5 0 015.5 4h13A1.5 1.5 0 0120 5.5v9a1.5 1.5 0 01-1.5 1.5h-13A1.5 1.5 0 014 14.5z", "M9 20h6", "M9.5 8.5l5 5M14.5 8.5l-5 5"],
  restart: ["M4.5 12a7.5 7.5 0 1 0 2.2-5.3", "M4.5 4.5v4h4"],
  power: ["M12 3.5v8", "M7 6.3a7.5 7.5 0 1010 0"],
  camera: ["M4 8.5A1.5 1.5 0 015.5 7h2.3L9.5 4.5h5L16.2 7h2.3A1.5 1.5 0 0120 8.5v9a1.5 1.5 0 01-1.5 1.5h-13A1.5 1.5 0 014 17.5z", "M12 9.5a3.5 3.5 0 110 7 3.5 3.5 0 010-7z"],
  timer: ["M12 7.5a6.5 6.5 0 110 13 6.5 6.5 0 010-13z", "M12 10.5V14l2 1.5", "M10 3.5h4"],
  mic: ["M12 3.5a2.5 2.5 0 012.5 2.5v5a2.5 2.5 0 01-5 0V6A2.5 2.5 0 0112 3.5z", "M6.5 11a5.5 5.5 0 0011 0M12 16.5v4"],
  calendar: ["M4.5 6.5A1.5 1.5 0 016 5h12a1.5 1.5 0 011.5 1.5v12A1.5 1.5 0 0118 20H6a1.5 1.5 0 01-1.5-1.5z", "M4.5 10h15M8.5 3.5v3M15.5 3.5v3"],
  open: ["M14 4.5h5.5V10", "M19.5 4.5L11 13", "M18 14v4.5a1.5 1.5 0 01-1.5 1.5h-11A1.5 1.5 0 014 18.5v-11A1.5 1.5 0 015.5 6H10"],
  check: ["M5 12.5l4.5 4.5L19 7.5"],
  shield: ["M12 3.5l7 3v5.5c0 4.2-3 7.3-7 8.5-4-1.2-7-4.3-7-8.5V6.5z", "M9 12l2.2 2.2L15.5 10"],
  bell: ["M6.5 16.5V11a5.5 5.5 0 0111 0v5.5l1.5 1.5H5z", "M10 20.5a2.2 2.2 0 004 0"],
  battery: ["M3.5 8.5A1.5 1.5 0 015 7h12a1.5 1.5 0 011.5 1.5v7A1.5 1.5 0 0117 17H5a1.5 1.5 0 01-1.5-1.5z", "M21 10.5v3"],
  folder: ["M3.5 7A1.5 1.5 0 015 5.5h4.2l2 2.2H19A1.5 1.5 0 0120.5 9.2v8.3A1.5 1.5 0 0119 19H5a1.5 1.5 0 01-1.5-1.5z"],
  file: ["M7 3.5h6.5L18 8v11a1.5 1.5 0 01-1.5 1.5h-9.5A1.5 1.5 0 015.5 19V5A1.5 1.5 0 017 3.5z", "M13.5 3.5V8H18", "M8.5 12.5h7M8.5 16h5"],
  image: ["M4 6A1.5 1.5 0 015.5 4.5h13A1.5 1.5 0 0120 6v12a1.5 1.5 0 01-1.5 1.5h-13A1.5 1.5 0 014 18z", "M4.5 16l4.5-4.5 3.5 3.5 2.5-2.5 4.5 4.5", "M15 8.5a1.2 1.2 0 110 2.4 1.2 1.2 0 010-2.4z"],
  up: ["M12 19V6M6 11.5L12 5.5l6 6"],
  keyboard: ["M3.5 7.5A1.5 1.5 0 015 6h14a1.5 1.5 0 011.5 1.5v9A1.5 1.5 0 0119 18H5a1.5 1.5 0 01-1.5-1.5z", "M7 10h.01M10.5 10h.01M14 10h.01M17.5 10h.01M8 14h8"],
  pointer: ["M6 3.5l12 7.5-5.2 1.3 3 5.6-2.4 1.3-3-5.6L6.5 18z"],
  swap: ["M5 8.5h13.5l-3.5-3.5", "M19 15.5H5.5l3.5 3.5"],
  play: ["M8 5.5v13l10.5-6.5z"], pause: ["M7 5h3.5v14H7zM13.5 5H17v14h-3.5z"],
  next: ["M5.5 6l8.5 6-8.5 6zM16 6h2.5v12H16z"], prev: ["M18.5 6L10 12l8.5 6zM5.5 6H8v12H5.5z"],
};
const FILLED = new Set(["play", "pause", "next", "prev"]);

function icon(name, size = 22) {
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 24 24"); svg.setAttribute("width", size); svg.setAttribute("height", size);
  svg.setAttribute("aria-hidden", "true"); svg.setAttribute("class", "ic");
  for (const d of ICONS[name] || []) {
    const p = document.createElementNS(ns, "path");
    p.setAttribute("d", d);
    if (FILLED.has(name)) p.setAttribute("fill", "currentColor");
    else { p.setAttribute("fill", "none"); p.setAttribute("stroke", "currentColor"); p.setAttribute("stroke-width", "2");
      p.setAttribute("stroke-linecap", "round"); p.setAttribute("stroke-linejoin", "round"); }
    svg.append(p);
  }
  return svg;
}

/** Nyo himself, drawn by the same painter as the Mac, Windows and Android (nyo.js, built from windows/src/mochi/nyo.ts). */
function nyo(size, { eye = "open", look = 0, cls = "" } = {}) {
  const c = document.createElement("canvas");
  const dpr = Math.min(3, devicePixelRatio || 1);
  c.width = c.height = Math.round(size * dpr);
  c.style.width = c.style.height = size + "px";
  c.className = "nyo" + (cls ? " " + cls : "");
  c.setAttribute("aria-hidden", "true");
  const x = c.getContext("2d");
  if (x) {
    const u = (size * dpr) / 100;          // the 120-unit sheet: Nyo spans about 90 × 92 units
    x.translate((size * dpr) / 2, 61 * u);
    drawNyoStill(x, { rx: 38 * u, ry: 35 * u, eye, lookX: look, lookY: 0 });
  }
  return c;
}

/** A rounded tile with a letter, coloured from the name (apps, sessions without an icon of their own). */
const TINTS = ["tan", "mint", "pink", "sun", "fur"];
function tint(name) { let n = 0; for (const ch of String(name)) n = (n * 31 + ch.codePointAt(0)) >>> 0; return TINTS[n % TINTS.length]; }
function monogram(name, size = "") {
  const letter = (String(name).replace(/^[^A-Za-z0-9]+/, "")[0] || "·").toUpperCase();
  return h(`span.mono-tile.${tint(name)}${size ? "." + size : ""}`, { "aria-hidden": "true" }, letter);
}

function toast(text, ms = 2600) {
  state.toast = text;
  render();
  setTimeout(() => { if (state.toast === text) { state.toast = ""; render(); } }, ms);
}

// ── pairing: several computers ───────────────────────────────────────────────────────────────────────

const SAFE = /^[A-Za-z0-9_-]+$/;

/**
 * A Nyeko code (`…#pair=<base64url JSON>`, from a Mac) or a nyeko://pair link (coucou://pair before the rebrand) with the relay fields (from Nyeko on
 * Windows, or any Coucou desktop with its relay on). Null when it is neither, or a field is malformed.
 */
function parsePairing(code) {
  return readPairing(code).p;
}

/** The pairing in a code, or why there is none (said to the user). The code may sit in a longer text (a chat message). */
function readPairing(code) {
  const t = (code || "").trim();
  if (!t) return { why: "Nothing was pasted. Copy the pairing code on the computer first." };
  try {
    const link = /(?:nyeko|coucou):\/\/pair\?[^\s"'<>]+/.exec(t)?.[0];
    if (link) {
      const q = new URLSearchParams(link.slice(link.indexOf("?") + 1));
      const p = { relay: q.get("relay") || "", room: q.get("room") || "", key: q.get("key") || "", access: q.get("access") || "",
        token: q.get("token") || "", name: (q.get("name") || "Computer").slice(0, 64), vapid: "", cid: cidOf(q.get("cid")) };
      if (!p.relay) return { why: "This code only works on the same Wi-Fi, for the Android app. On the computer, turn on Away from home Wi-Fi (Nyeko → Phone) with your relay and its secret, then copy the new code." };
      return validPairing(p) ? { p } : { why: problem(p) };
    }
    const b64 = /#pair=([A-Za-z0-9_-]+)/.exec(t)?.[1] ?? (/^[A-Za-z0-9_-]{40,}$/.test(t) ? t : null);
    if (!b64) return { why: "That is not a Nyeko pairing code: copy it again on the computer (Nyeko → Phone)." };
    const j = JSON.parse(new TextDecoder().decode(fromB64url(b64)));
    const p = { relay: j.relay, room: j.room, key: j.key, access: j.access, token: j.token, name: String(j.name || "Mac").slice(0, 64),
      vapid: typeof j.vapid === "string" ? j.vapid : "", cid: cidOf(j.cid) };
    if (j.v !== 1) return { why: "This pairing code is from a newer Nyeko: reload this app and try again." };
    return validPairing(p) ? { p } : { why: problem(p) };
  } catch {
    return { why: "This pairing code is cut or damaged: copy the whole code again on the computer." };
  }
}

/** The id a computer gives itself (one per computer and account), or "" for an older code. */
function cidOf(x) { return typeof x === "string" && /^[A-Za-z0-9_-]{8,64}$/.test(x) ? x : ""; }

/** Which part of a pairing is wrong, in words. */
function problem(p) {
  if (!/^wss?:\/\/[^/?#\s]+$/.test(p.relay || "")) return `The relay address in this code (${String(p.relay || "none").slice(0, 60)}) is not a wss:// address.`;
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(p.access || "")) return "The relay's secret in this code is not usable: it must be 16 to 128 letters, digits, - and _. Set it again on the computer (Away from home Wi-Fi), then copy a new code.";
  if (!/^[A-Za-z0-9_-]{22}$/.test(p.room || "") || !/^[A-Za-z0-9_-]{43}$/.test(p.key || "")) return "This code's relay room or key is damaged: on the computer press Pair again and copy the new code.";
  return "This code's pairing token is damaged: on the computer press Pair again and copy the new code.";
}

function validPairing(p) {
  return /^wss?:\/\/[^/?#\s]+$/.test(p.relay) && /^[A-Za-z0-9_-]{22}$/.test(p.room) && /^[A-Za-z0-9_-]{43}$/.test(p.key)
    && /^[A-Za-z0-9_-]{16,128}$/.test(p.access) && typeof p.token === "string" && p.token.length >= 16 && p.token.length <= 128
    && SAFE.test(p.token);
}

function saveComputers() {
  save(STORE.computers, state.computers.map((c) => c.p));
  save(STORE.current, state.current);
}

/**
 * A new computer's setup code (its QR code, Nyeko → Phone, before it has a relay): this phone sends it the relay's address
 * and access key from a computer it already has, encrypted to the code's key, and adds it with the pairing code it answers
 * with (setup.js, docs/RELAY_SETUP.md).
 */
async function setupComputer(text) {
  const offer = parseSetup(text);
  history.replaceState(null, "", location.pathname);
  const from = state.computers.find((c) => c.p.relay === offer.relay) || state.computers[0];
  if (!from) {
    return toast("Set up your first computer by hand once (Nyeko → Phone: the relay's address and access key). "
      + "After that, scan the code on each new computer and it sets itself up.", 9000);
  }
  toast(`Setting up ${offer.name}…`, 60_000);
  try {
    const code = await sendSetup(offer, { relay: from.p.relay, access: from.p.access, phone: isIOS ? "iPhone" : "Phone" });
    addComputer(code);
  } catch (e) {
    toast(e?.message || "The setup did not work: try again.", 8000);
  }
}

/** This computer's pairing again, as a code to paste in another copy of Nyeko (Safari → the Home Screen app). */
function codeOf(c) {
  const p = c.p;
  const j = { v: 1, relay: p.relay, room: p.room, key: p.key, access: p.access, token: p.token, name: p.name, vapid: p.vapid || undefined, cid: p.cid || undefined };
  return `${location.origin}/#pair=${b64url(new TextEncoder().encode(JSON.stringify(j)))}`;
}

async function copyForApp(c) {
  try {
    await navigator.clipboard.writeText(codeOf(c));
    toast(`Copied. Open Nyeko from your Home Screen: Settings › Add a computer › Paste pairing code.`, 7000);
  } catch { toast("Copy did not work. Try again."); }
}

/** Adds (or, for the same room, replaces) a computer and connects to it. */
function addComputer(code) {
  if (parseSetup(code)) return void setupComputer(code);
  const { p, why } = readPairing(code);
  if (!p) return toast(why, 7000);
  history.replaceState(null, "", location.pathname);   // the code never stays in the address bar
  // The same computer paired again (a new room after "Pair again") replaces itself: same room, or the same computer id.
  // Never the name: two accounts on one Mac, or two computers both called "MacBook Pro", are two computers.
  const same = (c) => c.id === p.room || (!!p.cid && c.p.cid === p.cid);
  for (const old of state.computers.filter(same)) old.channel?.stop();
  state.computers = state.computers.filter((c) => !same(c));
  const c = newComputer(p);
  state.computers.push(c);
  state.current = c.id;
  saveComputers();
  connect(c);
  state.tab = "now";
  toast(`${p.name} added.`);
  render();
}
const pair = addComputer;

function removeComputer(c) {
  if (!confirm(`Remove ${c.desktop}? You will need its pairing code to add it again.`)) return;
  c.channel?.send({ type: "bye" });
  c.channel?.stop();
  state.computers = state.computers.filter((x) => x !== c);
  if (state.thread?.comp === c.id) state.thread = null;
  if (state.launch?.comp === c.id) state.launch = null;
  if (state.current === c.id) state.current = state.computers[0]?.id ?? null;
  saveComputers();
  if (!state.computers.length) state.tab = "now";
  render();
}

const comp = (id) => state.computers.find((c) => c.id === id) || null;
const cur = () => comp(state.current) || state.computers[0] || null;
const many = () => state.computers.length > 1;
const kindOf = (c) => (c.os === "windows" ? "PC" : c.os === "macos" ? "Mac" : "computer");

/** The Nyeko app's own pairing link, carried in the same code for Android phones (null when absent or malformed). */
function androidLinkOf(code) {
  try {
    const p = JSON.parse(new TextDecoder().decode(fromB64url(code.trim().replace(/^.*#pair=/, ""))));
    return typeof p.android === "string" && /^(?:nyeko|coucou):\/\/pair\?[A-Za-z0-9%=&._~-]{20,1500}$/.test(p.android) ? p.android : null;
  } catch { return null; }
}

// ── One mouse and keyboard for a Mac and a PC (docs/SHARED_MOUSE.md) ─────────────────────────────────────────────────
// The phone only introduces them: it asks the PC for its link on the Wi-Fi and hands it to the Mac, with the side the PC
// stands on. After that the Mac and the PC talk to each other directly, phone or not.

/** Whether the Mac's sharing status is about this PC. */
const sharesWith = (s, pc) => !!s && (s.cid && pc.p.cid ? s.cid === pc.p.cid : s.name === pc.desktop);

/** The Mac and the PC this computer would share with: the one the Mac already shares with, else the first connected. */
function sharePair(c) {
  if (c.os !== "macos" && c.os !== "windows") return null;
  const macs = state.computers.filter((x) => x.os === "macos"), pcs = state.computers.filter((x) => x.os === "windows");
  if (!macs.length || !pcs.length) return null;
  const pick = (list, mine) => list.find(mine) || list.find((x) => x.status === "open") || list[0];
  const mac = c.os === "macos" ? c : pick(macs, (m) => sharesWith(m.mac?.share, c));
  const pc = c.os === "windows" ? c : pick(pcs, (p) => sharesWith(c.mac?.share, p));
  return { mac, pc };
}

function setupShare(mac, pc, side) {
  if (mac.status !== "open" || pc.status !== "open") return toast("Open Nyeko on both computers first.");
  state.shareSetup = { mac: mac.id, pc: pc.id, side, at: Date.now() };
  if (!send(pc, { type: "shareOffer" })) { state.shareSetup = null; return toast(`${shortName(pc)} is not connected.`); }
  setTimeout(() => { if (state.shareSetup?.at && Date.now() - state.shareSetup.at >= 15000) { state.shareSetup = null; render(); } }, 15500);
  render();
}

function shareCard(c) {
  const pair = sharePair(c);
  if (!pair) return null;
  const { mac, pc } = pair;
  const s = mac.mac?.share;
  const mine = sharesWith(s, pc);
  const macName = shortName(mac), pcName = shortName(pc);
  const busy = !!state.shareSetup;
  const where = (side) => `${pcName} on the ${side}`;
  let meta;
  if (busy) meta = "Introducing them…";
  else if (!mine) meta = s ? `${macName} shares with ${s.name} now` : `Push the pointer off the side of one screen to reach the other`;
  else meta = ({
    on: `On · ${pcName} is on the ${s.side} of ${macName}`,
    connecting: s.note || `Looking for ${pcName} on the Wi-Fi…`,
    permission: s.note || `Allow Nyeko in Accessibility on ${macName}`,
    refused: s.note || "Set it up again",
    off: "Off",
  })[s.state] || "";
  const other = s?.side === "left" ? "right" : "left";
  return h("section.card.share-card",
    h("div.share-head",
      h("span.tile.sun", icon("pointer", 20)),
      h("span.row-main", h("span.row-title", "One mouse for both"), h("span.row-meta.wrap", meta))),
    h("div.share-pair", { "aria-hidden": "true" },
      h("span.share-screen" + (mine && s.side === "left" ? ".pc" : ""), mine && s.side === "left" ? "PC" : "Mac"),
      h("span.share-arrow", icon("swap", 18)),
      h("span.share-screen" + (mine && s.side === "left" ? "" : ".pc"), mine && s.side === "left" ? "Mac" : "PC")),
    mine
      ? h("div.share-btns",
          h("button.btn.small", { disabled: mac.status !== "open", onclick: () => send(mac, { type: "share", action: "side", side: other }) }, "Swap sides"),
          h("button.btn.small.ghost.danger", { disabled: mac.status !== "open", onclick: () => send(mac, { type: "share", action: "off" }) }, "Turn off"))
      : h("div.share-btns",
          h("button.btn.small", { disabled: busy, onclick: () => setupShare(mac, pc, "left") }, where("left")),
          h("button.btn.small", { disabled: busy, onclick: () => setupShare(mac, pc, "right") }, where("right"))));
}

// ── Android: the Nyeko app when it is installed, a download when it is not ─────────────────────────────────────────

const ANDROID_PACKAGE = "com.broliix.nyeko.android";

/**
 * Chrome opens the app with this (its pairing link), or, when the app is not installed, comes back to this page with
 * ?noapp=1 and the same #pair= fragment (the fragment never reaches a server).
 */
function appIntent(link) {
  const back = location.origin + location.pathname + "?noapp=1" + location.hash;
  const scheme = link.startsWith("nyeko://") ? "nyeko" : "coucou";
  return "intent://" + link.replace(/^(?:nyeko|coucou):\/\//, "") +
    "#Intent;scheme=" + scheme + ";package=" + ANDROID_PACKAGE + ";S.browser_fallback_url=" + encodeURIComponent(back) + ";end";
}

function openApp() {
  if (state.androidOffer) location.href = appIntent(state.androidOffer.link);
}

/** The newest Nyeko for Android build this site serves (from the GitHub Release, see _worker.js), or null. */
async function checkApk() {
  try { const r = await fetch("/downloads/android.json", { cache: "no-store" }); state.apk = r.ok ? await r.json() : null; }
  catch { state.apk = null; }
  render();
}

// ── the channels (one per computer) ──────────────────────────────────────────────────────────────────

function connect(c) {
  c.channel?.stop();
  c.channel = new PhoneChannel(c.p, {
    status: (s) => { if (c.status !== "unpaired") { c.status = s; render(); } },
    open: () => c.channel.send({
      type: "hello", v: 1, token: c.p.token, device: isIOS ? "iPhone · Nyeko" : "Android · Nyeko",
      caps: ["details", "answers", "usage", "nyeko"],
    }),
    line: (m) => onLine(c, m),
  });
  c.channel.start();
}

const send = (c, m) => !!c?.channel?.send(m);

/** A computer paired before it gave itself an id (or a new name, "MacBook Pro · broly") says them when it connects: keep
 *  them, so the next "Pair again" replaces this entry. An older entry for the same computer that cannot connect any more
 *  (its room was replaced) goes. */
function learnIdentity(c, m) {
  const cid = cidOf(m.cid);
  const name = typeof m.desktop === "string" && m.desktop.trim() ? m.desktop.trim().slice(0, 64) : "";
  let changed = false;
  if (cid && c.p.cid !== cid) { c.p.cid = cid; changed = true; }
  if (name && c.p.name !== name) { c.p.name = name; changed = true; }
  if (cid) {
    const stale = state.computers.filter((x) => x !== c && x.p.cid === cid && x.status !== "open");
    for (const x of stale) x.channel?.stop();
    if (stale.length) { state.computers = state.computers.filter((x) => !stale.includes(x)); changed = true; }
  }
  if (changed) saveComputers();
}

function onLine(c, m) {
  switch (m.type) {
    case "welcome":
      c.desktop = m.desktop || c.p.name;
      c.os = m.os || c.os;
      learnIdentity(c, m);
      send(c, { type: "status" });
      if (state.thread?.comp === c.id) send(c, { type: "open", session: state.thread.id });
      resendPush(c);
      break;
    case "sessions": c.sessions = Array.isArray(m.sessions) ? m.sessions : []; break;
    case "approval": c.approval = { ...m, at: Date.now(), sent: false }; break;
    case "question": c.question = { ...m, at: Date.now(), sent: false, picks: (m.questions || []).map(() => []) }; break;
    case "approvalResolved":
      if (c.approval?.fingerprint === m.fingerprint) c.approval = null;
      if (c.question?.fingerprint === m.fingerprint) c.question = null;
      break;
    case "usage": c.usage = m; break;
    case "mac":
      c.mac = m; c.macAt = Date.now();
      if (m.os) c.os = m.os;
      break;
    case "apps": c.apps = Array.isArray(m.apps) ? m.apps : []; break;
    case "inputState": c.inputState = { ok: !!m.ok, note: typeof m.note === "string" ? m.note.slice(0, 300) : "" }; break;
    case "shareOffer": {
      // The PC's link for the shared mouse, on its way to the Mac (docs/SHARED_MOUSE.md).
      const S = state.shareSetup;
      if (!S || S.pc !== c.id) break;
      state.shareSetup = null;
      const mac = comp(S.mac);
      if (!m.ok || typeof m.link !== "string") { toast(m.note || `${shortName(c)} could not share its mouse.`, 7000); break; }
      if (send(mac, { type: "share", action: "setup", link: m.link, side: S.side })) toast(`Connecting ${shortName(mac)} to ${shortName(c)}…`);
      else toast(`${mac ? shortName(mac) : "The Mac"} is not connected.`);
      break;
    }
    case "shareState": if (!m.ok && typeof m.note === "string" && m.note) toast(m.note.slice(0, 300), 7000); break;
    case "folder": {
      const F = state.files;
      if (!F || F.comp !== c.id || F.asked !== m.id) break;
      F.asked = null;
      if (m.ok) { F.folder = m; F.path = m.path; } else toast(m.note || "That folder can't be shown.");
      break;
    }
    case "file": {
      const P = state.files?.preview;
      if (!P || P.id !== m.id) break;
      if (!m.ok) { state.files.preview = null; toast(m.note || "That file can't be shown."); break; }
      P.head = m; P.parts = new Array(m.chunks || 0); P.got = 0;
      if (!m.chunks) P.done = true;
      break;
    }
    case "chunk": {
      const P = state.files?.preview;
      if (!P || P.id !== m.id || !P.parts || P.parts[m.i] !== undefined || typeof m.d !== "string") return;
      P.parts[m.i] = m.d; P.got++;
      if (P.got < P.parts.length) { if (P.got % 8) return; break; }   // redraw the progress now and then
      finishPreview(P);
      break;
    }
    case "chat":
      if (state.thread?.comp === c.id && state.thread.id === m.session) { state.thread.data = m; state.thread.stick = state.thread.stick ?? true; }
      break;
    case "launched": {
      const st = state.launch?.starting;
      if (!st || st.id !== m.id) break;
      if (m.ok) st.launched = true;
      else { state.launch.starting = null; toast(m.note || "The session could not start."); }
      break;
    }
    case "started":
      if (state.launch?.starting?.id === m.id) {
        state.launch = null;
        openSession(c, { pillId: m.session, agent: m.title, statusText: m.host });
        return;
      }
      break;
    case "said": {
      const t = state.thread;
      if (t) t.sending = t.sending.filter((x) => x.id !== m.id);
      if (m.result === "typed") toast("Sent to Claude.");
      else if (m.note) toast(m.note);
      break;
    }
    case "reply":
      if (!state.waiting.has(m.id)) break;
      state.waiting.delete(m.id);
      state.chat.push({ me: false, text: String(m.text ?? ""), comp: c.id });
      break;
    case "error":
      if (m.code === "auth") { c.status = "unpaired"; c.channel?.stop(); }
      break;
    default: return;   // pong and anything unknown
  }
  render();
}

// ── Face ID (WebAuthn, on this phone only) ───────────────────────────────────────────────────────────

async function setupFaceId() {
  try {
    const cred = await navigator.credentials.create({ publicKey: {
      rp: { name: "Nyeko", id: location.hostname },
      user: { id: random(16), name: "nyeko", displayName: "Nyeko" },
      challenge: random(32),
      pubKeyCredParams: [{ type: "public-key", alg: -7 }, { type: "public-key", alg: -257 }],
      authenticatorSelection: { authenticatorAttachment: "platform", userVerification: "required", residentKey: "discouraged" },
      attestation: "none", timeout: 60000,
    } });
    save(STORE.cred, b64url(new Uint8Array(cred.rawId)));
    toast(`${isIOS ? "Face ID" : "Screen lock"} is set up.`);
  } catch { toast(`${isIOS ? "Face ID" : "The screen lock"} could not be set up.`); }
}

/** Allow and answers ask for Face ID (or the passcode) first. Deny never does. */
async function verify() {
  const id = load(STORE.cred);
  if (!id) { toast(`Set up ${lockName} in Settings first.`); return false; }
  try {
    await navigator.credentials.get({ publicKey: {
      challenge: random(32), rpId: location.hostname, userVerification: "required", timeout: 60000,
      allowCredentials: [{ type: "public-key", id: fromB64url(id) }],
    } });
    return true;
  } catch { return false; }
}

async function decide(c, allow) {
  const a = c.approval;
  if (!a || a.sent) return;
  if (allow && (a.truncated || !(await verify()))) return;
  a.sent = true;
  send(c, { type: "decision", fingerprint: a.fingerprint, decision: allow ? "allow" : "deny" });
  render();
}

async function answer(c) {
  const q = c.question;
  if (!q || q.sent) return;
  if (q.picks.some((p) => p.length === 0)) return toast("Pick an answer for each question.");
  if (!(await verify())) return;
  q.sent = true;
  send(c, { type: "answer", fingerprint: q.fingerprint, picks: q.picks });
  render();
}

/** Claude can act on what you send, and a power action can't be taken back: Face ID first, then not again for 10 minutes. */
async function unlock() {
  if (Date.now() <= unlockedUntil) return true;
  if (!(await verify())) return false;
  unlockedUntil = Date.now() + 10 * 60_000;
  return true;
}

function control(c, action, extra) {
  if (!send(c, { type: "control", action, ...extra })) { toast(`${c?.desktop || "The computer"} is not connected.`); return false; }
  return true;
}

/** Restart, shut down: asked twice (here and Face ID), and the computer still lets apps with unsaved work object. */
async function power(c, action) {
  const words = action === "restart" ? "Restart" : "Shut down";
  if (!confirm(`${words} ${c.desktop}?`)) return;
  if (!(await unlock())) return;
  if (control(c, action)) toast(`${words === "Restart" ? "Restarting" : "Shutting down"} ${c.desktop}…`);
}

// ── a coding session ─────────────────────────────────────────────────────────────────────────────────

function openSession(c, x) {
  if (state.thread) send(comp(state.thread.comp), { type: "close" });
  state.thread = { comp: c.id, id: x.pillId, title: x.agent, sub: x.statusText || "", data: null, sending: [], stick: true };
  state.tab = "session";
  send(c, { type: "open", session: x.pillId });
  render();
  scrollTo(0, document.body.scrollHeight);
}

function closeSession() {
  if (state.thread) send(comp(state.thread.comp), { type: "close" });
  state.thread = null;
  state.tab = "now";
  render();
  scrollTo(0, 0);
}

function newSession() {
  const c = cur();
  state.launch = { comp: c?.id, project: c?.mac?.projects?.[0]?.id ?? null, starting: null };
  state.tab = "launch";
  send(c, { type: "status" });   // the latest folders
  render();
  scrollTo(0, 0);
}

async function startSession(form) {
  const L = state.launch;
  const c = comp(L?.comp);
  if (!L || L.starting || !c) return;
  const project = L.folder ? null : (c.mac?.projects || []).find((p) => p.id === L.project);
  if (!project && !L.folder) return toast("Pick a folder first.");
  if (c.status !== "open") return toast(`${c.desktop} is not connected.`);
  if (!(await unlock())) return;
  const prompt = form.querySelector("textarea").value.trim();
  const id = b64url(random(9));
  const what = L.folder ? { folder: L.folder.path } : { project: project.id };
  if (!send(c, { type: "launch", id, ...what, prompt })) return toast(`${c.desktop} is not connected.`);
  L.starting = { id, name: L.folder ? L.folder.name : project.name, at: Date.now(), launched: false };
  render();
}

async function say(form) {
  const t = state.thread;
  const c = comp(t?.comp);
  const box = form.querySelector("textarea");
  const text = box.value.trim();
  if (!t || !c || !text) return;
  if (c.status !== "open") return toast(`${c.desktop} is not connected.`);
  if (!(await unlock())) return;
  const id = b64url(random(9));
  if (!send(c, { type: "say", session: t.id, id, text })) return toast(`${c.desktop} is not connected.`);
  t.sending.push({ id, text });
  t.stick = true;
  box.value = "";
  render();
  scrollTo(0, document.body.scrollHeight);
}

// ── alerts (Web Push, no payload) ────────────────────────────────────────────────────────────────────

const standalone = () => matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;

/** A phone has one push subscription, signed for one computer: the first Mac that can send alerts. */
const alertsComputer = () => state.computers.find((c) => c.p.vapid) || null;

async function enableAlerts() {
  const a = alertsComputer();
  if (!a) return toast("None of your computers can send alerts to this web app.");
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    return toast(isIOS ? "Add Nyeko to the Home Screen first (Share → Add to Home Screen)."
                       : "This browser cannot show alerts. Use Chrome.");
  }
  if ((await Notification.requestPermission()) !== "granted") return toast("Notifications are off for Nyeko.");
  try {
    const reg = await navigator.serviceWorker.ready;
    let sub = await reg.pushManager.getSubscription();
    if (sub && load(STORE.alerts) !== a.id) { await sub.unsubscribe(); sub = null; }   // signed for another computer
    sub = sub || (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: fromB64url(a.p.vapid) }));
    save(STORE.alerts, a.id);
    if (send(a, { type: "pushSub", endpoint: sub.endpoint })) toast("Alerts are on.");
    else toast(`Alerts will turn on when ${a.desktop} is connected.`);
  } catch { toast("Alerts could not be turned on."); }
  render();
}

async function resendPush(c) {
  if (load(STORE.alerts) !== c.id || !("serviceWorker" in navigator)) return;
  try {
    const sub = await (await navigator.serviceWorker.ready).pushManager.getSubscription();
    if (sub) send(c, { type: "pushSub", endpoint: sub.endpoint });
  } catch {}
}

// ── views ────────────────────────────────────────────────────────────────────────────────────────────

const sessionClass = (s) => ({ approval: "need", question: "need", error: "need", ratelimit: "need",
  working: "work", thinking: "work", searching: "work", finished: "done" }[s] || "idle");
const sessionLabel = (s) => ({ approval: "Needs you", question: "Needs you", error: "Error", ratelimit: "Rate limited",
  working: "Working", thinking: "Thinking", searching: "Searching", finished: "Done" }[s] || "Idle");
const dotOf = (c) => ({ open: "on", waiting: "wait", connecting: "wait" }[c.status] || "off");
const statusWord = (c) => ({ open: "Connected", waiting: "Waiting for it", connecting: "Connecting…",
  unpaired: "Paired again on the computer: add its new code" }[c.status] || "Offline");

/** "Neko's MacBook Pro · greenhawk_nyek" → { device, account }. Two accounts on one Mac share the device part. */
function nameParts(c) {
  const [device, ...rest] = String(c.desktop).split(" · ");
  return { device, account: rest.join(" · ") };
}
/** The shortest name that still tells this computer apart from the others on the phone. */
function shortName(c) {
  const { device, account } = nameParts(c);
  if (!account) return device;
  const twins = state.computers.filter((x) => nameParts(x).device === device).length > 1;
  return twins ? account : device;
}
const osIcon = (c) => (c.os === "windows" || c.os === "linux" ? "desktop" : "laptop");

const pill = (s) => h("span.pill." + sessionClass(s), sessionClass(s) === "work" ? h("span.dots", h("i"), h("i"), h("i")) : h("i.pip"), sessionLabel(s));
const section = (title, ...rest) => h("div.section-head", h("h2", title), ...rest);

function header() {
  const n = state.computers.length;
  const on = state.computers.filter((c) => c.status === "open").length;
  const one = state.computers[0];
  const [dot, text] = n === 1 ? [dotOf(one), one.status === "open" ? one.desktop : statusWord(one)]
    : [on === n ? "on" : on ? "wait" : "off", on === n ? `All ${n} computers connected` : `${on} of ${n} computers connected`];
  const busy = state.computers.some((c) => c.approval || c.question);
  return h("header.top",
    h("button.brand", { "aria-label": "Your computers", onclick: () => { state.tab = "settings"; render(); } },
      nyo(46, { eye: on ? "open" : "content", look: busy ? 0.4 : 0 }),
      h("span.brand-text", h("span.wordmark", "Nyeko"), h("span.status", h("span.dot." + dot), text))),
    h("button.icon-btn", { "aria-label": "Settings", onclick: () => { state.tab = "settings"; render(); } }, icon("gear")));
}

/** The computer a tab talks to (only with more than one): a row of chips that scrolls sideways. */
function picker(onPick) {
  if (!many()) return null;
  const c0 = cur();
  return h("div.switcher", { role: "tablist", "aria-label": "Computer" }, state.computers.map((c) =>
    h("button.switch" + (c === c0 ? ".on" : ""), { role: "tab", "aria-selected": c === c0 ? "true" : "false",
      onclick: () => { state.current = c.id; saveComputers(); onPick?.(c); render(); } },
      h("span.dot." + dotOf(c)), shortName(c))));
}

function approvalCard(c) {
  const a = c.approval;
  if (!a) return null;
  const left = Math.max(0, Math.ceil((a.at + APPROVAL_TTL - Date.now()) / 1000));
  if (left === 0) { c.approval = null; return null; }
  return h("section.card.urgent", { "aria-label": "Permission request" },
    h("div.urgent-head", h("span", "Claude needs your OK"), h("span.countdown", `${left}s`)),
    h("div.card-body",
      h("div.sub", `${a.tool}${many() ? ` · ${shortName(c)}` : ""}`),
      h("pre.code", a.command),
      a.truncated ? h("p.note", "The command is longer than shown: allow it on the computer, or deny it here.") : null,
      a.sent ? h("p.note", "Sent. Waiting for the computer…")
        : h("div.pair-btns",
            h("button.btn.ghost", { onclick: () => decide(c, false) }, "Deny"),
            a.truncated ? null : h("button.btn.go", { onclick: () => decide(c, true) }, icon("shield", 20), "Allow")),
      a.sent ? null : h("p.note", `Allow asks for your ${lockName}. Deny never does.`)));
}

function questionCard(c) {
  const q = c.question;
  if (!q) return null;
  return h("section.card.urgent", { "aria-label": "Question from Claude" },
    h("div.urgent-head", h("span", many() ? `Claude asks · ${shortName(c)}` : "Claude asks")),
    h("div.card-body",
      q.questions.map((item, i) => h("div.question",
        h("p.q", item.question),
        h("div.opts", item.options.map((o) => {
          const on = q.picks[i].includes(o.label);
          return h("button.opt" + (on ? ".on" : ""), { "aria-pressed": on ? "true" : "false", onclick: () => {
            if (item.multiSelect) q.picks[i] = on ? q.picks[i].filter((l) => l !== o.label) : [...q.picks[i], o.label];
            else q.picks[i] = [o.label];
            render();
          } }, h("span.opt-label", o.label), o.description ? h("small", o.description) : null);
        })))),
      q.sent ? h("p.note", "Sent. Waiting for the computer…")
        : h("button.btn.primary.block", { onclick: () => answer(c) }, "Send answer")));
}

function sessionRow(c, x) {
  const host = String(x.statusText || "").split(" · ")[0];
  const meta = [many() ? shortName(c) : null, x.statusText || null].filter(Boolean).join(" · ");
  return h("button.row-btn.session", { "aria-label": `${x.agent}${many() ? ` on ${c.desktop}` : ""}: open the session`,
      onclick: () => openSession(c, x) },
    h(`span.tile.${tint(host || x.agent)}`, icon("terminal", 22)),
    h("span.row-main", h("span.row-title", x.agent), meta ? h("span.row-meta", meta) : null),
    pill(x.state));
}

function nowTab() {
  const rows = state.computers.flatMap((c) => c.sessions.map((x) => ({ c, x })));
  const order = { need: 0, work: 1, done: 2, idle: 3 };
  rows.sort((a, b) => order[sessionClass(a.x.state)] - order[sessionClass(b.x.state)]);
  const u = cur()?.usage?.claude;
  return [
    // Nyeko in Safari on an iPhone keeps its own computers: the Home Screen app never sees them (and a private tab
    // forgets them when it closes). Say so, and move them across by the clipboard.
    isIOS && !standalone() ? h("section.card.tinted", h("div.card-body",
      h("div.title", "You're in Safari, not the Nyeko app"),
      h("p.sub", "Computers added here stay in Safari: the Nyeko app on your Home Screen doesn't see them, and a private tab forgets them when you close it. Move them to the app: Settings › Copy for the app on each computer, then paste it there."),
      h("div.pair-btns", h("button.btn.primary", { onclick: () => { state.tab = "settings"; render(); } }, "Move my computers")))) : null,
    state.computers.map((c) => [approvalCard(c), questionCard(c)]),
    // Android in the browser: Nyo on the screen and the camera-hole island need the app (a web page can't draw over apps).
    !isIOS && !load("nyeko.appHint.hidden") ? h("section.card.tinted",
      h("div.card-body",
        h("div.title", "Want Nyo on your screen?"),
        h("p.sub", "Nyo floating over your other apps and the island from the camera hole come with the Nyeko app for Android."),
        h("div.pair-btns",
          h("a.btn.primary", { href: "/download.html" }, "Get the app"),
          h("button.btn.ghost", { onclick: () => { save("nyeko.appHint.hidden", true); render(); } }, "Not now")))) : null,
    section("Sessions", rows.length ? h("span.count", String(rows.length)) : null),
    rows.length === 0
      ? h("section.card.empty-card",
          nyo(84, { eye: "closed" }),
          h("div.title", "Nothing running"),
          h("p.sub", many() ? "No coding session is open on your computers." : "No coding session is open on this computer."))
      : h("section.card.list", rows.map(({ c, x }) => sessionRow(c, x))),
    h("button.btn.dashed.block", { onclick: newSession }, icon("plus", 20), "New session"),
    u ? [section("Claude plan"), h("section.card",
      h("div.card-body", [["5-hour window", u.fiveHour], ["This week", u.sevenDay]].filter(([, w]) => w).map(([label, w]) =>
        h("div.meter-row", h("div.meter-label", h("span", label), h("b", `${w.pct}%`)),
          h("div.meter" + (w.pct >= 85 ? ".hot" : ""), h("div", { style: `width:${Math.min(100, w.pct)}%` }))))))] : null,
  ];
}

function computerTab() {
  const c = cur();
  if (!c) return null;
  const m = c.mac;
  const kind = kindOf(c);
  if (!m) return [picker(), h("section.card.empty-card", nyo(72, { eye: "content" }),
    h("div.title", c.status === "open" ? `Loading ${shortName(c)}…` : `${shortName(c)} is offline`),
    c.status === "open" ? null : h("p.sub", "Open Nyeko on it, and check its relay is switched on."))];
  const ctl = (action, extra) => control(c, action, extra);
  const np = m.nowPlaying;
  let pos = np?.position ?? 0;
  if (np?.playing && np?.duration) pos = Math.min(np.duration, pos + (Date.now() - c.macAt) / 1000);
  const t = m.timer;
  const tLeft = t ? Math.max(0, (t.remaining ?? 0) - (t.paused ? 0 : Math.floor((Date.now() - c.macAt) / 1000))) : 0;
  const mmss = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
  const apps = (c.apps || []).filter((a) => a.name.toLowerCase().includes(state.appSearch.toLowerCase())).slice(0, 60);
  const action = (ic, label, sub, onclick, cls = "") =>
    h("button.action" + cls, { onclick }, h("span.action-ic", icon(ic)), h("span.action-label", label), sub ? h("span.action-sub", sub) : null);
  return [
    picker(),
    m.next ? h("section.card.next-up",
      h("span.tile.fur", icon("calendar")),
      h("span.row-main", h("span.row-meta", "Next up"), h("span.row-title", m.next.title), h("span.row-meta", m.next.when))) : null,

    h("section.card.list.pad-entry", h("button.row-btn", { onclick: () => openPad(c) },
      h("span.tile.mint", icon("pointer", 20)),
      h("span.row-main", h("span.row-title", "Trackpad and keyboard"), h("span.row-meta", `Move the mouse and type on ${shortName(c)}`)),
      icon("chevron", 18))),
    shareCard(c),

    section("Now playing"),
    h("section.card.player" + (np?.playing ? ".playing" : ""), np ? [
      h("div.player-top",
        h("div.record", { "aria-hidden": "true" }, h("div.label")),
        h("div.row-main", h("div.track", np.title), h("div.row-meta", [np.artist, np.source].filter(Boolean).join(" · ")))),
      np.duration ? h("div.scrub", h("span", mmss(pos)),
        h("div.meter.thin", h("div", { style: `width:${Math.round(100 * pos / np.duration)}%` })), h("span", mmss(np.duration))) : null,
      h("div.transport",
        h("button.icon-btn", { "aria-label": "Previous track", onclick: () => ctl("previous") }, icon("prev")),
        h("button.icon-btn.big", { "aria-label": np.playing ? "Pause" : "Play", onclick: () => ctl("playPause") }, icon(np.playing ? "pause" : "play", 28)),
        h("button.icon-btn", { "aria-label": "Next track", onclick: () => ctl("next") }, icon("next"))),
    ] : h("div.player-idle", h("div.record.still", { "aria-hidden": "true" }, h("div.label")), h("p.sub", `Nothing is playing on ${shortName(c)}.`))),

    section("Sound"),
    h("section.card.sound",
      h("button.icon-btn", { "aria-label": m.muted ? "Unmute" : "Mute", "aria-pressed": m.muted ? "true" : "false", onclick: () => ctl("mute") }, icon(m.muted ? "mute" : "volume")),
      h("button.icon-btn.small", { "aria-label": "Volume down", onclick: () => ctl("volumeDown") }, "−"),
      h("div.volume", h("div.meter", h("div", { style: `width:${m.muted ? 0 : (m.volume ?? 0)}%` })),
        h("span.vol-num", m.muted ? "Muted" : m.volume != null ? `${m.volume}%` : "")),
      h("button.icon-btn.small", { "aria-label": "Volume up", onclick: () => ctl("volumeUp") }, "+")),

    section(`On the ${kind}`, m.battery ? h("span.battery", icon("battery", 18), `${m.battery.percent}%${m.battery.charging ? " · charging" : ""}`) : null),
    h("div.actions",
      m.timer !== undefined || c.os === "macos" ? action("timer", "Focus timer", t ? `${t.phase === "work" ? "Work" : "Break"} · ${mmss(tLeft)}` : "25 / 5 min",
        () => ctl("timer"), t ? ".active" : "") : null,
      m.recording !== undefined ? action("mic", "Notetaker", m.recording ? "Recording" : "Record a call", () => ctl("record"), m.recording ? ".active.rec" : "") : null,
      action("camera", "Screenshot", `Kept on the ${kind}`, () => { if (ctl("screenshot")) toast(`Screenshot taken on ${shortName(c)}.`); }),
      action("lock", "Lock", null, () => { if (ctl("lock")) toast(`${shortName(c)} is locked.`); }),
      action("screenOff", "Screen off", null, () => ctl("displaySleep")),
      action("moon", "Sleep", null, () => { if (confirm(`Put ${c.desktop} to sleep? The phone loses it until it wakes.`)) ctl("sleep"); })),
    h("div.power",
      h("button.btn.ghost", { onclick: () => power(c, "restart") }, icon("restart", 20), "Restart"),
      h("button.btn.ghost.danger", { onclick: () => power(c, "shutdown") }, icon("power", 20), "Shut down")),
    h("p.note.center", `Restart and shut down ask for your ${lockName}. Apps with unsaved work can still object.`),

    section("Files"),
    h("section.card.list", h("button.row-btn", { onclick: () => openFiles(c) },
      h("span.tile.sun", icon("folder", 20)),
      h("span.row-main", h("span.row-title", `Browse ${shortName(c)}`), h("span.row-meta", "Look through your folders, preview files, start a session")),
      icon("chevron", 18))),

    m.apps?.length ? [section("Quick launch"),
      h("section.card.launcher", m.apps.map((a) => h("button.app", { onclick: () => { if (ctl("open", { app: a.id })) toast(`Opening ${a.name}…`); } },
        monogram(a.name, "lg"), h("span.app-name", a.name))))] : null,

    section("All apps"),
    h("section.card.list",
      c.apps == null
        ? h("div.card-body", h("button.btn.block", { onclick: () => { if (send(c, { type: "listApps" })) { c.apps = []; render(); } else toast(`${shortName(c)} is not connected.`); } },
            `Show the apps on ${shortName(c)}`))
        : [h("label.search", icon("search", 20),
             h("input#appsearch", { type: "search", placeholder: "Search apps", autocomplete: "off", "aria-label": "Search apps",
               oninput: (e) => { state.appSearch = e.target.value; render(); } })),
           c.apps.length === 0 ? h("p.empty", "Loading…")
             : apps.length === 0 ? h("p.empty", "No app by that name.")
             : apps.map((a) => h("button.row-btn.app-row", { onclick: () => { if (ctl("openAny", { app: a.id })) toast(`Opening ${a.name} on ${shortName(c)}…`); } },
                 monogram(a.name), h("span.row-main", h("span.row-title.plain", a.name.replace(/^\./, ""))), icon("open", 18)))]),
  ];
}

function nyoTab() {
  const c = cur();
  const msgs = state.chat;
  const ask = (text) => {
    if (!text || !c) return;
    const id = b64url(random(9));
    if (!send(c, { type: "ask", id, text })) return toast(`${shortName(c)} is not connected.`);
    state.chat.push({ me: true, text, comp: c.id });
    state.waiting.set(id, c.id);
    render();
  };
  return [
    picker(),
    msgs.length === 0 ? h("div.nyo-hello",
      nyo(120, { look: 0.2 }),
      h("div.title", "Ask Nyo"),
      h("p.sub", `Questions, or things to do on ${c ? shortName(c) : "your computer"}.`),
      h("div.chips.wrap", ["Pause the music", "Start a focus timer", "What's next today?", "Lock my screen"].map((s) =>
        h("button.chip-btn", { onclick: () => ask(s) }, s)))) : null,
    h("div.chat",
      msgs.map((m) => h("div.msg." + (m.me ? "me" : "nyo"), many() && !m.me ? h("small.from", comp(m.comp) ? shortName(comp(m.comp)) : "") : null, m.text)),
      state.waiting.size ? h("div.msg.nyo.typing", h("span.dots", h("i"), h("i"), h("i"))) : null),
    h("div.composer", h("form", { onsubmit: (e) => {
      e.preventDefault();
      const input = e.target.querySelector("input");
      const text = input.value.trim();
      input.value = "";
      ask(text);
    } },
      h("input#ask", { type: "text", placeholder: many() ? `Message Nyo on ${c ? shortName(c) : ""}` : "Message Nyo", autocomplete: "off", enterkeyhint: "send", "aria-label": "Message Nyo" }),
      h("button.send", { type: "submit", "aria-label": "Send" }, icon("send", 22)))),
  ];
}

/** A session's lines grouped into turns: what you said, what Claude did, what it answered. */
function turnsOf(items) {
  const turns = [];
  let t = null;
  for (const it of items) {
    if (it.r === "you" || !t) { t = { you: null, tools: [], answer: [] }; turns.push(t); }
    if (it.r === "you") t.you = it;
    else if (it.r === "tools") t.tools.push(...String(it.t).split("\n").filter(Boolean));
    else t.answer.push(it.t);
  }
  return turns;
}

const QUICK = ["Continue", "Run the tests", "Fix the errors", "Commit"];

function sessionTab() {
  const t = state.thread;
  const c = comp(t?.comp);
  if (!t || !c) { state.tab = "now"; return nowTab(); }
  const d = t.data;
  const live = c.sessions.find((x) => x.pillId === t.id);
  const st = d?.state === "needsYou" ? "approval" : d?.state === "working" ? "working" : live?.state || "idle";
  const gone = d?.state === "gone";
  const where = d ? [many() ? shortName(c) : null, d.host, d.folder].filter(Boolean).join(" · ") : t.sub;
  const turns = turnsOf(d?.items || []);
  const last = turns[turns.length - 1];
  const earlier = turns.slice(0, -1).reverse();
  const queued = d?.queued || [];
  const canSend = d?.canMessage && !gone;
  t.open = t.open || {};
  const hint = !d ? "" : gone ? "This session has ended."
    : !d.canMessage ? "Only Claude Code sessions take messages from the phone. You can still open it on the computer."
    : d.state === "working" ? "Claude is working: it reads your message when it finishes this turn."
    : d.state === "needsYou" ? "Claude is waiting for you: answer the card above first."
    : d.note || "";
  const toolsCard = (tools, key) => tools.length ? h("section.card.fold" + (t.open[key] ? ".open" : ""),
    h("button.fold-head", { "aria-expanded": t.open[key] ? "true" : "false", onclick: () => { t.open[key] = !t.open[key]; render(); } },
      h("span", "What it did"), h("span.count", String(tools.length)), h("span.grow"), icon("down", 18)),
    t.open[key] ? h("div.tool-lines", tools.map((l) => h("div", l))) : h("div.tool-peek", tools[tools.length - 1])) : null;
  const sendQuick = (text) => {
    const box = document.getElementById("say");
    if (!box) return;
    box.value = text;
    say(box.form);
  };
  return [
    h("div.session-bar",
      h("button.icon-btn", { "aria-label": "Back to sessions", onclick: closeSession }, icon("back")),
      h("div.session-title", h("div.track", d?.title || t.title), h("div.row-meta", where)),
      h("button.icon-btn", { "aria-label": `Show it on the ${kindOf(c)}`, onclick: () => { if (control(c, "focus", { app: t.id })) toast(`Opening it on ${shortName(c)}…`); } }, icon("open"))),
    h("div.session-state", gone ? h("span.pill.idle", h("i.pip"), "Ended") : pill(st)),
    st === "approval" || st === "question" ? [approvalCard(c), questionCard(c)] : null,
    !d ? h("section.card.empty-card", nyo(64, { eye: "content" }), h("p.sub", c.status === "open" ? "Loading the session…" : `Connect to ${shortName(c)} to read it.`))
    : !d.readable ? h("section.card.empty-card", h("p.sub", "Nyeko can't read this session's conversation."))
    : !last ? h("section.card.empty-card", h("p.sub", "Nothing said yet."))
    : [
        last.you ? h("div.msg.me", last.you.p ? h("small.from", "From your phone") : null, last.you.t) : null,
        toolsCard(last.tools, "last"),
        last.answer.length ? h("section.card.answer", h("div.answer-head", nyo(28), h("span", "Claude's answer")),
          h("div.answer-text", last.answer.join("\n\n"))) : null,
        d?.state === "working" ? h("div.working", h("span.dots", h("i"), h("i"), h("i")), "Claude is working") : null,
        earlier.length ? [section("Earlier turns"), h("section.card.list", earlier.map((turn, i) => {
          const key = "e" + (earlier.length - i);
          const open = t.open[key];
          return h("div.turn" + (open ? ".open" : ""),
            h("button.row-btn", { "aria-expanded": open ? "true" : "false", onclick: () => { t.open[key] = !open; render(); } },
              h("span.row-main", h("span.row-title.plain", turn.you?.t || "Claude"), h("span.row-meta",
                [turn.tools.length ? `${turn.tools.length} step${turn.tools.length === 1 ? "" : "s"}` : null, turn.answer.length ? "answered" : null].filter(Boolean).join(" · "))),
              icon(open ? "down" : "chevron", 18)),
            open ? h("div.turn-body", turn.tools.length ? h("div.tool-lines", turn.tools.map((l) => h("div", l))) : null,
              turn.answer.length ? h("div.answer-text", turn.answer.join("\n\n")) : null) : null);
        }))] : null,
      ],
    queued.map((q) => h("div.msg.me.queued", h("small.from", "Waits for Claude"), q)),
    queued.length ? h("button.link.end", { onclick: () => send(c, { type: "unqueue", session: t.id }) }, "Cancel waiting message") : null,
    t.sending.map((m) => h("div.msg.me.queued", h("small.from", "Sending…"), m.text)),
    canSend ? h("div.composer.solo",
      hint ? h("p.composer-hint", hint) : null,
      h("div.chips", QUICK.map((q) => h("button.chip-btn", { onclick: () => sendQuick(q) }, q))),
      h("form", { onsubmit: (e) => { e.preventDefault(); say(e.target); } },
        h("textarea#say", { rows: "1", placeholder: "Tell Claude what to do next", "aria-label": "Message Claude", enterkeyhint: "send",
          oninput: (e) => { e.target.style.height = "auto"; e.target.style.height = Math.min(160, e.target.scrollHeight) + "px"; } }),
        h("button.send", { type: "submit", "aria-label": "Send" }, icon("send", 22))))
      : hint ? h("p.note.center", hint) : null,
  ];
}

// ── Files on a computer (read-only; docs/PHONE_FILES.md) ─────────────────────────────────────────────────────────

/** Opens the file browser on computer `c`, at `path` (its home folder when empty). `pick`: from New session. */
async function openFiles(c, { path = "", pick = false } = {}) {
  if (!c) return;
  if (c.status !== "open") return toast(`${shortName(c)} is not connected.`);
  if (!(await unlock())) return;
  state.files = { comp: c.id, path, folder: null, asked: null, preview: null, pick };
  state.tab = "files";
  browse(path);
}

function browse(path) {
  const F = state.files;
  const c = comp(F?.comp);
  if (!F || !c) return;
  F.asked = b64url(random(9));
  F.preview = null;
  if (!send(c, { type: "browse", id: F.asked, path })) { F.asked = null; toast(`${shortName(c)} is not connected.`); }
  render();
  scrollTo(0, 0);
}

const sepOf = (path) => (path.includes("\\") && !path.includes("/") ? "\\" : "/");
const joinPath = (dir, name) => dir.replace(/[\\/]+$/, "") + sepOf(dir) + name;

function previewFile(entry) {
  const F = state.files;
  const c = comp(F?.comp);
  if (!F?.folder || !c) return;
  const id = b64url(random(9));
  F.preview = { id, name: entry.name, kind: entry.kind, size: entry.size, head: null, parts: null, got: 0, done: false };
  if (!send(c, { type: "preview", id, path: joinPath(F.folder.path, entry.name) })) { F.preview = null; toast(`${shortName(c)} is not connected.`); }
  render();
  scrollTo(0, 0);
}

function fromBase64(d) {
  let s = d.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Every chunk is in: the text, or the picture as a data: URL (the page's CSP allows data: images only). */
function finishPreview(P) {
  try {
    const bytes = P.parts.map(fromBase64);
    const all = new Uint8Array(bytes.reduce((n, b) => n + b.length, 0));
    let at = 0;
    for (const b of bytes) { all.set(b, at); at += b.length; }
    if (P.head.kind === "text") P.text = new TextDecoder("utf-8", { fatal: false }).decode(all);
    else {
      let bin = "";
      for (let i = 0; i < all.length; i += 0x8000) bin += String.fromCharCode(...all.subarray(i, i + 0x8000));
      P.src = `data:${P.head.mime || "application/octet-stream"};base64,${btoa(bin)}`;
    }
  } catch { P.failed = true; }
  P.parts = null;
  P.done = true;
}

const sizeText = (n) => n == null ? "" : n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(n < 10240 ? 1 : 0)} KB` : `${(n / 1048576).toFixed(1)} MB`;
const dateText = (t) => t ? new Date(t * 1000).toLocaleDateString(undefined, { day: "numeric", month: "short", year: new Date(t * 1000).getFullYear() === new Date().getFullYear() ? undefined : "numeric" }) : "";
const fileIcon = (e) => e.dir ? ["folder", "sun"] : e.kind === "image" ? ["image", "pink"] : e.kind === "text" ? ["file", "paper"] : ["file", "fur"];

function filesTab() {
  const F = state.files;
  const c = comp(F?.comp);
  if (!F || !c) { state.tab = "mac"; return computerTab(); }
  const close = () => {
    if (F.preview) { F.preview = null; render(); return; }
    state.files = null;
    state.tab = F.pick ? "launch" : "mac";
    render();
  };
  const bar = (title, sub, right) => h("div.session-bar",
    h("button.icon-btn", { "aria-label": "Back", onclick: close }, icon("back")),
    h("div.session-title", h("div.track", title), sub ? h("div.row-meta", sub) : null),
    right || h("span", { style: "width:44px" }));
  const reveal = (path) => h("button.icon-btn", { "aria-label": `Show it on ${shortName(c)}`,
    onclick: () => { if (send(c, { type: "reveal", path })) toast(`Shown on ${shortName(c)}.`); } }, icon("open"));

  // One file
  const P = F.preview;
  if (P) {
    const path = F.folder ? joinPath(F.folder.path, P.name) : "";
    const head = P.head;
    const total = head?.chunks || 0;
    return [
      bar(P.name, [sizeText(head?.size ?? P.size), shortName(c)].filter(Boolean).join(" · "), reveal(path)),
      !head ? h("section.card.empty-card", nyo(64, { look: 0.3 }), h("p.sub", "Opening…"))
      : !P.done ? h("section.card.empty-card", nyo(64, { look: 0.3 }), h("p.sub", `Loading… ${Math.round(100 * P.got / Math.max(1, total))}%`),
          h("div.meter", { style: "width:70%" }, h("div", { style: `width:${Math.round(100 * P.got / Math.max(1, total))}%` })))
      : P.failed ? h("section.card.empty-card", h("p.sub", "This file couldn't be shown."))
      : head.kind === "text" ? [
          head.truncated ? h("p.note.center", `Showing the first ${sizeText(new TextEncoder().encode(P.text).length)}.`) : null,
          h("section.card.viewer", h("pre.text-view", P.text || " ")),
        ]
      : head.kind === "image" && P.src ? h("section.card.viewer.picture", h("img", { src: P.src, alt: P.name }))
      : h("section.card.empty-card",
          h(`span.tile.${fileIcon({ kind: head.kind })[1]}`, icon("file")),
          h("div.title", P.name),
          h("p.sub", head.note || `No preview for this kind of file. You can show it on ${shortName(c)}.`),
          h("button.btn", { onclick: () => { if (send(c, { type: "reveal", path })) toast(`Shown on ${shortName(c)}.`); } }, icon("open", 20), `Show on ${shortName(c)}`)),
    ];
  }

  // One folder
  const f = F.folder;
  const name = f ? (f.display === "~" ? "Home" : f.display.split(/[\\/]/).filter(Boolean).pop()) : "Files";
  return [
    bar(name, f ? `${shortName(c)} · ${f.display}` : shortName(c), f ? reveal(f.path) : null),
    !f ? h("section.card.empty-card", nyo(64, { look: 0.3 }), h("p.sub", F.asked ? "Opening…" : "Nothing to show."))
    : [
        h("section.card.list.files",
          f.parent ? h("button.row-btn", { onclick: () => browse(f.parent) },
            h("span.tile.paper", icon("up", 20)), h("span.row-main", h("span.row-title.plain", "Up a folder"))) : null,
          f.entries.length === 0 ? h("p.empty", "This folder is empty.")
          : f.entries.map((e) => {
              const [ic, tone] = fileIcon(e);
              return h("button.row-btn", { onclick: () => e.dir ? browse(joinPath(f.path, e.name)) : previewFile(e) },
                h(`span.tile.${tone}`, icon(ic, 20)),
                h("span.row-main", h("span.row-title.plain", e.name),
                  h("span.row-meta", e.dir ? (dateText(e.mtime) || "Folder") : [sizeText(e.size), dateText(e.mtime)].filter(Boolean).join(" · "))),
                e.dir ? icon("chevron", 18) : null);
            })),
        f.truncated ? h("p.note.center", "Only the first 300 items are shown.") : null,
        h("div.file-actions",
          h("button.btn.primary.block", { onclick: () => {
            const L = state.launch || (state.launch = { comp: c.id, project: null, starting: null });
            L.comp = c.id;
            L.folder = { path: f.path, name: name === "Home" ? "home folder" : name, display: f.display };
            state.files = null;
            state.tab = "launch";
            render();
          } }, icon("terminal", 20), "Start a session here")),
      ],
  ];
}

// ── The phone as trackpad and keyboard (docs/REMOTE_INPUT.md) ───────────────────────────────────────────────────

/** Opens the trackpad for computer `c` (behind Face ID: whoever holds the phone moves the computer's mouse). */
async function openPad(c) {
  if (!c) return;
  if (c.status !== "open") return toast(`${shortName(c)} is not connected.`);
  if (!(await unlock())) return;
  state.pad = { comp: c.id, mods: new Set(), keyboard: false };
  c.inputState = null;
  state.tab = "pad";
  padSend(c, [{ k: "hello" }]);
  render();
}

function closePad() {
  const P = state.pad;
  const c = comp(P?.comp);
  if (c) padSend(c, [{ k: "release" }]);
  state.pad = null;
  state.tab = "mac";
  render();
}

// Moves and scrolls are added up and sent about 25 times a second (the relay takes 30 frames a second from a phone).
const pad = { move: [0, 0], scroll: [0, 0], timer: null };
function padSend(c, events) {
  const e = [];
  if (pad.move[0] || pad.move[1]) e.push({ k: "move", dx: Math.round(pad.move[0] * 10) / 10, dy: Math.round(pad.move[1] * 10) / 10 });
  if (pad.scroll[0] || pad.scroll[1]) e.push({ k: "scroll", dx: Math.round(pad.scroll[0]), dy: Math.round(pad.scroll[1]) });
  pad.move = [0, 0]; pad.scroll = [0, 0];
  e.push(...events);
  if (e.length) send(c, { type: "input", e });
}
function padQueue(kind, dx, dy) {
  const P = state.pad;
  const c = comp(P?.comp);
  if (!c) return;
  pad[kind][0] += dx; pad[kind][1] += dy;
  if (!pad.timer) pad.timer = setTimeout(() => { pad.timer = null; padSend(c, []); }, 40);
}

/** The touch surface: one finger moves, a tap clicks, two fingers scroll, a two-finger tap right-clicks, hold then
 *  move drags. Built once per render; its state lives in the closure. */
function touchSurface(c) {
  const el = h("div.pad-surface", { role: "application", "aria-label": `Trackpad for ${shortName(c)}` },
    h("div.pad-hint", "Move with one finger · tap to click · two fingers scroll · two-finger tap right-clicks · hold, then move to drag"));
  let t0 = 0, moved = 0, maxFingers = 0, last = null, hold = null, dragging = false, lastTap = 0, lastAt = 0;
  const center = (ts) => { let x = 0, y = 0; for (const t of ts) { x += t.clientX; y += t.clientY; } return [x / ts.length, y / ts.length]; };
  el.addEventListener("touchstart", (e) => {
    e.preventDefault();
    if (e.touches.length === e.changedTouches.length) { t0 = performance.now(); moved = 0; maxFingers = 0; }
    maxFingers = Math.max(maxFingers, e.touches.length);
    last = center(e.touches); lastAt = performance.now();
    clearTimeout(hold);
    if (e.touches.length === 1 && !dragging) hold = setTimeout(() => {
      if (moved < 10) { dragging = true; el.classList.add("dragging"); padSend(c, [{ k: "down", b: "left" }]); navigator.vibrate?.(15); }
    }, 420);
  }, { passive: false });
  el.addEventListener("touchmove", (e) => {
    e.preventDefault();
    const now = performance.now();
    const p = center(e.touches);
    const dx = p[0] - last[0], dy = p[1] - last[1];
    const dt = Math.max(1, now - lastAt);
    last = p; lastAt = now;
    moved += Math.hypot(dx, dy);
    if (moved > 10 && !dragging) clearTimeout(hold);
    if (e.touches.length >= 2) padQueue("scroll", -dx * 1.4, -dy * 1.4);
    else {
      const speed = Math.hypot(dx, dy) / dt;                 // px per ms
      const gain = 1.4 + Math.min(3.2, speed * 2.2);        // slow and precise, fast and far
      padQueue("move", dx * gain, dy * gain);
    }
  }, { passive: false });
  const end = (e) => {
    e.preventDefault();
    if (e.touches.length) { last = center(e.touches); return; }
    clearTimeout(hold);
    if (dragging) { dragging = false; el.classList.remove("dragging"); padSend(c, [{ k: "up", b: "left" }]); return; }
    if (moved < 10 && performance.now() - t0 < 280) {
      if (maxFingers >= 2) padSend(c, [{ k: "click", b: "right", n: 1 }]);
      else { const now = performance.now(); padSend(c, [{ k: "click", b: "left", n: now - lastTap < 350 ? 2 : 1 }]); lastTap = now; }
      el.classList.add("tapped"); setTimeout(() => el.classList.remove("tapped"), 120);
    }
  };
  el.addEventListener("touchend", end, { passive: false });
  el.addEventListener("touchcancel", end, { passive: false });
  // A desktop browser: the mouse works too (handy for trying it out).
  let mdown = null;
  el.addEventListener("pointerdown", (e) => { if (e.pointerType === "mouse") { mdown = [e.clientX, e.clientY]; el.setPointerCapture(e.pointerId); } });
  el.addEventListener("pointermove", (e) => { if (e.pointerType === "mouse" && mdown) { padQueue("move", e.clientX - mdown[0], e.clientY - mdown[1]); mdown = [e.clientX, e.clientY]; } });
  el.addEventListener("pointerup", (e) => { if (e.pointerType === "mouse") mdown = null; });
  return el;
}

const MAC_MODS = [["cmd", "⌘"], ["alt", "⌥"], ["ctrl", "⌃"], ["shift", "⇧"]];
const PC_MODS = [["ctrl", "Ctrl"], ["alt", "Alt"], ["shift", "Shift"], ["win", "Win"]];
const KEYS = [["esc", "Esc"], ["tab", "Tab"], ["left", "←"], ["up", "↑"], ["down", "↓"], ["right", "→"], ["backspace", "⌫"], ["enter", "↵"]];

function padTab() {
  const P = state.pad;
  const c = comp(P?.comp);
  if (!P || !c) { state.tab = "mac"; return computerTab(); }
  const isMac = c.os !== "windows" && c.os !== "linux";
  const mods = [...P.mods];
  const press = (key) => { padSend(c, [{ k: "key", key, mods }]); if (P.mods.size) { P.mods.clear(); render(); } };
  const st = c.inputState;
  return [
    h("div.session-bar",
      h("button.icon-btn", { "aria-label": "Back", onclick: closePad }, icon("back")),
      h("div.session-title", h("div.track", "Trackpad"), h("div.row-meta", shortName(c))),
      h("button.icon-btn" + (P.keyboard ? ".on" : ""), { "aria-label": P.keyboard ? "Hide the keyboard" : "Show the keyboard", "aria-pressed": P.keyboard ? "true" : "false",
        onclick: () => { P.keyboard = !P.keyboard; render(); if (P.keyboard) setTimeout(() => document.getElementById("kbd")?.focus(), 30); } }, icon("keyboard"))),
    many() ? picker((x) => { padSend(c, [{ k: "release" }]); P.comp = x.id; x.inputState = null; padSend(x, [{ k: "hello" }]); }) : null,
    c.status !== "open" ? h("p.note.center", `${shortName(c)} is not connected.`)
      : st && !st.ok ? h("section.card.tinted", h("div.card-body", h("div.title", "One thing on the computer"), h("p.sub", st.note || "This computer can't take the trackpad yet."))) : null,
    touchSurface(c),
    h("div.pad-buttons",
      ...["left", "right"].map((b) => h("button.pad-btn", {
        "aria-label": b === "left" ? "Left click (hold to keep pressed)" : "Right click",
        onpointerdown: (e) => { e.preventDefault(); padSend(c, [{ k: "down", b }]); },
        onpointerup: () => padSend(c, [{ k: "up", b }]), onpointercancel: () => padSend(c, [{ k: "up", b }]),
      }, b === "left" ? "Left" : "Right"))),
    P.keyboard ? h("div.keys",
      h("div.key-row", (isMac ? MAC_MODS : PC_MODS).map(([m, label]) => h("button.key.mod" + (P.mods.has(m) ? ".on" : ""), {
        "aria-pressed": P.mods.has(m) ? "true" : "false", onclick: () => { P.mods.has(m) ? P.mods.delete(m) : P.mods.add(m); render(); setTimeout(() => document.getElementById("kbd")?.focus(), 0); } }, label))),
      h("div.key-row", KEYS.map(([k, label]) => h("button.key", { "aria-label": k, onclick: () => { press(k); document.getElementById("kbd")?.focus(); } }, label))),
      // What the phone's own keyboard types goes through this box (kept empty).
      h("textarea#kbd.kbd-sink", { autocapitalize: "off", autocomplete: "off", autocorrect: "off", spellcheck: "false", "aria-label": "Type on the computer",
        placeholder: "Type here", rows: "1",
        onbeforeinput: (e) => {
          e.preventDefault();
          const t = e.inputType;
          if (t === "insertText" || t === "insertFromPaste" || t === "insertReplacementText") {
            const text = e.data ?? e.dataTransfer?.getData("text/plain") ?? "";
            if (!text) return;
            if (P.mods.size && text.length === 1) press(text.toLowerCase());
            else padSend(c, [{ k: "text", t: text.slice(0, 500) }]);
          } else if (t === "insertLineBreak" || t === "insertParagraph") press("enter");
          else if (t === "deleteContentBackward" || t === "deleteWordBackward") press("backspace");
          else if (t === "deleteContentForward") press("delete");
        },
        oninput: (e) => { const v = e.target.value; e.target.value = ""; if (v) padSend(c, [{ k: "text", t: v.slice(0, 500) }]); },
      })) : null,
  ];
}

function launchTab() {
  const L = state.launch || (state.launch = { comp: cur()?.id, project: null, starting: null });
  const c = comp(L.comp) || cur();
  L.comp = c?.id;
  const projects = c?.mac?.projects || [];
  if (!projects.some((p) => p.id === L.project)) L.project = projects[0]?.id ?? null;
  const bar = (title) => h("div.session-bar",
    h("button.icon-btn", { "aria-label": "Back", onclick: () => { state.launch = null; state.tab = "now"; render(); } }, icon("back")),
    h("div.session-title", h("div.track", title)), h("span", { style: "width:44px" }));
  if (L.starting) {
    const late = Date.now() - L.starting.at > 60_000;
    return [bar("New session"),
      h("section.card.empty-card", nyo(84, { look: 0.3 }),
        h("div.title", L.starting.launched ? `Claude Code is starting in ${L.starting.name}…` : `Asking ${c ? shortName(c) : "the computer"} to start ${L.starting.name}…`),
        h("p.sub", late ? "It is open in a terminal on the computer. It shows on the Now tab once Claude Code is up."
                        : "This opens as soon as Claude Code says hello."))];
  }
  const pickRow = (on, tone, ic, title, meta, onclick, tail) => h("button.row-btn.pick" + (on ? ".on" : ""),
    { type: "button", "aria-pressed": on ? "true" : "false", onclick },
    h(`span.tile.${on ? "tan" : tone}`, icon(ic, 20)),
    h("span.row-main", h("span.row-title", title), meta ? h("span.row-meta", meta) : null),
    on ? h("span.check", icon("check", 18)) : tail || null);
  return [
    bar("New session"),
    picker((x) => { L.comp = x.id; L.project = null; L.folder = null; send(x, { type: "status" }); }),
    !c?.mac ? h("section.card.empty-card", h("p.sub", c?.status === "open" ? "Loading the folders…" : `${c ? shortName(c) : "The computer"} is not connected.`))
    : h("form", { onsubmit: (e) => { e.preventDefault(); startSession(e.target); } },
        section("Folder"),
        h("section.card.list",
          L.folder ? pickRow(true, "sun", "folder", L.folder.name, L.folder.display, () => {}) : null,
          projects.map((p) => pickRow(!L.folder && p.id === L.project, "paper", "terminal", p.name, p.where,
            () => { L.folder = null; L.project = p.id; render(); })),
          pickRow(false, "sun", "folder", L.folder ? "Choose another folder" : "Browse folders",
            `Any folder in your home folder on ${c ? shortName(c) : "the computer"}`,
            () => openFiles(c, { path: L.folder?.path || "", pick: true }), icon("chevron", 18))),
        !projects.length && !L.folder ? h("p.note", "Pick a folder to start in. Folders you start sessions in show here next time.") : null,
        section("What should Claude do?"),
        h("textarea#launch-prompt.field", { placeholder: "Leave empty to just open Claude Code", "aria-label": "What should Claude do?" }),
        h("p.note", "The computer opens a terminal in that folder and starts Claude Code with this. Follow it and talk to it from here."),
        h("button.btn.primary.block", { type: "submit", disabled: !L.folder && !L.project ? "" : null }, "Start session")),
  ];
}

function settingsTab() {
  const hasFace = !!load(STORE.cred);
  const alerts = alertsComputer();
  return [
    h("div.session-bar",
      h("button.icon-btn", { "aria-label": "Done", onclick: () => { state.tab = "now"; render(); } }, icon("back")),
      h("div.session-title", h("div.track", "Settings")), h("span", { style: "width:44px" })),
    section("Your computers"),
    h("section.card.list",
      state.computers.map((c) => {
        const { device, account } = nameParts(c);
        const short = shortName(c);
        const other = short === device ? account : device;
        const inUse = many() && c === cur();
        return h("div.computer",
          h(`span.tile.${c.status === "open" ? "mint" : "paper"}`, icon(osIcon(c))),
          h("span.row-main",
            h("span.row-title", short),
            h("span.row-meta.wrap", h("span.dot." + dotOf(c)), [other || null, statusWord(c)].filter(Boolean).join(" · ")),
            h("span.row-meta.faint", `via ${new URL(c.p.relay.replace(/^ws/, "http")).host}`)),
          h("span.computer-actions",
            many() ? (inUse ? h("span.tag", "In use") : h("button.btn.small", { onclick: () => { state.current = c.id; saveComputers(); render(); } }, "Use")) : null,
            isIOS && !standalone() ? h("button.link", { onclick: () => copyForApp(c) }, "Copy for the app") : null,
            h("button.link.danger", { onclick: () => removeComputer(c) }, "Remove")));
      }),
      h("div.card-body", h("button.btn.primary.block", { onclick: () => { state.tab = "add"; render(); } }, icon("plus", 20), "Add a computer"))),
    h("p.note", "Each computer is paired with its own code, end-to-end encrypted. Removing one cuts it off at once."),
    !standalone() && !isIOS ? [section("Install"),
      h("section.card", h("div.card-body",
        h("p.sub", "Put Nyeko on your home screen: it opens like an app, and stays paired."),
        installPrompt
          ? h("button.btn.primary", { onclick: async () => { installPrompt.prompt(); await installPrompt.userChoice; installPrompt = null; render(); } }, "Install Nyeko")
          : h("p.note", "Chrome menu ⋮ → Install app (or Add to Home screen).")))] : null,
    section(isIOS ? "Face ID" : "Screen lock"),
    h("section.card.setting",
      h("span.tile.fur", icon("shield")),
      h("span.row-main", h("span.row-title", hasFace ? "On" : "Off"),
        h("span.row-meta.wrap", hasFace ? `Allow, answers, messages and power actions ask for your ${lockName}.` : `Allow and answers need your ${lockName}. Deny never does.`)),
      h("button.btn.small" + (hasFace ? "" : ".primary"), { onclick: setupFaceId }, hasFace ? "Redo" : "Set up")),
    section("Alerts"),
    h("section.card.setting",
      h("span.tile.pink", icon("bell")),
      h("span.row-main", h("span.row-title", alerts && load(STORE.alerts) === alerts.id ? "On" : "Off"),
        h("span.row-meta.wrap", !standalone() && isIOS ? "Alerts need Nyeko on the Home Screen: Share → Add to Home Screen, open it from there, and pair again."
          : alerts ? `When Claude needs you on ${shortName(alerts)} and Nyeko is closed, your phone shows “Nyo needs you”. Nothing about the command is in the alert.`
          : "None of your computers can send alerts to this web app yet.")),
      alerts && load(STORE.alerts) !== alerts.id ? h("button.btn.small.primary", { onclick: enableAlerts }, "Turn on") : null),
    h("p.version", `Nyeko web app · ${VERSION}`),
  ];
}

function androidScreen() {
  const o = state.androidOffer;
  const download = state.apk
    ? h("a.btn" + (o.noApp ? ".primary" : "") + ".block", { href: "/downloads/android" },
        `Download the app (${state.apk.versionName}, ${(state.apk.size / 1048576).toFixed(0)} MB)`)
    : h("p.note", "No Nyeko for Android build is published yet (GitHub Actions → android → Run workflow).");
  return h("main.screen.welcome",
    nyo(132, { look: 0.15 }),
    h("h1.hero", "Nyeko for Android"),
    h("p.lede", "Nyo on your screen, the island from the camera hole, alerts and widgets: the app does what a web page can't."),
    h("section.card", h("div.card-body",
      o.noApp
        ? [h("div.title", "The Nyeko app isn't installed yet"),
           h("ol.steps", h("li", "Tap Download the app, then open the file."), h("li", "Allow installs from Chrome when Android asks, and install."),
             h("li", "Come back here and tap Open in the Nyeko app: it pairs with your Mac.")),
           download,
           h("button.btn.block", { onclick: openApp }, "Open in the Nyeko app")]
        : [h("div.title", "Pair the Nyeko app with your Mac"),
           h("p.sub", "It opens the app and asks you to confirm. Nothing is stored in this browser."),
           h("button.btn.primary.block", { onclick: openApp }, "Open in the Nyeko app"),
           download])),
    h("button.link", { onclick: () => { const code = location.hash; state.androidOffer = null;
      history.replaceState(null, "", location.pathname); pair(code); } }, "Use Nyeko in the browser instead"));
}

function pairScreen() {
  const fromLink = location.hash.startsWith("#pair=") || location.hash.startsWith("#setup=");
  const adding = state.computers.length > 0;
  return h("main.screen.welcome",
    adding ? h("div.session-bar",
      h("button.icon-btn", { "aria-label": "Cancel", onclick: () => { state.tab = "settings"; render(); } }, icon("back")),
      h("div.session-title"), h("span", { style: "width:44px" })) : null,
    nyo(adding ? 104 : 140, { look: fromLink ? 0.3 : 0 }),
    h("h1.hero", adding ? "Add a computer" : "Nyeko"),
    h("p.lede", adding ? "Pair another Mac or your Windows PC: each one shows here with its own sessions and controls."
                       : "Nyo in your pocket: approve, answer, chat and control your computers."),
    // The camera opened this code in Safari, which keeps its own storage: the Home Screen app gets it through the
    // iPhone's clipboard (works for a Mac and a Windows PC alike).
    !standalone() && fromLink && isIOS ? h("section.card.tinted", h("div.card-body",
      h("div.title", "Add this computer to Nyeko"),
      h("button.btn.primary.block", { onclick: async () => {
        try { await navigator.clipboard.writeText(location.href); toast("Copied. Now open Nyeko from your Home Screen."); }
        catch { toast("Copy did not work: long-press the address bar and copy it."); }
      } }, "Copy pairing code"),
      h("ol.steps", h("li", "Open Nyeko from your Home Screen (not there yet? Share › Add to Home Screen first)."),
        h("li", "Settings › Add a computer › Paste pairing code. Your other computers stay.")),
      h("button.link", { onclick: () => addComputer(location.hash) }, "Use it in Safari only (the Home Screen app won't have it)"))) : null,
    // In Safari on the iPhone, without a code: install first (a pairing made in Safari stays in Safari).
    !standalone() && !fromLink && isIOS ? h("section.card.tinted", h("div.card-body",
      h("div.title", "Install Nyeko first"),
      h("ol.steps", h("li", "Tap Share (the square with an arrow), then Add to Home Screen → Add."),
        h("li", "Open Nyeko from the Home Screen and pair there: it keeps its own pairing, alerts and Face ID.")),
      h("a.link", { href: "/download.html" }, "All the steps"))) : null,
    h("section.card", h("div.card-body",
      h("div.title", "Pair with a computer"),
      h("p.sub", isIOS ? "Scan the computer's QR code (Nyeko → Phone) with the Camera app and tap Copy pairing code, or on a Mac use Copy pairing code. Then paste it here."
                       : "Scan the QR code on the computer (Nyeko → Phone) with your camera, or paste its pairing code or link."),
      h("button.btn.primary.block", { onclick: async () => {
        try { addComputer(await navigator.clipboard.readText()); } catch { toast("Paste the code in the box below."); }
      } }, "Paste pairing code"),
      h("textarea#code.field", { autocomplete: "off", autocapitalize: "off", spellcheck: "false", placeholder: "Or paste the code here", "aria-label": "Pairing code" }),
      h("button.btn.block", { onclick: () => addComputer(document.getElementById("code").value) }, "Pair"))));
}

function tabs() {
  const need = state.computers.reduce((n, c) => n + (c.approval ? 1 : 0) + (c.question ? 1 : 0), 0);
  const c = cur();
  const tab = (id, ic, label, badge) => h("button", { "aria-current": state.tab === id ? "page" : null,
    onclick: () => { state.tab = id; render(); scrollTo(0, 0); } }, icon(ic, 22), h("span", label), badge ? h("span.badge", String(badge)) : null);
  return h("nav.tabs", h("div.tabs-inner",
    tab("now", "now", "Now", need || null),
    tab("mac", c?.os === "windows" && !many() ? "desktop" : "laptop", many() ? "Computers" : c?.os === "windows" ? "PC" : "Mac"),
    tab("nyo", "cat", "Nyo")));
}

// ── render ───────────────────────────────────────────────────────────────────────────────────────────

let padShown = "";
function render() {
  // The trackpad isn't drawn again for status updates: a finger on it would lose its touch, the keyboard its focus.
  if (state.tab === "pad" && state.pad && !state.androidOffer) {
    const c = comp(state.pad.comp);
    const key = JSON.stringify([state.pad.comp, state.pad.keyboard, [...state.pad.mods], c?.status, c?.inputState, many(), state.computers.map((x) => x.status)]);
    if (key === padShown && app.querySelector(".pad-surface")) return;
    padShown = key;
  } else padShown = "";
  // Keep what is being typed (a status update re-renders the screen).
  const active = document.activeElement;
  const keep = active && active.id ? { id: active.id, value: active.value, start: active.selectionStart } : null;
  const draft = document.getElementById("ask")?.value;
  const sayDraft = document.getElementById("say")?.value;
  const launchDraft = document.getElementById("launch-prompt")?.value;
  // In a session: stay at the bottom when new lines arrive, unless you scrolled up to read.
  if (state.tab === "session" && state.thread) {
    state.thread.stick = innerHeight + scrollY >= document.body.scrollHeight - 120;
  }
  const keepY = scrollY;

  let view;
  const paired = state.computers.length > 0;
  if (state.androidOffer) view = androidScreen();
  else if (!paired || state.tab === "add") view = pairScreen();
  else {
    const body = { now: nowTab, mac: computerTab, nyo: nyoTab, settings: settingsTab, session: sessionTab, launch: launchTab, files: filesTab, pad: padTab }[state.tab]?.() ?? nowTab();
    const main = ["now", "mac", "nyo"].includes(state.tab);
    view = h("main.screen" + (state.tab === "session" ? ".chatting" : "") + (state.tab === "nyo" ? ".chatting" : ""), main ? header() : null, body);
  }
  app.replaceChildren(view, paired && !state.androidOffer && !["settings", "session", "launch", "add", "files", "pad"].includes(state.tab) ? tabs() : "",
    state.toast ? h("div.toast", { role: "status" }, state.toast) : "");

  const ask = document.getElementById("ask");
  if (ask && draft) ask.value = draft;
  const launchBox = document.getElementById("launch-prompt");
  if (launchBox && launchDraft) launchBox.value = launchDraft;
  const sayBox = document.getElementById("say");
  if (sayBox && sayDraft) { sayBox.value = sayDraft; sayBox.style.height = Math.min(160, sayBox.scrollHeight) + "px"; }
  const search = document.getElementById("appsearch");
  if (search && !keep) search.value = state.appSearch;
  if (state.tab === "session" && state.thread) scrollTo(0, state.thread.stick ? document.body.scrollHeight : keepY);
  if (keep) {
    const el = document.getElementById(keep.id);
    if (el) { el.value = keep.value; el.focus(); try { el.setSelectionRange(keep.start, keep.start); } catch {} }
  }
  // Count down an approval, and move the progress bar, once a second while something on screen needs it.
  const c = cur();
  const needsTick = state.computers.some((x) => x.approval) || state.launch?.starting
    || (state.tab === "mac" && (c?.mac?.nowPlaying?.playing || c?.mac?.timer));
  if (needsTick && !ticker) ticker = setInterval(() => { if (!document.activeElement?.id) render(); }, 1000);
  if (!needsTick && ticker) { clearInterval(ticker); ticker = null; }
}

// ── start ────────────────────────────────────────────────────────────────────────────────────────────

// The computers paired on this phone (an older single pairing becomes the first of the list).
{
  let list = load(STORE.computers);
  if (!Array.isArray(list)) {
    const old = load(STORE.oldPairing);
    list = old ? [old] : [];
    save(STORE.computers, list);
    save(STORE.oldPairing, null);
  }
  state.computers = list.filter(validPairing).map(newComputer);
  // phone/tests/preview.html only: a still picture of the app with made-up computers, for checking the design. Nothing connects.
  if (PREVIEW) {
    state.computers = PREVIEW.computers.map((x) => Object.assign(newComputer(x.p), x.live));
    Object.assign(state, PREVIEW.state || {});
  }
  state.current = load(STORE.current) || state.computers[0]?.id || null;
  if (load(STORE.alerts) === true) save(STORE.alerts, alertsComputer()?.id ?? null);   // alerts were on for the one Mac
}

// The trackpad never leaves a button held when the phone locks or switches app.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden" && state.pad) { const c = comp(state.pad.comp); if (c) padSend(c, [{ k: "release" }]); }
});

if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});
if (location.hash.startsWith("#pair=") && (standalone() || !isIOS)) {
  // Android in the browser, and the Mac sent the app's pairing too: the Nyeko app first (or its download).
  const link = !isIOS && !standalone() ? androidLinkOf(location.hash) : null;
  if (link) {
    state.androidOffer = { link, noApp: new URLSearchParams(location.search).has("noapp") };
    checkApk();
    if (!state.androidOffer.noApp) setTimeout(openApp, 300);   // Chrome may want a tap: the button below does the same
  } else {
    addComputer(location.hash);
  }
}
// A new computer's setup code, scanned with the camera (Android) or opened in the Home Screen app.
if (location.hash.startsWith("#setup=") && (standalone() || !isIOS)) setupComputer(location.hash);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") return;
  for (const c of state.computers) { c.channel?.wake(); if (c.status === "open") send(c, { type: "status" }); }
});
if (!PREVIEW) for (const c of state.computers) if (!c.channel) connect(c);
render();
