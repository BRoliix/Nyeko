// Nyeko phone web app. Talks to Nyeko on your computers through your own relay, end to end encrypted (relay.js).
// Several computers can be paired (your Macs, your Windows PC): one encrypted channel each, everything shown together.
// Untrusted text (commands, session lines, Nyo's replies) is only ever set as text, never as HTML.
import { PhoneChannel, b64url, fromB64url, random } from "./relay.js";
import { parseSetup, sendSetup } from "./setup.js";

const VERSION = "2026-11-20 · nyeko 7";   // shown in Settings: tells which web app the phone runs
const STORE = { computers: "nyeko.computers", current: "nyeko.current", cred: "nyeko.faceid", alerts: "nyeko.alerts", oldPairing: "nyeko.pairing" };
const APPROVAL_TTL = 115_000; // the computer dismisses a request after 115 s
const app = document.getElementById("app");

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
    else if (k === "style") el.setAttribute("style", v);
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

const icon = (name) => {
  const paths = {
    play: "M8 5v14l11-7z", pause: "M7 5h4v14H7zM13 5h4v14h-4z", next: "M6 6l8.5 6L6 18zM16 6h2v12h-2z",
    prev: "M18 6l-8.5 6L18 18zM6 6h2v12H6z", gear: "M12 8a4 4 0 100 8 4 4 0 000-8zm8.9 3H19a7 7 0 00-1-2.4l1.4-1.4-1.6-1.6L16.4 7A7 7 0 0014 6V4h-2.1v2a7 7 0 00-2.4 1L8.1 5.6 6.5 7.2 7.9 8.6A7 7 0 007 11H5v2h2a7 7 0 001 2.4l-1.4 1.4 1.6 1.6 1.4-1.4a7 7 0 002.4 1V20h2v-2a7 7 0 002.4-1l1.4 1.4 1.6-1.6-1.4-1.4A7 7 0 0019 13h1.9z",
    note: "M9 18V6l10-2v12M9 18a2.5 2.5 0 11-5 0 2.5 2.5 0 015 0zm10-2a2.5 2.5 0 11-5 0 2.5 2.5 0 015 0z",
  };
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 24 24"); svg.setAttribute("width", "24"); svg.setAttribute("height", "24");
  svg.setAttribute("aria-hidden", "true");
  const p = document.createElementNS(ns, "path");
  p.setAttribute("d", paths[name]);
  if (name === "note") { p.setAttribute("fill", "none"); p.setAttribute("stroke", "currentColor"); p.setAttribute("stroke-width", "2"); }
  else p.setAttribute("fill", "currentColor");
  svg.append(p);
  return svg;
};

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
  const project = (c.mac?.projects || []).find((p) => p.id === L.project);
  if (!project) return toast("Pick a folder first.");
  if (c.status !== "open") return toast(`${c.desktop} is not connected.`);
  if (!(await unlock())) return;
  const prompt = form.querySelector("textarea").value.trim();
  const id = b64url(random(9));
  if (!send(c, { type: "launch", id, project: project.id, prompt })) return toast(`${c.desktop} is not connected.`);
  L.starting = { id, name: project.name, at: Date.now(), launched: false };
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

function header() {
  const n = state.computers.length;
  const on = state.computers.filter((c) => c.status === "open").length;
  const one = state.computers[0];
  const [dot, text] = n === 1 ? [dotOf(one), one.status === "open" ? one.desktop : statusWord(one)]
    : [on === n ? "on" : on ? "wait" : "off", `${on} of ${n} computers connected`];
  return h("header.top",
    h("img.cat", { src: "/icons/icon-192.png", alt: "" }),
    h("button.grow", { style: "background:none;border:none;text-align:left;padding:0;cursor:pointer", "aria-label": "Your computers",
      onclick: () => { state.tab = "settings"; render(); } },
      h("h1", "Nyeko"), h("span.status", h("span.dot." + dot), text)),
    h("button.btn.round", { "aria-label": "Settings", onclick: () => { state.tab = "settings"; render(); } }, icon("gear")));
}

