# Setting up a computer from your phone

You type the relay's address and access key only once, on your first computer. After that, each new computer (Mac, Windows or Linux) shows a QR code while it has no relay. A phone where Nyeko already works scans that code and sends the relay to the computer, end-to-end encrypted. The computer saves it, turns its phone link on and sends back its pairing code. The phone then adds the computer. Nothing is typed on the new computer.

## For the user

1. On the new computer, open Nyeko's Phone settings (Mac: the window's **Phone** page; Windows/Linux: **Settings → iPhone and Android**). While no relay is set, a **Set up with your phone** card shows a QR code.
2. Scan it with the phone:
   - **iPhone:** scan with the Camera, tap **Copy pairing code**, then paste it in Nyeko on the Home Screen (**Add a computer → Paste pairing code**). The Home Screen app is the one that knows your relay; Safari does not.
   - **Android:** open the link in Chrome, in the Nyeko web app.
3. A few seconds later the computer says *Set up by …* and appears in the phone's computer list.

A code lasts about 14 minutes. **Show a new code** makes a fresh one at any time.

## Protocol (nyeko-setup/v1)

The implementations are `phone/web/setup.js` (phone side, plus a JS computer side used by the tests), `NotchBuddy/Sources/App/PhoneWeb/NyekoSetup.swift` (Mac) and `windows/src-tauri/src/phone_link/setup.rs` (Windows/Linux).

**The offer (QR code).** `<web app>/#setup=<base64url JSON>`, with JSON `{v: 1, relay, room, pub, name, cid}`:
- `room`: 16 random bytes, base64url (22 characters).
- `pub`: the computer's ephemeral P-256 public key, uncompressed (65 bytes, 87 characters).
- `name`, `cid`: what the phone shows and matches.

The fragment never reaches a server.

**The setup room.** Both sides open `wss://<relay>/v1/setup/<room>?role=pc|phone` with the subprotocols `coucou.v1` and `coucou.join.<proof>`, where:

    proof = base64url(SHA-256("nyeko-setup/v1 join <room> <pub>"))

The relay's limits for setup rooms are in `android/relay/src/protocol.ts`:
- No access key is needed, which is the point: the new computer does not have one yet.
- Each socket may send at most 4 frames of at most 4096 bytes.
- A room lives 15 minutes.

A text `ping` keeps the socket alive.

**The key.** The phone makes its own ephemeral P-256 key. Then:

    shared = ECDH(x-coordinate, 32 bytes)
    key    = HKDF-SHA256(ikm = shared, salt = room, info = "nyeko-setup/v1", 32 bytes)

**Phone → computer.**

    0x01 ‖ phone public key (65) ‖ nonce (12) ‖ AES-256-GCM(JSON {relay, access, phone})

with aad `"nyeko-setup/v1 hello <room>"`.

**Computer → phone.**

    0x02 ‖ nonce (12) ‖ AES-256-GCM(JSON {code, name} or {error})

with aad `"nyeko-setup/v1 done <room>"`. `code` is the computer's usual pairing link (`…/#pair=…`), which the phone adds like a scanned one.

## Why this is safe

- **The QR is the secret.** Only someone who sees the screen knows `pub` and can compute the join proof. The relay never sees the access key in clear: it is encrypted to the computer's key.
- **A wrong public key gets nothing.** Someone who swaps `pub` (a tampered link) cannot make the computer decrypt anything, so it never answers.
- **The relay forwards only.** It cannot read the frames, and a setup room cannot be used as a normal room.
- **A failed decrypt ends the code.** On Windows the ephemeral key is single-use (ring), so a hello that fails to decrypt ends that code, and the user shows a new one.

## Tests

- `node phone/tests/setup.test.mjs`: phone and computer in JS over the relay's Node twin, including refusals and a tampered offer.
- `node phone/tests/relay.test.mjs`, `cd android/relay && npm test`: the setup-room rules.
- `cargo test --lib setup::` (in `windows/src-tauri`): the Rust crypto, plus, with `-- --include-ignored`, the Rust computer against the web app's phone side (`phone/tests/setup-windows.mjs`).
