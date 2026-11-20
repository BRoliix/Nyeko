// The download page: the newest build of each app the Release Nyeko workflow published (see _worker.js), the visitor's
// own device first, and Nyo at the top (the same painter as the apps, nyo.js).
import { drawNyoStill } from "./nyo.js";

function el(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  for (const k of kids) e.append(k);
  return e;
}

const ICON = {
  laptop: ["M5 6.5A1.5 1.5 0 016.5 5h11A1.5 1.5 0 0119 6.5V15H5z", "M2.5 18.5h19"],
  desktop: ["M4 5.5A1.5 1.5 0 015.5 4h13A1.5 1.5 0 0120 5.5v9a1.5 1.5 0 01-1.5 1.5h-13A1.5 1.5 0 014 14.5z", "M9 20h6M12 16v4"],
  phone: ["M7.5 4.5A1.5 1.5 0 019 3h6a1.5 1.5 0 011.5 1.5v15A1.5 1.5 0 0115 21H9a1.5 1.5 0 01-1.5-1.5z", "M11 18h2"],
};
function icon(name) {
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 24 24"); svg.setAttribute("width", "22"); svg.setAttribute("height", "22"); svg.setAttribute("class", "ic");
  for (const d of ICON[name]) {
    const p = document.createElementNS(ns, "path");
    p.setAttribute("d", d); p.setAttribute("fill", "none"); p.setAttribute("stroke", "currentColor");
    p.setAttribute("stroke-width", "2"); p.setAttribute("stroke-linecap", "round"); p.setAttribute("stroke-linejoin", "round");
    svg.append(p);
  }
  return svg;
}

const mb = (n) => `${(n / 1048576).toFixed(1)} MB`;
const when = (iso) => new Date(iso).toLocaleDateString(undefined, { dateStyle: "medium" });
const head = (ic, tint, title, meta) => el("div", { class: "dl-head" }, el("span", { class: `tile ${tint}` }, icon(ic)),
  el("span", { class: "row-main" }, el("span", { class: "row-title" }, title), el("span", { class: "row-meta" }, meta)));

const APPS = [
  {
    id: "mac", title: "Nyeko for Mac", icon: "laptop", tint: "tan", needs: "macOS 15 or later",
    sub: "Nyo in the notch: your coding sessions, approvals, chat, now playing, and your phones' link.",
    button: "Download for Mac",
    after: (i) => "Open the DMG and drag Nyeko onto Applications. The first time, macOS blocks it (it is not notarized): System Settings › Privacy & Security › Open Anyway."
      + (i.signed ? "" : " This build is signed ad hoc: macOS asks for Nyeko's permissions again (Accessibility, microphone…)."),
  },
  {
    id: "windows", title: "Nyeko for Windows", icon: "desktop", tint: "mint", needs: "Windows 10 or 11",
    sub: "Nyo at the top of your screen: your coding sessions, approvals, chat, and your phones' link.",
    button: "Download for Windows",
    after: () => "Run the installer. It is not signed: when SmartScreen warns, More info → Run anyway.",
  },
  {
    id: "android", title: "Nyeko for Android", icon: "phone", tint: "pink", needs: "Android 11 or later",
    sub: "Nyo on your screen, the island from the camera hole, alerts and widgets. It updates itself.",
    button: "Download for Android",
    after: () => "Open the file, allow installs from your browser when Android asks, then pair it: Settings › Add a computer, and scan the code on your computer (Nyeko → Phone).",
  },
];

for (const app of APPS) {
  const body = document.querySelector(`#${app.id} .card-body`);
  if (!body) continue;
  (async () => {
    let info = null;
    try { const r = await fetch(`/downloads/${app.id}.json`, { cache: "no-store" }); if (r.ok) info = await r.json(); } catch {}
    if (!info) {
      body.replaceChildren(head(app.icon, app.tint, app.title, app.needs),
        el("p", { class: "note" }, "No build is published yet. Run the Release Nyeko workflow in GitHub Actions; it appears here when it is done."));
      return;
    }
    body.replaceChildren(
      head(app.icon, app.tint, app.title, `${info.versionName} · ${mb(info.size)} · ${when(info.publishedAt)}`),
      el("p", { class: "sub" }, app.sub),
      el("a", { class: "btn primary block", href: `/downloads/${app.id}` }, app.button),
      el("p", { class: "note" }, app.after(info)),
      el("details", { class: "hash" }, el("summary", {}, "SHA-256"), el("code", {}, info.sha256)),
    );
  })();
}

// The visitor's own device first; on an iPhone, where they are in the steps.
{
  const ua = navigator.userAgent;
  const ios = /iPhone|iPad|iPod/.test(ua) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  const mine = ios ? "iphone" : /Android/.test(ua) ? "android" : /Windows|Linux/.test(ua) ? "windows" : "mac";
  const cards = document.getElementById("cards");
  const card = document.getElementById(mine);
  if (cards && card) { cards.prepend(card); card.classList.add("yours"); }
  const safari = ios && !/CriOS|FxiOS|EdgiOS|OPiOS|GSA\//.test(ua);
  if (ios) document.getElementById(safari ? "iphone-here" : "iphone-not-safari")?.removeAttribute("hidden");
  for (const t of document.querySelectorAll("[data-icon]")) t.append(icon(t.dataset.icon));
}

// Nyo
{
  const c = document.getElementById("hero-nyo");
  const size = 132, dpr = Math.min(3, devicePixelRatio || 1);
  c.width = c.height = Math.round(size * dpr);
  c.style.width = c.style.height = size + "px";
  const x = c.getContext("2d");
  if (x) { const u = (size * dpr) / 100; x.translate((size * dpr) / 2, 61 * u); drawNyoStill(x, { rx: 38 * u, ry: 35 * u, lookX: 0.15 }); }
}