/** Chips to pick the computer a tab talks to (only with more than one). */
function picker(onPick) {
  if (!many()) return null;
  const c0 = cur();
  return h("div.opts", { style: "margin:0 0 6px" }, state.computers.map((c) =>
    h("button.opt" + (c === c0 ? ".on" : ""), { "aria-pressed": c === c0 ? "true" : "false",
      onclick: () => { state.current = c.id; saveComputers(); onPick?.(c); render(); } },
      h("span.dot." + dotOf(c), { style: "display:inline-block;margin-right:6px" }), c.desktop)));
}

function approvalCard(c) {
  const a = c.approval;
  if (!a) return null;
  const left = Math.max(0, Math.ceil((a.at + APPROVAL_TTL - Date.now()) / 1000));
  if (left === 0) { c.approval = null; return null; }
  return h("section.card.alert", { "aria-label": "Permission request" },
    h("div.row", h("div.grow", h("div.title", "Claude needs you"), h("div.sub", `Wants to use ${a.tool}${many() ? ` · on ${c.desktop}` : ""}`)),
      h("span.timer.small.muted", `${left}s`)),
    h("p.mono", a.command),
    a.truncated ? h("p.small.muted", "The command is longer than shown: allow it on the computer, or deny it here.") : null,
    a.sent ? h("p.small.muted", "Sent. Waiting for the computer…")
      : h("div.row",
          h("button.btn.grow", { onclick: () => decide(c, false) }, "Deny"),
          a.truncated ? null : h("button.btn.primary.grow", { onclick: () => decide(c, true) }, "Allow")));
}

function questionCard(c) {
  const q = c.question;
  if (!q) return null;
  return h("section.card.alert", { "aria-label": "Question from Claude" },
    h("div.title", many() ? `Claude asks · on ${c.desktop}` : "Claude asks"),
    q.questions.map((item, i) => h("div",
      h("p", { style: "font-weight:700;margin:12px 0 4px" }, item.question),
      h("div.opts", item.options.map((o) => {
        const on = q.picks[i].includes(o.label);
        return h("button.opt" + (on ? ".on" : ""), { "aria-pressed": on ? "true" : "false", onclick: () => {
          if (item.multiSelect) q.picks[i] = on ? q.picks[i].filter((l) => l !== o.label) : [...q.picks[i], o.label];
          else q.picks[i] = [o.label];
          render();
        } }, o.label, o.description ? h("small", o.description) : null);
      })))),
    q.sent ? h("p.small.muted", "Sent. Waiting for the computer…")
      : h("button.btn.primary.block", { onclick: () => answer(c) }, "Send answer"));
}

function nowTab() {
  const rows = state.computers.flatMap((c) => c.sessions.map((x) => ({ c, x })));
  const u = cur()?.usage?.claude;
  return [
    state.computers.map((c) => [approvalCard(c), questionCard(c)]),
    // Android in the browser: Nyo on the screen and the camera-hole island need the app (a web page can't draw over apps).
    !isIOS && !load("nyeko.appHint.hidden") ? h("section.card.alert",
      h("div.title", "Want Nyo on your screen?"),
      h("p.sub", "Nyo floating over your other apps and the island from the camera hole come with the Nyeko app for Android."),
      h("div.row", { style: "gap:10px;flex-wrap:wrap" },
        h("a.btn.primary", { href: "/download.html", style: "text-decoration:none;color:inherit" }, "Get the app"),
        h("button.btn", { onclick: () => { save("nyeko.appHint.hidden", true); render(); } }, "Not now"))) : null,
    h("h2", many() ? "Coding sessions · all computers" : "Coding sessions"),
    h("section.card", rows.length === 0 ? h("p.empty", "No coding session is running.") :
      h("div.list", rows.map(({ c, x }) => h("button.item", {
          style: "display:block;width:100%;text-align:left;background:none;border:none;padding:12px 0;cursor:pointer",
          "aria-label": `${x.agent}${many() ? ` on ${c.desktop}` : ""}: open the session`,
          onclick: () => openSession(c, x),
        },
        h("div.row", h("div.grow", h("div.title", x.agent),
            h("div.sub", [many() ? c.desktop : null, x.statusText || null].filter(Boolean).join(" · "))),
          h("span.chip." + sessionClass(x.state), h("i"), sessionLabel(x.state))))))),
    rows.length ? h("p.small.muted", { style: "margin:-6px 4px 0" }, "Tap a session to read it and talk to Claude.") : null,
    h("button.btn.block", { style: "margin-top:12px", onclick: newSession }, "＋ New session"),
    u ? [h("h2", "Claude plan"), h("section.card",
      [["5-hour window", u.fiveHour], ["This week", u.sevenDay]].filter(([, w]) => w).map(([label, w]) =>
        h("div", { style: "margin-bottom:10px" }, h("div.row", h("span.grow.small", label), h("b.small", `${w.pct}%`)),
          h("div.bar", h("div", { style: `width:${w.pct}%` })))))] : null,
  ];
}

