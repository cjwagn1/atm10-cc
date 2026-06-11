// Telemetry bridge: CC historian (websocket) -> Discord webhook + status API
//
//   npm install ws
//   BRIDGE_TOKEN="$(openssl rand -hex 16)" \
//   DISCORD_WEBHOOK="https://discord.com/api/webhooks/..." node server.mjs [port]
//
// The in-game historian streams JSON lines here; point its bridge.conf at
//   wss://<host>:<port>/?token=<BRIDGE_TOKEN>
// Alerts are forwarded to the Discord webhook; the latest reading per
// source is kept in memory and served at GET /status?token=... — the
// substrate a future MCP get_power_status tool queries, so the MCP layer
// never touches the game directly.
//
// Security posture (this listens on the public internet):
//   - shared-secret token on every websocket upgrade and /status hit,
//     compared in constant time
//   - browser-originated upgrades rejected (CC never sends an Origin)
//   - 64 KiB max websocket payload; alert text truncated; mention
//     parsing disabled and markdown-ish characters stripped before
//     anything reaches Discord
//   - bounded in-memory state (64 sources, 100 alerts)

import http from "node:http";
import crypto from "node:crypto";
import { WebSocketServer } from "ws";

const port = Number(process.argv[2] ?? 8466);
const hook = process.env.DISCORD_WEBHOOK;
const token = process.env.BRIDGE_TOKEN;
if (!token) {
  console.error("Set BRIDGE_TOKEN (shared secret; openssl rand -hex 16)");
  process.exit(1);
}

const latest = {}; // source -> { t, data, receivedAt }
const alerts = []; // last 100 alerts
const MAX_SOURCES = 64;

function tokenOk(req) {
  try {
    const got = new URL(req.url, "http://x").searchParams.get("token") ?? "";
    const a = Buffer.from(got);
    const b = Buffer.from(token);
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  } catch {
    return false;
  }
}

function sanitize(s) {
  return String(s)
    .replace(/[`*_~|]/g, "")          // markdown formatting
    .replace(/@/g, "@​")         // break @everyone / @here / mentions
    .slice(0, 1500);
}

async function discord(content) {
  if (!hook) return;
  try {
    await fetch(hook, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ content, allowed_mentions: { parse: [] } }),
    });
  } catch (err) {
    console.error("discord forward failed:", err.message);
  }
}

const server = http.createServer((req, res) => {
  if (req.url?.startsWith("/status")) {
    if (!tokenOk(req)) {
      res.statusCode = 401;
      res.end("unauthorized");
      return;
    }
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ latest, alerts: alerts.slice(-20) }, null, 2));
    return;
  }
  res.statusCode = 404;
  res.end("telemetry bridge: GET /status?token=...");
});

const wss = new WebSocketServer({
  server,
  maxPayload: 64 * 1024,
  verifyClient: (info, cb) => {
    // browsers always send Origin on upgrades; the CC http client doesn't.
    if (info.origin) return cb(false, 403, "forbidden origin");
    if (!tokenOk(info.req)) return cb(false, 401, "bad token");
    cb(true);
  },
});

wss.on("connection", (sock, req) => {
  console.log(`historian connected from ${req.socket.remoteAddress}`);
  sock.on("message", (buf) => {
    let msg;
    try {
      msg = JSON.parse(buf.toString());
    } catch {
      return; // non-JSON line, ignore
    }
    if (msg.alert) {
      const text = sanitize(msg.alert);
      alerts.push({ at: Date.now(), msg: text });
      if (alerts.length > 100) alerts.shift();
      console.log("ALERT:", text);
      discord(`\u{1F514} **base alert:** ${text}`);
    } else if (typeof msg.source === "string" && msg.source.length <= 64) {
      if (!(msg.source in latest)
        && Object.keys(latest).length >= MAX_SOURCES) {
        const oldest = Object.entries(latest)
          .sort((a, b) => a[1].receivedAt - b[1].receivedAt)[0];
        if (oldest) delete latest[oldest[0]];
      }
      latest[msg.source] = { t: msg.t, data: msg.data, receivedAt: Date.now() };
    }
  });
  sock.on("close", () => console.log("historian disconnected"));
});

server.listen(port, () => {
  console.log(`telemetry bridge: ws://0.0.0.0:${port}  +  GET /status?token=...`);
  if (!hook) console.log("(DISCORD_WEBHOOK not set - alerts log to console only)");
});
