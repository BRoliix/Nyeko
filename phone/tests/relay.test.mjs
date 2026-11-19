// node --test tests/  — the web app's relay crypto against android/relay/test-vectors.json (the same vectors the Rust
// computer side and the Kotlin phone side pass), plus a full handshake + exchange between a phone and a computer.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as R from "../web/relay.js";

const V = JSON.parse(readFileSync(new URL("../../android/relay/test-vectors.json", import.meta.url), "utf8"));
const K = R.fromHex(V.inputs.key);
const room = V.inputs.room;
const nPhone = R.fromHex(V.inputs.nPhone);
const nPc = R.fromHex(V.inputs.nPc);
const te = new TextEncoder();

test("HKDF matches RFC 5869 A.1", async () => {
  const a = V.rfc5869_a1;
  const okm = await R.hkdf(R.fromHex(a.ikm), R.fromHex(a.salt), R.fromHex(a.info), a.length);
  assert.equal(R.hex(okm), a.okm);
});

test("derived keys", async () => {
  const s = await R.deriveStatic(K);
  assert.equal(R.hex(s.kAuth), V.derived.kAuth);
  assert.equal(R.hex(s.kJoin), V.derived.kJoin);
  const k = await R.deriveSession(K, nPhone, nPc);
  assert.equal(R.hex(k.p2h), V.derived.kP2H);
  assert.equal(R.hex(k.h2p), V.derived.kH2P);
  assert.equal(R.b64url(R.fromHex(V.inputs.roomBytes)), room);
});

test("init and accept frames", async () => {
  const s = await R.deriveStatic(K);
  assert.equal(R.hex(await R.initFrame(s.kAuth, room, nPhone)), V.init.frame);
  assert.equal(R.hex(await R.acceptMac(s.kAuth, room, nPhone, nPc)), V.accept.mac);
});

test("data frames: nonce, aad, padding, ciphertext", async () => {
  const k = await R.deriveSession(K, nPhone, nPc);
  for (const d of V.data) {
    const dir = R.DIR[d.dir];
    const key = dir === R.DIR.p2h ? k.p2h : k.h2p;
    assert.equal(R.hex(R.nonce(dir, d.counter)), d.nonce);
    assert.equal(R.hex(R.aad(room, dir, R.TYPE.data, d.counter)), d.aad);
    assert.equal(R.hex(R.pad(te.encode(d.line))), d.plaintext);
    if (d.frame) assert.equal(R.hex(await R.seal(key, dir, room, d.counter, te.encode(d.line))), d.frame);
    const opened = await R.openFrame(key, dir, room, R.parseFrame(R.fromHex(d.frame ?? R.hex(await R.seal(key, dir, room, d.counter, te.encode(d.line))))));
    assert.equal(new TextDecoder().decode(opened), d.line);
  }
});

test("must refuse tampered frames", async () => {
  const k = await R.deriveSession(K, nPhone, nPc);
  for (const m of V.mustRefuse) {
    const dir = R.DIR[m.dir];
    // A case may name another room or another key: the receiver uses it, and must refuse.
    const key = m.key ? R.fromHex(m.key) : (dir === R.DIR.p2h ? k.p2h : k.h2p);
    const parsed = R.parseFrame(R.fromHex(m.frame));
    const opened = parsed && parsed.type === R.TYPE.data ? await R.openFrame(key, dir, m.room ?? room, parsed) : null;
    assert.equal(opened, null, m.name);
  }
});

test("phone and computer: handshake, then lines both ways", async () => {
  const s = await R.deriveStatic(K);
  // phone → init
  const init = R.parseFrame(await R.initFrame(s.kAuth, room, nPhone));
  // computer checks it, answers accept
  const body = init.body;
  const mac = await R.hmac(s.kAuth, R.concat(te.encode("init"), te.encode(room), body.slice(0, 16)));
  assert.deepEqual(mac, body.slice(16));
  const pcN = R.random(16);
  const keysPc = await R.deriveSession(K, body.slice(0, 16), pcN);
  const keysPhone = await R.deriveSession(K, nPhone, pcN);
  assert.deepEqual(keysPc, keysPhone);
  const toPc = await R.seal(keysPhone.p2h, R.DIR.p2h, room, 0, te.encode('{"type":"hello"}'));
  assert.equal(new TextDecoder().decode(await R.openFrame(keysPc.p2h, R.DIR.p2h, room, R.parseFrame(toPc))), '{"type":"hello"}');
  // wrong direction key: refused
  assert.equal(await R.openFrame(keysPc.h2p, R.DIR.h2p, room, R.parseFrame(toPc)), null);
});