function computerTab() {
  const c = cur();
  if (!c) return null;
  const m = c.mac;
  const kind = kindOf(c);
  if (!m) return [picker(), h("section.card", h("p.empty", c.status === "open" ? `Loading ${c.desktop}…` : `${c.desktop} is not connected.`))];
  const ctl = (action, extra) => control(c, action, extra);
  const np = m.nowPlaying;
  let pos = np?.position ?? 0;
  if (np?.playing && np?.duration) pos = Math.min(np.duration, pos + (Date.now() - c.macAt) / 1000);
  const t = m.timer;
  const tLeft = t ? Math.max(0, (t.remaining ?? 0) - (t.paused ? 0 : Math.floor((Date.now() - c.macAt) / 1000))) : 0;
  const mmss = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
  const apps = (c.apps || []).filter((a) => a.name.toLowerCase().includes(state.appSearch.toLowerCase())).slice(0, 60);
  return [
    picker(),
    h("h2", "Now playing"),
    h("section.card", np ? [
      h("div.row", h("div.art", icon("note")),
        h("div.grow", h("div.title", np.title), h("div.sub", np.artist), h("div.small.muted", np.source))),
      np.duration ? h("div.row", { style: "margin-top:12px" }, h("span.small.timer", mmss(pos)),
        h("div.bar.grow", h("div", { style: `width:${Math.round(100 * pos / np.duration)}%` })), h("span.small.timer", mmss(np.duration))) : null,
      h("div.row", { style: "justify-content:center;margin-top:14px;gap:16px" },
        h("button.btn.round", { "aria-label": "Previous track", onclick: () => ctl("previous") }, icon("prev")),
        h("button.btn.round.big.primary", { "aria-label": np.playing ? "Pause" : "Play", onclick: () => ctl("playPause") }, icon(np.playing ? "pause" : "play")),
        h("button.btn.round", { "aria-label": "Next track", onclick: () => ctl("next") }, icon("next"))),
    ] : h("p.empty", `Nothing is playing on ${c.desktop}.`)),
    h("h2", "Sound"),
    h("section.card",
      h("div.row", { style: "gap:10px" },
        h("button.btn.round", { "aria-label": "Volume down", onclick: () => ctl("volumeDown") }, "−"),
        h("div.grow", h("div.bar", h("div", { style: `width:${m.muted ? 0 : (m.volume ?? 0)}%` })),
          h("div.small.muted", { style: "margin-top:4px;text-align:center" }, m.muted ? "Muted" : m.volume != null ? `${m.volume}%` : "")),
        h("button.btn.round", { "aria-label": "Volume up", onclick: () => ctl("volumeUp") }, "+"),
        h("button.btn", { onclick: () => ctl("mute") }, m.muted ? "Unmute" : "Mute"))),
    h("h2", `Your ${kind}`),
    h("section.card",
      m.next ? h("div.item", h("div.small.muted", "Next up"), h("div.title", m.next.title), h("div.sub", m.next.when)) : null,
      m.timer !== undefined || c.os === "macos" ? h("div.item.row",
        h("div.grow", h("div.title", "Focus timer"), h("div.sub", t ? `${t.phase === "work" ? "Work" : "Break"} · ${mmss(tLeft)} left` : "25 min of work, 5 of rest")),
        h("button.btn" + (t ? "" : ".mint"), { onclick: () => ctl("timer") }, t ? "Stop" : "Start")) : null,
      m.recording !== undefined ? h("div.item.row",
        h("div.grow", h("div.title", "Notetaker"), h("div.sub", m.recording ? "Recording a meeting" : "Record and transcribe a call")),
        h("button.btn" + (m.recording ? "" : ".primary"), { onclick: () => ctl("record") }, m.recording ? "Stop" : "Record")) : null,
      h("div.item.row",
        h("div.grow", h("div.title", "Screenshot"), h("div.sub", `Of the screen, kept on the ${kind}`)),
        h("button.btn", { onclick: () => { if (ctl("screenshot")) toast(`Screenshot taken on ${c.desktop}.`); } }, "Take")),
      m.battery ? h("div.item.small.muted", `Battery ${m.battery.percent}%${m.battery.charging ? " · charging" : ""}`) : null),
    h("h2", "Lock and power"),
    h("section.card",
      h("div.apps", { style: "grid-template-columns:repeat(3,1fr)" },
        h("button.btn", { onclick: () => { if (ctl("lock")) toast(`${c.desktop} is locked.`); } }, "Lock"),
        h("button.btn", { onclick: () => ctl("displaySleep") }, "Screen off"),
        h("button.btn", { onclick: () => { if (confirm(`Put ${c.desktop} to sleep? The phone loses it until it wakes.`)) ctl("sleep"); } }, "Sleep")),
      h("div.row", { style: "gap:10px;margin-top:12px" },
        h("button.btn.grow", { onclick: () => power(c, "restart") }, "Restart"),
        h("button.btn.grow", { style: "color:var(--red)", onclick: () => power(c, "shutdown") }, "Shut down")),
      h("p.small.muted", { style: "margin:10px 0 0" }, `Restart and shut down ask for your ${lockName}; apps with unsaved work can still object.`)),
    m.apps?.length ? [h("h2", "Quick launch"),
      h("section.card", h("div.apps", m.apps.map((a) => h("button.btn", { onclick: () => { if (ctl("open", { app: a.id })) toast(`Opening ${a.name}…`); } }, a.name))))] : null,
    h("h2", "Open any app"),
    h("section.card",
      c.apps == null
        ? h("button.btn.block", { onclick: () => { if (send(c, { type: "listApps" })) { c.apps = []; render(); } else toast(`${c.desktop} is not connected.`); } }, `Show the apps on ${c.desktop}`)
        : [h("input#appsearch", { type: "text", placeholder: "Search apps", autocomplete: "off", "aria-label": "Search apps",
              oninput: (e) => { state.appSearch = e.target.value; render(); } }),
           h("div.list", { style: "margin-top:8px" }, c.apps.length === 0 ? h("p.empty", "Loading…")
             : apps.map((a) => h("button.item", { style: "display:block;width:100%;text-align:left;background:none;border:none;padding:12px 0;font-weight:700;cursor:pointer",
                 onclick: () => { if (ctl("openAny", { app: a.id })) toast(`Opening ${a.name} on ${c.desktop}…`); } }, a.name)))]),
  ];
}

