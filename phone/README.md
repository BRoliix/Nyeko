# Nyeko on your phone

A web app (no App Store, no Apple Developer account) that talks to Nyeko on your Mac from anywhere:

- **Now**: your coding sessions, Claude Code's permission requests (Allow needs Face ID, Deny never does) and its questions.
- **Mac**: what's playing (any app) with play/pause/skip, your next event, the focus timer, record a meeting, take a
  screenshot, open an app from your Quick launch list.
- **Nyo**: chat with Nyo. Mac commands ("pause", "start a timer", "what's next") are done on the Mac; anything else is
  answered by Claude with your plan, on the Mac.
- **Alerts**: when Claude needs you and the app is closed, your phone shows "Nyo needs you". The push carries **no
  content** (nothing about the command leaves the Mac).

## How it connects

```
iPhone (web app) ──wss──▶ your relay (Cloudflare Worker) ◀──wss── Nyeko on the Mac
         └──────── end-to-end encrypted (AES-256-GCM, keys from the pairing) ────────┘
```

The relay is `android/relay` in this repo (Coucou's link relay, plus one change: a browser may send the access key as a
WebSocket sub-protocol). It forwards opaque frames, stores nothing, logs nothing and never sees a key. The protocol is
Coucou's own (docs/ANDROID_LINK.md inside docs/RELAY_LINK.md): decisions only apply to the request still pending, once,
within 115 s; a command cut at 500 characters can only be denied from the phone.

It is **not** your `broly-relay` worker (that one is the iPhone Live Activity relay). This is a second, separate worker.

## Set up (once, about 10 minutes)

### 1. Deploy the relay

```
cd android/relay
npm install
npx wrangler login
openssl rand -base64 32 | tr '+/' '-_' | tr -d '='    # your access key: copy it (it is shown once, keep it in your password manager)
npx wrangler secret put ACCESS_KEY                     # paste it
npx wrangler deploy                                    # prints https://coucou-link.<you>.workers.dev
curl https://coucou-link.<you>.workers.dev/            # answers "Coucou link relay"
```

### 2. Deploy the web app (Cloudflare Pages)

From the repo root:

```
npx wrangler pages project create nyeko-phone --production-branch main    # first time only
npx wrangler pages deploy phone/web --project-name nyeko-phone --branch main
```

It prints the address, usually `https://nyeko-phone.pages.dev` (if the name is taken, Cloudflare adds a suffix: use the
address it prints).

### 3. On the Mac

Nyeko window → **Phone**:

1. **Relay address**: `wss://coucou-link.<you>.workers.dev` (press Return).
2. **Access key**: paste it, **Save** (stored in the Keychain).
3. **Web app address**: the Pages address from step 2 (press Return).
4. Turn on **Let my phone reach Nyeko through the relay**. The status says *Ready · waiting for your phone*.

### 4a. On the iPhone

1. Scan the QR code on the Phone page with the Camera: Safari opens Nyeko.
2. **Share → Add to Home Screen**, then open **Nyeko from the Home Screen** (alerts only work there).
3. On the Mac click **Copy pairing code**; on the iPhone tap **Paste pairing code** (Universal Clipboard).
4. Settings (gear) → **Set up Face ID**, then **Turn on alerts**.

### 4b. On an Android phone (Chrome)

