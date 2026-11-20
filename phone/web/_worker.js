// Nyeko site (Cloudflare Pages, advanced mode). Everything is the static web app, except the downloads:
//   /downloads/android        the newest Nyeko for Android APK, streamed from the newest GitHub Release that has one
//   /downloads/android.json   its build number, version, size, date and SHA-256 (the download card and the app's updater)
//   /downloads/mac(.json)     the same for the Mac installer (Nyeko.dmg)
//   /downloads/windows(.json) the same for the Windows installer (Nyeko-Windows-setup.exe)
// The "Release Nyeko" workflow publishes the three together, as one release (nyeko-1.0.<build>).
// The repository is public: the site finds the newest release through GitHub's API and sends the browser straight to
// the file on GitHub (a redirect: the bytes never pass through this site, so there is no bandwidth limit to hit).
// GITHUB_TOKEN, when set (a read-only token kept as a Cloudflare secret:
// npx wrangler pages secret put GITHUB_TOKEN --project-name nyeko-phone), only raises GitHub's rate limit; it is never
// sent to the browser.

const REPO = "BRoliix/Nyeko";
/** What each download is: the file, its info file, and how it is served. Older per-app releases (nyeko-android-v…) count too. */
const KINDS = {
  android: { prefix: "nyeko-android-", file: "Nyeko.apk", info: "nyeko-android.json", type: "application/vnd.android.package-archive", ext: "apk" },
  mac: { prefix: "nyeko-mac-", file: "Nyeko.dmg", info: "nyeko-mac.json", type: "application/x-apple-diskimage", ext: "dmg" },
  windows: { prefix: "nyeko-windows-", file: "Nyeko-Windows-setup.exe", info: "nyeko-windows.json", type: "application/vnd.microsoft.portable-executable", ext: "exe" },
};

// The headers _headers gives the static files, applied here too (in advanced mode the worker answers every request).
const SECURITY = {
  "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self' wss:; manifest-src 'self'; worker-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=(), publickey-credentials-get=(self), publickey-credentials-create=(self)",
};
const NO_CACHE = new Set(["/", "/index.html", "/sw.js", "/app.js", "/relay.js", "/setup.js", "/style.css", "/download.html", "/download.js"]);

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const m = /^\/downloads\/(android|mac|windows)(\.json)?$/.exec(url.pathname);
    if (m) return m[2] ? info(env, ctx, KINDS[m[1]]) : file(env, ctx, KINDS[m[1]], m[1]);
    const res = await env.ASSETS.fetch(request);
    const out = new Response(res.body, res);
    for (const [k, v] of Object.entries(SECURITY)) if (!out.headers.has(k)) out.headers.set(k, v);
    if (NO_CACHE.has(url.pathname)) out.headers.set("Cache-Control", "no-cache");
    return out;
  },
};

function json(body, status = 200, extra = {}) {
  return new Response(JSON.stringify(body), {
    status, headers: { "Content-Type": "application/json", "Cache-Control": "no-cache", ...SECURITY, ...extra },
  });
}

function gh(env, path, accept = "application/vnd.github+json") {
  return fetch(`https://api.github.com${path}`, {
    headers: {
      ...(env.GITHUB_TOKEN ? { Authorization: `Bearer ${env.GITHUB_TOKEN}` } : {}),
      Accept: accept, "User-Agent": "nyeko-site", "X-GitHub-Api-Version": "2022-11-28",
    },
    redirect: "manual",
  });
}

/** The newest release of one download (cached for two minutes, so a burst of phones asks GitHub once). */
async function latest(env, ctx, kind) {
  const cache = caches.default;
  const key = new Request(`https://nyeko-cache.invalid/latest-${kind.prefix}`);
  const hit = await cache.match(key);
  if (hit) return hit.json();
  const res = await gh(env, `/repos/${env.GITHUB_REPO || REPO}/releases?per_page=30`);
  if (!res.ok) throw new Error(`github ${res.status}`);
  // GitHub does not list releases newest first (it sorts by tag): the newest one that has this file, by publication date.
  const has = (r) => r.assets?.some((a) => a.name === kind.file) && r.assets?.some((a) => a.name === kind.info);
  const rel = (await res.json())
    .filter((r) => !r.draft && typeof r.tag_name === "string" && r.tag_name.startsWith("nyeko-") && has(r))
    .sort((a, b) => String(b.published_at).localeCompare(String(a.published_at)))[0];
  if (!rel) return null;
  const fileAsset = rel.assets.find((a) => a.name === kind.file);
  const infoAsset = rel.assets.find((a) => a.name === kind.info);
  if (!fileAsset || !infoAsset) return null;
  const meta = await fetch(infoAsset.browser_download_url).then((r) => r.json());
  const out = {
    versionCode: meta.versionCode, versionName: meta.versionName, sha256: meta.sha256, signed: meta.signed,
    size: fileAsset.size, publishedAt: rel.published_at, tag: rel.tag_name, url: fileAsset.browser_download_url,
  };
  ctx.waitUntil(cache.put(key, new Response(JSON.stringify(out), { headers: { "Cache-Control": "max-age=120" } })));
  return out;
}

async function info(env, ctx, kind) {
  try {
    const r = await latest(env, ctx, kind);
    if (!r) return json({ error: "no release yet" }, 404);
    const { url, ...pub } = r;
    return json(pub);
  } catch {
    return json({ error: "github unreachable" }, 502);
  }
}

async function file(env, ctx, kind, label) {
  try {
    const r = await latest(env, ctx, kind);
    if (!r) return new Response(`No Nyeko for ${label} build has been published yet.`, { status: 404, headers: SECURITY });
    // Straight to GitHub's copy of the newest file.
    return new Response(null, { status: 302, headers: { ...SECURITY, Location: r.url, "Cache-Control": "no-cache" } });
  } catch {
    return new Response("The download is not available right now.", { status: 502, headers: SECURITY });
  }
}
