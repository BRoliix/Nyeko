// Nyeko phone web app: the app shell offline, and the lock-screen alert.
// The Mac's push carries no payload, so there is nothing to read here: the alert is always the same words.
const CACHE = "nyeko-v7";
const SHELL = ["/", "/index.html", "/app.js", "/relay.js", "/setup.js", "/nyo.js", "/style.css", "/fonts/fredoka.woff2", "/fonts/nunito.woff2", "/manifest.webmanifest",
  "/icons/icon-180.png", "/icons/icon-192.png", "/icons/icon-512.png", "/icons/favicon.svg"];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

// Network first (a new version shows at once), the cache when offline. Only this site's own files.
self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET" || new URL(req.url).origin !== self.location.origin) return;
  if (new URL(req.url).pathname.startsWith("/downloads/")) return;   // the APK and its card: always from the network, never cached
  event.respondWith(fetch(req).then((res) => {
    if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
    return res;
  }).catch(() => caches.match(req).then((hit) => hit || caches.match("/index.html"))));
});

self.addEventListener("push", (event) => {
  event.waitUntil(self.registration.showNotification("Nyo needs you", {
    body: "Claude Code is waiting for your answer. Tap to open Nyeko.",
    icon: "/icons/icon-192.png",
    badge: "/icons/icon-192.png",
    tag: "nyeko-alert",
    renotify: true,
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
    for (const c of list) if ("focus" in c) return c.focus();
    return self.clients.openWindow("/");
  }));
});
