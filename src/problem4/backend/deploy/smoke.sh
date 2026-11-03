#!/usr/bin/env bash
# Post-deploy smoke test through the load balancer.
#
# Passes only if SMOKE_REQUESTS consecutive requests to /api/version all report
# the expected release. Each curl opens a new connection, so the ALB spreads
# them across targets; with 20 requests the chance of never reaching one of
# three instances is about 0.1%. A mixed or stale fleet therefore fails.
#
# Usage: smoke.sh <base-url> <expected-release>
set -euo pipefail

base="${1:?usage: smoke.sh <base-url> <expected-release>}"
base="${base%/}"
want="${2:?usage: smoke.sh <base-url> <expected-release>}"
requests="${SMOKE_REQUESTS:-20}"

for ((i = 1; i <= requests; i++)); do
  if ! body="$(curl --fail --silent --show-error --max-time 5 \
    --retry 3 --retry-all-errors --retry-delay 2 \
    "${base}/api/version")"; then
    echo "::error::request ${i}/${requests} to ${base}/api/version failed" >&2
    exit 1
  fi
  got="$(jq -r '.release // empty' <<<"$body" 2>/dev/null || true)"
  if [[ "$got" != "$want" ]]; then
    echo "::error::request ${i}/${requests} served release '${got:-<unparseable>}', want '${want}'" >&2
    exit 1
  fi
done
echo "smoke: ${requests}/${requests} requests served release ${want}" >&2
