// Setting up a new computer from the phone (docs/RELAY_SETUP.md).
//
// A computer that has no relay yet shows a QR code with a setup offer: its relay's address, a one-time setup room and
// a P-256 public key. The phone, which already knows the relay's access key, scans it, meets the computer in that setup
// room (the relay opens setup rooms without the key, for a few small frames) and sends the address and the key,
// encrypted to the computer's public key. The computer saves them, turns its phone link on and answers with its pairing
// code, which the phone adds like any other. Nothing is typed on the computer.
//
// Both sides are here (the computer's in `offerSetup`), so Windows' island uses the same code and the tests run them
// against each other. WebCrypto only; runs unchanged in Node 22.

import { b64url, concat, fromB64url, hkdf, random } from "./relay.js";

export const SETUP = "nyeko-setup/v1";
const subtle = globalThis.crypto.subtle;
const enc = new TextEncoder();
const dec = new TextDecoder();
const HELLO = 1, DONE = 2;

/** The offer in a scanned or pasted text (`…#setup=<base64url JSON>`), or null. */
export function parseSetup(text) {
  const b64 = /#setup=([A-Za-z0-9_-]{40,2000})/.exec(text || "")?.[1];
  if (!b64) return null;
  try {
    const j = JSON.parse(dec.decode(fromB64url(b64)));
    if (j.v !== 1 || !/^wss?:\/\/[^/?#\s]+$/.test(j.relay) || !/^[A-Za-z0-9_-]{22}$/.test(j.room)
        || !/^[A-Za-z0-9_-]{87}$/.test(j.pub)) return null;
    return { relay: j.relay, room: j.room, pub: j.pub, name: String(j.name || "Computer").slice(0, 64),
      cid: typeof j.cid === "string" ? j.cid.slice(0, 64) : "" };
  } catch {
    return null;
  }
}

/** The text a computer puts in its QR code. */
export function setupLink(site, offer) {
  const json = JSON.stringify({ v: 1, relay: offer.relay, room: offer.room, pub: offer.pub, name: offer.name, cid: offer.cid || "" });
  return `${site.replace(/\/+$/, "")}/#setup=${b64url(enc.encode(json))}`;
}

/** Both sides present this join proof: anyone holding the QR code can compute it, nobody else can. */
export async function joinProof(room, pub) {
  return b64url(new Uint8Array(await subtle.digest("SHA-256", enc.encode(`${SETUP} join ${room} ${pub}`))));
}

async function sharedKey(myPrivate, theirRaw, room) {
  const theirs = await subtle.importKey("raw", theirRaw, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const bits = new Uint8Array(await subtle.deriveBits({ name: "ECDH", public: theirs }, myPrivate, 256));
  const raw = await hkdf(bits, enc.encode(room), enc.encode(SETUP), 32);
  return subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}

async function seal(key, aad, obj) {
  const nonce = random(12);
  const sealed = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: enc.encode(aad) }, key,
    enc.encode(JSON.stringify(obj))));
  return concat(nonce, sealed);
}

async function open(key, aad, bytes) {
  const plain = await subtle.decrypt({ name: "AES-GCM", iv: bytes.subarray(0, 12), additionalData: enc.encode(aad) }, key,
    bytes.subarray(12));
  return JSON.parse(dec.decode(plain));
}

/** One socket on a setup room, with its frames as a queue. */
function room(relay, roomId, role, proof, WS) {
  const ws = new WS(`${relay}/v1/setup/${roomId}?role=${role}`, ["coucou.v1", `coucou.join.${proof}`]);
  ws.binaryType = "arraybuffer";
  const frames = [];
  let wake = null, closed = null;
  ws.onmessage = (e) => {
    if (typeof e.data === "string") return;            // {"peer":…} notices
    frames.push(new Uint8Array(e.data)); wake?.();
  };
  ws.onclose = (e) => { closed = e.code || 1000; wake?.(); };
  ws.onerror = () => { closed = closed ?? 1006; wake?.(); };
  const opened = new Promise((resolve, reject) => {
    ws.onopen = () => resolve();
    setTimeout(() => reject(new Error("The relay did not answer.")), 15_000);
  });
  return {
    opened,
    send: (b) => ws.send(b),
    close: () => { try { ws.close(1000, ""); } catch {} },
    /** The next frame, or null when the socket closed or `ms` passed. */
    async next(ms) {
      const until = Date.now() + ms;
      while (!frames.length && closed == null && Date.now() < until) {
        await new Promise((r) => { wake = r; setTimeout(r, Math.min(1000, until - Date.now())); });
      }
      return frames.shift() ?? null;
    },
  };
}

