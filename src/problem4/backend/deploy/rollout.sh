#!/usr/bin/env bash
# Backend rollout for one environment: immutable instances behind an ALB,
# replaced by an EC2 Auto Scaling instance refresh.
#
# A release is a numbered launch template version whose user data pins one
# artifact by S3 key and sha256 (see bootstrap.sh). Deploying is moving the
# ASG to that version; rolling back is moving it to an older one. Both go
# through `refresh`, so the rollback path is exercised on every deploy.
#
# Subcommands (values on stdout, logs on stderr):
#   current                     release the ASG is pinned to ("" if none)
#   publish <artifact> <sha>    upload artifact write-once, create or reuse its
#                               launch template version; prints the version
#   find <sha>                  launch template version previously published
#                               for <sha>; fails if there is none
#   refresh <version>           guarded rollout of a new release: alarms, auto
#                               rollback, bake + smoke test; on any failure the
#                               fleet is put back on the version it ran before
#   refresh --recovery <version>
#                               restore a previously verified release, e.g. in
#                               an incident: no alarm gate (a firing alarm must
#                               not block recovery) and no auto rollback (it
#                               would return to the broken release); health
#                               checks, timeout and smoke test still apply. A
#                               refresh still active (e.g. a stalled recovery)
#                               is cancelled first, never rolled back
#   on-cancel                   called when the job is cancelled: rolls back
#                               the guarded refresh this job started if it is
#                               still the active one; never touches a recovery
#                               or a refresh whose id was not yet recorded
#
# Exit codes: 0 target live and verified; 1 target not kept, previous release
# live and verified; 2 fleet state needs a human.
#
# Env: AWS_REGION ASG_NAME LAUNCH_TEMPLATE_ID, plus
#   publish: RELEASE_BUCKET
#   refresh: API_BASE_URL; ROLLBACK_ALARM_NAMES (comma-separated, >=1, guarded
#            only); BAKE_SECONDS (300) TIMEOUT_SECONDS (1200) POLL_SECONDS (15)
#   refresh, on-cancel: REFRESH_STATE_FILE (optional; "<refresh-id> <mode>",
#            or "pending <mode>" while a start request is in flight)
set -euo pipefail
# Bash clears -e inside $(...) unless told otherwise; without this a failing
# AWS call inside a helper would just return an empty string.
shopt -s inherit_errexit

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sha_re='^[0-9a-f]{40}$'

log() { echo "rollout: $*" >&2; }
warn() { echo "::warning::$*" >&2; }
die() {
  echo "::error::$*" >&2
  exit 1
}

: "${AWS_REGION:?}" "${ASG_NAME:?}" "${LAUNCH_TEMPLATE_ID:?}"
export AWS_REGION AWS_PAGER=""

# --- launch template / ASG helpers -------------------------------------------

# S3 reports additional checksums base64-encoded; compare in hex.
b64_to_hex() { base64 -d | od -An -v -tx1 | tr -d ' \n'; }

asg_version() {
  local lt_id version
  read -r lt_id version < <(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].LaunchTemplate.[LaunchTemplateId,Version]' --output text)
  [[ "$lt_id" == "$LAUNCH_TEMPLATE_ID" ]] ||
    die "ASG $ASG_NAME uses launch template '$lt_id', expected $LAUNCH_TEMPLATE_ID"
  # Rollback (manual or automatic) is only available from a numbered version.
  [[ "$version" =~ ^[0-9]+$ ]] ||
    die "ASG $ASG_NAME must pin a numbered launch template version, not '$version'"
  echo "$version"
}

# Print the value of a header variable from a launch template version's user data.
# Prints nothing if the version has no user data (e.g. the infra stack's
# initial version, before the first release).
user_data_var() {
  local version="$1" name="$2" encoded decoded
  # An API error must not read as "no release": `current` feeds the
  # forward-only guard, which would then wave any deploy through.
  encoded="$(aws ec2 describe-launch-template-versions \
    --launch-template-id "$LAUNCH_TEMPLATE_ID" --versions "$version" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' --output text)" ||
    die "could not read launch template version $version"
  [[ -n "$encoded" && "$encoded" != None ]] || return 0
  decoded="$(base64 -d <<<"$encoded")"
  sed -n "/^${name}=/{s///p;q}" <<<"$decoded"
}

