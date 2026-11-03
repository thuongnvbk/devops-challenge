#!/usr/bin/env bash
# Exercises rollout.sh's refresh state machine without AWS: a fake `aws` on
# PATH plays the Auto Scaling side, and the real API binary answers the smoke
# test. The rollback branches never run in a healthy deploy, so this is the
# only place they are proven before an incident needs them.
#
# Usage: rollout_test.sh   (needs go, jq, curl)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

live=1111111111111111111111111111111111111111 # release the "fleet" serves
other=2222222222222222222222222222222222222222

# --- the API, serving $live ----------------------------------------------------
(cd "$here/.." && go build -o "$work/api" -ldflags "-X main.release=${live}" .)
port=$((20000 + RANDOM % 20000))
API_ADDR="127.0.0.1:${port}" "$work/api" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 50); do
  if curl -fs "http://127.0.0.1:${port}/healthz" >/dev/null; then break; fi
  sleep 0.1
done

# --- fake aws ---------------------------------------------------------------------
# State lives in $FAKE_DIR: asg_version, ud.<n> (user data), desc.<n>
# (version description), statuses (refresh status sequence; the last line
# repeats), active (the group's active refresh as JSON [id, status], or
# absent), cancelled (ids cancelled so far), s3object (the single release
# object), and flag files that inject failures.
mkdir -p "$work/bin"
cat >"$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
d="${FAKE_DIR:?}"
echo "$*" >>"$d/calls"
args=" $* "
flag() { [[ -e "$d/$1" ]]; }
opt() { local v="${args#* "$1" }"; echo "${v%% *}"; }
case "$1 $2" in
  "autoscaling describe-auto-scaling-groups") printf 'lt-0fake\t%s\n' "$(cat "$d/asg_version")" ;;
  "ec2 describe-launch-template-versions")
    if flag describe_lt_fails; then echo "An error occurred (RequestLimitExceeded)" >&2; exit 254; fi
    if [[ "$args" == *" --versions "* ]]; then
      v="$(opt --versions)"
      if [[ -f "$d/ud.$v" ]]; then base64 -w0 "$d/ud.$v"; echo; else echo None; fi
    else
      # find: max(VersionNumber) for a description. The real CLI evaluates
      # --query per page with text output, so a match on page 2 prints
      # "None" then the number; JSON output is evaluated on the merged result.
      want="${args#*VersionDescription==\'}"
      want="${want%%\'*}"
      found=""
      for f in "$d"/desc.*; do
        if [[ -f "$f" && "$(cat "$f")" == "$want" ]]; then found="${f##*.}"; fi
      done
      if [[ "$args" == *"--output text"* ]]; then printf 'None\n%s\n' "${found:-None}"; else echo "${found:-null}"; fi
    fi
    ;;
  "ec2 create-launch-template-version")
    n=$(($(cat "$d/asg_version") + 2))
    opt --launch-template-data | jq -r .UserData | base64 -d >"$d/ud.$n"
    opt --version-description >"$d/desc.$n"
    echo "$n"
    ;;
  "s3api put-object")
    if [[ -e "$d/s3object" ]]; then
      echo "An error occurred (PreconditionFailed) when calling the PutObject operation" >&2
      exit 254
    fi
    cp "$(opt --body)" "$d/s3object"
    ;;
  "s3api head-object")
    if [[ -e "$d/s3object" ]]; then openssl dgst -sha256 -binary "$d/s3object" | base64; else cat "$d/checksum"; fi
    ;;
  "autoscaling start-instance-refresh")
    if flag start_refused; then echo "An error occurred (ValidationError): alarm is in ALARM state" >&2; exit 254; fi
    if [[ -s "$d/active" ]]; then echo "An error occurred (InstanceRefreshInProgress)" >&2; exit 254; fi
    n=$(($(cat "$d/next_id" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$d/next_id"
    id="refresh-$n"
    if flag accept_then_die && [[ "$args" == *'"AutoRollback":false'* ]]; then
      # AWS accepted the recovery, then the job was killed before the id
      # came back: the caller never learns it.
      printf '["%s","InProgress"]\n' "$id" >"$d/active"
      exit 143
    fi
    echo "$id"
    ;;
  "autoscaling cancel-instance-refresh")
    if [[ ! -s "$d/active" ]]; then echo "An error occurred (ActiveInstanceRefreshNotFound)" >&2; exit 254; fi
    jq -r '.[0]' "$d/active" >>"$d/cancelled"
    rm "$d/active"
    ;;
  "autoscaling describe-instance-refreshes")
    if [[ "$args" != *" --instance-refresh-ids "* ]]; then # active-refresh lookup
      if [[ -s "$d/active" ]]; then cat "$d/active"; else echo null; fi
      exit 0
    fi
    if grep -qx "$(opt --instance-refresh-ids)" "$d/cancelled" 2>/dev/null; then
      line="$(printf 'Cancelled\t50\tcancelled')"
    else
      if flag describe_fails_once; then
        rm "$d/describe_fails_once"
        echo "An error occurred (Throttling): Rate exceeded" >&2
        exit 254
      fi
      line="$(head -n1 "$d/statuses")"
      if (($(wc -l <"$d/statuses") > 1)); then sed -i 1d "$d/statuses"; fi
    fi
    # Honour the two queries the script uses: Status only, or the triple.
    if [[ "$(opt --query)" == 'InstanceRefreshes[0].Status' ]]; then echo "${line%%$'\t'*}"; else echo "$line"; fi
    ;;
  "autoscaling rollback-instance-refresh")
    if flag rollback_rejected; then
      echo "An error occurred (ActiveInstanceRefreshNotFound)" >&2
      exit 254
    fi
    printf 'RollbackInProgress\t50\tmanual\nRollbackSuccessful\t100\tmanual\n' >"$d/statuses"
    ;;
  *)
    echo "fake aws: unexpected call: $*" >&2
    exit 64
    ;;
