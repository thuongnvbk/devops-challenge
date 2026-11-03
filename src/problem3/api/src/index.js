const express = require("express");
const { Pool } = require("pg");
const Redis = require("ioredis");

const PORT = 3000;

// One JSON object per line, with stable event names, for log-based alerts.
function log(level, event, fields = {}) {
  console.log(JSON.stringify({ ts: new Date().toISOString(), level, event, ...fields }));
}

const app = express();

// Every dependency call is time-bounded so a slow or dead dependency fails the
// request fast instead of pinning pool slots and nginx workers. Worst case for
// /api/users is ~7s (2s pool wait/connect + 4s query + 1s Redis), below the
// nginx proxy_read_timeout (10s) and the shutdown deadline (8s).
const pool = new Pool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  application_name: "api", // attributes sessions in pg_stat_activity
  max: 10,
  connectionTimeoutMillis: 2000, // new connection, or wait for a free slot
  statement_timeout: 3000, // server-side cancel
  query_timeout: 4000, // client-side backstop if Postgres stops answering
});

// Idle clients error when Postgres restarts or the network drops. pg-pool
// discards the client and re-emits on the pool; with no listener Node treats
// it as an unhandled 'error' event and the process exits.
pool.on("error", (err) => {
  log("warn", "dependency_error", { dep: "postgres", source: "idle_client", code: err.code, error: err.message });
});

const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: Number(process.env.REDIS_PORT || 6379),
  connectTimeout: 2000,
  commandTimeout: 1000, // rejects the caller's promise only
  // A hung Redis keeps the socket open, so timed-out commands would pile up
  // and still run when it recovers. Drop the connection after 2s without a
  // reply and do not replay unanswered commands on reconnect.
  socketTimeout: 2000,
  autoResendUnfulfilledCommands: false,
  maxRetriesPerRequest: 1,
  // Fail immediately while disconnected instead of queueing the command
  // through up to 20 reconnect attempts (the default).
  enableOfflineQueue: false,
});

redis.on("error", (err) => {
  log("warn", "dependency_error", { dep: "redis", source: "connection", code: err.code, error: err.message });
});

app.get("/api/users", async (req, res) => {
  const started = Date.now();
  let dep = "postgres";
  try {
    // pool.query() returns the client on every path and discards it on error.
    // connect()/release() without a finally leaks the client on any query
    // error; ten leaks exhaust the pool and every later request hangs.
    const result = await pool.query("SELECT NOW()");
    dep = "redis";
    await redis.set("last_call", Date.now());
    res.json({ ok: true, time: result.rows[0] });
  } catch (err) {
    log("error", "request_failed", {
      route: "/api/users", dep, code: err.code, error: err.message, duration_ms: Date.now() - started,
    });
    res.status(500).json({ ok: false, error: "internal error" });
  }
});

// Liveness: the process is up and serving. Deliberately no dependency checks.
app.get("/status", (req, res) => {
  res.json({ status: "ok" });
});

// Log each dependency's readiness only when it changes (fail and recovery),
// so the reason for an unhealthy api is in the log without per-probe noise.
const readiness = {};
function noteReadiness(dep, result) {
  const ok = result.status === "fulfilled";
  if (readiness[dep] === ok) return;
  readiness[dep] = ok;
  const err = ok ? {} : { code: result.reason.code, error: result.reason.message };
  log(ok ? "info" : "warn", "readiness_changed", { dep, state: ok ? "ok" : "fail", ...err });
}

// Readiness: Postgres runs a query and Redis accepts a write (what /api/users
// needs; PING alone passes on a read-only or out-of-memory Redis). Worst case
// ~3s (2s pool wait + 1s query), below the 5s healthcheck timeout.
app.get("/ready", async (req, res) => {
  const [pg, rd] = await Promise.allSettled([
    pool.query({ text: "SELECT 1", query_timeout: 1000 }),
    redis.set("health:api", "1", "EX", 10),
  ]);
  noteReadiness("postgres", pg);
  noteReadiness("redis", rd);
  const ready = pg.status === "fulfilled" && rd.status === "fulfilled";
  res.status(ready ? 200 : 503).json({
    status: ready ? "ok" : "unavailable",
    postgres: pg.status === "fulfilled" ? "ok" : pg.reason.message,
    redis: rd.status === "fulfilled" ? "ok" : rd.reason.message,
    pool: {
      total: pool.totalCount,
      idle: pool.idleCount,
      waiting: pool.waitingCount,
    },
  });
});

const server = app.listen(PORT, () => log("info", "listening", { port: PORT }));

// As PID 1, node gets no default SIGTERM handling: without this, docker stop
// waits 10s and SIGKILLs, dropping in-flight requests.
let shuttingDown = false;
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  log("info", "shutdown_started", { signal });
  setTimeout(() => {
    log("error", "shutdown_deadline_exceeded");
    process.exit(1);
  }, 8000).unref();
  server.close(async () => {
    await Promise.allSettled([pool.end(), redis.quit()]);
    process.exit(0);
  });
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