# Refuse to roll onto a version whose artifact is missing or has changed:
# instances would boot, fail the checksum, and never become healthy.
verify_artifact() {
  local version="$1" uri sha bucket key stored
  uri="$(user_data_var "$version" RELEASE_URI)"
  sha="$(user_data_var "$version" RELEASE_SHA256)"
  [[ "$uri" =~ ^s3://([^/]+)/(.+)$ ]] || die "launch template version $version has no RELEASE_URI"
  bucket="${BASH_REMATCH[1]}" key="${BASH_REMATCH[2]}"
  stored="$(aws s3api head-object --bucket "$bucket" --key "$key" --checksum-mode ENABLED \
    --query ChecksumSHA256 --output text)" || die "artifact $uri is missing"
  [[ "$(b64_to_hex <<<"$stored")" == "$sha" ]] ||
    die "artifact $uri does not match the sha256 pinned in launch template version $version"
}

# --- subcommands --------------------------------------------------------------

cmd_current() {
  local release
  release="$(user_data_var "$(asg_version)" RELEASE)"
  [[ -z "$release" || "$release" =~ $sha_re ]] || die "unrecognised release in user data: $release"
  echo "$release"
}

cmd_find() {
  local release="${1:?find <sha>}" version
  [[ "$release" =~ $sha_re ]] || die "not a commit SHA: $release"
  version="$(aws ec2 describe-launch-template-versions --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --query "max(LaunchTemplateVersions[?VersionDescription=='${release}'].VersionNumber)" --output json)" ||
    die "could not list launch template versions"
  # JSON, not text: with text output the CLI evaluates --query once per page,
  # so a match beyond the first page would come back as "None<newline>N".
  [[ "$version" =~ ^[0-9]+$ ]] || die "release $release was never published to this environment"
  echo "$version"
}

cmd_publish() {
  local artifact="${1:?publish <artifact> <sha>}" release="${2:?publish <artifact> <sha>}"
  : "${RELEASE_BUCKET:?}"
  [[ "$release" =~ $sha_re ]] || die "not a commit SHA: $release"
  [[ -f "$artifact" ]] || die "no such artifact: $artifact"

  local sha key uri
  sha="$(sha256sum "$artifact" | cut -d' ' -f1)"
  key="backend/${release}/api.tar.gz"
  uri="s3://${RELEASE_BUCKET}/${key}"

  # 1. Artifact, write-once: a release key can never be repointed at other bytes.
  "$here/../../ci/s3-put-once.sh" "$RELEASE_BUCKET" "$key" "$artifact"

  # 2. Launch template version. Reuse one from an earlier attempt at this
  #    release so re-runs are idempotent.
  local version
  if version="$(cmd_find "$release" 2>/dev/null)"; then
    [[ "$(user_data_var "$version" RELEASE_SHA256)" == "$sha" ]] ||
      die "launch template version $version for $release pins a different artifact"
    log "reusing launch template version $version"
    echo "$version"
    return
  fi

  # New version derived from what the fleet runs now, so AMI, instance type,
  # security groups and instance profile carry over; only user data changes.
  local base userdata
  base="$(asg_version)"
  userdata="$(mktemp)"
  {
    echo '#!/bin/bash'
    printf 'RELEASE=%q\nRELEASE_URI=%q\nRELEASE_SHA256=%q\nAWS_REGION=%q\n' \
      "$release" "$uri" "$sha" "$AWS_REGION"
    sed '1{/^#!/d}' "$here/bootstrap.sh"
  } >"$userdata"
  version="$(aws ec2 create-launch-template-version --launch-template-id "$LAUNCH_TEMPLATE_ID" \
    --source-version "$base" --version-description "$release" \
    --launch-template-data "$(jq -cn --arg ud "$(base64 -w0 "$userdata")" '{UserData: $ud}')" \
    --query LaunchTemplateVersion.VersionNumber --output text)"
  rm -f "$userdata"
  log "created launch template version $version (from $base) for $release"
  echo "$version"
}

# Print the active refresh, if any, as "<id> <status>". At most one refresh
# can be active per group, so no ordering assumption is needed.
active_refresh() {
  local found
  found="$(aws autoscaling describe-instance-refreshes --auto-scaling-group-name "$ASG_NAME" \
    --query "InstanceRefreshes[?Status=='Pending' || Status=='InProgress' || Status=='Baking' || Status=='Cancelling' || Status=='RollbackInProgress'] | [0].[InstanceRefreshId, Status]" \
    --output json)" || die "could not list instance refreshes"
  jq -r 'if . == null then "" else join(" ") end' <<<"$found"
}

# Recovery must be able to start even if an earlier refresh is still running
# (typically a recovery that timed out and was left to AWS). Cancel it and
# wait until it has stopped. Cancel keeps whatever it already replaced;
# rollback-instance-refresh is never used here, because rolling back a
# recovery would bring the broken release back.
take_over() {
  local active id status deadline=$((SECONDS + ${TIMEOUT_SECONDS:-1200}))
  active="$(active_refresh)"
  [[ -n "$active" ]] || return 0
  read -r id status <<<"$active"
  warn "refresh $id is still $status; cancelling it so this recovery can start"
  if [[ "$status" != Cancelling ]]; then
    aws autoscaling cancel-instance-refresh --auto-scaling-group-name "$ASG_NAME" >/dev/null ||
      die "could not cancel refresh $id"
  fi
  while true; do
    status="$(aws autoscaling describe-instance-refreshes --auto-scaling-group-name "$ASG_NAME" \
      --instance-refresh-ids "$id" --query 'InstanceRefreshes[0].Status' --output text)" || status=Unknown
    read -r status _ <<<"$status" || true
    case "$status" in
      Cancelled | Successful | Failed | RollbackSuccessful | RollbackFailed)
        log "refresh $id stopped ($status)"
        return 0
        ;;
    esac
    ((SECONDS <= deadline)) || die "refresh $id did not stop within ${TIMEOUT_SECONDS:-1200}s"
    sleep "${POLL_SECONDS:-15}"
  done
}

# start_refresh <version> <guarded|recovery>; prints the refresh id.
start_refresh() {
  local version="$1" mode="$2" alarms prefs desired id
  # Record intent before asking AWS: if the job is cancelled after AWS has
  # accepted the request but before the id is written, on-cancel must not
  # act on a stale record (it would roll back the wrong refresh).
  if [[ -n "${REFRESH_STATE_FILE:-}" ]]; then echo "pending $mode" >"$REFRESH_STATE_FILE"; fi
  if [[ "$mode" == recovery ]]; then take_over; fi
  # Launch-before-terminate (min 100 / max 200): capacity never drops and the
  # old instances keep serving until replacements pass ELB health checks.
  if [[ "$mode" == guarded ]]; then
    alarms="$(jq -cn --arg a "${ROLLBACK_ALARM_NAMES:-}" \
      '$a | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"
    [[ "$(jq length <<<"$alarms")" -ge 1 ]] ||
      die "ROLLBACK_ALARM_NAMES must name at least one CloudWatch alarm"
    # BakeTime keeps the refresh open after the last replacement so the
    # alarms and our smoke test can still trigger an automatic rollback.
    # AWS refuses to start while any alarm is in ALARM/INSUFFICIENT_DATA,
    # which is the right answer for a new release; recovery skips it.
    prefs="$(jq -cn --argjson alarms "$alarms" --argjson bake "${BAKE_SECONDS:-300}" '{
      MinHealthyPercentage: 100, MaxHealthyPercentage: 200, SkipMatching: true,
      AutoRollback: true, AlarmSpecification: {Alarms: $alarms}, BakeTime: $bake,
      ScaleInProtectedInstances: "Refresh", StandbyInstances: "Ignore"}')"
  else
    prefs="$(jq -cn '{
      MinHealthyPercentage: 100, MaxHealthyPercentage: 200, SkipMatching: true,
      AutoRollback: false, BakeTime: 0,
      ScaleInProtectedInstances: "Refresh", StandbyInstances: "Ignore"}')"
  fi
  desired="$(jq -cn --arg id "$LAUNCH_TEMPLATE_ID" --arg v "$version" \
    '{LaunchTemplate: {LaunchTemplateId: $id, Version: $v}}')"

  id="$(aws autoscaling start-instance-refresh --auto-scaling-group-name "$ASG_NAME" \
    --strategy Rolling --desired-configuration "$desired" --preferences "$prefs" \
    --query InstanceRefreshId --output text)" || die "could not start a $mode instance refresh"
  [[ -n "$id" && "$id" != None ]] || die "start-instance-refresh returned no id"
  if [[ -n "${REFRESH_STATE_FILE:-}" ]]; then echo "$id $mode" >"$REFRESH_STATE_FILE"; fi
  echo "$id"
}

