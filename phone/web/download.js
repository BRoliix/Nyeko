// The download page's cards: the newest build of each app the workflows released (see _worker.js).
function el(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  for (const k of kids) e.append(k);
  return e;
}

const mb = (n) => `${(n / 1048576).toFixed(1)} MB`;
const when = (iso) => new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
const row = (k, v) => el("div", { class: "row small", style: "justify-content:space-between;margin:4px 0" }, el("span", { class: "muted" }, k), el("b", {}, v));

const APPS = [
  {
    id: "android", title: "Nyeko for Android", workflow: "Release Nyeko",
    sub: "Android 11 or later. Nyo on your screen, the island from the camera hole, alerts and widgets. It updates itself.",
    version: (i) => i.versionName,
    button: "Download for Android",
    after: () => "Open the file, allow installs from your browser when Android asks, then pair it: Settings › Your computers › Add a computer, and scan the code on your computer (Nyeko → Phone).",
  },
  {
    id: "mac", title: "Nyeko for Mac", workflow: "Release Nyeko",
    sub: "macOS 15 or later. Nyo in the notch: your coding sessions, approvals, chat, now playing, and your phones' link.",
    version: (i) => i.versionName,
    button: "Download for Mac",
    after: (i) => "Open the DMG and drag Nyeko onto Applications. The first time, right-click Nyeko → Open (it is not notarized)."
      + (i.signed ? "" : " This build is signed ad hoc: macOS asks for Nyeko's permissions again (Accessibility, microphone…)."),
  },
  {
    id: "windows", title: "Nyeko for Windows", workflow: "Release Nyeko",
    sub: "Windows 10 or 11. Nyo at the top of your screen: your coding sessions, approvals, chat, and your phones' link.",
    version: (i) => i.versionName,
    button: "Download for Windows",
    after: () => "Run the installer. It is not signed: when SmartScreen warns, More info → Run anyway.",
  },
];

for (const app of APPS) {
  const card = document.getElementById(app.id);
  if (!card) continue;
  (async () => {
    let info = null;
    try { const r = await fetch(`/downloads/${app.id}.json`, { cache: "no-store" }); if (r.ok) info = await r.json(); } catch {}
    if (!info) {
      card.replaceChildren(el("div", { class: "title" }, app.title),
        el("p", { class: "sub" }, `No build is published yet. Run the ${app.workflow} workflow in GitHub Actions; it appears here when it is done.`));
      return;
    }
    card.replaceChildren(
      el("div", { class: "title" }, app.title),
      el("p", { class: "sub" }, app.sub),
      row("Version", app.version(info)),
      row("Size", mb(info.size)),
      row("Published", when(info.publishedAt)),
      el("p", { class: "mono", style: "font-size:11px;margin:10px 0" }, `SHA-256 ${info.sha256}`),
      el("a", { class: "btn primary block", href: `/downloads/${app.id}`, style: "text-decoration:none;color:inherit" }, app.button),
      el("p", { class: "small muted", style: "margin:10px 0 0" }, app.after(info)),
    );
  })();
}

// The iPhone card: say where the visitor is in the steps.
{
  const ios = /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  const safari = ios && !/CriOS|FxiOS|EdgiOS|OPiOS|GSA\//.test(navigator.userAgent);
  if (ios) document.getElementById(safari ? "iphone-here" : "iphone-not-safari")?.removeAttribute("hidden");
}
