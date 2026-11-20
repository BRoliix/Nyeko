# Files on your computer, from the phone

The phone can look through the folders on a paired computer, preview a file, and start a Claude Code session in any
folder. Computers tab → **Files**, or New session → **Browse folders**.

## What it can and can't do

- **Read-only.** The phone lists folders and reads files. It never writes, moves, deletes or opens a file. **Show on
  computer** selects the file in Finder or Explorer; it doesn't open it.
- **Only your home folder.** Paths are resolved on the computer, links followed, and must stay inside the home folder.
- **Nothing hidden.** Dotfiles (`.env`, `.ssh`, `.git` and the like), `~/Library` on the Mac and Windows' hidden folders
  (such as `AppData`) are never listed or read.
- **Face ID first.** Opening the browser asks for Face ID (or the phone's screen lock), like messages and new sessions.
- **Sizes.** A listing shows up to 300 items. Text files are shown up to 256 KB (the rest is cut); pictures (PNG, JPEG,
  GIF, WebP, HEIC, BMP, SVG) up to 4 MB. Other files show their name and size only.
- **macOS asks once.** The first time you browse Desktop, Documents or Downloads, macOS asks on the Mac whether Nyeko may
  read that folder. Allow it there.

## Messages (nyeko, end-to-end encrypted like the rest)

| Phone → computer | Computer → phone |
|---|---|
| `{type:"browse", id, path}` (empty path: home) | `{type:"folder", id, ok, path, display, parent?, entries:[{name, dir, size?, kind?, mtime?}], truncated}` |
| `{type:"preview", id, path}` | `{type:"file", id, ok, name, size, kind:"text"\|"image"\|"other", mime?, truncated?, chunks}`, then `chunks` × `{type:"chunk", id, i, d}` (base64 or base64url, 36,000 bytes each) |
| `{type:"reveal", path}` | nothing |
| `{type:"launch", id, folder, prompt}` (instead of `project`) | `launched` / `started`, as for a recent project |

Code: Mac `NotchBuddy/Sources/App/PhoneWeb/NyekoFiles.swift`, Windows/Linux `windows/src-tauri/src/phone_link/files.rs`
(with tests), phone `phone/web/app.js` (`openFiles`, `filesTab`).