# wait_refresh <id> <expected-release|""> <guarded|recovery>. Returns:
#   0  succeeded and the smoke test passed
#   1  AWS rolled the fleet back to its previous configuration
#   2  needs a human: a rollback or recovery failed or never finished
#   3  guarded only: the fleet may be on the new release or mixed (smoke
#      failed after success, rollback rejected, or the refresh ended Failed
#      or Cancelled); the caller must restore the previous version
#
# Callers invoke this in a `||` context, where bash disables `set -e`, so
# every failure that matters is handled explicitly below.
wait_refresh() {
  local id="$1" want="$2" mode="$3" smoke=pending rolling_back=false
  local line status pct reason deadline=$((SECONDS + ${TIMEOUT_SECONDS:-1200}))
  smoke_test() { [[ -z "$want" ]] || "$here/smoke.sh" "$API_BASE_URL" "$want"; }
  while true; do
    if ! line="$(aws autoscaling describe-instance-refreshes \
      --auto-scaling-group-name "$ASG_NAME" --instance-refresh-ids "$id" \
      --query 'InstanceRefreshes[0].[Status,PercentageComplete,StatusReason]' --output text)"; then
      warn "could not read refresh $id status; retrying"
      line="Unknown"
    fi
    IFS=$'\t' read -r status pct reason <<<"$line" || true
    log "refresh $id ($mode): $status ${pct:-?}% ${reason:-}"

    case "$mode:$status" in
      *:Unknown | *:Pending | *:InProgress | *:Cancelling | *:RollbackInProgress | recovery:Baking) ;;
      guarded:Baking)
        if [[ "$smoke" == pending ]] && ! $rolling_back; then
          if smoke_test; then
            smoke=passed
          else
            smoke=failed
            warn "smoke test failed during bake; rolling back"
            if aws autoscaling rollback-instance-refresh --auto-scaling-group-name "$ASG_NAME" >/dev/null; then
              rolling_back=true
            else
              warn "rollback request rejected; will restore the previous version after the refresh ends"
            fi
          fi
        fi
        ;;
      *:Successful)
        if [[ "$smoke" == pending ]]; then
          if smoke_test; then smoke=passed; else smoke=failed; fi
        fi
        [[ "$smoke" == passed ]] && return 0
        [[ "$mode" == guarded ]] && return 3
        echo "::error::recovery refresh $id completed but release ${want} fails its smoke test; needs a human" >&2
        return 2
        ;;
      guarded:RollbackSuccessful)
        echo "::error::refresh $id was rolled back by AWS. ${reason:-}" >&2
        return 1
        ;;
      guarded:Failed | guarded:Cancelled)
        warn "refresh $id ended $status without a rollback; instances may be mixed. ${reason:-}"
        return 3
        ;;
      *)
        echo "::error::refresh $id ($mode) ended ${status:-<none>}; fleet state needs a human (see runbook). ${reason:-}" >&2
        return 2
        ;;
    esac

    if ((SECONDS > deadline)); then
      if [[ "$mode" == recovery ]]; then
        # Rolling a recovery back would return to the broken release. Leave
        # it to AWS (health-gated, launch-before-terminate) and escalate.
        echo "::error::recovery refresh $id did not finish within ${TIMEOUT_SECONDS:-1200}s; left running; needs a human" >&2
        return 2
      fi
      if $rolling_back; then
        echo "::error::rollback of refresh $id did not finish in time" >&2
        return 2
      fi
      warn "refresh $id exceeded ${TIMEOUT_SECONDS:-1200}s; rolling back"
      aws autoscaling rollback-instance-refresh --auto-scaling-group-name "$ASG_NAME" >/dev/null ||
        warn "rollback request rejected"
      rolling_back=true
      deadline=$((SECONDS + ${TIMEOUT_SECONDS:-1200}))
    fi
    sleep "${POLL_SECONDS:-15}"
  done
}