function nyoTab() {
  const c = cur();
  const msgs = state.chat;
  return [
    picker(),
    h("div.chat", { style: "margin-top:6px" },
      msgs.length === 0 ? h("p.empty", `Ask Nyo anything, or tell it what to do on ${c?.desktop || "your computer"}: “pause the music”, “start a timer”, “what's next?”.`) : null,
      msgs.map((m) => h("div.msg." + (m.me ? "me" : "nyo"), many() && !m.me ? h("small.from", comp(m.comp)?.desktop || "") : null, m.text)),
      state.waiting.size ? h("div.msg.nyo.muted", "Nyo is thinking…") : null),
    h("div.composer", h("form", { onsubmit: (e) => {
      e.preventDefault();
      const input = e.target.querySelector("input");
      const text = input.value.trim();
      if (!text || !c) return;
      const id = b64url(random(9));
      if (!send(c, { type: "ask", id, text })) return toast(`${c.desktop} is not connected.`);
      state.chat.push({ me: true, text, comp: c.id });
      state.waiting.set(id, c.id);
      input.value = "";
      render();
    } },
      h("input#ask", { type: "text", placeholder: many() ? `Message Nyo on ${c?.desktop}` : "Message Nyo", autocomplete: "off", enterkeyhint: "send", "aria-label": "Message Nyo" }),
      h("button.btn.primary", { type: "submit" }, "Send"))),
  ];
}