esac
FAKE
chmod +x "$work/bin/aws"

sha="$(printf 'artifact' | sha256sum | cut -d' ' -f1)"
third=3333333333333333333333333333333333333333

# Run `rollout.sh refresh [REFRESH_ARGS] 8` with version 7 live.
# Args: name, release pinned by version 8, expected exit code, statuses
# (one "Status<TAB>pct<TAB>reason" per line). Env knobs: FLAGS, ALARMS,
# TIMEOUT, PREV (release pinned by version 7), REFRESH_ARGS.
pass=0
run_refresh() { # run_refresh <dir> <refresh args...>
  local d="$1"
  shift
  FAKE_DIR="$d" PATH="$work/bin:$PATH" \
    AWS_REGION=eu-west-1 ASG_NAME=api LAUNCH_TEMPLATE_ID=lt-0fake \
    API_BASE_URL="http://127.0.0.1:${port}" ROLLBACK_ALARM_NAMES="${ALARMS-api-5xx,api-unhealthy}" \
    POLL_SECONDS=0.02 TIMEOUT_SECONDS="${TIMEOUT-3}" SMOKE_REQUESTS=3 REFRESH_STATE_FILE="$d/state" \
    "$here/rollout.sh" refresh "$@"
}
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ud() { printf 'RELEASE=%s\nRELEASE_URI=s3://bucket/backend/%s/api.tar.gz\nRELEASE_SHA256=%s\n' "$1" "$1" "$sha"; }
scenario() {
  local name="$1" target_release="$2" want_rc="$3" statuses="$4" rc=0
  local d="$work/$name"
  mkdir -p "$d"
  for flag in ${FLAGS-}; do touch "$d/$flag"; done
  echo 7 >"$d/asg_version"
  ud "${PREV-$live}" >"$d/ud.7"
  ud "$target_release" >"$d/ud.8"
  printf 'artifact' | openssl dgst -sha256 -binary | base64 >"$d/checksum"
  printf '%b' "$statuses" >"$d/statuses"

  if [[ -n "${ACTIVE-}" ]]; then echo "$ACTIVE" >"$d/active"; fi

  # shellcheck disable=SC2086 # REFRESH_ARGS is intentionally word-split
  run_refresh "$d" ${REFRESH_ARGS-} 8 >"$d/out" 2>&1 || rc=$?

  if [[ "$rc" != "$want_rc" ]]; then
    echo "FAIL $name: exit $rc, want $want_rc" >&2
    cat "$d/out" "$d/calls" >&2
    exit 1
  fi
  echo "ok   $name (exit $rc)"
  pass=$((pass + 1))
}
called() { grep -q -- "$2" "$work/$1/calls"; }
starts() { grep -c start-instance-refresh "$work/$1/calls" || true; }
# nth start-instance-refresh call of a scenario
start_call() { grep start-instance-refresh "$work/$1/calls" | sed -n "${2}p"; }
is_recovery() {
  local c
  c="$(start_call "$1" "$2")"
  [[ "$c" == *'"AutoRollback":false'* && "$c" != *AlarmSpecification* && "$c" == *"\"Version\":\"$3\""* ]] ||
    fail "$1: start #$2 is not a recovery refresh to version $3: $c"
}
is_guarded() {
  local c
  c="$(start_call "$1" "$2")"
  [[ "$c" == *'"AutoRollback":true'* && "$c" == *AlarmSpecification* && "$c" == *'"MinHealthyPercentage":100'* ]] ||
    fail "$1: start #$2 is not a guarded refresh: $c"
}

