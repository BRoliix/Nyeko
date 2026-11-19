// Nyeko phone web app: the phone side of the relay link (docs/RELAY_LINK.md), in the browser.
//
// The same wire as Coucou for Android: HKDF-SHA-256, HMAC-SHA-256 and AES-256-GCM, all from WebCrypto (no library).
// Everything inside is protocol v1 (docs/ANDROID_LINK.md), one JSON line per encrypted frame. The relay only forwards
// opaque frames: it never sees K, the token, a session, a command or a chat.
//
// Runs unchanged in Node 22 for the tests (tests/relay.test.mjs checks it against android/relay/test-vectors.json).

export const LABEL = "coucou-relay/v1";
export const VERSION = 1;
export const TYPE = { init: 1, accept: 2, data: 3 };
export const DIR = { p2h: 1, h2p: 2 };
const MAX_LINE = 65536;
const LAST_COUNTER = 2 ** 32 - 1;

const enc = new TextEncoder();
const dec = new TextDecoder("utf-8", { fatal: true });
const subtle = globalThis.crypto.subtle;

// ── bytes ──────────────────────────────────────────────────────────────────────────────────────────

export function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let i = 0;
  for (const p of parts) { out.set(p, i); i += p.length; }
  return out;
}

export function b64url(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromB64url(text) {
  const s = atob(text.replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
}

export const hex = (b) => [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
export const fromHex = (h) => Uint8Array.from(h.match(/../g) ?? [], (x) => parseInt(x, 16));

function u64(counter) {
  const b = new Uint8Array(8);
  new DataView(b.buffer).setBigUint64(0, BigInt(counter));
  return b;
}

function equal(a, b) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

export function random(n) {
  return globalThis.crypto.getRandomValues(new Uint8Array(n));
}

// ── primitives ─────────────────────────────────────────────────────────────────────────────────────

export async function hkdf(ikm, salt, info, length) {
  const key = await subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  const bits = await subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, length * 8);
  return new Uint8Array(bits);
}

export async function hmac(key, data) {
  const k = await subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await subtle.sign("HMAC", k, data));
}

/** K_auth and K_join, from the pairing key K. */
export async function deriveStatic(K) {
  const empty = new Uint8Array(0);
  return {
    kAuth: await hkdf(K, empty, enc.encode(LABEL + " auth"), 32),
    kJoin: await hkdf(K, empty, enc.encode(LABEL + " join"), 32),
  };
}

/** The two session keys of one connection. */
export async function deriveSession(K, nPhone, nPc) {
  const s = await hkdf(K, concat(nPhone, nPc), enc.encode(LABEL + " session"), 64);
  return { p2h: s.slice(0, 32), h2p: s.slice(32, 64) };
}

// ── frames ─────────────────────────────────────────────────────────────────────────────────────────

export function frame(type, counter, body) {
  return concat(new Uint8Array([VERSION, type]), u64(counter), body);
}

export function parseFrame(bytes) {
  if (bytes.length < 10 || bytes[0] !== VERSION) return null;
  const counter = Number(new DataView(bytes.buffer, bytes.byteOffset + 2, 8).getBigUint64(0));
  return { type: bytes[1], counter, body: bytes.subarray(10) };
}

export function nonce(dir, counter) {
  return concat(new Uint8Array([dir, 0, 0, 0]), u64(counter));
}

export function aad(room, dir, type, counter) {
  return concat(enc.encode(LABEL), enc.encode(room), new Uint8Array([dir, VERSION, type]), u64(counter));
}

/** u32 length ‖ line ‖ zeros, a multiple of 128 and at least 128 (hides a ping from an approval). */
export function pad(line) {
  if (line.length > MAX_LINE) throw new Error("line too long");
  const size = Math.max(128, Math.ceil((4 + line.length) / 128) * 128);
  const out = new Uint8Array(size);
  new DataView(out.buffer).setUint32(0, line.length);
  out.set(line, 4);
  return out;
}

export function unpad(plain) {
  if (plain.length < 128 || plain.length % 128 !== 0) return null;
  const n = new DataView(plain.buffer, plain.byteOffset, 4).getUint32(0);
  if (n > MAX_LINE || 4 + n > plain.length) return null;
  for (let i = 4 + n; i < plain.length; i++) if (plain[i] !== 0) return null;
  return plain.slice(4, 4 + n);
}

export async function initFrame(kAuth, room, nPhone) {
  const mac = await hmac(kAuth, concat(enc.encode("init"), enc.encode(room), nPhone));
  return frame(TYPE.init, 0, concat(nPhone, mac));
}

export async function acceptMac(kAuth, room, nPhone, nPc) {
  return hmac(kAuth, concat(enc.encode("accept"), enc.encode(room), nPhone, nPc));
}

export async function seal(key, dir, room, counter, lineBytes) {
  const k = await subtle.importKey("raw", key, "AES-GCM", false, ["encrypt"]);
  const ct = await subtle.encrypt({ name: "AES-GCM", iv: nonce(dir, counter), additionalData: aad(room, dir, TYPE.data, counter) },
                                  k, pad(lineBytes));
  return frame(TYPE.data, counter, new Uint8Array(ct));
}

/** The line inside a data frame, or null for any fault (bad tag, padding, header). */
export async function openFrame(key, dir, room, parsed) {
  try {
    const k = await subtle.importKey("raw", key, "AES-GCM", false, ["decrypt"]);
    const plain = new Uint8Array(await subtle.decrypt(
      { name: "AES-GCM", iv: nonce(dir, parsed.counter), additionalData: aad(room, dir, TYPE.data, parsed.counter) },
      k, parsed.body));
    return unpad(plain);
  } catch {
    return null;
  }
}

// ── the phone's channel ────────────────────────────────────────────────────────────────────────────

/**
 * One end-to-end encrypted channel to the Mac, through the relay. Reconnects by itself.
 *   pairing: { relay: "wss://…", room, key (K, base64url), access (base64url) }
 *   on.status(text)   "connecting" | "waiting" (Mac offline) | "open" | "closed"
 *   on.open()         the channel is up: send hello
 *   on.line(object)   one v1 message from the Mac
 */
export class PhoneChannel {
  constructor(pairing, on) {
    this.p = pairing;
    this.on = on;
    this.K = fromB64url(pairing.key);
    this.ws = null;
    this.session = null;
    this.stopped = false;
    this.backoff = 1000;
    this.queue = Promise.resolve();   // frames are handled one at a time, in order
  }

  async start() {
    this.stopped = false;
    if (!this.statics) this.statics = await deriveStatic(this.K);
    this.connect();
  }

  stop() {
    this.stopped = true;
    this.endSession();
    try { this.ws?.close(1000, "bye"); } catch {}
    this.ws = null;
    this.on.status?.("closed");
  }

  /** Back to the foreground (iOS suspends a page in the background): reconnect now if the socket died. */
  wake() {
    if (this.stopped) return;
    if (!this.ws || this.ws.readyState > 1) { this.backoff = 1000; this.connect(); }
    else if (!this.session) this.sendInit();
  }

  connect() {
    if (this.stopped) return;
    clearTimeout(this.retry);
    const url = `${this.p.relay.replace(/\/+$/, "")}/v1/room/${this.p.room}?role=phone`;
    const protocols = ["coucou.v1", "coucou.join." + b64url(this.statics.kJoin), "coucou.access." + this.p.access];
    this.on.status?.("connecting");
    let ws;
    try { ws = new WebSocket(url, protocols); } catch { return this.later(); }
    ws.binaryType = "arraybuffer";
    this.ws = ws;
    ws.onopen = () => { this.backoff = 1000; this.on.status?.("waiting"); this.sendInit(); };
    ws.onmessage = (ev) => { this.queue = this.queue.then(() => this.receive(ev.data)).catch(() => {}); };
    ws.onclose = () => { if (this.ws === ws) { this.ws = null; this.endSession(); this.later(); } };
    ws.onerror = () => {};
    clearInterval(this.pinger);
    // Text "ping" is answered by Cloudflare itself (cheap); the v1 ping proves the Mac is there.
    this.pinger = setInterval(() => {
      if (this.ws?.readyState === 1) {
        if (this.session) this.send({ type: "ping" }); else this.ws.send("ping");
      }
    }, 20000);
  }

  later() {
    if (this.stopped) return;
    this.on.status?.("connecting");
    clearTimeout(this.retry);
    this.retry = setTimeout(() => this.connect(), this.backoff);
    this.backoff = Math.min(30000, this.backoff * 2);
  }

  endSession() {
    if (this.session) { this.session = null; this.on.status?.("waiting"); }
  }

  async sendInit() {
    if (!this.ws || this.ws.readyState !== 1) return;
    this.nPhone = random(16);
    this.ws.send(await initFrame(this.statics.kAuth, this.p.room, this.nPhone));
  }

  async receive(data) {
    if (typeof data === "string") {
      if (data === '{"peer":"online"}' || data === '{"peer":"offline"}') {
        // Hints are not authenticated: they only make us start again (an open session ends, as specified).
        this.endSession();
        if (data === '{"peer":"online"}') await this.sendInit();
      }
      return;
    }
    const parsed = parseFrame(new Uint8Array(data));
    if (!parsed) return this.fault();
    if (parsed.type === TYPE.accept && !this.session && this.nPhone && parsed.counter === 0 && parsed.body.length === 48) {
      const nPc = parsed.body.slice(0, 16);
      const mac = await acceptMac(this.statics.kAuth, this.p.room, this.nPhone, nPc);
      if (!equal(mac, parsed.body.slice(16))) return;   // a recorded or forged accept: ignored
      const keys = await deriveSession(this.K, this.nPhone, nPc);
      this.session = { keys, out: 0, in: 0 };
      this.on.status?.("open");
      this.on.open?.();
      return;
    }
    if (parsed.type !== TYPE.data || !this.session) return;
    if (parsed.counter !== this.session.in) return this.fault();
    const line = await openFrame(this.session.keys.h2p, DIR.h2p, this.p.room, parsed);
    if (!line) return this.fault();
    this.session.in += 1;
    let message;
    try { message = JSON.parse(dec.decode(line)); } catch { return this.fault(); }
    this.on.line?.(message);
  }

  /** Any fault: drop the keys and start again (no error is sent to the peer). */
  fault() {
    this.endSession();
    this.sendInit();
  }

  /** One v1 message to the Mac. False when the channel is not open. */
  send(message) {
    const s = this.session;
    if (!s || !this.ws || this.ws.readyState !== 1) return false;
    if (s.out >= LAST_COUNTER) { this.fault(); return false; }
    const counter = s.out++;
    const bytes = enc.encode(JSON.stringify(message));
    this.queue = this.queue.then(async () => {
      if (this.session !== s) return;
      this.ws?.send(await seal(s.keys.p2h, DIR.p2h, this.p.room, counter, bytes));
    }).catch(() => {});
    return true;
  }
}
