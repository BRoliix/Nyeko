// The phone's side of setup for windows/src-tauri/src/phone_link/setup.rs's end-to-end test: starts the relay's Node twin,
// prints "PORT <n>", reads the computer's setup link on stdin, sends the relay and its key, prints "CODE <code>".
// Run by the Rust test (cargo test -p coucou --lib setup_with_the_web_app -- --ignored); needs `npm install` in android/relay.
import { createInterface } from "node:readline";
import { startRelay } from "../../android/relay/tools/dev-relay.ts";
import { parseSetup, sendSetup } from "../web/setup.js";
import WebSocket from "../../android/relay/node_modules/ws/wrapper.mjs";

const access = "B".repeat(43);
const relay = await startRelay({ accessKey: access });
console.log(`PORT ${relay.port}`);
const lines = createInterface({ input: process.stdin });
for await (const line of lines) {
  const offer = parseSetup(line);
  if (!offer) { console.log("BAD offer"); process.exit(1); }
  try {
    const code = await sendSetup(offer, { relay: "wss://my-relay.example.workers.dev", access, phone: "Test iPhone" },
      { WS: WebSocket, waitMs: 10_000 });
    console.log(`CODE ${code}`);
  } catch (e) {
    console.log(`ERROR ${e.message}`);
  }
  process.exit(0);
}