# --- guarded rollouts ------------------------------------------------------------
scenario healthy "$live" 0 'InProgress\t0\t\nInProgress\t50\t\nBaking\t100\t\nSuccessful\t100\t\n'
is_guarded healthy 1
! called healthy rollback-instance-refresh || fail "healthy: rolled back a good release"

scenario smoke-fails-during-bake "$other" 1 'InProgress\t50\t\nBaking\t100\t\n'
called smoke-fails-during-bake rollback-instance-refresh || fail "bad release not rolled back"

scenario alarm-auto-rollback "$live" 1 'InProgress\t50\t\nRollbackInProgress\t50\talarm\nRollbackSuccessful\t100\talarm\n'

# AWS reports RollbackSuccessful, but the restored release does not serve.
PREV="$third" scenario rolled-back-but-previous-broken "$live" 2 'InProgress\t50\t\nRollbackSuccessful\t100\talarm\n'

TIMEOUT=1 scenario timeout-rolls-back "$live" 1 'InProgress\t10\twaiting for health checks\n'
called timeout-rolls-back rollback-instance-refresh || fail "stuck refresh not rolled back"

# Bake window missed: AWS can no longer roll back, so a recovery refresh puts
# the fleet back on version 7.
scenario smoke-fails-after-success "$other" 1 'InProgress\t50\t\nSuccessful\t100\t\n'
[[ "$(starts smoke-fails-after-success)" == 2 ]] || fail "no restore after post-success smoke failure"
is_recovery smoke-fails-after-success 2 7

# Failed/Cancelled are not a rollback: replaced instances may still run the
# candidate. Both must restore version 7.
scenario cancelled-midway-restores "$live" 1 'InProgress\t50\t\nCancelled\t50\tcancelled by user\nSuccessful\t100\t\n'
is_recovery cancelled-midway-restores 2 7
scenario failed-without-rollback-restores "$live" 1 'InProgress\t50\t\nFailed\t50\tlaunch failures\nSuccessful\t100\t\n'
is_recovery failed-without-rollback-restores 2 7

FLAGS=describe_fails_once scenario transient-describe-error "$live" 0 'InProgress\t50\t\nBaking\t100\t\nSuccessful\t100\t\n'

# Smoke fails while baking but AWS rejects the rollback request: the release
# must not be reported live; the previous version is restored instead.
FLAGS=rollback_rejected scenario rollback-rejected-during-bake "$other" 1 'Baking\t100\t\nSuccessful\t100\t\n'
is_recovery rollback-rejected-during-bake 2 7

# The restore itself does not come back healthy: escalate, don't loop.
PREV="$third" scenario restore-fails-needs-human "$other" 2 'InProgress\t50\t\nSuccessful\t100\t\n'

scenario rollback-failed "$live" 2 'InProgress\t50\t\nRollbackFailed\t50\tlaunch failure\n'

