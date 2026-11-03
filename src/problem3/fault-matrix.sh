#!/usr/bin/env bash
# Fault-injection matrix behind the "after" evidence in SOLUTION.md. About 6
# minutes: run it nightly or before a release under a CI job timeout, not on
# every push. Same isolation as smoke-test.sh. Needs GNU date (Linux).
#   ./fault-matrix.sh               optional: TEST_PROJECT=<new name> HOST_PORT=<port>
#   ./fault-matrix.sh --self-test   checks the verdict logic on synthetic samples
# shellcheck disable=SC2317  # cleanup, crash_api, recreate_api_new_ip run via trap/eval
set -euo pipefail
cd "$(dirname "$0")"

LAT_BUDGET=8   # s: every failure must be answered inside nginx's 10s read timeout
DEG_BUDGET=1   # s: a Redis outage may not slow /api/users (Redis is off its path)
STREAK=10      # good responses in a row that count as recovered
GRACE_MS=5000  # requests caught by the fault may complete this long after its removal
failed=0
judge() { if [ "$1" = ok ]; then v=PASS; else v="FAIL ($1)"; failed=1; fi; }

# evaluate <samples> <fault start ms> <fault removed ms> <dep|blip|degrade|disrupt>
# One sample per request: <start_ms> <end_ms> <http_code> <seconds> <body_ok>,
# processed in completion order. dep rows (Postgres outage) must show app 500s
# completing inside [start, removed + grace], and no other failure: a 502, 504,
# transport error or bad body means the app did not answer. blip rows (a
# restart short enough to be absorbed without errors) have the same rule minus
# the 500s; row() confirms the fault from the app log instead. degrade rows
# (Redis outage) must not fail or slow any request (DEG_BUDGET); row() proves
# the fault from the app log. disrupt rows (api crash or recreate) may fail any way. Recovery needs STREAK good responses
# (200 and "ok":true) completing after the removal and after the last failure;
# "recovered" is when the first of them completed, relative to the removal.
evaluate() {
  sort -n -k2 "$1" | awk -v fs="$2" -v tr="$3" -v grace="$GRACE_MS" -v kind="$4" \
    -v budget="$LAT_BUDGET" -v deg="$DEG_BUDGET" -v need="$STREAK" '
    function add(m) { why = (why == "") ? m : why "; " m }
    { n++; if ($4 > max) max = $4
      if ($3 == 200 && $5 == 1) { ok++; if ($2 > tr) { if (!post) first = $2; post++ } }
      else { post = 0; if ($3 == 500) { e5++; if ($2 >= fs && $2 <= tr + grace) seen++ } else other++ } }
    END {
      if (kind == "dep" && !seen) add("fault not observed")
      if (kind == "degrade" && e5 + other) add(e5 + other " failed requests")
      else if (kind != "disrupt" && other) add(other " non-app failures")
      if (max > (kind == "degrade" ? deg : budget)) add("latency " max "s")
      if (post < need) add("no sustained recovery")
      printf "%d %d %d %d %.2f %s %s\n", n, ok, e5, other, max,
        (post >= need) ? sprintf("%.1f", (first - tr) / 1000) : "-", (why == "") ? "ok" : why }'
}

