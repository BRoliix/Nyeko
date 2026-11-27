# One mouse and keyboard for a Mac and a PC

Nyeko lets a Mac and a Windows PC that sit side by side share one mouse and keyboard: push the pointer off the side of
one screen and it carries on on the other computer, with the keyboard following it. Either computer's mouse and
keyboard works; touching the other computer's own mouse takes it straight back.

## Setting it up

1. Both computers run Nyeko with the phone link on (Mac: Nyeko → Phone; PC: Settings → Phone) and are on the same Wi-Fi.
2. On the phone (the Nyeko web app, with both computers added), open **Computers** → either computer → **One mouse for
   both**, and tap the side the PC stands on: *PC on the left* or *PC on the right* (as seen sitting at the Mac).
3. The first time, the Mac asks for **Accessibility** (System Settings › Privacy & Security › Accessibility: allow Nyeko)
   and macOS may ask to let Nyeko **find devices on the local network**: allow both.

The phone only introduces them: it asks the PC for its address on the Wi-Fi and hands it to the Mac. After that the Mac
connects to the PC directly whenever both are on, phone or not. **Swap sides** and **Turn off** are on the same card.

## How it behaves

- Keys go by position, and the modifiers keep each computer's habits: on the PC the Mac's ⌘ and ⌃ are Ctrl (⌘C copies),
  ⌥ is Alt. On the Mac the PC's Ctrl is ⌘ (Ctrl+C copies), Win is ⌃ and Alt is ⌥.
- While the Mac drives the PC, the Mac's pointer waits at the edge it left by. While the PC drives the Mac, the PC's
  pointer waits in the middle of its main screen.
- The pointer does not cross while a button is held (dragging a window stays on its own computer).
- If the link drops or goes silent for 7 seconds, each computer gets its own mouse and keyboard back.
- Windows does not let an app type into windows run as administrator unless it is one too; those stay out of reach.
- Linux: not yet.

## Protocol

The Mac is the client of the PC's phone link (docs/ANDROID_LINK.md): TLS on the local network with the PC's certificate
pinned by its SHA-256 fingerprint, then `{"type":"hello","v":1,"token":…,"caps":["share"]}`. The link comes from the PC's
pairing link for phones on its Wi-Fi (`nyeko://pair?v=1&host=…&port=…&fp=…&token=…&name=…&cid=…`), which a phone gets
with `{"type":"shareOffer"}` (answered `{"type":"shareOffer","ok":true,"link":…}`) and passes on to the Mac with
`{"type":"share","action":"setup","link":…,"side":"left"|"right"}`; `action` is also `side` and `off`. The Mac keeps the
token in its Keychain.

On the Mac–PC connection, either way:

| Line | Meaning |
| --- | --- |
| `{"type":"share","side":"left"}` | Mac → PC: the PC stands on the Mac's left (`right`, or `off`) |
| `{"type":"shareState","ok":…,"note":…}` | PC → Mac: whether this PC can share |
| `{"type":"shareEnter","y":0.42}` | The sender's pointer crossed at this height (0 top, 1 bottom): the receiver is now driven |
| `{"type":"input","raw":true,"e":[…]}` | The driver's events (below), about every 8 ms |
| `{"type":"shareLeave","y":0.42}` | The driven computer's pointer went back across (or its own mouse was touched): control returns |
| `{"type":"ping"}` / `{"type":"pong"}` | Every 2 s; 7 s of silence ends any sharing in progress |

Events (`e`): `move {dx,dy}` (pixels, the driver's pointer speed), `down`/`up {b: left|right|middle}`,
`scroll {dx,dy}` (pixels; dy > 0 shows what is further down), `kd`/`ku {key}` (a key pressed or let go, named as in
docs/REMOTE_INPUT.md, plus `cmd`, `ctrl`, `alt`, `shift`, already in the receiver's habits), `release`.

Code: Mac `NotchBuddy/Sources/App/PhoneWeb/MacShare.swift` (with `MacRemoteInput.swift`), PC
`windows/src-tauri/src/phone_link/share.rs` (with `remote_input.rs`), phone `phone/web/app.js` (`shareCard`).
