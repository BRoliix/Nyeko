// The same relay in plain Node (the `ws` package): the twin of src/index.ts + src/room.ts. It enforces the same rules from the
// same code (src/protocol.ts) so the Rust and Kotlin clients can be tested against a real server without Cloudflare, and so
// the relay can be self-hosted on a small server behind a TLS proxy (docs/RELAY_LINK.md). Erasable TypeScript only:
//
//   ACCESS_KEY=<key> PORT=8787 node android/relay/tools/dev-relay.ts
//
// It listens on plain ws:// (put a TLS terminator in front of it for the internet). Like the Worker it stores nothing,
// logs nothing and fails closed without an access key.

import { createServer } from "node:http";
import { pathToFileURL } from "node:url";
import type { Duplex } from "node:stream";
import { WebSocketServer, type WebSocket } from "ws";
import {
  Bucket, MAX_FRAME, MAX_SETUP_FRAME, PEER_OFFLINE, PEER_ONLINE, RATE_BURST, RATE_PER_SECOND, SETUP_FRAMES, SETUP_TTL_MS,
  SUBPROTOCOL, accessGeneration, accessKeyOk, joinVerifier, otherRole, parseJoinProof, parseRoomRequest, roomName,
  type Role,
} from "../src/protocol.ts";

interface Peer {
  ws: WebSocket;
  role: Role;
  verifier: string;
  gen: string;
  bucket: Bucket;
  replaced: boolean;
  setup: boolean;
  frames: number;
  since: number;
}

export interface Relay {
  port: number;
  /** Change (or remove) the access key while running, as `wrangler secret put` does. */
  setAccessKey(key: string | undefined): void;
  /** How many rooms have a live socket. A room with none leaves nothing behind. */
  rooms(): number;
  close(): Promise<void>;
}

