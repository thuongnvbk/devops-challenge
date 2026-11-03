# Problem 3: Debugging the unreliable API

## TL;DR

- **Inaccessible.** nginx proxied to `api:3001`, but the app listens on `3000`, so every `/api/*` request returned 502. Once that is fixed, a second outage appears: **any Postgres restart crashes the Node process** (the `pg` pool emits an unhandled `'error'`), and with no restart policy it stays down.
- **Unreliable.** Three more problems: pool clients leak on query errors (10 errors leave the pool exhausted and requests hang forever, even after the fault clears), dependency calls have no time limit (Redis or Postgres blips make requests hang for about 60s and end in 504), and nginx resolves the API's IP once at startup and never again.
- **Fixed where the fault is.** In the app: `pool.query()`, error listeners, bounded timeouts, a readiness check that exercises what requests need, graceful shutdown. In the infra: correct port, nginx resolves the API name per request, healthchecks with `service_healthy` gates, restart policy.
- **Verified by checked-in fault injection.** `fault-matrix.sh` stops, hangs and kills each dependency and the API under load, injects query errors, sends SIGTERM mid-request, and asserts bounded failures and sustained recovery. 14/14 checks pass; the slowest failed request takes 4.0s (was 60s, nginx's timeout). `smoke-test.sh` is the fast per-push gate. It fails on the original stack and on a port-only fix.

```sh
docker compose up --build   # http://localhost:8080 (HOST_PORT / POSTGRES_PASSWORD via env or .env)
./smoke-test.sh             # CI gate, ~30s: own throwaway project, ephemeral port
./fault-matrix.sh           # nightly, ~6 min: the "after" evidence below (--self-test checks its verdicts)
```

## Findings (root causes of the reported symptoms, ranked by user impact)

| # | Issue | Symptom | Root cause | Evidence: before -> after | Fix |
|---|---|---|---|---|---|
| 1 | Proxy/app port mismatch | 100% of `/api/*` return 502 | `proxy_pass http://api:3001`; app listens on 3000 | nginx: `connect() failed (111: Connection refused) ... upstream: "http://172.18.0.4:3001/api/users"`; same request to `api:3000` from the nginx container: 200 -> 200 through nginx | `nginx/conf.d/default.conf`: port 3000 |
| 2 | API dies on Postgres restart, nothing restarts it | After any DB restart or failover, `/api/*` stays 502 until someone intervenes | pg-pool re-emits idle-client errors on the `Pool`. No `'error'` listener, so Node throws `Unhandled 'error' event` and exits. `restart: no` | `Emitted 'error' event on BoundPool ... terminating connection due to administrator command (57P01)`, api `Exited (1)`, `restartPolicy=no` -> 8x 500, recovered 2.4s after the restart, api not restarted | `pool.on('error')`, `restart: unless-stopped` |
| 3 | Pool client leak on query error | After 10 failed queries, every request hangs to nginx's 60s 504, even after the DB is healthy again. `/status` still says ok | `db.release()` skipped when `query()` throws. Pool `max` 10, `connectionTimeoutMillis` 0 (wait forever) | Injected query error: req 1-10 got 500, req 11-12 hung. After removing the fault: `504 t=60.08s`, `pg_stat_activity: idle n=10` -> 15/15 errors return 500 fast, then 10/10 return 200 | `pool.query()` (releases on all paths, destroys errored clients), `connectionTimeoutMillis: 2000` |
| 4 | Unbounded waits on dependencies | During Redis or Postgres blips, requests hang ~1 min and end 504 | ioredis defaults: offline queue plus 20 reconnect retries, each with a slow failing DNS lookup (`EAI_AGAIN`), and no timeouts. On a hung Redis, timed-out commands also stay queued on the open socket. pg: no query timeout. nginx: 60s defaults | Redis stopped: `504 t=60.0s`, `500 t=55.9s` (`max retries per request limit (which is 20)`). Redis paused: `504 t=60.1s`. Postgres paused: 12/12 `504 t=60s` -> worst failure: Redis <=1.0s; Postgres down 2.0s, hung 4.0s; recovery <=2.5s. Already-failed writes Redis still ran after a 10s/30s hang at 100 req/s: 848/2832 with `socketTimeout` and replay protection removed -> 199/197 | `enableOfflineQueue: false`, `commandTimeout`, `socketTimeout`, no command replay, connect timeouts, `statement_timeout`/`query_timeout`, nginx `proxy_connect_timeout 2s`/`proxy_read_timeout 10s` |
| 5 | nginx resolves `api` once, at startup | After the API is recreated with a new IP, 502 until nginx restarts. If the API is down, nginx will not start at all, so `/` is down too | Static `proxy_pass` hostname is resolved at config load and cached for the process lifetime | IP `.4 -> .6`: 502 still at +15s, error log shows upstream `172.18.0.4`. With api stopped, nginx restart fails: `[emerg] host not found in upstream "api"`, exit 1 -> IP change asserted (`.4 -> .6`), recovered 0.9s after the recreate. nginx starts with api down: `/` 200, `/api/users` 502 in 1ms | `resolver 127.0.0.11 valid=5s` + variable `proxy_pass` |
| 6 | Startup race | 500s right after `docker compose up` | `depends_on` only waits for container start, not readiness | 12x 500 `ECONNREFUSED ...:5432` during cold start -> 0x 5xx (nginx starts only once api is ready; until then clients get connection refused, not errors) | Healthchecks on all three backends, `condition: service_healthy` |
| 7 | SIGTERM ignored | Every stop/deploy takes 10s and kills in-flight requests | Node as PID 1 gets no default SIGTERM action, and there was no handler | `docker stop`: 10335 ms, exit 137 -> 233 ms idle, exit 0. With a request in flight: stop 3.7s, exit 0, and the request gets its answer (500 from the hung DB), not a dropped connection | `SIGTERM`/`SIGINT` drain: `server.close`, `pool.end`, `redis.quit`, 8s deadline |

### Latent risks found on the way (fixed)

| Risk | Evidence | Fix |
|---|---|---|
| No readiness signal: `/status` returns 200 while the pool is exhausted or a dependency is down | `/status` 200 during finding 3 | `/ready` runs a Postgres query (1s budget) and a Redis write (`SET health:api 1 EX 10`). PING alone passes on a read-only or out-of-memory Redis: with `maxmemory` hit, the old check returned 200 while `/api/users` returned 500 -> 503 and api `unhealthy` in 15s. Each dependency's fail/recovery is logged once (`readiness_changed`). `/status` stays as liveness |
| Internal errors returned to clients | `{"error":"injected query failure"}`. Connection errors include internal IPs | Generic `internal error` body; detail is logged |
| Logs not machine-parseable | Free-text app errors, custom nginx format | App writes JSON lines (`request_failed`, `dependency_error` with `dep`, `code`, `duration_ms`); nginx `escape=json` access log with upstream address, status and timings |
| Credentials hardcoded in code and duplicated in compose | `user/password: "postgres"` in `index.js` | `DB_*` env vars, one `POSTGRES_PASSWORD` variable feeds both postgres and api (local default kept so `docker compose up` works) |
| Non-reproducible build | No lockfile, `npm install` against `^` ranges | `package-lock.json` (resolves to the same versions the original image had: express 4.22.3, pg 8.23.1, ioredis 5.11.1), `npm ci --omit=dev` |
| Container runs as root | `ps`: `1 root node src/index.js` | `USER node` |
| Dead config that looks live | `nginx/nginx.conf` (empty) and `postgres/init.sql` were never mounted (`show max_connections` = 100) | Removed. Mounted, the empty `nginx.conf` breaks nginx (`[emerg] no "events" section`) and `init.sql` sets `max_connections=20`, which fixes nothing |
| `/` served as `application/octet-stream` (the image's `default_type`), so browsers download it; obsolete `version:` key | `grep default_type /etc/nginx/nginx.conf`; compose warning | `default_type text/plain` on that location; key removed |

### Deliberately not applied

- **Runtime upgrades.** `nginx:1.25` (superseded in 2024) and `node:20` (EOL April 2026) no longer get security fixes. Upgrade in a separate, tested change, pinned by digest.
- **Redis stays a hard dependency of `/api/users`.** The `last_call` write is a side effect the response does not need. Making it best-effort is a product decision. It now fails fast instead of hanging.
- **Zero-downtime deploys.** One api replica means a recreate leaves a ~1s gap. Closing it needs 2+ replicas behind health-aware routing.
- **Named Postgres volume.** The app stores nothing, and the image's anonymous volume already survives restarts and recreates. Either way, `POSTGRES_PASSWORD` only initialises an empty data directory: changing it later changes the api's login, not the DB password. Rotate with `ALTER ROLE` first, then the app credential.
- **nginx is gated on api readiness, and readiness includes Redis.** So `docker compose up` will not start nginx (or `/`) while Postgres or Redis is down: no traffic until the API can serve it. This applies only to `up`; engine restarts ignore `depends_on`.
- **Health endpoints stay off nginx.** `/status` and `/ready` expose internals and are for the orchestrator only. **No metrics endpoint in this change**; see monitoring.
- Note: plain Compose does not restart `unhealthy` containers. Healthchecks gate startup and give visibility; crash recovery comes from `restart:`.

## How I diagnosed it

1. **Reproduced as shipped** (only the published port changed; 8080 was busy on the test host). `/` returned 200, `/api/users` 502. The nginx error log named upstream `:3001`, while `api:3000` answered 200 from inside the nginx container: finding 1. I also tested the unmounted files (`nginx -t` with the empty `nginx.conf`; Postgres booted with `init.sql`).
2. **Removed the first fault to see what it hid.** On a copy with only the port fixed, I injected faults under load (4-8 curl clients through nginx): Postgres restart, stop and pause; Redis stop and pause; api recreated onto a new IP (a placeholder holds the freed address); SIGTERM; cold start. Query errors come from shadowing `now()` (`CREATE FUNCTION public.now() ... RAISE EXCEPTION` plus `ALTER ROLE postgres SET search_path = public, pg_catalog`).
3. **Confirmed each mechanism in library source.** pg-pool's `idleListener` re-emits on the pool. `Pool.query()` calls `release(err)`, which destroys the client. ioredis defaults to 20 retries per request. Its `commandTimeout` only rejects the promise: the command stays queued and is resent on reconnect unless `autoResendUnfulfilledCommands` is off. `socketTimeout` drops a connection that stopped answering.
4. **Encoded the matrix in `fault-matrix.sh`:** 4 clients through nginx while each fault is held, samples ordered by completion. Dependency rows pass only if app 500s complete inside the fault window (no 502/504/transport errors), and then 10+ good responses (status and body) complete after both the fault's removal and the last failure. A Postgres restart can be absorbed with no errors, so that row proves the fault from the app's idle-client error log instead. Crash/recreate rows may fail any way. The backlog check refuses to score without a confirmed MONITOR capture, a clean load run and baseline writes. `--self-test` proves these verdicts on synthetic samples. Final files:

```
fault                       reqs  good   500 other      max recovered  result
postgres restart             451   443     8     0    2.01s     2.4s  PASS
postgres down 10s            468   441    27     0    2.01s     2.5s  PASS
postgres hung 10s            533   520    13     0    4.00s     0.0s  PASS
redis down 10s               892   468   424     0    0.01s     1.8s  PASS
redis hung 30s              1492   504   988     0    1.00s     0.7s  PASS
redis rejects writes 10s     872   524   348     0    0.01s     0.1s  PASS
api crash (SIGKILL)          503   499     0     4    1.09s     1.1s  PASS
api recreate on new IP       516   491     0    25    1.00s     0.9s  PASS
  api IP 172.18.0.4 -> 172.18.0.6  PASS

late Redis writes after a hang           10s hang: 199 (baseline 177), 30s hang: 197 (baseline 178)  PASS
/ready, postgres hung                    503 in 1.003283s, fail and recovery logged  PASS
/ready, redis rejects writes             503 in 0.002121s, fail and recovery logged  PASS
15 query errors, then fault removed      500s=15/15, then ok=10/10  PASS
SIGTERM with a request in flight         stop 3685ms exit=0 in-flight=500  PASS
```

## Timeout budget

| Layer | Setting | Value |
|---|---|---|
| pg pool | `connectionTimeoutMillis` (connect, or wait for a free slot) | 2s |
| Postgres / pg client | `statement_timeout` (server cancels; verified `pg_sleep(5)` -> 57014) / `query_timeout` (backstop if the server stops answering) | 3s / 4s |
| ioredis | `connectTimeout` / `commandTimeout` / `socketTimeout` | 2s / 1s / 2s |
| App worst case: `/api/users` / `/ready` | 2 + 4 + 1 / 2 + 1 (per-query `query_timeout`; the Redis write runs in parallel) | ~7s / ~3s |
| Healthcheck timeout (> `/ready`); drain deadline (< Docker's 10s stop) | | 5s; 8s |
| nginx | `proxy_connect_timeout` / `proxy_read_timeout` (> app worst case) | 2s / 10s |

Each layer gives up before its caller, so the app answers with a clean 500 before nginx turns the request into a 504.

## Monitoring and alerts

**SLIs.** Ship the JSON logs (app and nginx) to Loki with Alloy or Fluent Bit.
- *Server-observed availability* (nginx log): the population is `/api/users` requests excluding 499 (the client gave up); good means 2xx. SLO 99.9% over 30 days. It cannot see connections nginx never accepted (refusals while nginx restarts). The 5xx ratio: `sum(rate({app="nginx"} | json | uri="/api/users" | status >= 500 [5m])) / sum(rate({app="nginx"} | json | uri="/api/users" | status != 499 [5m]))`.
- *External availability*: blackbox `probe_success` for `GET /api/users` through the public endpoint from 2+ locations. It counts refusals, DNS and TLS failures. SLO 99.9%.
- *Latency*: share of good requests with `request_time` < 500ms. SLO 99%.

| Alert | Signal | Threshold | Route | Would have caught |
|---|---|---|---|---|
| Error budget burn | server-observed availability | Burn rate 14.4x over 1h and 5m, or 6x over 6h and 30m | Page | 1 (100% 502, fires within ~2 min), 2, 3, 5 |
| External probe failing | `probe_success` | 3 consecutive failures from 2+ locations | Page | 1 and 5, and outages nginx never logs (nginx down, refused connections) |
| Upstream unreachable | nginx error log `connect() failed`, `could not be resolved` | > 0 for 2m | Ticket (the burn alert pages) | 1 and 5. Names the bad `host:port`: "app down", not "app erroring" |
| Upstream latency | p99 `upstream_response_time` on `/api/users` | > 2s for 5m | Page if sustained 15m | 3 and 4 (the 60s hangs) |
| Dependency errors | app log `event="request_failed"`, counted by `dep` and `code` | > 1/s for 2m per dep | Ticket | 4, naming the dependency |
| Pool saturation | `pool.totalCount/idleCount/waitingCount` (in `/ready` today; export via prom-client) | `waiting > 0` for 1m | Ticket | 3. A cause signal: waits fail after 2s, so it fires alongside user impact, not before it, but says why |
| Restarts and unclean exits | `docker events`, cAdvisor or `kube_pod_container_status_restarts_total` | > 2 restarts in 15m, or any exit code other than 0/143 | Page on crash loop | 2 (the restart policy hides crashes from users) and 7 (exit 137 on stop) |
| Readiness | blackbox `probe_success` on each instance's `/ready` (status code only) | Failing 2m | Ticket | 6 and dependency outages. The reason is the app's `readiness_changed` log line (`dep`, `state`, `code`), written on failure and on recovery |
| Postgres connections | postgres_exporter: sessions vs `max_connections`; `application_name='api'` sessions idle > 5m | > 80% of max, or any long-idle api session (the pool closes idle ones after 10s) | Ticket | 3 from the DB side |

## Preventing this in production

1. **CI gate on every change to this stack.** Run `docker compose config -q`, then `nginx -t` with the conf in the pinned image, then `npm ci` (fails on lockfile drift), then `./smoke-test.sh`. The smoke test:
   - Uses its own throwaway project. It refuses to run if that project already exists, and removes only what it created.
   - Publishes on an ephemeral port and calls `/api/users` through nginx: at startup, after a Postgres restart, after a Redis restart, and after moving the api to a new IP (the IP change is asserted).
   - Requires 10 consecutive successes within 30s of each fault, measured on the clock.
   - Asserts the api did not restart, because the restart policy would hide a crash.

   It fails on the original stack (step 1), on a port-only fix (Postgres restart), and on the final code without the pool `'error'` listener (requests recover, the crash assertion fails).
2. **Proxy/app contract.** The port is an interface between two configs: test it through the proxy, never by calling the app directly. Better, render the nginx config from one `PORT` with the image's `/etc/nginx/templates` envsubst.
3. **Static checks for the footguns that bit here.** A Semgrep or ESLint rule that flags `pool.connect()` without `release()` in `finally`, and `new Pool`/`new Redis` without an `.on('error')` listener. A review checklist item: every network call has a timeout lower than the caller's. The leak case is in `fault-matrix.sh`, and it fails when the leak fix is reverted.
4. **Readiness gates in the real platform.** On Kubernetes or ECS: `readinessProbe` on `/ready`, `livenessProbe` on `/status`, a `preStop` sleep so the load balancer drains first, termination grace > the app's drain deadline, 2+ replicas, `maxUnavailable: 0`, and a PodDisruptionBudget. Canary rollouts gated on the SLIs above, with automated rollback.
5. **Rehearse failure.** Run `fault-matrix.sh` nightly in non-prod, and add DB failover and node drain on the real platform. Promote dev -> sit -> uat -> prod only on green.
6. **Config hygiene.** CODEOWNERS on infra config. Reviews look at the rendered config diff (`docker compose config`, `helm diff`). No unreferenced config files. Images pinned by digest, Renovate, and EOL tracking, which would have flagged node 20 and nginx 1.25.