function sessionTab() {
  const t = state.thread;
  const c = comp(t?.comp);
  if (!t || !c) { state.tab = "now"; return nowTab(); }
  const d = t.data;
  const live = c.sessions.find((x) => x.pillId === t.id);
  const st = d?.state === "needsYou" ? "approval" : d?.state === "working" ? "working" : live?.state || "idle";
  const gone = d?.state === "gone";
  const where = d ? [many() ? c.desktop : null, d.host, d.folder].filter(Boolean).join(" · ") : t.sub;
  const items = d?.items || [];
  const queued = d?.queued || [];
  const canSend = d?.canMessage && !gone;
  const hint = !d ? "" : gone ? "This session has ended."
    : !d.canMessage ? "Only Claude Code sessions take messages from the phone. You can still open it on the computer."
    : d.state === "working" ? "Claude is working: it reads your message when it finishes this turn."
    : d.state === "needsYou" ? "Claude is waiting for you: answer it on the Now tab first."
    : d.note || "";
  return [
    h("div.row", { style: "margin:-4px 0 6px" },
      h("button.link", { onclick: closeSession }, "‹ Sessions"), h("div.grow"),
      h("button.link", { onclick: () => { if (control(c, "focus", { app: t.id })) toast(`Opening it on ${c.desktop}…`); } }, `Show on ${kindOf(c)}`)),
    h("section.card.quiet", { style: "padding:12px 14px" },
      h("div.row", h("div.grow", h("div.title", d?.title || t.title), h("div.sub", where)),
        gone ? h("span.chip.idle", h("i"), "Ended") : h("span.chip." + sessionClass(st), h("i"), sessionLabel(st)))),
    st === "approval" || st === "question" ? [approvalCard(c), questionCard(c)] : null,
    h("div.thread",
      !d ? h("p.empty", c.status === "open" ? "Loading the session…" : `Connect to ${c.desktop} to read it.`)
      : !d.readable ? h("p.empty", "Nyeko can't read this session's conversation.")
      : items.length === 0 ? h("p.empty", "Nothing said yet.") : null,
      items.map((it) => it.r === "tools"
        ? h("div.tools", it.t.split("\n").map((l) => h("div", l)))
        : h("div.msg." + (it.r === "you" ? "me" : "nyo"), it.p ? h("small.from", "From your phone") : null, it.t)),
      queued.map((q) => h("div.msg.me.queued", h("small.from", "Waiting for Claude"), q)),
      queued.length ? h("button.link", { style: "align-self:flex-end", onclick: () => send(c, { type: "unqueue", session: t.id }) }, "Cancel waiting message") : null,
      t.sending.map((m) => h("div.msg.me.queued", h("small.from", "Sending…"), m.text)),
      d?.state === "working" ? h("div.tools.muted", "Claude is working…") : null),
    canSend ? h("div.composer.solo", h("form", { onsubmit: (e) => { e.preventDefault(); say(e.target); } },
      h("div.grow",
        hint ? h("p.small.muted", { style: "margin:0 4px 6px" }, hint) : null,
        h("div.row",
          h("textarea#say", { rows: "1", placeholder: "Message Claude", "aria-label": "Message Claude", enterkeyhint: "send",
            oninput: (e) => { e.target.style.height = "auto"; e.target.style.height = Math.min(160, e.target.scrollHeight) + "px"; } }),
          h("button.btn.primary", { type: "submit" }, "Send")))))
      : hint ? h("p.small.muted.center", hint) : null,
  ];
}