# backlog_eval <monitor capture> <pause ms> <unpause ms> <monitor_seen 0|1> <load exit code>
# Counts SET last_call that Redis ran after the hang ended and >1.5s after their
# request (the 1s command timeout had already given up on them). Refuses to report a number
# unless the evidence is real: MONITOR was capturing, the load generator
# succeeded, and the capture holds baseline writes from before the hang.
backlog_eval() {
  awk -v tp="$2" -v tu="$3" -v seen="$4" -v rc="$5" '
    /"last_call"/ { ts = $1 * 1000; val = $NF; gsub(/"/, "", val)
      if (ts < tp) base++; else if (ts >= tu - 100 && ts - val > 1500) late++ }
    END { why = "ok"
      if (seen != 1) why = "MONITOR not capturing"
      else if (rc != 0) why = "load generator exit " rc
      else if (!base) why = "no baseline writes captured"
      printf "%d %d %s\n", late, base, why }' "$1"
}

if [ "${1:-}" = --self-test ]; then
  t=$(mktemp)
  trap 'rm -f "$t"' EXIT
  goods() { for i in $(seq "$1" "$2"); do echo "$((i * 100)) $((i * 100 + 5)) 200 0.005 1"; done; }
  check() { # check <name> <want PASS|FAIL> <kind> [fault start] [fault removed]; samples on stdin
    cat >"$t"
    read -r _ _ _ _ _ rec why <<<"$(evaluate "$t" "${4:-500}" "${5:-1000}" "$3")"
    got=FAIL
    [ "$why" != ok ] || got=PASS
    [ "$got" = "$2" ] || failed=1
    printf '%-44s want %s, got %s (recovered=%s; %s)\n' "$1" "$2" "$got" "$rec" "$why"
  }
  check "500s in window, then sustained 200s" PASS dep < <(echo "900 1000 500 0.1 0"; goods 11 22)
  check "fast 502, then 200s" FAIL dep < <(echo "900 905 502 0.005 0"; goods 11 22)
  check "slow 500 finishing last" FAIL dep < <(echo "500 7500 500 7.0 0"; goods 11 22)
  check "no fault observed" FAIL dep < <(goods 11 22)
  check "200 with a bad body" FAIL dep < <(echo "900 1000 500 0.1 0"; echo "1000 1005 200 0.005 0"; goods 11 22)
  check "only 1 good after removal (ends 105..1005)" FAIL dep 0 1000 < <(echo "60 100 500 0.04 0"; goods 1 10)
  check "500s only before the fault window" FAIL dep 500 1000 < <(echo "50 100 500 0.05 0"; goods 11 22)
  check "restart absorbed without errors" PASS blip < <(goods 11 22)
  check "502 during a dependency restart" FAIL blip < <(echo "900 905 502 0.005 0"; goods 11 22)
  check "502 during an api recreate" PASS disrupt < <(echo "900 905 502 0.005 0"; goods 11 22)
  check "redis outage served with 200s" PASS degrade < <(goods 4 22)
  check "500 during a redis outage" FAIL degrade < <(echo "900 1000 500 0.1 0"; goods 11 22)
  check "1.5s 200s during a redis outage" FAIL degrade < <(echo "900 2400 200 1.5 1"; goods 11 22)
  bcheck() { # bcheck <name> <want PASS|FAIL> <monitor_seen> <load rc>; capture on stdin
    cat >"$t"
    read -r late base why <<<"$(backlog_eval "$t" 2000000 3000000 "$3" "$4")"
    got=FAIL
    [ "$why" != ok ] || got=PASS
    [ "$got" = "$2" ] || failed=1
    printf '%-44s want %s, got %s (late=%s baseline=%s; %s)\n' "backlog: $1" "$2" "$got" "$late" "$base" "$why"
  }
  set_at() { echo "$1.000000 [0 172.18.0.4:1] \"set\" \"last_call\" \"$2\""; }
  bcheck "baseline and late writes" PASS 1 0 < <(set_at 1000 999000; set_at 3001 1000000)
  bcheck "empty capture" FAIL 1 0 < <(:)
  bcheck "MONITOR never confirmed" FAIL 0 0 < <(set_at 1000 999000)
  bcheck "load generator failed" FAIL 1 1 < <(set_at 1000 999000)
  exit "$failed"
fi

project=${TEST_PROJECT:-p3-matrix-$$-$RANDOM}
export HOST_PORT=${HOST_PORT:-0}
work=$(mktemp -d)

dc() { docker compose -p "$project" "$@"; }
svc() { dc ps -q "$1"; }
ip_of() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(svc "$1")"; }
now_ms() { date +%s%3N; }

if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$project")$(docker volume ls -q --filter "label=com.docker.compose.project=$project")" ]; then
  echo "refusing to run: compose project '$project' already exists" >&2
  exit 2