export async function startRelay(options: { port?: number; host?: string; accessKey?: string; connectsPerMinute?: number } = {}): Promise<Relay> {
  let accessKey = options.accessKey;
  const rooms = new Map<string, Partial<Record<Role, Peer>> & { verifier?: string }>();
  const connects = new Map<string, number[]>();
  const wss = new WebSocketServer({
    noServer: true,
    maxPayload: MAX_FRAME, // a larger frame closes the socket with 1009
    handleProtocols: () => SUBPROTOCOL,
  });

  const refuse = (socket: Duplex, status: number, text: string) => {
    socket.write(`HTTP/1.1 ${status} ${text}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`);
    socket.destroy();
  };

  const server = createServer((req, res) => {
    if (req.url === "/" && req.method === "GET") {
      res.writeHead(200, { "content-type": "text/plain" }).end("Coucou link relay");
    } else {
      res.writeHead(req.url === "/" ? 405 : 404).end();
    }
  });

  server.on("upgrade", async (req, socket, head) => {
    const url = new URL(req.url ?? "/", "http://relay.invalid");
    const target = req.method === "GET" ? parseRoomRequest(url) : null;
    if (!target) return refuse(socket, 404, "Not Found");
    if (options.connectsPerMinute) {
      const ip = req.socket.remoteAddress ?? "unknown";
      const now = Date.now();
      const recent = (connects.get(ip) ?? []).filter((t) => now - t < 60_000);
      if (recent.length >= options.connectsPerMinute) return refuse(socket, 429, "Too Many Requests");
      connects.set(ip, [...recent, now]);
    }
    if (!target.setup && !(await accessKeyOk(accessKey, req.headers.authorization ?? null,
                            (req.headers["sec-websocket-protocol"] as string | undefined) ?? null))) return refuse(socket, 401, "Unauthorized");
    const proof = parseJoinProof((req.headers["sec-websocket-protocol"] as string | undefined) ?? null);
    if (!proof) return refuse(socket, 400, "Bad Request");
    const verifier = await joinVerifier(proof);
    const gen = target.setup ? "" : await accessGeneration(accessKey);
    const name = roomName(target);

    wss.handleUpgrade(req, socket, head, (ws) => {
      const room = rooms.get(name) ?? {};
      const live = (Object.values(room).filter((v) => typeof v === "object") as Peer[]).filter((p) => !p.replaced);
      if (live.length > 0 && live[0].verifier !== verifier) {
        ws.close(1008, "join proof");
        return;
      }
      const old = room[target.role];
      if (old) {
        old.replaced = true;
        old.ws.close(1000, "replaced");
      }
      const me: Peer = { ws, role: target.role, verifier, gen, bucket: new Bucket(RATE_PER_SECOND, RATE_BURST), replaced: false,
        setup: target.setup, frames: 0, since: Date.now() };
      room[target.role] = me;
      rooms.set(name, room);
      const peer = room[otherRole(target.role)];
      if (peer && !peer.replaced && peer.ws.readyState === peer.ws.OPEN) {
        ws.send(PEER_ONLINE);
        peer.ws.send(PEER_ONLINE);
      }

      const onMessage = async (data: WebSocket.RawData, isBinary: boolean) => {
        if (me.setup) {
          if (!isBinary && data.toString() === "ping") return ws.send("pong");
          if (Date.now() - me.since > SETUP_TTL_MS) return ws.close(1008, "expired");
          if (!isBinary) return ws.close(1003, "binary only");
          const f = Buffer.isBuffer(data) ? data : Buffer.concat(data as Buffer[]);
          if (f.length > MAX_SETUP_FRAME) return ws.close(1009, "too big");
          if (++me.frames > SETUP_FRAMES) return ws.close(1008, "setup limit");
          const o = room[otherRole(me.role)];
          if (!o || o.replaced || o.ws.readyState !== o.ws.OPEN) return ws.send(PEER_OFFLINE);
          return o.ws.send(f, { binary: true });
        }
        if ((await accessGeneration(accessKey)) !== me.gen || !me.gen) return ws.close(1008, "access key changed");
        if (!isBinary) {
          if (data.toString() === "ping") return ws.send("pong"); // the platform's auto-response in the Worker
          return ws.close(1003, "binary only");
        }
        const frame = Buffer.isBuffer(data) ? data : Buffer.concat(data as Buffer[]);
        if (frame.length > MAX_FRAME) return ws.close(1009, "too big");
        if (!me.bucket.take()) return ws.close(1008, "rate");
        const other = room[otherRole(me.role)];
        if (!other || other.replaced || other.ws.readyState !== other.ws.OPEN) return ws.send(PEER_OFFLINE);
        other.ws.send(frame, { binary: true });
      };
      // One message at a time: the await above would otherwise let a burst overtake itself, which the Worker never does.
      let turn: Promise<void> = Promise.resolve();
      ws.on("message", (data, isBinary) => {
        turn = turn.then(() => onMessage(data, isBinary)).catch(() => {});
      });

      const left = () => {
        if (room[me.role] === me) delete room[me.role];
        if (!room.pc && !room.phone) rooms.delete(name);
        if (me.replaced) return;
        const other = room[otherRole(me.role)];
        if (other && !other.replaced && other.ws.readyState === other.ws.OPEN) other.ws.send(PEER_OFFLINE);
      };
      ws.on("close", left);
      ws.on("error", left);
    });
  });

  await new Promise<void>((resolve) => server.listen(options.port ?? 0, options.host ?? "127.0.0.1", resolve));
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  return {
    port,
    setAccessKey: (key) => void (accessKey = key),
    rooms: () => rooms.size,
    close: () =>
      new Promise<void>((resolve) => {
        for (const c of wss.clients) c.terminate();
        server.close(() => resolve());
        server.closeAllConnections();
      }),
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const relay = await startRelay({ port: Number(process.env.PORT ?? 8787), host: process.env.HOST ?? "0.0.0.0", accessKey: process.env.ACCESS_KEY, connectsPerMinute: 30 });
  if (!process.env.ACCESS_KEY) process.stderr.write("ACCESS_KEY is not set: every room request will be refused (fail closed)\n");
  process.stdout.write(`Coucou link relay (Node) listening on port ${relay.port}\n`);
}