function launchTab() {
  const L = state.launch || (state.launch = { comp: cur()?.id, project: null, starting: null });
  const c = comp(L.comp) || cur();
  L.comp = c?.id;
  const projects = c?.mac?.projects || [];
  if (!projects.some((p) => p.id === L.project)) L.project = projects[0]?.id ?? null;
  const back = h("button.link", { onclick: () => { state.launch = null; state.tab = "now"; render(); } }, "‹ Sessions");
  if (L.starting) {
    const late = Date.now() - L.starting.at > 60_000;
    return [h("div.row", { style: "margin:-4px 0 6px" }, back),
      h("section.card", { style: "text-align:center" },
        h("div.title", L.starting.launched ? `Claude Code is starting in ${L.starting.name}…` : `Asking ${c?.desktop} to start ${L.starting.name}…`),
        h("p.sub", late ? "It is open in a terminal on the computer. It shows on the Now tab once Claude Code is up."
                        : "This opens as soon as Claude Code says hello."))];
  }
  return [
    h("div.row", { style: "margin:-4px 0 6px" }, back),
    h("h2", "New Claude Code session"),
    picker((x) => { L.comp = x.id; L.project = null; send(x, { type: "status" }); }),
    !c?.mac ? h("section.card", h("p.empty", c?.status === "open" ? "Loading the folders…" : `${c?.desktop || "The computer"} is not connected.`))
    : projects.length === 0 ? h("section.card", h("p.sub",
        "Nyeko learns your project folders from the sessions you run on the computer. Start one there once, and it shows here."))
    : h("form", { onsubmit: (e) => { e.preventDefault(); startSession(e.target); } },
        h("section.card",
          h("div.title", "Folder"),
          h("div.opts", projects.map((p) => {
            const on = p.id === L.project;
            return h("button.opt" + (on ? ".on" : ""), { type: "button", "aria-pressed": on ? "true" : "false",
              onclick: () => { L.project = p.id; render(); } }, p.name, h("small", p.where));
          })),
          h("label.field", { for: "launch-prompt" }, "What should Claude do?"),
          h("textarea#launch-prompt", { placeholder: "Leave empty to just open Claude Code", "aria-label": "What should Claude do?" }),
          h("p.small.muted", "The computer opens a terminal in that folder and starts Claude Code with this. You can follow and talk to it from here.")),
        h("button.btn.primary.block", { type: "submit" }, "Start session")),
  ];
}

