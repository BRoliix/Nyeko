// Setup over a real relay (the Node twin): a computer offers, a phone sends the relay and its key, the computer answers
// with a pairing code. Also: a wrong access key reported back, a tampered offer refused, and the relay never needing
// the key for a setup room.
//   node phone/tests/setup.test.mjs     (needs `npm install` in android/relay)
import assert from "node:assert/strict";
import { startRelay } from "../../android/relay/tools/dev-relay.ts";
import { offerSetup, parseSetup, sendSetup } from "../web/setup.js";
import WebSocket from "../../android/relay/node_modules/ws/wrapper.mjs";

const access = "A".repeat(43);
const relayServer = await startRelay({ accessKey: access });
const relay = `ws://127.0.0.1:${relayServer.port}`;
const WS = WebSocket;
let saved = null;

// 1. The happy path.
const offer = await offerSetup("https://nyeko-phone.pages.dev", { relay, name: "MacBook Pro · test", cid: "abcdefgh12" },
  async (s) => { saved = s; return "https://nyeko-phone.pages.dev/#pair=CODE"; }, { WS });
const parsed = parseSetup(offer.link);
assert.ok(parsed, "the QR link parses");
assert.equal(parsed.name, "MacBook Pro · test");
const code = await sendSetup(parsed, { relay: "wss://my-relay.example.workers.dev", access, phone: "iPhone" }, { WS, waitMs: 5000 });
assert.equal(code, "https://nyeko-phone.pages.dev/#pair=CODE");
assert.deepEqual(saved, { relay: "wss://my-relay.example.workers.dev", access, phone: "iPhone" });
assert.equal(await offer.done, true);

// 2. The computer refuses (a bad key): the phone hears why.
const offer2 = await offerSetup("https://x.test", { relay, name: "PC", cid: "" },
  async () => { throw new Error("That access key is not a relay key."); }, { WS });
await assert.rejects(sendSetup(parseSetup(offer2.link), { relay, access: "nope", phone: "Phone" }, { WS, waitMs: 5000 }),
  /not a relay key/);
offer2.cancel();

// 3. A tampered offer (another public key) cannot be decrypted by the computer: it never answers.
const offer3 = await offerSetup("https://x.test", { relay, name: "PC", cid: "" }, async () => "never", { WS });
const p3 = parseSetup(offer3.link);
const other = parseSetup((await offerSetup("https://x.test", { relay, name: "Other", cid: "" }, async () => "x", { WS })).link);
await assert.rejects(sendSetup({ ...p3, pub: other.pub }, { relay, access, phone: "P" }, { WS, waitMs: 1500 }), /did not answer/);
offer3.cancel();

// 4. Garbage is not an offer.
assert.equal(parseSetup("https://nyeko-phone.pages.dev/#pair=abc"), null);
assert.equal(parseSetup("#setup=AAAA"), null);

await relayServer.close();
console.log("setup: 4 checks passed");
process.exit(0);
