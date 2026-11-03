#!/usr/bin/env bash
# CI gate (~30s): end to end through nginx, plus behaviour under the events behind
# the original outages. Runs in its own throwaway Compose project on an
# ephemeral host port and removes only what it created.
#   ./smoke-test.sh        optional: TEST_PROJECT=<new name> HOST_PORT=<port>
set -euo pipefail
cd "$(dirname "$0")"

project=${TEST_PROJECT:-p3-smoke-$$-$RANDOM}
export HOST_PORT=${HOST_PORT:-0}   # exported, so it also overrides any .env value
RECOVERY_S=30                      # per check, counted from the end of the fault
STREAK=10                          # consecutive successes that count as recovered

dc() { docker compose -p "$project" "$@"; }
ip_of() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(dc ps -q "$1")"; }

if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$project")$(docker volume ls -q --filter "label=com.docker.compose.project=$project")" ]; then
  echo "refusing to run: compose project '$project' already exists" >&2
  exit 2
fi
cleanup() {
  docker rm -f "$project-ipholder" >/dev/null 2>&1 || true
  dc down -v --remove-orphans --rmi local >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1"
  dc ps -a
  dc logs --tail 30
  exit 1
}

expect_ok() {
  local deadline=$((SECONDS + RECOVERY_S)) streak=0 left body
  while ((streak < STREAK)); do
    left=$((deadline - SECONDS))
    ((left > 0)) || fail "$1 (no sustained recovery within ${RECOVERY_S}s)"
    body=$(curl -fsS -m "$((left < 2 ? left : 2))" "$url" 2>/dev/null) || body=""
    if [[ $body == *'"ok":true'* ]]; then streak=$((streak + 1)); else streak=0; fi
    sleep 0.2
  done
  echo "PASS: $1"
}

dc config -q
dc up -d --build --wait --wait-timeout 120 || fail "stack did not become healthy"
url="http://127.0.0.1:$(dc port nginx 80 | sed 's/.*://')/api/users"
expect_ok "GET /api/users through nginx"

api=$(dc ps -q api)
dc restart postgres
expect_ok "recovers after postgres restart"
# The restart policy would hide a crash; the api must survive, not be restarted.
[ "$(docker inspect -f '{{.RestartCount}}' "$api")" = 0 ] || fail "api process crashed on postgres restart"

# Redis only holds telemetry: with it down the api keeps serving and reports degraded.
dc stop redis
expect_ok "serves /api/users with redis down"
[[ $(dc exec -T nginx curl -s -m 5 http://api:3000/ready) == *'"redis":"degraded"'* ]] ||
  fail "/ready does not report redis as degraded"
dc start redis
expect_ok "still serving after redis returns"

# Recreate the api on a new IP. Holding the freed address stops Docker from
# reusing it, which would hide a proxy that cached the old one.
old_ip=$(ip_of api)
dc rm -sf api >/dev/null
docker run -d --rm --name "$project-ipholder" --network "${project}_default" \
  --entrypoint sleep "${project}-api" 300 >/dev/null
dc up -d --no-deps api
new_ip=$(ip_of api)
[ "$new_ip" != "$old_ip" ] || fail "could not move the api to a new IP (still $old_ip)"
expect_ok "nginx follows the api to a new IP ($old_ip -> $new_ip)"