# Put the fleet back on <version> in recovery mode and verify <release>.
restore() {
  local version="$1" release="$2" id rc=0
  warn "restoring launch template version $version (${release:-no release})"
  id="$(start_refresh "$version" recovery)" || return 2
  wait_refresh "$id" "$release" recovery || rc=$?
  return "$rc"
}

cmd_refresh() {
  local mode=guarded
  if [[ "${1:-}" == --recovery ]]; then
    mode=recovery
    shift
  fi
  local target="${1:?refresh [--recovery] <version>}" want previous prev_release id rc=0
  : "${API_BASE_URL:?}"
  [[ "$target" =~ ^[0-9]+$ ]] || die "not a launch template version: $target"
  want="$(user_data_var "$target" RELEASE)"
  [[ "$want" =~ $sha_re ]] || die "launch template version $target does not pin a release"
  verify_artifact "$target"
  previous="$(asg_version)"
  prev_release="$(user_data_var "$previous" RELEASE)"

  log "rolling $ASG_NAME ($mode) from launch template version $previous to $target ($want)"
  if ! id="$(start_refresh "$target" "$mode")"; then
    # Nothing changed. For a new release that is a clean refusal (1); for a
    # recovery it means the broken release is still live (2).
    [[ "$mode" == recovery ]] && return 2
    return 1
  fi

  if [[ "$mode" == recovery ]]; then
    wait_refresh "$id" "$want" recovery || rc=$?
    [[ "$rc" == 0 ]] && { log "release $want restored"; return 0; }
    return 2
  fi

  wait_refresh "$id" "$want" guarded || rc=$?
  case "$rc" in
    0)
      log "release $want is live"
      return 0
      ;;
    1)
      # AWS restored the previous configuration; check it actually serves.
      if [[ -z "$prev_release" ]] || "$here/smoke.sh" "$API_BASE_URL" "$prev_release"; then
        return 1
      fi
      echo "::error::fleet was rolled back but ${prev_release} fails its smoke test; needs a human" >&2
      return 2
      ;;
    3)
      # AWS cannot roll back a finished refresh, and a Failed/Cancelled one
      # may have left new instances in place: roll forward onto the previous
      # version instead.
      [[ "$previous" != "$target" ]] || { echo "::error::no earlier version to restore" >&2; return 2; }
      rc=0
      restore "$previous" "$prev_release" || rc=$?
      [[ "$rc" == 0 ]] && return 1
      return 2
      ;;
    *) return 2 ;;
  esac
}