function settingsTab() {
  const hasFace = !!load(STORE.cred);
  const alerts = alertsComputer();
  return [
    h("h2", "Your computers"),
    h("section.card",
      h("div.list", state.computers.map((c) => h("div.item",
        h("div.row",
          h("span.dot." + dotOf(c)),
          h("div.grow", h("div.title", c.desktop), h("div.sub", `${statusWord(c)} · through ${new URL(c.p.relay.replace(/^ws/, "http")).host}`)),
          many() && c !== cur() ? h("button.btn", { onclick: () => { state.current = c.id; saveComputers(); render(); } }, "Use") : many() ? h("span.chip.done", "In use") : null),
        h("button.link", { onclick: () => removeComputer(c) }, `Remove ${c.desktop}`)))),
      h("button.btn.primary.block", { style: "margin-top:10px", onclick: () => { state.tab = "add"; render(); } }, "＋ Add a computer"),
      h("p.small.muted", { style: "margin:10px 0 0" }, "Each computer is paired with its own code, end-to-end encrypted. Removing one cuts it off at once.")),
    !standalone() && !isIOS ? [h("h2", "Install"),
      h("section.card",
        h("p.sub", "Put Nyeko on your home screen: it opens like an app, and stays paired."),
        installPrompt
          ? h("button.btn.primary", { onclick: async () => { installPrompt.prompt(); await installPrompt.userChoice; installPrompt = null; render(); } }, "Install Nyeko")
          : h("p.small.muted", "Chrome menu ⋮ → Install app (or Add to Home screen)."))] : null,
    h("h2", isIOS ? "Face ID" : "Screen lock"),
    h("section.card",
      h("p.sub", hasFace ? `On. Allow, answers, messages and power actions ask for your ${lockName}.` : `Allow and answers need your ${lockName}. Deny never does.`),
      h("button.btn" + (hasFace ? "" : ".primary"), { onclick: setupFaceId }, hasFace ? "Set up again" : `Set up ${isIOS ? "Face ID" : "screen lock"}`)),
    h("h2", "Alerts"),
    h("section.card",
      standalone() || !isIOS ? null : h("p.sub", "Alerts need Nyeko on the Home Screen: Share → Add to Home Screen, open it from there, and pair again."),
      h("p.sub", alerts ? `When Claude needs you on ${alerts.desktop} and Nyeko is closed, your phone shows “Nyo needs you”. Nothing about the command is in the alert.`
                        : "None of your computers can send alerts to this web app yet."),
      alerts ? h("button.btn" + (load(STORE.alerts) === alerts.id ? "" : ".primary"), { onclick: enableAlerts },
        load(STORE.alerts) === alerts.id ? "Alerts are on" : "Turn on alerts") : null),
    h("p.small.muted.center", `Web app ${VERSION}`),
    h("button.btn.block", { onclick: () => { state.tab = "now"; render(); } }, "Done"),
  ];
}

function androidScreen() {
  const o = state.androidOffer;
  const download = state.apk
    ? h("a.btn" + (o.noApp ? ".primary" : "") + ".block", { href: "/downloads/android", style: "text-decoration:none;color:inherit" },
        `Download the app (${state.apk.versionName}, ${(state.apk.size / 1048576).toFixed(0)} MB)`)
    : h("p.small.muted", "No Nyeko for Android build is published yet (GitHub Actions → android → Run workflow).");
  return h("main.screen.center",
    h("img.cat.big", { src: "/icons/icon-512.png", alt: "Nyo the cat" }),
    h("h1", { style: "font-size:30px;margin:0 0 6px" }, "Nyeko for Android"),
    h("p.sub", "Nyo on your screen, the island from the camera hole, alerts and widgets: the app does what a web page can't."),
    h("section.card", { style: "text-align:left;margin-top:18px" },
      o.noApp
        ? [h("div.title", "The Nyeko app isn't installed yet"),
           h("ol.steps", h("li", "Tap Download the app, then open the file."), h("li", "Allow installs from Chrome when Android asks, and install."),
             h("li", "Come back here and tap Open in the Nyeko app: it pairs with your Mac.")),
           download,
           h("button.btn.block", { style: "margin-top:10px", onclick: openApp }, "Open in the Nyeko app")]
        : [h("div.title", "Pair the Nyeko app with your Mac"),
           h("p.sub", "It opens the app and asks you to confirm. Nothing is stored in this browser."),
           h("button.btn.primary.block", { onclick: openApp }, "Open in the Nyeko app"),
           h("div", { style: "margin-top:10px" }, download)]),
    h("button.link", { onclick: () => { const code = location.hash; state.androidOffer = null;
      history.replaceState(null, "", location.pathname); pair(code); } }, "Use Nyeko in the browser instead"));
}

