# The phone as trackpad and keyboard

Computers tab → **Trackpad and keyboard** turns the phone into the computer's touchpad, with a keyboard. The chips at
the top switch between your computers.

## Using it

- **Move:** one finger. Slow movements are precise; fast ones go far.
- **Click:** tap. Tap twice quickly to double-click.
- **Right-click:** tap with two fingers, or the **Right** button.
- **Scroll:** two fingers.
- **Drag:** hold one finger still for a moment (the pad outlines), then move; lift to drop. Or hold **Left** and move.
- **Keyboard:** the keyboard button at the top right. What you type on the phone goes to the app in front on the
  computer, in any language. The keys row has Esc, Tab, arrows, ⌫ and Enter. The modifier keys (⌘ ⌥ ⌃ ⇧ on a Mac,
  Ctrl Alt Shift Win on Windows) stay down for the next key: ⌘ then C copies.

## Permissions and safety

- The phone asks for **Face ID** (or its screen lock) before it opens the trackpad.
- **Mac:** Nyeko needs **Accessibility** (System Settings › Privacy & Security › Accessibility), the same permission
  typing into a session uses. The first time, macOS asks on the Mac.
- **Windows:** nothing to allow. Windows doesn't let any app move the pointer over an administrator window (UAC
  prompts, Task Manager run as administrator) unless Nyeko itself runs as administrator.
- **Linux:** not yet; the phone says so.
- When the phone locks or leaves the trackpad, any held button is let go.

## Messages (nyeko, end-to-end encrypted like the rest)

`{type:"input", e:[…]}` from the phone, about 25 a second (the relay takes at most 30 frames a second from a phone).
Each event: `{k:"move", dx, dy}` (pixels, already accelerated), `{k:"down"|"up", b:"left"|"right"}`,
`{k:"click", b, n}` (n = 2 for a double-click), `{k:"scroll", dx, dy}` (pixels; dy > 0 shows what is further down),
`{k:"text", t}` (up to 500 characters), `{k:"key", key, mods}` (key: enter, tab, space, backspace, delete, esc, arrows,
home, end, pageup, pagedown, f1–f12, a letter, a digit or punctuation; mods: cmd, ctrl, alt, shift, win),
`{k:"release"}`, `{k:"hello"}`. The computer answers a hello with `{type:"inputState", ok, note}`.

A move is spread over up to four steps 8 ms apart on the computer, so the pointer glides between batches.

Code: Mac `NotchBuddy/Sources/App/PhoneWeb/MacRemoteInput.swift`, Windows `windows/src-tauri/src/phone_link/remote_input.rs`
(with tests), phone `phone/web/app.js` (`openPad`, `padTab`, `touchSurface`).

Sharing one mouse and keyboard between a Mac and a PC beside it (push the pointer off the side of the screen) is described in [SHARED_MOUSE.md](SHARED_MOUSE.md).
