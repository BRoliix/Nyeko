// Manual end-to-end check (needs `npm install` in android/relay):
//   ACCESS_KEY=$(printf "A%.0s" $(seq 43)) PORT=8799 node ../android/relay/tools/dev-relay.ts &
//   node tests/e2e.mjs
// End to end: dev relay (Node twin) + PhoneChannel (the web app) + a stand-in Mac in the pc role.
import * as R from "../web/relay.js";
import WebSocket from "../../android/relay/node_modules/ws/wrapper.mjs";

const access = "A".repeat(43);
const K = R.random(32);
const room = R.b64url(R.random(16));
const relay = "ws://127.0.0.1:8799";
const s = await R.deriveStatic(K);
const te = new TextEncoder(), td = new TextDecoder();

// The Mac: Authorization header, like the Swift client.
const pc = new WebSocket(`${relay}/v1/room/${room}?role=pc`, ["coucou.v1", "coucou.join." + R.b64url(s.kJoin)],
  { headers: { Authorization: `Bearer ${access}` } });
pc.binaryType = "arraybuffer";
let keys = null, out = 0, inn = 0;
const results = [];
pc.on("message", async (data, isBinary) => {
  if (!isBinary) return;
  const f = R.parseFrame(new Uint8Array(data));
  if (f.type === R.TYPE.init) {
    const nPhone = f.body.slice(0, 16);
    const mac = await R.hmac(s.kAuth, R.concat(te.encode("init"), te.encode(room), nPhone));
    if (R.hex(mac) !== R.hex(f.body.slice(16))) { results.push("bad init mac"); return; }
    const nPc = R.random(16);
    keys = await R.deriveSession(K, nPhone, nPc); out = 0; inn = 0;
    pc.send(R.frame(R.TYPE.accept, 0, R.concat(nPc, await R.acceptMac(s.kAuth, room, nPhone, nPc))));
  } else if (f.type === R.TYPE.data) {
    if (f.counter !== inn) { results.push("bad counter"); return; }
    const line = td.decode(await R.openFrame(keys.p2h, R.DIR.p2h, room, f)); inn++;
    const m = JSON.parse(line);
    results.push("mac got " + m.type);
    const reply = m.type === "hello" ? { type: "welcome", v: 1, desktop: "Test Mac", os: "macos", caps: ["nyeko"] }
      : m.type === "ask" ? { type: "reply", id: m.id, text: "hi from Nyo" }
      // A session's conversation as large as the Mac ever sends one (60,000 bytes of JSON).
      : m.type === "open" ? (() => { const c = { type: "chat", session: m.session, items: [{ r: "claude", t: "" }] };
          c.items[0].t = "x".repeat(60_000 - JSON.stringify(c).length); return c; })()
      : m.type === "say" ? { type: "said", id: m.id, session: m.session, result: "queued", note: "" } : null;
    if (reply) pc.send(await R.seal(keys.h2p, R.DIR.h2p, room, out++, te.encode(JSON.stringify(reply))));
  }
});
await new Promise((r) => pc.on("open", r));

// The phone: the web app's own class, access key as a sub-protocol (browser style; Node 22 has WebSocket).
const got = [];
const phone = new R.PhoneChannel({ relay, room, key: R.b64url(K), access }, {
  status: (x) => got.push("status " + x),
  open: () => phone.send({ type: "hello", v: 1, token: "t", device: "test", caps: ["nyeko"] }),
  line: (m) => {
    got.push("phone got " + m.type + (m.type === "chat" ? ` (${JSON.stringify(m).length} bytes)` : ""));
    if (m.type === "welcome") phone.send({ type: "ask", id: "1", text: "hello" });
    if (m.type === "reply") phone.send({ type: "open", session: "integration_claude|s1" });
    if (m.type === "chat") phone.send({ type: "say", session: m.session, id: "2", text: "run the tests" });
  },
});
await phone.start();
await new Promise((r) => setTimeout(r, 1500));

// A phone with a wrong access key is refused by the relay.
let refused = false;
const bad = new WebSocket(`${relay}/v1/room/${room}?role=phone`, ["coucou.v1", "coucou.join." + R.b64url(s.kJoin), "coucou.access." + "B".repeat(43)]);
bad.on("unexpected-response", (_, res) => { refused = res.statusCode; });
bad.on("error", () => {});
await new Promise((r) => setTimeout(r, 500));
phone.stop(); pc.close();
console.log(JSON.stringify({ mac: results, phone: got.filter((g) => !g.startsWith("status connecting")), wrongKeyRefused: refused }, null, 1));
process.exit(0);
