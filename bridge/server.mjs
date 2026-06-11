// Telemetry bridge: CC historian (websocket) -> Discord webhook + status API
//
//   npm install ws
//   DISCORD_WEBHOOK="https://discord.com/api/webhooks/..." node server.mjs [port]
//
// The in-game historian streams JSON lines here (see bridge.conf on the
// historian computer). Alerts are forwarded to the Discord webhook; the
// latest reading per source is kept in memory and served at GET /status —
// which is the substrate a future MCP get_power_status tool queries, so
// the MCP layer never touches the game directly.

import http from "node:http";
import { WebSocketServer } from "ws";

const port = Number(process.argv[2] ?? 8466);
const hook = process.env.DISCORD_WEBHOOK;
const latest = {}; // source -> { t, data, receivedAt }
const alerts = []; // last 100 alerts

async function discord(content) {
  if (!hook) return;
  try {
    await fetch(hook, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ content }),
    });
  } catch (err) {
    console.error("discord forward failed:", err.message);
  }
}

const server = http.createServer((req, res) => {
  if (req.url === "/status") {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ latest, alerts: alerts.slice(-20) }, null, 2));
    return;
  }
  res.statusCode = 404;
  res.end("telemetry bridge: GET /status");
});

const wss = new WebSocketServer({ server });
wss.on("connection", (sock, req) => {
  console.log(`historian connected from ${req.socket.remoteAddress}`);
  sock.on("message", (buf) => {
    let msg;
    try {
      msg = JSON.parse(buf.toString());
    } catch {
      return; // non-JSON line (harness-style fallback), ignore
    }
    if (msg.alert) {
      alerts.push({ at: Date.now(), msg: msg.alert });
      if (alerts.length > 100) alerts.shift();
      console.log("ALERT:", msg.alert);
      discord(`\u{1F514} **base alert:** ${msg.alert}`);
    } else if (msg.source) {
      latest[msg.source] = { t: msg.t, data: msg.data, receivedAt: Date.now() };
    }
  });
  sock.on("close", () => console.log("historian disconnected"));
});

server.listen(port, () => {
  console.log(`telemetry bridge: ws://0.0.0.0:${port}  +  GET /status`);
  if (!hook) console.log("(DISCORD_WEBHOOK not set - alerts log to console only)");
});
