#!/usr/bin/env bash
# Make a published release live. Used by every deploy and every rollback.
#
#   1. resolve <sha> -> digest from releases/<sha>.digest
#   2. fetch releases/<digest>.tar.gz; check its sha256 and its provenance
#      attestation; unpack it locally
#   3. upload in the order that prevents a broken window:
#        hashed assets   new names, unreferenced until index.html changes
#        other files     non-hashed public files (robots.txt, favicon, ...)
#        index.html      the single switch from old release to new
#   4. invalidate only the non-hashed paths; hashed assets never change
#
# Nothing under site/ changes until steps 1-2 have fully succeeded, so a
# missing, tampered or unattested release is refused with the old one live.
# Old assets are never deleted, so open tabs keep loading their chunks.
#
# Usage: activate.sh <release-sha>
# Env: SITE_BUCKET DISTRIBUTION_ID AWS_REGION GITHUB_REPOSITORY GH_TOKEN
#      SIGNER_WORKFLOW (e.g. .github/workflows/frontend.yml)
set -euo pipefail

release="${1:?usage: activate.sh <release-sha>}"
: "${SITE_BUCKET:?}" "${DISTRIBUTION_ID:?}" "${SIGNER_WORKFLOW:?}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ci="$here/../../ci"
export AWS_PAGER=""
die() {
  echo "::error::$*" >&2
  exit 1
}
[[ "$release" =~ ^[0-9a-f]{40}$ ]] || die "not a commit SHA: $release"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
s3="s3://${SITE_BUCKET}"

# 1. Listing (not HEAD/GET) tells "missing" apart from "forbidden": with
#    ListBucket scoped to releases/* and site/*, S3 reports a missing key as 403.
found="$(aws s3api list-objects-v2 --bucket "$SITE_BUCKET" --prefix "releases/${release}.digest" \
  --query "length(Contents[?Key=='releases/${release}.digest'] || \`[]\`)" --output json)"
[[ "$found" == 1 ]] || die "release $release was never published to this environment"
aws s3 cp --only-show-errors "${s3}/releases/${release}.digest" "$work/digest"
digest="$(tr -d '[:space:]' <"$work/digest")"
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "releases/${release}.digest is not a sha256 digest"

# 2. The exact attested bytes, or nothing.
aws s3 cp --only-show-errors "${s3}/releases/${digest}.tar.gz" "$work/site.tar.gz"
"$ci/verify-artifact.sh" "$work/site.tar.gz" "$digest" "$SIGNER_WORKFLOW"
dist="$work/site"
mkdir "$dist"
tar -xzf "$work/site.tar.gz" -C "$dist" --no-same-owner
grep -q "<meta name=\"release\" content=\"${release}\"" "$dist/index.html" ||
  die "archive ${digest} is not release ${release}"
[[ -d "$dist/assets" ]] || die "archive ${digest} has no assets/ directory"

# Paths to invalidate come from the archive itself: "/" plus every
# non-hashed file (index.html included).
others="$(cd "$dist" && find . -type f ! -path './assets/*' | sed 's|^\.||' | LC_ALL=C sort)"
mapfile -t paths <<<"$others"
[[ " ${paths[*]} " == *" /index.html "* ]] || die "archive ${digest} has no index.html"

# 3. The switch.
aws s3 cp "$dist/assets/" "${s3}/site/assets/" --recursive --only-show-errors \
  --cache-control 'public, max-age=31536000, immutable'
aws s3 cp "$dist/" "${s3}/site/" --recursive --only-show-errors \
  --exclude 'assets/*' --exclude 'index.html' --cache-control 'public, max-age=300'
aws s3 cp "$dist/index.html" "${s3}/site/index.html" --only-show-errors \
  --cache-control 'no-cache' --content-type 'text/html; charset=utf-8'
echo "activate: site/index.html now points at release ${release} (${digest})" >&2

# 4. Invalidate and wait until every edge has dropped the old copies.
id="$(aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" \
  --paths / "${paths[@]}" --query Invalidation.Id --output text)"
echo "activate: invalidating / ${paths[*]} (${id})" >&2
aws cloudfront wait invalidation-completed --distribution-id "$DISTRIBUTION_ID" --id "$id"
