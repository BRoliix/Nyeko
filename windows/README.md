<div align="center">

<img src="src-tauri/icons/128x128.png" width="96" alt="Nyeko icon">

# Nyeko for Windows and Linux

**Nyo doesn't get a notch on a PC, so he lives at the top of your screen instead.**

Approve Claude Code permissions, watch your sessions work, drop a file, chat with Claude, keep an eye on your services
and reach this PC from your phone, without leaving what you're doing.

</div>

---

This is the Tauri 2 version of Nyeko (Rust + TypeScript), the PC side of the same app as the Mac's `NotchBuddy/`. It is
built on the Windows and Linux version of [Coucou](https://github.com/Louis-CFM/coucou) by Louis Raillé (MIT); see
[`../LICENSE-ASSETS.md`](../LICENSE-ASSETS.md) for what is whose.

## Install

Get **Nyeko-Windows-setup.exe** from the download page, **https://nyeko-phone.pages.dev/download**, or from the newest
GitHub release. Windows may warn that the publisher is unknown (the installer isn't signed with a paid certificate):
**More info → Run anyway**.

## Build it yourself

You need [Rust](https://rustup.rs), [Node 20+](https://nodejs.org) and, on Windows, the **MSVC build tools** (Visual
Studio Build Tools with "Desktop development with C++"). WebView2 ships with Windows 10/11.

```powershell
cd windows
npm install
cargo build --release -p nyeko-hook   # the Claude Code relay, bundled with the app
npm run tauri dev      # live-reloading development build
npm run pack           # builds the installer and drops it in windows/release/
npm test               # the TypeScript tests; `cargo test` in src-tauri/ and hook/ for the Rust ones
```

`npm run dev` alone serves the front end in an ordinary browser, which is enough to work on the island's looks
(`dev/upload-preview.html` replays the file drop, `dev/recap-preview.html` the weekly recap).

`npm run pack` leaves `Nyeko-Windows-X.Y.Z-setup.exe` and `Nyeko-Windows-setup.exe` in `windows/release/`. Installing is
optional: `target/release/Nyeko.exe` runs on its own. The island at the top of the screen and Nyo in the notification
area are the whole app; Quit lives in its menu.

The sounds are the Mac app's own files (`../NotchBuddy/Resources/sounds`, made by `../scripts/nyeko-sounds.py`); the
icons come from `../scripts/nyeko-icons.py` (`npm run icons`). Nyo is drawn in code: `src/mochi/nyo.ts`.

### Layout

```
windows/
  src/                 island front end (TypeScript, no framework)
    mochi/             Nyo (nyo.ts), his engine and the launch greeting, in Canvas 2D
    desktop/           Nyo's own little window, when he lives on the desktop
    island/            state machine, hooks, integrations
    views/             every island view
    settings/          the settings window
  src-tauri/           Rust backend: window, named pipe, Claude API, pollers, the phone link (phone_link/)
  hook/                nyeko-hook(.exe), the Claude Code relay
```

### Log

`%LOCALAPPDATA%\Nyeko\nyeko.log` on Windows, `~/.local/share/nyeko/nyeko.log` on Linux: hook events, permission
decisions, poller problems. It stays on your machine.

## Supported agents

Every agent below is installed from **Settings → Agents** with the same steps as
Claude Code: the exact diff, the path of the dated backup, nothing written until
you click, and uninstalling removes only Nyeko's entries. A config Nyeko cannot
read, or where it finds something it does not expect, is left alone and the
reason is shown. Each agent gets its own pill (`agent_<name>`, the Mac's ids and
colours). The files are the Mac's, under `%USERPROFILE%` on Windows and `~` on
Linux.

| Agent | Installs | Permissions |
|---|---|---|
| Claude Code | `.claude\settings.json` (**Settings → Claude Code**) | Allow / Deny and questions in the island |
| Codex | `.codex\hooks.json` — then trust the hooks once with `/hooks` in Codex | Allow / Deny in the island |
| GitHub Copilot CLI | `.copilot\hooks\nyeko.json` | Allow / Deny in the island |
| Muse Code | `.config\muse\settings.json` | Allow / Deny in the island |
| Gemini CLI | `.gemini\settings.json` | asked in Gemini CLI |
| Antigravity | `.gemini\config\hooks.json` (a `nyeko` hook group) | asked in Antigravity; or, with **Approve commands from the notch** on, Allow / Deny / Reply in terminal in the island for the shell commands none of its rules covers |
| Cursor Agent | `.cursor\hooks.json` — Claude Code in Cursor's terminal also goes on the Cursor pill, through the Claude Code hooks | asked in Cursor |
| Claude Desktop | nothing to install: Claude Code sessions from the Claude app are tagged by the relay | asked in the Claude app |
| OpenCode | plugin `.config\opencode\plugins\nyeko.js` | asked in OpenCode |
| Amp | plugin `.config\amp\plugins\nyeko.ts` | asked in Amp |
| Hermes Agent | plugin `.hermes\plugins\nyeko\` — then `hermes plugins enable nyeko` once | asked in Hermes |
| Any other | run `nyeko-hook --agent <name> [<Event>]` from your tool's hooks | asked in the tool |

The relay maps every agent's event and field names onto Claude Code's (Gemini
CLI's `BeforeTool`, Copilot's `preToolUse`, Cursor's `beforeSubmitPrompt`…), and
answers each agent the way it expects. It never lets anything through on its
own: with no click it prints no decision at all (`{}` for the agents that need
JSON, `"ask"` for Copilot, which is fail-closed), so the agent asks in its own
terminal exactly as without Nyeko — including when Nyeko is closed.

**Antigravity** has no permission request: it runs its `PreToolUse` hook before
its own permission check and waits for the hook's decision. The relay answers
`{"decision":"ask"}`, so Antigravity's rules and prompt decide — unless
**Approve commands from the notch** is on (Settings → Agents → Antigravity, off
by default, shown once the hooks are installed). Then a `run_command` that none
of Antigravity's `command(...)` rules covers waits on the island's card, as on
the Mac: **Allow** prints `{"decision":"allow"}`, **Deny**
`{"decision":"deny","reason":"Denied from Nyeko"}`, and **Reply in terminal**,
no click within 110 s, a full card or Nyeko closed print `{"decision":"ask"}`.
Nyeko reads those rules from the files the Mac reads, under `.gemini`. The
`PreToolUse` hook is installed with a 120 s timeout: hooks written by an older
Nyeko (10 s) must be installed again, and Settings says so.

The plugins start the relay directly, with no shell in between, and never wait
for it. Amp's steps appear as each tool finishes: its "before" hook must return
a verdict, and Nyeko never gives one.

**How each agent runs the relay on Windows.** Hook commands are written for the
shell that runs them: Git Bash for Claude Code (quoted, forward slashes),
PowerShell for Gemini CLI and Copilot CLI (`& '…\nyeko-hook.exe'`), `cmd /C`
for Codex. Cursor, Antigravity and Muse Code do not document theirs: the relay
path is written bare when it has no space or special character — which works in
cmd, PowerShell and when started directly — and in double quotes otherwise.
These three are untested on Windows.

A pill is **connected** when Nyeko finds its own entries in the files above —
the same check as Settings → Agents (for Claude Code: a SessionStart hook
running Nyeko's relay; the Cursor pill also counts Claude Code's hooks).
Nyeko only reads these files, each time the island opens. Permission requests
get the island's card for Claude Code (in any terminal, and in Cursor's),
Codex, Copilot CLI and Muse Code, and Antigravity's commands when that is turned
on; other agents and Claude Desktop ask in their own window.

## What's different from the Mac version

- **Flow dictation** pastes with `Ctrl+V` (`Ctrl+Shift+V` in a terminal),
  typed by `SendInput` on Windows and XTest on X11, and puts back what the
  clipboard held once it is pasted; clipboard history (Windows, KDE, GNOME
  extensions) leaves the dictation out. On **Wayland** no app may watch the
  keyboard: the desktop holds the dictation key through its GlobalShortcuts
  portal (`Ctrl+Alt+V` unless you pick others when it asks) and the
  RemoteDesktop portal types the paste, asked once and remembered. Desktops
  without those portals (older GNOME) dictate from the pill's microphone and
  leave the words on the clipboard. The Mac's fn key and Apple's own
  recognition have no equivalent: Parakeet is the only engine.
- **The Notetaker** records what the computer plays through WASAPI loopback on
  Windows and the default output's monitor on Linux (PulseAudio or PipeWire).
  The people in a call are told apart by
  [pyannote](https://github.com/pyannote/pyannote-audio)'s segmentation and
  3D-Speaker's voice prints, also on the CPU. Summaries are Claude's only:
  there is no Apple Intelligence here.
- **« OK Nyeko »** listens with a small energy detector and Parakeet instead of
  the Mac's speech recognizer, so it understands Parakeet's 25 languages.
  Emails open in your default mail app through a `mailto:` link, with no
  contact lookup and no attachment; « play » something on Spotify opens its
  search rather than starting a track; apps open from the Start menu's
  shortcuts or Linux's `.desktop` entries. The system voice is the webview's;
  where WebKitGTK has none, `spd-say` (speech-dispatcher) or `espeak-ng`
  speaks if installed.
- No notch, so the island lives at the top centre of the screen and retracts into
  the top edge instead of hiding in a notch.
- Permission approval works from **any** terminal; the Mac build only listens to
  VS Code sessions.
- "Open terminal" finds the session's window by walking up from the relay's
  process to the terminal or editor that runs it. A session in a classic
  console window (`cmd.exe` or PowerShell without Windows Terminal) has no such
  ancestor — conhost owns that window — so its folder opens in VS Code instead,
  as it does when `code` is on your `PATH` and nothing was found. Linux walks
  the same tree; what it can bring forward depends on the desktop (see Linux).
- For a session in [herdr](https://herdr.dev), "Open terminal" also selects
  the session's pane with `herdr agent focus`, and never falls back to VS
  Code. The relay reads `HERDR_PANE_ID`, `HERDR_BIN_PATH` and, in WSL,
  `WSL_DISTRO_NAME`. In WSL, a Windows program only sees the variables that
  `WSLENV` names, so the hook command in the distro's
  `~/.claude/settings.json` passes them on:
  `WSLENV=$WSLENV:HERDR_PANE_ID:HERDR_BIN_PATH:WSL_DISTRO_NAME /mnt/c/Users/<you>/AppData/Local/Nyeko/bin/nyeko-hook.exe`.
- Global keyboard shortcuts are hot keys on Windows, key grabs on Linux under
  X11, and go through the desktop's GlobalShortcuts portal under Wayland (see
  [Linux](#linux)). A waiting card is also folded with its **⌃** or `Esc` in
  the island, and reopened by clicking the island, Open in the tray or **Go to
  alert**.
- **New Claude Code session** opens Windows Terminal (`wt.exe`) in the
  project, or PowerShell in a console of its own without it; on Linux
  `$TERMINAL`, `x-terminal-emulator`, GNOME Terminal, Ptyxis, Konsole, kitty,
  Alacritty, WezTerm, foot or xterm, whichever is found first, with your login
  shell. The prompt never goes into a command line: on Linux it is in
  `COUCOU_PROMPT`, set on the terminal; on Windows it goes through a file in
  your temp folder that PowerShell reads and deletes, since Windows Terminal
  starts its tabs without wt.exe's environment. A double quote in it becomes a
  single quote there (npm's `claude.cmd` would read it as the end of the
  argument). **Choose a folder…** is the system's folder picker on Windows,
  zenity or kdialog on Linux. There is no dictation button (the chat here
  has none either) and no global shortcut yet: the header's terminal tab
  opens it.
- A file let go on a session in the drop card is pasted with `Ctrl+V` on
  Windows and `Ctrl+Shift+V` on Linux, through Flow's paste (and its clipboard
  restore), instead of the Mac's ⌘V with Accessibility.
- Apple Music, the one pill from the Mac catalog with nothing behind it here,
  is left out.
- **Spotify** (Settings → Integrations) is read from the system media
  controls, the session Spotify publishes for the media keys: the same pill
  and card as on Linux (cover, progress bar, play/pause, previous, next,
  shuffle, repeat), and Nyo dances while it plays. Nothing is polled: one
  thread waits for the session's change events while the pill is declared.
  The volume is Spotify's own in the Windows mixer. Works with the installer
  from spotify.com and the Microsoft Store app; **Open Spotify** goes through
  its `spotify:` link, and without Spotify **Get Spotify** opens its download
  page. Windows gives no Spotify link for the track, so an ad is told apart by
  having a title and no artist or album.
- Not in this version: sending a dropped file by email and dragging Nyo onto
  a window to attach it as context. On the Mac, email goes through Resend or
  Apple Mail's scripting; neither has a safe equivalent that attaches a file
  here, and the drop card would need a third button it doesn't have.
- New versions: the Mac checks the downloaded app's Developer ID signature and
  notarization; the Windows installer isn't code-signed yet, so it is checked
  against the SHA-256 GitHub publishes for it, and the installer (not Nyeko)
  replaces the app and starts it again.
- Cal.com shows the next bookings as a list rather than the Mac's calendar.
- The Cursor pill carries both Cursor Agent's own hooks and Claude Code running
  in Cursor's terminal.
- Hermes: Nyeko writes the plugin but does not run the `hermes` CLI, so it is
  turned on once by hand. Hermes runs natively on Linux; on Windows it is
  untested.
- Plan usage: the user's previous status line runs through Git Bash on Windows
  (`/bin/sh` on Linux and Mac); without Git Bash it is not run, rather than
  guessed at with `cmd`. The Codex CLI is looked for on `PATH` and in npm's,
  Volta's, Bun's and pnpm's folders (and nvm's on Linux).
- The chat's model picker opens inside the chat card instead of a popover, and
  it also offers OpenRouter and any OpenAI-compatible server, which the Mac
  does not. Google AI, OpenAI and OpenRouter can see an image you dropped (sent
  inline), where the Mac sends its name only.
- Live diff: the relay forwards an edit's text whole only once the edit is done
  (PostToolUse), up to 256 KB per string and 512 KB per event. A bigger edit
  shows its "Edits · file" step without counts rather than wrong ones. The
  diff's ↗ needs `code` on your `PATH`; without it, it opens the file's folder —
  never the file itself. Counts and diffs come from Claude Code's Edit,
  MultiEdit and Write, on whichever pill its session is on (VS Code, Cursor,
  Claude Desktop); other agents' edits show as plain steps.
- There is no iPhone to keep fetching the GitHub lists while the pill is off.
- Keyboard shortcuts use `Ctrl+Alt` where the Mac uses `⌃⌥`, with different
  keys (see [Keyboard shortcuts](#keyboard-shortcuts)), and `Ctrl` where the
  Mac uses `⌘` inside the island. "Bring the terminal forward" is "Open
  terminal" here. Not in this version: attaching the front window (its id is
  kept for later). The island only reads its own shortcuts while it has the
  keyboard: in the chat, or after a global shortcut opened it. `Ctrl+↓`
  `Ctrl+↑` `Ctrl+O` walk the GitHub lists, as on the Mac, and the highlighted
  row scrolls into view where the Mac's three-row list doesn't follow it; in the
  chat field `Ctrl+↑` `Ctrl+↓` keep moving the cursor. **Go to alert** brings
  up any agent's waiting card on its own pill; **Toggle the island** folds a
  waiting card rather than dropping it, like `Esc` in the island. **Send Nyo
  to the desktop** (`Ctrl+Alt+D`, the Mac's `⌃⌥D`)
  flies him to his spot, or to the bottom-right corner when that spot was on a
  display that is gone; pressed again, he flies home.
- Weekly recap:
  - Sharing happens inside the island instead of a separate panel, and Save
    writes straight into Pictures (or Downloads) instead of asking where. There
    is no system Share sheet; Copy uses the web clipboard.
  - Questions are counted when an agent asks one (`AskUserQuestion`), whether
    it is then answered in the island or in the terminal. Permissions count the
    Allow and Deny clicks on the island's card, for every agent that gets one.
  - There is no sleep/wake notification to listen to without a background
    loop, so after the machine wakes the Monday card waits for the first agent
    to start or for you to hover the island.
  - The card is 24 px taller than the Mac's: it also lists top agent, project,
    busiest day, longest session, permissions and questions, which the Mac
    leaves to the image. A turn cut short by the session ending still counts.
  - Tray → Pause doesn't stop the history (it stays on the machine anyway);
    switch it off in Settings → General.
- The wardrobe opens with a right-click on Nyo, from the tray menu, or with
  its global shortcut (`Ctrl+Alt+G` by default). In the compact island a tall hat
  is cut by the top edge of the screen, as it is by the notch on a Mac.
- Languages: chosen in Settings, independently of the system, and applied
  without a restart (the Mac's **Restart Nyeko** isn't needed). Arabic turns
  the island's text right to left but not its layout: Nyo and the pills keep
  their sides.
- Nyo on the desktop dances to Spotify. While he dances he stays awake (the
  Mac lets him doze off mid-dance). Dropping him on a window doesn't attach it
  to the chat. While he
  sleeps, the transparent square around him (120 px) takes the first mouse
  move, which wakes him and gives the rest back to the desktop.

## Linux

To check toolbar collapse even when WebKitGTK loses the pointer-leave event,
run `python3 scripts/test-linux-pill-hover.py target/release/Nyeko` from
`windows/` after building. This native regression test uses a separate Xvfb
display and temporary preferences; it requires Xvfb, xdotool, xwd, a C compiler
and GTK3 development headers. It leaves captures under `target/pill-hover-test/`.

The same app builds for Linux: everything that differs lives in
`src-tauri/src/platform/`, and the relay's transport in `hook/src/unix.rs`.

```bash
sudo apt install build-essential pkg-config \
  libwebkit2gtk-4.1-dev libgtk-layer-shell-dev libayatana-appindicator3-dev \
  librsvg2-dev libssl-dev libdbus-1-dev patchelf \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good
npm install
npm run tauri dev      # live-reloading development build
npm run pack           # AppImage, .deb and .rpm in windows/release/
```

Store API keys with GNOME Keyring or KWallet.

What changes on Linux:

- **The island** is a gtk-layer-shell overlay anchored to the top edge, over any
  top panel, on compositors that support it: COSMIC, KDE Plasma, Hyprland, Sway
  and other wlroots compositors. GNOME has no layer-shell and ignores where a
  Wayland window asks to go, so there Nyeko runs through XWayland as a dock
  window: top centre, on every workspace, still there after Super+D.
  `COUCOU_X11=0` keeps the native Wayland window, `COUCOU_DOCK=0` makes it a
  utility window instead of a dock. `COUCOU_LAYER_SHELL=0` forces the regular
  window anywhere.
- **Click-through** is the window's input region, kept equal to the island
  shape, so the compositor sends every other click to what is underneath.
- **Nyo's eyes** follow the pointer only while it is over the island: Wayland
  gives no app the cursor position anywhere else. On the desktop, likewise,
  they follow it only while it is over him, and "the cursor is far away" (so
  he may fall asleep) means it hasn't been over him for a few seconds.
- **Nyo on the desktop** is a layer-shell surface on the island's display
  (KDE Plasma, COSMIC, Hyprland, Sway…), placed with margins and dragged within
  that display; on X11 it is an ordinary always-on-top window that goes
  anywhere. **GNOME on Wayland** has no layer-shell and lets no app place its
  own window, so there Nyo can't leave the island: dragging him does nothing,
  and the desktop shortcut only makes him grumble.
- **Claude Code hooks** go through `~/.local/share/nyeko/bin/nyeko-hook` and a
  Unix socket at `$XDG_RUNTIME_DIR/coucou.sock`. Both ends check that the other
  runs as the same user. Every other agent uses the same relay, single-quoted
  for `sh`, and its config under `~` (see Supported agents). A config that is a
  symlink (dotfiles) is written through to its target, with its permissions
  kept.
- **Global shortcuts** are X11 key grabs in an X11 session.
  On X11, AltGr is a modifier of its own and never clashes with `Ctrl+Alt`;
  combinations the desktop already uses (GNOME's `Ctrl+Alt+T` terminal and
  `Ctrl+Alt+←`/`→` workspace switching) show up as *In use*.
  Wayland has no key grabs, so there Nyeko hands its shortcuts to the desktop
  through the XDG **GlobalShortcuts portal** (`xdg-desktop-portal`, with a
  backend that has it: KDE Plasma 6, GNOME 48+, Hyprland, COSMIC…). Each
  shortcut goes with its description and your keys as the preferred trigger;
  the desktop may show its own window to confirm them or to pick other keys,
  and it has the last word: a shortcut it already knows keeps the keys it was
  given there, and you change them in the desktop's own shortcut settings.
  **Settings → Shortcuts** says the shortcuts are registered with the desktop,
  shows next to each one the keys the desktop reports (*Desktop: …*), and flags
  one it left out. Changing or turning off a shortcut in Nyeko binds the new
  set in a new portal session. Nyeko names itself `fr.louisraille.coucou` to
  the portal where the portal allows it (`xdg-desktop-portal` 1.19+); a
  desktop that wants an app name may otherwise refuse.
  Where there is no such portal, or the desktop refuses, nothing is registered
  and **Settings → Shortcuts** lists commands to bind in your
  desktop's own keyboard settings instead (they are shown with the portal too,
  for any shortcut that doesn't work):
  `coucou --shortcut openChat` (or the AppImage's path) runs the action in the
  Nyeko that is already open. The ids are `toggleIsland`, `openChat`,
  `goToAlert`, `jumpToTerminal`, `nextPill`, `prevPill`, `muteToggle`,
  `desktopToggle` and `wardrobeToggle`.
- **Keys** live in the Secret Service (GNOME Keyring, KWallet).
- **Spotify** (Settings → Integrations) is read over MPRIS, Spotify's D-Bus
  interface on the session bus: the pill shows the track and plays, pauses
  or skips on hover, the card has the cover, the progress bar (drag to
  seek), shuffle, previous, next, repeat and the volume, and Nyo dances
  while it plays — in the compact island, on the Spotify card, on the pill
  and on the desktop. Nothing is polled: one thread waits on the bus for
  Spotify's own signals while the pill is declared, and stops when it isn't.
  **Open Spotify** brings it forward or starts `spotify` from your `PATH`,
  else the Flatpak (`com.spotify.Client`) or the Snap; without one, **Get
  Spotify** opens its download page. Covers come from Spotify's image CDN
  (or a local track's file) and are fetched by Nyeko itself, not the page.
  Spotify builds that don't report the position over MPRIS show the bar
  from where the track started; the Mac's Automation prompt has no
  equivalent here.
- **Plan usage**: the status line relay is `~/.local/share/nyeko/bin/nyeko-hook
  --statusline` and runs your previous status line with `/bin/sh -c`, like Claude
  Code. Codex is found on `$PATH`, in `~/.local/bin`, npm's global prefix, Volta,
  Bun, pnpm, or nvm (newest Node first), since a desktop launch often has a
  shorter `$PATH` than your shell.
- **Nyo's greeting** uses the full name in your account's GECOS field
  (`chfn` sets it); without one the chat stays neutral.
- **Files**: preferences in `~/.config/nyeko/`, the log at
  `~/.local/share/nyeko/nyeko.log`, the weekly recap history beside it in
  `recap.json`. A saved recap image goes to the pictures folder named in
  `~/.config/user-dirs.dirs`, else `~/Pictures`, else `~/Downloads`.
- **Languages**: Hindi, Bengali, Chinese and Arabic need fonts that carry those
  scripts; Nyeko asks for the Noto families (`fonts-noto-core` and
  `fonts-noto-cjk` on Debian and Ubuntu, `noto-fonts` and `noto-fonts-cjk` on
  Arch). **System** reads the language from the webview, which follows
  `LANGUAGE` / `LANG`.
- **Copying the recap image** needs a WebKitGTK with image clipboard support;
  where it is missing, the island says so and Save still works.
- What the Windows build leaves out, this one does too: sending a file by
  email and dragging Nyo onto a window.
- **New versions** are announced (once you agree), but **Update now** opens
  the release page: update the AppImage, .deb or .rpm the way
  you installed it.
- **Open terminal** walks up from the relay through `/proc` (stopping at
  systemd, logins, ssh, session managers and panels, and at any process of
  another user) to the terminal or editor the session runs in, then brings its
  window forward — the one titled after the session's folder if it has several:
  - **X11** (any desktop): EWMH — the window whose `_NET_WM_PID` is the nearest
    ancestor gets a `_NET_ACTIVE_WINDOW` request, on its workspace. A terminal
    that doesn't set `_NET_WM_PID` (some old `xterm` builds) isn't found.
  - **KDE Plasma on Wayland**: a few lines of KWin script, loaded over D-Bus
    from `$XDG_RUNTIME_DIR`, activate the window by process ID and are unloaded
    right after; Plasma 5 and 6.
  - **kitty**, anywhere: its tab is selected too when remote control listens on
    a socket (`allow_remote_control` and `listen_on` in kitty.conf).
  - **GNOME on Wayland** and other Wayland compositors let no app bring another
    app's native window forward (an XWayland one, such as VS Code's by default,
    still can be). There, and for a session under tmux, screen or ssh, whose
    terminal is no ancestor, the folder opens in VS Code as before.
- The **Claude Desktop** pill opens Anthropic's Linux app (its `.deb`): through
  its `claude-desktop.desktop` entry, else its binary, else the `claude://` link.