/**
 * The phone's side: sends the relay's address and access key to the computer behind `offer`, and returns the pairing code
 * the computer answers with. Throws with a sentence for the user when it cannot.
 */
export async function sendSetup(offer, { relay, access, phone }, { WS = globalThis.WebSocket, waitMs = 60_000 } = {}) {
  const mine = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const myRaw = new Uint8Array(await subtle.exportKey("raw", mine.publicKey));
  const key = await sharedKey(mine.privateKey, fromB64url(offer.pub), offer.room);
  const sock = room(offer.relay, offer.room, "phone", await joinProof(offer.room, offer.pub), WS);
  try {
    await sock.opened;
    sock.send(concat(new Uint8Array([HELLO]), myRaw,
      await seal(key, `${SETUP} hello ${offer.room}`, { relay, access, phone: phone || "Phone" })));
    for (;;) {
      const f = await sock.next(waitMs);
      if (!f) throw new Error(`${offer.name} did not answer: check that Nyeko is open on it with its setup code showing.`);
      if (f[0] !== DONE) continue;
      const reply = await open(key, `${SETUP} done ${offer.room}`, f.subarray(1));
      if (reply.error) throw new Error(String(reply.error).slice(0, 200));
      if (typeof reply.code !== "string") throw new Error("The computer's answer is damaged.");
      return reply.code;
    }
  } finally {
    sock.close();
  }
}

/**
 * The computer's side: makes an offer for `relay` and waits in its setup room. `onSetup({relay, access, phone})` saves the
 * settings and returns the pairing code for the phone (or throws a sentence, sent back to it). Returns the link to show
 * as a QR code, and a promise that settles when a phone has been set up (or the offer was cancelled).
 */
export async function offerSetup(site, { relay, name, cid }, onSetup, { WS = globalThis.WebSocket, ttlMs = 14 * 60_000 } = {}) {
  const mine = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const pub = b64url(new Uint8Array(await subtle.exportKey("raw", mine.publicKey)));
  const roomId = b64url(random(16));
  const offer = { relay, room: roomId, pub, name, cid };
  const sock = room(relay, roomId, "pc", await joinProof(roomId, pub), WS);
  let cancelled = false;
  const done = (async () => {
    await sock.opened;
    const until = Date.now() + ttlMs;
    while (!cancelled && Date.now() < until) {
      const f = await sock.next(until - Date.now());
      if (!f) break;
      if (f[0] !== HELLO || f.length < 1 + 65 + 12 + 16) continue;
      let key, hello;
      try {
        key = await sharedKey(mine.privateKey, f.subarray(1, 66), roomId);
        hello = await open(key, `${SETUP} hello ${roomId}`, f.subarray(66));
      } catch {
        continue;                                          // not for this offer: keep waiting
      }
      let reply;
      try {
        reply = { code: await onSetup({ relay: String(hello.relay || ""), access: String(hello.access || ""),
          phone: String(hello.phone || "Phone").slice(0, 64) }), name };
      } catch (e) {
        reply = { error: e?.message || "The computer could not save the settings." };
      }
      sock.send(concat(new Uint8Array([DONE]), await seal(key, `${SETUP} done ${roomId}`, reply)));
      if (reply.code) return true;
    }
    return false;
  })().finally(() => setTimeout(() => sock.close(), 1500));
  return { link: setupLink(site, offer), offer, done, cancel: () => { cancelled = true; sock.close(); } };
}