cmd_on_cancel() {
  local id mode active active_id active_status
  [[ -s "${REFRESH_STATE_FILE:-}" ]] || { log "no refresh was started"; return 0; }
  read -r id mode <"$REFRESH_STATE_FILE"
  if [[ "$id" == pending || "$mode" == recovery ]]; then
    # A recovery, or a request whose id never got recorded: rolling back the
    # ASG's active refresh could undo a restore. A guarded refresh started
    # this way is still covered by AWS auto rollback and its alarms.
    warn "job cancelled during a $mode refresh ($id); leaving it to finish"
    return 0
  fi
  # rollback-instance-refresh acts on whatever refresh is active, so only
  # call it if that is still the guarded refresh this job started.
  if ! active="$(active_refresh)"; then
    warn "could not read the active refresh; not rolling back"
    return 0
  fi
  read -r active_id active_status <<<"$active"
  if [[ "$active_id" != "$id" ]]; then
    log "guarded refresh $id is no longer active (active: ${active_id:-none}); nothing to roll back"
    return 0
  fi
  case "$active_status" in
    Pending | InProgress | Baking)
      warn "job cancelled during guarded refresh $id; requesting rollback"
      aws autoscaling rollback-instance-refresh --auto-scaling-group-name "$ASG_NAME" >/dev/null ||
        warn "rollback request rejected"
      ;;
    *) log "refresh $id is already $active_status; leaving it" ;;
  esac
}

sub="${1:-}"
shift || true
case "$sub" in
  current) cmd_current ;;
  find) cmd_find "$@" ;;
  publish) cmd_publish "$@" ;;
  refresh) cmd_refresh "$@" ;;
  on-cancel) cmd_on_cancel ;;
  *) die "usage: rollout.sh {current|find <sha>|publish <artifact> <sha>|refresh [--recovery] <version>|on-cancel}" ;;
esac
