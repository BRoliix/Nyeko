<div align="center">

<a href="docs/media/hero.mp4"><img src="docs/media/hero.gif" width="900" alt="Nyo, a tabby kitten, sits in a MacBook notch and goes from idle to thinking, working, asking 'can I run git push?' and 'all done!', next to the word Nyeko."></a>

**Nyo lives in your Mac's notch (or at the top of your PC's screen). He keeps an eye on your AI coding agents,<br>
taps you on the shoulder when they need you, and turns your phone into the remote for all your computers.**

[**Download**](https://nyeko-phone.pages.dev/download) ·
[Meet Nyo](#meet-nyo) ·
[What it does](#what-it-does) ·
[Your phone](#your-phone) ·
[One mouse](#one-mouse) ·
[How it works](#how-it-works) ·
[Get started](#get-started) ·
[Credits](#credits)

</div>

---

<a id="meet-nyo"></a>

## 🐾 Meet Nyo

Nyo is a little tabby kitten with mint eyes, three tangerine stripes on his forehead and a tail that shows his mood.
He is drawn entirely in code (no images, no Lottie, no Rive), the same way on the Mac, Windows, Android and the
iPhone, so every blink, ear twitch and tail flick happens live. His face tells you how your agents are doing
without you reading a single line:

<div align="center">
<a href="docs/media/moods.mp4"><img src="docs/media/moods.gif" width="800" alt="Twelve cards, one for each of Nyo's moods: idle, thinking, working, searching, needs you, question, finished, error, rate limited, sleeping, dizzy and loved."></a>
</div>

He also has **29 sounds of his own**, made from nothing but maths (`python3 scripts/nyeko-sounds.py` writes them), and
he reacts when you pet him. Poke him too many times and he gets dizzy. You were warned.

---

<a id="what-it-does"></a>

## 🧶 What Nyo does all day

You start Claude Code (or Codex, Gemini CLI, Antigravity…) in a terminal or an editor. A tiny hook tells Nyeko what
happens, and the island at the top of your screen shows it: what the session is reading, editing and running, and
when it wants your permission. You answer **right there**, without finding the terminal again.

<div align="center">
<a href="docs/media/island.mp4"><img src="docs/media/island.gif" width="900" alt="The island at the top of the screen: Nyo greets, a session starts, the island shows it reading server.rs, editing MacShare.swift and running cargo test, then asks for permission to run git push; Allow is pressed and the island says Claude Code finished."></a>
<br><sub>The real island, running its own code with a made-up session. <a href="docs/media/island.mp4">▶ Watch the video</a></sub>
</div>

- **Every session, one by one.** Claude Code, Codex, Gemini CLI, Antigravity, GitHub Copilot CLI, OpenCode, Amp,
  Muse Code and Hermes. Tap a session to bring its terminal or editor to the front.
- **Approve or deny from the island.** Nyeko never says yes on its own. If you don't answer, the terminal asks you as
  usual, and Claude Code is never held up waiting for the app.
- **Answer Claude's questions, read its answer, chat with Nyo.** Typed messages run Mac commands first ("open
  Spotify", "next song", "take a screenshot") and go to Claude otherwise.
- **A Mac home when nothing is running:** what's playing in any app, your next meeting, the Notetaker, your favourite
  apps and quick actions, plus WhatsApp, Mail and Calendar notifications.
- **The Nyeko window:** dictation anywhere (hold a key, speak, let go: it's typed for you), a Notetaker that writes your
  calls person by person with a summary and to-dos (offline, no bot in the meeting), statistics, integrations
  (GitHub, Vercel, Stripe, n8n, Notion, Resend…) and "OK Nyeko".

<div align="center">
<img src="docs/media/window.png" width="900" alt="Three windows of the Nyeko app: Dictation, Notetaker and Statistics.">
</div>

---

<a id="your-phone"></a>

## 📱 Your computers in your pocket

The phone side is a web app you add to your iPhone's Home Screen, plus a native Android app. One phone holds **all
your computers** (every Mac account and every Windows PC is its own), and everything goes through your own relay,
end-to-end encrypted.

<div align="center">
<img src="docs/media/phone-app.png" width="900" alt="Five phone screens: Now with a permission card, a session's conversation, the Computers page, the trackpad and the file browser.">
</div>

<div align="center">
<a href="docs/media/phone.mp4"><img src="docs/media/phone.gif" width="620" alt="A phone walking through the app: approve from anywhere, talk to a session, your computers, a trackpad in your pocket, open any folder."></a>
<br><sub><a href="docs/media/phone.mp4">▶ Watch the video</a></sub>
</div>

| | |
|---|---|
| ✅ **Approve** | Permission cards land on your phone. *Allow* needs your Face ID, *Deny* never does. |
| 💬 **Talk to a session** | Read what it did and Claude's answer, then tell it what to do next. If Claude is busy, your message waits for the end of its turn. |
| 🚀 **Start a session** | Pick a recent folder (or browse to one) and Claude Code starts there on your computer. |
| 🗂️ **Files** | Browse your computer's folders and preview text and images. |
| 🖱️ **Trackpad and keyboard** | Move, click, scroll, right-click, drag and type on any of your computers. |
| 🎵 **Controls** | Music, volume, lock, sleep, restart, open any app. |

---

<a id="one-mouse"></a>

## 🖱️ One mouse, two computers

Got a Mac and a Windows laptop side by side? Push the pointer off the edge of one screen and it carries on on the other,
**with the keyboard**. It works both ways, shortcuts keep their habits (⌘C copies on the PC, Ctrl+C copies on the Mac),
and touching the other computer's own mouse takes it straight back.

<div align="center">
<a href="docs/media/share.mp4"><img src="docs/media/share.gif" width="760" alt="A PC and a Mac side by side: the pointer leaves the Mac by its left edge, appears on the PC, types a sentence there, then goes back to the Mac."></a>
</div>

Your phone only introduces them (Computers → **One mouse for both** → which side the PC is on). After that the two
talk to each other directly over your Wi-Fi. The details are in [`docs/SHARED_MOUSE.md`](docs/SHARED_MOUSE.md).

---

<a id="how-it-works"></a>

## 🔧 How it works

<div align="center">
<img src="docs/media/how-it-works.png" width="900" alt="Diagram: your AI agents talk to Nyeko through nyeko-hook; Nyeko talks to your own relay (encrypted), which talks to your phones; the Mac and the PC share a mouse over the Wi-Fi.">
</div>

| Part | Where | What it is |
|---|---|---|
| **Mac app** | [`NotchBuddy/`](NotchBuddy) | Swift 6, SwiftUI + AppKit. Bundle `com.broliix.nyeko`. Lives in the notch. |
| **Windows / Linux app** | [`windows/`](windows) | Tauri 2 (Rust + TypeScript). Lives at the top of the screen. |
| **Android app** | [`android/`](android) | Kotlin + Jetpack Compose, with a floating Nyo and a camera-hole island. |
| **iPhone** | [`phone/web/`](phone/web) | The web app (Add to Home Screen), served from Cloudflare Pages. |
| **Relay** | [`android/relay/`](android/relay) | A Cloudflare Worker you deploy yourself. It only forwards encrypted frames. |
| **Hooks** | `nyeko-hook` | The tiny relay each agent calls. If Nyeko doesn't answer, it gets out of the way at once. |

More in [`docs/`](docs): the agents ([`AGENTS.md`](docs/AGENTS.md)), the relay ([`RELAY_SETUP.md`](docs/RELAY_SETUP.md)),
the phone link ([`RELAY_LINK.md`](docs/RELAY_LINK.md)), files ([`PHONE_FILES.md`](docs/PHONE_FILES.md)), the trackpad
([`REMOTE_INPUT.md`](docs/REMOTE_INPUT.md)) and the shared mouse ([`SHARED_MOUSE.md`](docs/SHARED_MOUSE.md)).

### 🔒 Nyo's promises

- **No telemetry, no account.** Nyeko only talks to the services *you* set up.
- **End-to-end encrypted.** Your relay forwards frames it can't read; the pairing keys stay on your devices.
- **Secrets in the Keychain** (Windows' Credential Manager, Linux's Secret Service), never in files or in git.
- **Never approves on its own.** No permission, email or command goes ahead without your click.
- **Your `~/.claude/settings.json` is safe.** A dated backup, a merge, and the diff shown before anything is written.
- **0% CPU when the island is hidden.**

---

<a id="get-started"></a>

## 🚀 Get started

### 1. Install

Head to the **[download page](https://nyeko-phone.pages.dev/download)**, or grab the files from the latest
[release](https://github.com/BRoliix/Nyeko/releases/latest):

| | File | Notes |
|---|---|---|
| 🍎 **Mac** (macOS 15+) | `Nyeko.dmg` | Drag Nyeko into Applications. |
| 🪟 **Windows** 10/11 | `Nyeko-Windows-setup.exe` | Not code-signed yet: SmartScreen → **More info** → **Run anyway**. |
| 🤖 **Android** 11+ | `Nyeko.apk` | Allow installs from your browser when Android asks. |
| 📱 **iPhone** | [nyeko-phone.pages.dev](https://nyeko-phone.pages.dev) | Open it in Safari → Share → **Add to Home Screen**. |

### 2. Let Nyo see your agents

Open Nyeko → **Agents** and install the hooks for the agents you use. Nyeko shows you exactly what it will change in
each agent's settings before it writes anything.

### 3. Pair your phone

1. Deploy your relay once (a free Cloudflare account is enough): [`phone/README.md`](phone/README.md).
2. On the computer: Nyeko → **iPhone and Android**. Scan the QR code with your phone.
3. Every next computer can be set up **from the phone** in a few seconds: [`docs/RELAY_SETUP.md`](docs/RELAY_SETUP.md).

### 4. Give the Mac its permissions

**Accessibility** (for the trackpad, the shared mouse and typing into sessions) and, if you want it, **Full Disk
Access** for the Notification Center feed. The first time you share the mouse, macOS also asks to let Nyeko find
devices on the local network.

### 🩹 Something not right?

| Symptom | Fix |
|---|---|
| The trackpad or shared mouse does nothing on the Mac after an update | System Settings › Privacy & Security › **Accessibility**: remove Nyeko with **–**, open Nyeko again and allow it. A new build needs a new OK. |
| A computer disappears from the iPhone app | Safari and the Home Screen app keep separate lists. Use the Home Screen app (Settings › **Copy for the app** moves a computer over). |
| "The relay could not be reached" | Redeploy your relay (`npx wrangler deploy` in `android/relay`) and check its address in the app. |
| Windows says it protected your PC | That's SmartScreen on an unsigned app: **More info** → **Run anyway**. |

---

## 🛠️ Build it yourself

```sh
# Mac, every day (signed with your own Apple Development certificate, installed in /Applications)
./scripts/nyeko-install.sh

# Windows / Linux
cd windows && npm install && npm run tauri dev

# Android
cd android && ./gradlew assembleDebug

# The phone web app
npx wrangler pages deploy phone/web --project-name nyeko-phone --branch main
```

**Releases:** GitHub › Actions › **Release Nyeko** › Run workflow. It builds the Mac, Windows and Android apps from
`main` and publishes them together; the download page and the Android app's updater pick them up.

**Regenerating the brand:** `python3 scripts/nyeko-icons.py` (every platform's icons) and
`python3 scripts/nyeko-sounds.py` (the 29 sounds).

---

<a id="credits"></a>

## 💛 Credits

Nyeko stands on the shoulders of some lovely people and projects.

### Where it started

- **[Coucou](https://github.com/Louis-CFM/coucou)** by **Louis Raillé** (MIT). Nyeko began as a fork of Coucou: the
  island, the hooks, the approval cards, the phone link and much more started there. Thank you, Louis.
- **Coucou for Android** by **Rhytam Biswas** (MIT): the base of Nyeko's Android app and its relay.

Their copyright notices stay in [`LICENSE`](LICENSE) and [`android/LICENSE`](android/LICENSE), next to Nyeko's.

### Speech and voices (offline, on your computer)

- **[Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)** by **NVIDIA** (CC BY 4.0): dictation
  and the Notetaker.
- **[FluidAudio](https://github.com/FluidInference/FluidAudio)** by FluidInference (Apache-2.0): runs Parakeet and
  speaker separation on the Mac.
- **[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)** by the k2-fsa project (Apache-2.0), with the ONNX models
  converted by Fangjun Kuang: runs them on Windows and Linux.
- **[pyannote segmentation 3.0](https://huggingface.co/pyannote/segmentation-3.0)** (MIT) and the
  **[3D-Speaker](https://github.com/modelscope/3D-Speaker)** CAM++ speaker embedding (Apache-2.0): telling voices apart
  in the Notetaker.

### Built with

- **Mac:** Swift, SwiftUI and AppKit, with [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the project.
- **Windows and Linux:** [Tauri](https://tauri.app) (MIT / Apache-2.0), [Vite](https://vitejs.dev) and TypeScript,
  and the Rust crates [tokio](https://tokio.rs), [rustls](https://github.com/rustls/rustls),
  [ring](https://github.com/briansmith/ring), [rcgen](https://github.com/rustls/rcgen),
  [reqwest](https://github.com/seanmonstar/reqwest), [serde](https://serde.rs),
  [tokio-tungstenite](https://github.com/snapview/tokio-tungstenite), [mdns-sd](https://github.com/keepsimple1/mdns-sd),
  [cpal](https://github.com/RustAudio/cpal), [qrcode](https://github.com/kennytm/qrcode-rust),
  [keyring](https://crates.io/crates/keyring), [lopdf](https://github.com/J-F-Liu/lopdf), [miniz_oxide](https://github.com/Frommi/miniz_oxide) and
  [windows-rs](https://github.com/microsoft/windows-rs).
- **Android:** Kotlin, [Jetpack Compose](https://developer.android.com/compose) and
  [CameraX](https://developer.android.com/media/camera/camerax) (Apache-2.0), and
  [ZXing](https://github.com/zxing/zxing) (Apache-2.0) for the QR codes.
- **Relay and phone app:** [Cloudflare Workers and Pages](https://workers.cloudflare.com).
- **Fonts:** [Fredoka](https://github.com/hafontia/Fredoka-One) and [Nunito](https://github.com/googlefonts/nunito)
  (SIL Open Font License 1.1, in [`phone/web/fonts/`](phone/web/fonts)).

### Nyo and Nyeko

- **Nyo, the Nyeko name, the icons, the sounds and the art in this README** by **Rohil Sagar**
  ([@BRoliix](https://github.com/BRoliix)).
- Every picture and video above was made by Nyeko's own code (Nyo's engine, the real island and the phone app with
  made-up data), recorded with headless Chrome and [FFmpeg](https://ffmpeg.org).

---

## 📜 Licence

- **Code:** [MIT](LICENSE), like Coucou's. Use it, fork it, learn from it.
- **Nyo, the Nyeko name, the icons, the sounds and the art:** © 2026 Rohil Sagar, all rights reserved, even where code
  draws or generates them. See [`LICENSE-ASSETS.md`](LICENSE-ASSETS.md) for what you can and can't do with them.
- **Coucou's name, Mochi, its icon, sounds and media** belong to Louis Raillé and are not part of Nyeko.

Nyeko is an independent project. It is not made, endorsed or supported by Louis Raillé or the Coucou project, so
please send Nyeko's issues [here](https://github.com/BRoliix/Nyeko/issues), not to Coucou.

<div align="center">
<br>
<img src="NotchBuddy/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="72" alt="Nyeko icon"><br>
<sub>Made with too much coffee and one very patient cat.</sub>
</div>
