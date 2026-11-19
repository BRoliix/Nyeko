// Nyeko: the web app's client against the Windows computer's relay client, through the dev relay. See the ignored test
// windows_and_the_web_app_through_the_dev_relay in windows/src-tauri/src/phone_link/relay_client.rs.
import * as R from "../web/relay.js";

const room = process.env.NYEKO_E2E_ROOM || "R".repeat(21) + "A";
const key = process.env.NYEKO_E2E_KEY || "K".repeat(42) + "A";
const access = process.env.NYEKO_E2E_ACCESS || "nyeko-e2e-secret-2026";
const got = [];
const phone = new R.PhoneChannel({ relay: "ws://127.0.0.1:8799", room, key, access }, {
  status: (x) => got.push("status " + x),
  open: () => phone.send({ type: "hello", v: 1, token: "t".repeat(32), device: "iPhone (test)", caps: ["nyeko"] }),
  line: (m) => {
    got.push("got " + m.type + (m.type === "welcome" ? " caps=" + JSON.stringify(m.caps) : "") + (m.type === "mac" ? ` os=${m.os} name=${m.name}` : "")
      + (m.type === "error" ? " " + JSON.stringify(m) : ""));
    if (m.type === "welcome") phone.send({ type: "status" });
  },
});
await phone.start();
await new Promise((r) => setTimeout(r, 6000));
console.log(got.join("\n"));
process.exit(0);