fi
cleanup() {
  rm -f "$work/run"
  docker rm -f "$project-ipholder" >/dev/null 2>&1 || true
  dc down -v --remove-orphans --rmi local >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

wait_healthy() { # bounded: a stuck api fails the run (and the trap cleans up)
  local deadline=$((SECONDS + 60)) id
  while :; do
    id=$(svc api 2>/dev/null) || id=""
    if [ -n "$id" ] && [ "$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null)" = healthy ]; then return 0; fi
    if ((SECONDS >= deadline)); then
      echo "FAIL: api not healthy within 60s"
      dc ps -a
      dc logs --tail 30 api
      exit 1
    fi
    sleep 1
  done
}

# 4 clients through nginx, writing samples in the format evaluate() reads.
probe_start() {
  : >"$work/p"
  touch "$work/run"
  for _ in 1 2 3 4; do
    (while [ -e "$work/run" ]; do
      t=$(now_ms)
      r=$(curl -s -m 15 -w '\n%{http_code} %{time_total}' "$url" || true)
      ok=0
      [[ ${r%$'\n'*} != *'"ok":true'* ]] || ok=1
      echo "$t $(now_ms) ${r##*$'\n'} $ok" >>"$work/p"
      sleep 0.1
    done) &
  done
}
probe_stop() { rm -f "$work/run"; wait; }

# row <name> <dep|blip|degrade|disrupt> <expected api restarts|any> <fault cmd> <hold s> [<recover cmd>] [<api log line that proves the fault>]
row() {
  local name=$1 kind=$2 want=$3 fault=$4 hold=$5 recover=${6:-} proof=${7:-} r0 t_start t_rec restarts since logs
  r0=$(docker inspect -f '{{.RestartCount}}' "$(svc api)")
  probe_start
  sleep 3
  since=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
  t_start=$(now_ms)
  eval "$fault" >/dev/null 2>&1
  sleep "$hold"
  if [ -n "$recover" ]; then eval "$recover" >/dev/null 2>&1; fi
  t_rec=$(now_ms)
  sleep 12
  probe_stop
  read -r n ok e5 other max rec why <<<"$(evaluate "$work/p" "$t_start" "$t_rec" "$kind")"
  restarts=$(($(docker inspect -f '{{.RestartCount}}' "$(svc api)") - r0))
  # Capture first: under pipefail, grep -q exiting early would SIGPIPE docker logs.
  logs=$(docker logs --since "$since" "$(svc api)" 2>&1)
  if [ -n "$proof" ] && ! grep -qF "$proof" <<<"$logs"; then
    why=$([ "$why" = ok ] && echo "fault not observed in api log" || echo "$why; fault not observed in api log")
  fi
  if [ "$want" != any ] && [ "$restarts" != "$want" ]; then
    why=$([ "$why" = ok ] && echo "api restarts=$restarts" || echo "$why; api restarts=$restarts")
  fi
  judge "$why"
  printf '%-26s %5s %5s %5s %5s %7ss %8s  %s\n' "$name" "$n" "$ok" "$e5" "$other" "$max" "${rec}s" "$v"
}

crash_api() {
  docker run --rm --pid=host --user 0 --entrypoint kill "${project}-api" -9 \
    "$(docker inspect -f '{{.State.Pid}}' "$(svc api)")"
}
recreate_api_new_ip() {
  dc rm -sf api
  docker rm -f "$project-ipholder" >/dev/null 2>&1 || true
  docker run -d --rm --name "$project-ipholder" --network "${project}_default" \
    --entrypoint sleep "${project}-api" 300
  dc up -d --no-deps api
}

dc up -d --build --wait --wait-timeout 120 >/dev/null 2>&1 || { echo "stack did not become healthy"; exit 1; }
url="http://127.0.0.1:$(dc port nginx 80 | sed 's/.*://')/api/users"
pg=$(svc postgres)
rd=$(svc redis)

printf '%-26s %5s %5s %5s %5s %8s %8s  %s\n' fault reqs good 500 other max recovered result
row "postgres restart" blip 0 "dc restart postgres" 0 "" '"dep":"postgres","source":"idle_client"'
row "postgres down 10s" dep 0 "dc stop postgres" 10 "dc start postgres"
row "postgres hung 10s" dep 0 "docker pause $pg" 10 "docker unpause $pg"
redis_proof='"dep":"redis","source":"last_call_write"'
row "redis down 10s" degrade 0 "dc stop redis" 10 "dc start redis" "$redis_proof"
row "redis hung 30s" degrade 0 "docker pause $rd" 30 "docker unpause $rd" "$redis_proof"
row "redis rejects writes 10s" degrade 0 "docker exec $rd redis-cli config set maxmemory 1" 10 \
  "docker exec $rd redis-cli config set maxmemory 0" "$redis_proof"
row "api crash (SIGKILL)" disrupt 1 crash_api 0
old_ip=$(ip_of api)
row "api recreate on new IP" disrupt any recreate_api_new_ip 0
new_ip=$(ip_of api)
why=ok
[ "$new_ip" != "$old_ip" ] || why="IP unchanged"
judge "$why"
echo "  api IP $old_ip -> $new_ip  $v"
wait_healthy

echo
# Writes Redis still runs after a hang ends, >1.5s after their request (the 1s
# command timeout had already given up on them), at a fixed offered 100 req/s.
# Must not grow with the hang's length: timed-out commands may not pile up or replay.
loadjs='const [rate, secs] = process.argv.slice(2).map(Number);
const t = setInterval(() => fetch("http://127.0.0.1:3000/api/users").then((r) => r.arrayBuffer()).catch(() => {}), 1000 / rate);
setTimeout(() => { clearInterval(t); setTimeout(() => process.exit(0), 1500); }, secs * 1000);'
backlog() {
  local hold=$1 mon load rc=0 seen=0 t_pause t_un id
  docker exec "$rd" redis-cli MONITOR >"$work/mon" 2>&1 &
  mon=$!
  for _ in $(seq 20); do # confirm the capture is live before measuring
    docker exec "$rd" redis-cli ECHO "monitor-check-$hold" >/dev/null
    if grep -q "monitor-check-$hold" "$work/mon"; then seen=1; break; fi
    sleep 0.25
  done
  docker exec -i "$(svc api)" node - 100 $((hold + 4)) <<<"$loadjs" >/dev/null 2>&1 &
  load=$!
  sleep 2
  t_pause=$(now_ms)
  docker pause "$rd" >/dev/null
  sleep "$hold"
  t_un=$(now_ms)
  docker unpause "$rd" >/dev/null
  wait "$load" || rc=$?
  sleep 2
  id=$(docker exec "$rd" redis-cli client list | awk '/ flags=O / { sub("id=", "", $1); print $1 }')
  [ -z "$id" ] || docker exec "$rd" redis-cli client kill id "$id" >/dev/null
  kill "$mon" 2>/dev/null || true
  wait "$mon" 2>/dev/null || true
  backlog_eval "$work/mon" "$t_pause" "$t_un" "$seen" "$rc"
}
read -r short sbase swhy <<<"$(backlog 10)"
sleep 3
read -r long lbase lwhy <<<"$(backlog 30)"
why=ok
[ "$swhy" = ok ] || why="10s run: $swhy"
[ "$lwhy" = ok ] || why="30s run: $lwhy"
[ "$why" != ok ] || ((long <= short * 3 / 2 + 50)) || why="grows with hang length"
judge "$why"
printf '%-40s %s\n' "late Redis writes after a hang" \
  "10s hang: $short (baseline $sbase), 30s hang: $long (baseline $lbase)  $v"
wait_healthy

# Readiness answers inside the 5s healthcheck timeout: 503 when Postgres
# cannot serve, 200 with "redis":"degraded" when only Redis fails. Both log
# the bad state and the recovery (readiness_changed).
for f in "pause $pg|unpause $pg|postgres|postgres hung|503|\"status\":\"unavailable\"|fail" \
  "exec $rd redis-cli config set maxmemory 1|exec $rd redis-cli config set maxmemory 0|redis|redis rejects writes|200|\"redis\":\"degraded\"|degraded"; do
  IFS='|' read -r on off dep name want body bad <<<"$f"
  since=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
  eval "docker $on" >/dev/null
  r=$(docker exec "$(svc nginx)" curl -s -m 10 -w '\n%{http_code} %{time_total}' http://api:3000/ready || true)
  eval "docker $off" >/dev/null
  for _ in $(seq 15); do # until fully ready again (Redis degradation also returns 200)
    [[ $(docker exec "$(svc nginx)" curl -s -m 5 http://api:3000/ready || true) != *'"status":"ok"'* ]] || break
    sleep 1
  done
  logs=$(docker logs --since "$since" "$(svc api)" 2>&1)
  last=${r##*$'\n'} code=${last% *} t=${last#* } why=ok
  [ "$code" = "$want" ] && [[ ${r%$'\n'*} == *"$body"* ]] && awk -v t="$t" 'BEGIN { exit !(t < 5) }' ||
    why="got $code in ${t}s"
  for s in "$bad" ok; do
    grep -q "\"event\":\"readiness_changed\",\"dep\":\"$dep\",\"state\":\"$s\"" <<<"$logs" || why="no $s transition logged"
  done
  judge "$why"
  printf '%-40s %s\n' "/ready, $name" "$code in ${t}s, $bad and recovery logged  $v"
done
wait_healthy

# More query errors than the pool size, then the fault is removed: the next
# requests must succeed at once (a leaking pool hangs here instead).
docker exec -i "$pg" psql -U postgres -v ON_ERROR_STOP=1 -q >/dev/null <<'SQL'
CREATE FUNCTION public.now() RETURNS timestamptz LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected'; END $$;
ALTER ROLE app SET search_path = public, pg_catalog;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'api';
SQL
errs=$(for _ in $(seq 15); do curl -s -o /dev/null -m 5 -w '%{http_code}\n' "$url" || true; done | grep -c '^500$' || true)
docker exec -i "$pg" psql -U postgres -v ON_ERROR_STOP=1 -q >/dev/null <<'SQL'
DROP FUNCTION public.now();
ALTER ROLE app RESET search_path;
SQL
oks=$(for _ in $(seq 10); do curl -s -m 5 "$url" || true; echo; done | grep -c '"ok":true' || true)
why=ok
[ "$errs" = 15 ] && [ "$oks" = 10 ] || why="500s=$errs/15 then ok=$oks/10"
judge "$why"
printf '%-40s %s\n' "15 query errors, then fault removed" "500s=$errs/15, then ok=$oks/10  $v"

# SIGTERM with a request in flight (held on a hung Postgres): the app must
# finish it and exit 0 well inside Docker's 10s stop timeout.
api=$(svc api)
docker pause "$pg" >/dev/null
curl -s -o /dev/null -m 15 -w '%{http_code}' "$url" >"$work/inflight" &
inflight=$!
sleep 0.5
t0=$(now_ms)
docker stop "$api" >/dev/null
stop_ms=$(($(now_ms) - t0))
wait "$inflight" || true
docker unpause "$pg" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$api")
docker start "$api" >/dev/null
why=ok
[ "$code" = 0 ] && [ "$(cat "$work/inflight")" = 500 ] && ((stop_ms < 9000)) || why="unclean"
judge "$why"
printf '%-40s %s\n' "SIGTERM with a request in flight" \
  "stop ${stop_ms}ms exit=$code in-flight=$(cat "$work/inflight")  $v"
wait_healthy

exit "$failed"
