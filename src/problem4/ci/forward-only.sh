#!/usr/bin/env bash
# Decide whether an automatic deploy may replace what an environment runs.
#
# GitHub concurrency groups stop deploys from overlapping but do not order
# them: if commit A's pipeline is slower than commit B's, A can reach the
# deploy step last and silently roll the environment back. This guard lets
# the automatic path only move forward along main. Explicit rollbacks go
# through the rollback workflows, which do not call it.
#
# Usage: forward-only.sh <deployed-sha|""> <candidate-sha>
# Prints "deploy" or "skip". Exits non-zero if history has diverged.
# Needs GH_TOKEN (contents: read) and GITHUB_REPOSITORY.
set -euo pipefail

deployed="${1-}"
candidate="${2:?usage: forward-only.sh <deployed-sha> <candidate-sha>}"
sha_re='^[0-9a-f]{40}$'

[[ "$candidate" =~ $sha_re ]] || { echo "::error::candidate is not a commit SHA: $candidate" >&2; exit 1; }

if [[ -z "$deployed" ]]; then
  echo "::notice::Nothing recorded as deployed; first release to this environment." >&2
  echo deploy
  exit 0
fi
[[ "$deployed" =~ $sha_re ]] || { echo "::error::deployed release is not a commit SHA: $deployed" >&2; exit 1; }

status="$(gh api "repos/${GITHUB_REPOSITORY:?}/compare/${deployed}...${candidate}" --jq .status)"
case "$status" in
  ahead | identical)
    echo deploy
    ;;
  behind)
    echo "::warning::${candidate} is older than deployed ${deployed}; skipping so a newer release is not overwritten." >&2
    echo skip
    ;;
  *)
    echo "::error::${candidate} and deployed ${deployed} have diverged (${status}); refusing to guess. Use the rollback workflow or redeploy from main." >&2
    exit 1
    ;;
esac