ALARMS="" scenario no-alarms-refuses "$live" 1 'Successful\t100\t\n'
[[ "$(starts no-alarms-refuses)" == 0 ]] || fail "guarded refresh started without alarms"

# A firing alarm makes AWS refuse a guarded refresh: nothing changes (exit 1).
FLAGS=start_refused scenario guarded-start-refused "$live" 1 'Successful\t100\t\n'

# --- recovery (manual rollback / restore) -----------------------------------------
# No alarm gate (they may be firing: that is why we are recovering), no auto
# rollback (it would return to the broken release); smoke still decides.
REFRESH_ARGS=--recovery ALARMS="" scenario recovery-ignores-alarms "$live" 0 'InProgress\t50\t\nSuccessful\t100\t\n'
is_recovery recovery-ignores-alarms 1 8
REFRESH_ARGS=--recovery scenario recovery-smoke-fails "$other" 2 'InProgress\t50\t\nSuccessful\t100\t\n'
! called recovery-smoke-fails rollback-instance-refresh || fail "recovery was rolled back to the broken release"
REFRESH_ARGS=--recovery TIMEOUT=1 scenario recovery-timeout-escalates "$live" 2 'InProgress\t10\twaiting\n'
! called recovery-timeout-escalates rollback-instance-refresh || fail "recovery timeout rolled back"
REFRESH_ARGS=--recovery FLAGS=start_refused scenario recovery-start-refused "$live" 2 'Successful\t100\t\n'

# Takeover: a recovery timed out and was left running in AWS; the manual
# rollback must cancel it (never roll it back) and then start its own.
d="$work/recovery-timeout-escalates"
printf '["refresh-1","InProgress"]\n' >"$d/active"
printf 'InProgress\t50\t\nSuccessful\t100\t\n' >"$d/statuses"
: >"$d/calls"
rc=0
REFRESH_ARGS=--recovery run_refresh "$d" --recovery 8 >"$d/out2" 2>&1 || rc=$?
[[ "$rc" == 0 ]] || { cat "$d/out2" "$d/calls" >&2; fail "manual rollback did not take over the stalled recovery (exit $rc)"; }
cancel_at="$(grep -n cancel-instance-refresh "$d/calls" | head -n1 | cut -d: -f1)"
start_at="$(grep -n start-instance-refresh "$d/calls" | head -n1 | cut -d: -f1)"
if [[ -z "$cancel_at" || -z "$start_at" ]] || ((cancel_at > start_at)); then
  fail "takeover: stalled refresh not cancelled before the new recovery started"
fi
! called recovery-timeout-escalates rollback-instance-refresh || fail "takeover rolled back a recovery"
is_recovery recovery-timeout-escalates 1 8
echo "ok   recovery timed out -> manual rollback cancels it and takes over"
pass=$((pass + 1))

# Cancellation race: AWS accepts the restore, then the job is killed before
# the id is recorded. The state file must say "pending recovery" (not the
# earlier guarded id), and on-cancel must leave the restore alone.
FLAGS=accept_then_die scenario cancel-before-id-recorded "$live" 2 'InProgress\t50\t\nFailed\t50\tlaunch failures\n'
[[ "$(cat "$work/cancel-before-id-recorded/state")" == "pending recovery" ]] ||
  fail "state file does not record the in-flight recovery: $(cat "$work/cancel-before-id-recorded/state")"
FAKE_DIR="$work/cancel-before-id-recorded" PATH="$work/bin:$PATH" AWS_REGION=eu-west-1 ASG_NAME=api \
  LAUNCH_TEMPLATE_ID=lt-0fake REFRESH_STATE_FILE="$work/cancel-before-id-recorded/state" \
  "$here/rollout.sh" on-cancel 2>/dev/null
! called cancel-before-id-recorded rollback-instance-refresh || fail "on-cancel rolled back the accepted recovery"
echo "ok   cancel between AWS acceptance and id record leaves the recovery running"

echo "$pass refresh scenarios passed"

