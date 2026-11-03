#!/usr/bin/env bash
# Publish an attested SPA bundle as an immutable release, then activate it.
#
# Bucket layout (CloudFront origin path is /site; releases/ is never served):
#   releases/<digest>.tar.gz   the attested artifact, created once
#   releases/<sha>.digest      commit -> digest, created once, written LAST
#   site/...                   what users get (see activate.sh)
#
# Both records are create-once, so a commit can never be re-pointed at other
# bytes, and an interrupted publish leaves no record a rollback could pick up.
#
# Usage: publish.sh <site.tar.gz> <release-sha>
# Env: SITE_BUCKET, plus those of activate.sh
set -euo pipefail

tarball="${1:?usage: publish.sh <site.tar.gz> <release-sha>}"
release="${2:?usage: publish.sh <site.tar.gz> <release-sha>}"
: "${SITE_BUCKET:?}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ci="$here/../../ci"
export AWS_PAGER=""

[[ "$release" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::not a commit SHA: $release" >&2; exit 1; }
[[ -f "$tarball" ]] || { echo "::error::no such artifact: $tarball" >&2; exit 1; }
index="$(tar -xzOf "$tarball" ./index.html)"
grep -q "<meta name=\"release\" content=\"${release}\"" <<<"$index" ||
  { echo "::error::$tarball is not stamped with release $release" >&2; exit 1; }

digest="$(sha256sum "$tarball" | cut -d' ' -f1)"
record="$(mktemp)"
trap 'rm -f "$record"' EXIT
printf '%s\n' "$digest" >"$record"

"$ci/s3-put-once.sh" "$SITE_BUCKET" "releases/${digest}.tar.gz" "$tarball"
"$ci/s3-put-once.sh" "$SITE_BUCKET" "releases/${release}.digest" "$record"

"$here/activate.sh" "$release"
