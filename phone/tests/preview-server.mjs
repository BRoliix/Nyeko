// Serves phone/web with the design preview at /preview.html (phone/tests/preview.html). node phone/tests/preview-server.mjs [port]
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
const web = join(here, "../web");
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".woff2": "font/woff2", ".png": "image/png",
  ".svg": "image/svg+xml", ".webmanifest": "application/manifest+json", ".json": "application/json" };
const port = Number(process.argv[2] || 8788);
createServer(async (req, res) => {
  const path = new URL(req.url, "http://x").pathname;
  const file = path === "/preview.html" ? join(here, "preview.html") : join(web, normalize(path === "/" ? "/index.html" : path));
  if (!file.startsWith(web) && !file.endsWith("preview.html")) { res.writeHead(403).end(); return; }
  let body;
  try { body = await readFile(file); } catch { res.writeHead(404).end(); return; }
  res.writeHead(200, { "content-type": types[extname(file)] || "application/octet-stream" }).end(body);
}).listen(port, "127.0.0.1", () => console.log(`http://127.0.0.1:${port}/preview.html`));