1. Scan the QR code on the Phone page with the camera (or Google Lens): Chrome opens Nyeko and **pairs at once** (on
   Android the installed app shares Chrome's storage, so there is nothing to paste).
2. Settings (gear) → **Install Nyeko** (or Chrome menu ⋮ → Install app).
3. Settings → **Set up screen lock** (fingerprint or PIN), then **Turn on alerts**.

The Mac's Phone page then says *Connected* (to "iPhone · Nyeko" or "Android · Nyeko"), and **Send a test alert** should
buzz the phone. One pairing at a time: pairing a second phone with the same code makes the relay drop the first one
(one phone per room); use **Pair again** to move to another phone.

## Nyeko for Android (the app)

On Android, the web app works, and there is also a real app (`android/`, upstream's Coucou for Android made into
Nyeko). It adds what a web page can't do:

- **Nyo on your screen**: a small Nyo floating on the edge of the screen over your other apps. His face says how your
  sessions are (asleep, calm, working, needs you, done), a bubble says when something needs you, a tap opens Nyeko.
  Drag him to either side.
- **The island**: a black island that drops from the camera hole while Claude works, shows how it ended, and goes back
  up. On a Samsung it grows out of the punch-hole camera.
- Approvals and questions with the fingerprint or screen lock, alerts that keep working with the app closed, widgets,
  a quick-settings tile.
- Everything Nyeko does on the iPhone: sessions (read them, message Claude), New session, Your Mac (music, timer,
  Notetaker, screenshot, apps), and Nyo's chat (the Chat tab).

It pairs through the same relay, in a room of its own, so the iPhone and the Android phone can both be connected.

### One QR for both phones

The Phone page's QR code works on both. On an iPhone it opens the web app. On Android, Chrome opens a page that
offers **Open in the Nyeko app**: it opens the app, which pairs after you confirm. If the app is not installed,
Chrome comes back to the page with **Download the app**: install it, then tap Open again.

The Download button, and the page **/download.html** (version, size, date and SHA-256 of the newest build, like the
PDF editor's site), take the newest **GitHub Release** (see *Releasing Nyeko*).

### Releases and updates (set up once)

Every **Release Nyeko** run (see *Releasing Nyeko*) tests the app, builds it and publishes it with the Mac and Windows
installers (`Nyeko.apk` and its SHA-256 in `nyeko-android.json`). The Nyeko site serves the newest one at `/downloads/android` (the page `/download.html` shows it), and the app on the phone updates itself from
there: it looks when it opens and every few hours, downloads the new build, checks its SHA-256 and installs it. The
first update asks you to confirm; after that Android lets Nyeko update itself quietly. Android refuses any APK not
signed with the same key, so nothing else can be pushed to the phone this way.

The releases are public (github.com/BRoliix/Nyeko). The site can read them with a read-only token of its own, for
GitHub's higher rate limit:

1. GitHub → Settings → Developer settings → **Fine-grained tokens** → Generate: repository access *Public
   repositories (read-only)*, permission **Contents: Read-only**, the longest expiry you like. Copy it.
2. On the Mac:
   ```
   cd ~/Nyeko/android/relay
   npx wrangler pages secret put GITHUB_TOKEN --project-name nyeko-phone
   npx wrangler pages deploy ../../phone/web --project-name nyeko-phone --branch main
   ```
   Paste the token when asked. It is kept by Cloudflare, never in git, never sent to a browser.

### Install it

1. On the phone, open **https://nyeko-phone.pages.dev/download.html** (or scan the Mac's QR code: the page offers
   the app) and tap **Download for Android**.
2. Open the file. Android asks to allow installs from your browser: allow it once. It installs as **Nyeko**.
3. **Pair.** Scan the Mac's QR code (Nyeko → Phone) with the camera and tap **Open in the Nyeko app**, or use the
   app's own **Scan** with the code in **4 · Nyeko for Android**.
4. **Nyo on your screen.** In the app: Settings → turn on **Nyo on your screen** (and, if you want it, the island
   above it). Android opens *Display over other apps*: turn it on for Nyeko and come back.
5. **Keep it alive on a Samsung.** Settings → Apps → Nyeko → Battery → **Unrestricted**.

The app is a debug build signed with GitHub's throwaway key: an update installs over it as long as it comes from the
same workflow. If Android refuses an update ("conflicts with an existing package"), uninstall Nyeko first and pair again.

## Talking to a coding session

On the **Now** tab, tap a session: you see its conversation (what you asked, Claude's answers, one line per tool it
used) and can send it a message. **Show on Mac** brings it forward on the Mac instead. Claude Code sessions only.

How your message gets in:

- **Claude is working** (or waiting for you): it waits on the Mac and goes to Claude the moment the turn ends (through
  the session's Stop hook: Claude reads it and carries on). Nothing on the Mac moves. You can cancel it until then.
- **Claude is idle**: Nyeko types it into the session for you. In **Terminal** or **iTerm** it finds the session's own
  tab. In **VS Code**, Warp and others it brings that app forward and types where its cursor is, so leave Claude's box
  selected there. Typing needs Accessibility for Nyeko (System Settings → Privacy & Security → Accessibility), and the
  first time, permission to control Terminal or iTerm. Nyeko never types while the Mac is locked: the message then waits
  for the end of the next turn.

Sending asks for Face ID (or the screen lock), then not again for 10 minutes. The conversation is read from Claude
Code's transcript on the Mac only while the session screen is open, and travels end-to-end encrypted like everything
else. The Mac's side is `NotchBuddy/Sources/App/SessionChat.swift` and `SessionTranscript.swift`.

## Starting a new session

**Now → ＋ New session**: pick one of your recent project folders, say what Claude should do (or leave it empty), and
**Start session**. Your Mac opens a terminal there and starts Claude Code, exactly like the notch's New session card,
and the phone opens the new session as soon as Claude Code is up, so you can follow it and talk to it. The folders are
the ones Nyeko has seen sessions run in (or that you picked in the notch's card): the phone can't start anything
anywhere else. Starting asks for Face ID, like messages.

## Several computers, one phone

Both phones can hold several computers: your Mac and your Windows PC, say.

- **iPhone (web app)**: Settings › **Your computers** › **＋ Add a computer**, or just scan another computer's QR with the
  camera. Each one can be used or removed there. Now lists every computer's sessions together, each labelled; the
  Computers tab has each one's controls.
- **Android app**: Settings › **Your computers** lists them with their state; **Add a computer** scans another QR,
  **Remove** (tap twice) forgets one. The first computer you paired keeps everything it had (island, widgets, chat);
  the others add their sessions, approvals and questions to the same lists, named "Claude Code · Work PC". On Home, the
  computer card has a chip per computer when there are several.

Each computer **and each account on it** is its own computer to the phone: it is named with the account ("MacBook Pro ·
broly", "MacBook Pro · work", "LENOVO · Rohil") and carries an id of its own in its pairing code. Scanning a computer you
already have (paired again, same account) replaces it instead of adding a copy; two accounts on one Mac, or two computers
with the same name, never replace each other. A computer paired before this learns its id the next time it connects. There is no limit on how many
computers a phone holds, and a computer takes several phones at once (the Mac: the web app and the Android app; Windows:
up to 8 connections).

### What the phone controls on each computer

Sound (− / Mute / +), **Lock**, **Screen off**, **Sleep**, **Restart** and **Shut down** (tap twice, then Face ID or the
screen lock; open apps may still ask to save), **Open any app** (search every installed app), what is playing, a
screenshot (kept on the computer), and the coding sessions: their conversation, messages to Claude, new sessions.

## Your Windows PC

Nyeko for Windows is the Windows app of this repo (`windows/`) with the same `nyeko` messages as the Mac
(`windows/src-tauri/src/phone_link/nyeko.rs`), named Nyeko, with the Nyeko icon and its own folders
(`%APPDATA%\Nyeko`, `%LOCALAPPDATA%\Nyeko`) and keys, so it never mixes with an upstream Coucou. It never offers
upstream's Coucou updates. The character on screen is still drawn as Mochi until the Nyo redesign reaches it.

1. **Install it**: `https://nyeko-phone.pages.dev/download.html` › Windows (or the newest release on GitHub ›
   `Nyeko-Windows-setup.exe`). SmartScreen warns because it is not signed: More info › Run anyway.
2. **Turn on the phone link**: its Settings › Android phone › on.
3. **Away from home Wi-Fi** (the relay): turn it on, relay address `wss://coucou-link.broliix.workers.dev`, and the same
   access key as the Mac (the Mac's Android link on its Phone page carries it: the part after `access=`).
4. **Scan its QR**: with the iPhone Camera app: Safari opens a page with **Copy pairing code**; tap it, open Nyeko from
   your Home Screen, then Settings › Your computers › ＋ Add a computer › **Paste pairing code** (the Home Screen app
   keeps its own storage, so the code goes through the clipboard). Your Mac stays paired beside it. On Android: the
   Nyeko app › Settings › Your computers › Add a computer. One QR serves both, as on the Mac; the web app gets its own
   relay room.

On Windows, a message to an idle session is typed into its terminal (its window comes forward, on one line); while
Claude works it waits for the end of Claude's turn (the Stop hook, through `coucou-hook`). Nyo's chat knows a few
words there (play, pause, next, louder, quieter, mute, lock, screen off, screenshot).

## Releasing Nyeko

Everything lives on `main`. One workflow makes every installer: GitHub › Actions › **Release Nyeko** › Run workflow. It
builds the Mac app (`Nyeko.dmg`, universal), the Windows app (`Nyeko-Windows-setup.exe`) and the Android app
(`Nyeko.apk`) from the same commit, with one build number, and publishes them together as one GitHub Release,
**Nyeko 1.0.<build>** (marked Latest). If one of them fails, nothing is published. It keeps the three newest releases and
deletes older ones.

The other workflows (`Build`, `Windows`, `android`) only test and build; they publish nothing.

The Android app is signed with one kept key, or a new build would not install over the old one. Keep it for good as a
repository secret: the first Release Nyeko run makes the key and leaves it as a one-day artifact, **nyeko-signing-key**.
Download it, unzip, run `base64 -i debug.keystore | pbcopy`, and paste it as the secret `NYEKO_DEBUG_KEYSTORE`
(Settings › Secrets and variables › Actions). Until then it lives in the Actions cache, which GitHub empties after
7 days without a run.

## The download page

`https://nyeko-phone.pages.dev/download.html` offers each app from the newest release (it needs the `GITHUB_TOKEN`
Cloudflare secret above), and the Android app updates itself from it.

### The Mac installer

- **On your Mac** (signed with your own certificate, so permissions and Keychain items stay):
  `./scripts/nyeko-dmg.sh` → `dist/Nyeko-<version>.dmg`.
- **From GitHub** (Release Nyeko): to sign it like your Mac does, add two repository secrets once:
  `MAC_CERT_P12` (Keychain Access › your "Apple Development" certificate › Export as .p12, then
  `base64 -i cert.p12 | pbcopy`) and `MAC_CERT_PASSWORD`. Without them the DMG is signed ad hoc: Nyeko runs, but macOS
  asks for its permissions again.
- Installing: open the DMG, drag Nyeko onto Applications; the first time, right-click Nyeko › Open (not notarized).

## Updating the web app

`npx wrangler pages deploy phone/web --project-name nyeko-phone --branch main`. The app checks the network first, so the
new version shows the next time it opens.

## Security notes

- The pairing code holds the pairing key, the relay's access key and a token: treat it like a password. The Mac clears
  it from the clipboard after a minute. **Pair again** (Mac → Phone) makes a new key and cuts the old phone off.
- On the phone, the pairing is kept in the web app's storage on that phone only.
- Allow and answers need Face ID, or the fingerprint / screen lock on Android (WebAuthn, on the phone); Deny never does. The Mac still decides: it ignores a late,
  repeated or mismatched decision.
- A message to a coding session can make Claude act, so sending one asks for Face ID too. Claude's tools still ask for
  your approval as usual: a message never approves anything.
- The relay and Cloudflare see IP addresses, that a pairing exists, when each side is online, and padded frame sizes.
  They cannot read anything.

## Tests

```
node --test phone/tests/relay.test.mjs      # the crypto against android/relay/test-vectors.json
```

`phone/tests/e2e.mjs` runs a phone, a stand-in Mac and the relay's Node twin end to end (see the file's first lines).