# --- other subcommands --------------------------------------------------------------
sub() { # sub <dir> <args...>: run rollout.sh against fake state in <dir>
  local d="$1"
  shift
  FAKE_DIR="$d" PATH="$work/bin:$PATH" AWS_REGION=eu-west-1 ASG_NAME=api \
    LAUNCH_TEMPLATE_ID=lt-0fake RELEASE_BUCKET=bucket "$here/rollout.sh" "$@"
}

# `current` feeds the forward-only guard: empty for a template with no user
# data (before the first release), the release otherwise, and an API error
# must fail rather than read as "nothing deployed".
d="$work/current"
mkdir -p "$d"
echo 7 >"$d/asg_version"
[[ "$(sub "$d" current)" == "" ]] || fail "current: expected empty release for a bare launch template"
ud "$live" >"$d/ud.7"
[[ "$(sub "$d" current)" == "$live" ]] || fail "current: did not read the deployed release"
touch "$d/describe_lt_fails"
if out="$(sub "$d" current 2>/dev/null)"; then fail "current: API error read as release '$out'"; fi
echo "ok   current (bare template, released template, API error)"

# publish: write-once artifact + launch template version pinning its digest;
# a re-run reuses both; other bytes under the same release are refused.
d="$work/publish"
mkdir -p "$d"
echo 7 >"$d/asg_version"
ud "$live" >"$d/ud.7"
printf 'artifact' >"$work/api.tar.gz"
v="$(sub "$d" publish "$work/api.tar.gz" "$other" 2>/dev/null)"
[[ "$v" == 9 ]] || fail "publish: expected new version 9, got '$v'"
# shellcheck disable=SC2016 # the last entry is literal bootstrap.sh source
for want in "RELEASE=$other" "RELEASE_SHA256=$sha" 'echo "${RELEASE_SHA256}  ${bundle}" | sha256sum --check --strict --status'; do
  grep -qxF -- "$want" "$d/ud.9" || fail "publish: user data lacks: $want"
done
[[ "$(sub "$d" publish "$work/api.tar.gz" "$other" 2>/dev/null)" == 9 ]] || fail "publish: re-run did not reuse version 9"
[[ "$(grep -c create-launch-template-version "$d/calls")" == 1 ]] || fail "publish: re-run created another version"
printf 'other bytes' >"$work/api-other.tar.gz"
if sub "$d" publish "$work/api-other.tar.gz" "$other" >/dev/null 2>&1; then fail "publish: accepted different bytes for a published release"; fi
echo "ok   publish (create, idempotent re-run, immutable)"

# find must survive pagination (see fake): JSON output, single number.
[[ "$(sub "$d" find "$other" 2>/dev/null)" == 9 ]] || fail "find: lost a match beyond the first page"
if sub "$d" find "$third" >/dev/null 2>&1; then fail "find: invented a version for an unpublished release"; fi
echo "ok   find (paginated result, unknown release)"

# on-cancel: roll back the guarded refresh this job started only while it is
# the active one; never a recovery or an unconfirmed request.
d="$work/cancel"
mkdir -p "$d"
on_cancel() { # on_cancel <state> <active-json|"">: did on-cancel request a rollback?
  echo "$1" >"$d/state"
  if [[ -n "$2" ]]; then echo "$2" >"$d/active"; else rm -f "$d/active"; fi
  : >"$d/calls"
  REFRESH_STATE_FILE="$d/state" sub "$d" on-cancel 2>/dev/null
  called cancel rollback-instance-refresh
}
on_cancel "refresh-1 guarded" '["refresh-1","InProgress"]' || fail "on-cancel: active guarded refresh not rolled back"
! on_cancel "refresh-1 guarded" '["refresh-2","InProgress"]' || fail "on-cancel: rolled back a different (newer) refresh"
! on_cancel "refresh-1 guarded" "" || fail "on-cancel: rollback requested with no active refresh"
! on_cancel "refresh-2 recovery" '["refresh-2","InProgress"]' || fail "on-cancel: rolled back a recovery refresh"
! on_cancel "pending guarded" '["refresh-3","InProgress"]' || fail "on-cancel: acted on an unconfirmed request"
echo "ok   on-cancel (active guarded rolled back; stale, recovery, pending left alone)"