function pairScreen() {
  const fromLink = location.hash.startsWith("#pair=") || location.hash.startsWith("#setup=");
  const adding = state.computers.length > 0;
  return h("main.screen.center",
    h("img.cat.big", { src: "/icons/icon-512.png", alt: "Nyo the cat" }),
    h("h1", { style: "font-size:30px;margin:0 0 6px" }, adding ? "Add a computer" : "Nyeko"),
    h("p.sub", adding ? "Pair another Mac or your Windows PC: each one shows here with its own sessions and controls."
                      : "Nyo in your pocket: approve, answer, chat and control your computers."),
    // The camera opened this code in Safari, which keeps its own storage: the Home Screen app gets it through the
    // iPhone's clipboard (works for a Mac and a Windows PC alike).
    !standalone() && fromLink && isIOS ? h("section.card", { style: "text-align:left;margin-top:18px" },
      h("div.title", "Add this computer to Nyeko"),
      h("button.btn.primary.block", { onclick: async () => {
        try { await navigator.clipboard.writeText(location.href); toast("Copied. Now open Nyeko from your Home Screen."); }
        catch { toast("Copy did not work: long-press the address bar and copy it."); }
      } }, "Copy pairing code"),
      h("ol.steps", h("li", "Open Nyeko from your Home Screen (not yet there? Share › Add to Home Screen first)."),
        h("li", "Settings › Your computers › ＋ Add a computer › Paste pairing code. Your other computers stay.")),
      h("button.link", { onclick: () => addComputer(location.hash) }, "Or use Nyeko here in Safari")) : null,
    // In Safari on the iPhone, without a code: install first (a pairing made in Safari stays in Safari).
    !standalone() && !fromLink && isIOS ? h("section.card.alert", { style: "text-align:left;margin-top:18px" },
      h("div.title", "Install Nyeko first"),
      h("ol.steps", h("li", "Tap Share (the square with an arrow), then Add to Home Screen → Add."),
        h("li", "Open Nyeko from the Home Screen and pair there: it keeps its own pairing, alerts and Face ID.")),
      h("a.link", { href: "/download.html" }, "All the steps")) : null,
    h("section.card", { style: "text-align:left;margin-top:18px" },
      h("div.title", "Pair with a computer"),
      h("p.sub", isIOS ? "Scan the computer's QR code (Nyeko → Phone) with the Camera app and tap Copy pairing code, or on a Mac use Copy pairing code. Then tap Paste pairing code here."
                       : "Scan the QR code on the computer (Nyeko → Phone) with your camera, or paste its pairing code or link."),
      h("button.btn.primary.block", { onclick: async () => {
        try { addComputer(await navigator.clipboard.readText()); } catch { toast("Paste the code in the box below."); }
      } }, "Paste pairing code"),
      h("label.field", { for: "code" }, "Or paste it here"),
      h("textarea#code", { autocomplete: "off", autocapitalize: "off", spellcheck: "false" }),
      h("button.btn.block", { style: "margin-top:10px", onclick: () => addComputer(document.getElementById("code").value) }, "Pair")),
    adding ? h("button.link", { onclick: () => { state.tab = "settings"; render(); } }, "Cancel") : null);
}

function tabs() {
  const need = state.computers.reduce((n, c) => n + (c.approval ? 1 : 0) + (c.question ? 1 : 0), 0);
  const c = cur();
  const tab = (id, label, badge) => h("button", { "aria-current": state.tab === id ? "page" : null,
    onclick: () => { state.tab = id; render(); } }, h("span", label, badge ? h("span.badge", badge) : null));
  return h("nav.tabs", tab("now", "Now", need || null), tab("mac", many() ? "Computers" : c?.os === "windows" ? "PC" : "Mac"), tab("nyo", "Nyo"));
}

// ── render ───────────────────────────────────────────────────────────────────────────────────────────

function render() {
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
    const body = { now: nowTab, mac: computerTab, nyo: nyoTab, settings: settingsTab, session: sessionTab, launch: launchTab }[state.tab]?.() ?? nowTab();
    view = h("main.screen" + (state.tab === "session" ? ".chatting" : ""), header(), body);
  }
  app.replaceChildren(view, paired && !state.androidOffer && !["settings", "session", "launch", "add"].includes(state.tab) ? tabs() : "",
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
  state.current = load(STORE.current) || state.computers[0]?.id || null;
  if (load(STORE.alerts) === true) save(STORE.alerts, alertsComputer()?.id ?? null);   // alerts were on for the one Mac
}

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
for (const c of state.computers) if (!c.channel) connect(c);
render();
