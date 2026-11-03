#!/usr/bin/env bash
# Print the release the live site serves, read from the release meta tag in
# site/index.html. Prints nothing if the site has never been deployed.
#
# Existence is checked with a prefix-scoped list rather than by treating a
# failed GET as "missing": with ListBucket limited to site/* and releases/*,
# S3 answers a GET for a missing key with 403, indistinguishable from a real
# permission error. JSON output: with text output the CLI applies --query
# to each page separately.
#
# Usage: current.sh
# Env: SITE_BUCKET AWS_REGION
set -euo pipefail

: "${SITE_BUCKET:?}"
export AWS_PAGER=""

found="$(aws s3api list-objects-v2 --bucket "$SITE_BUCKET" --prefix site/index.html \
  --query "length(Contents[?Key=='site/index.html'] || \`[]\`)" --output json)"
[[ "$found" == 1 ]] || exit 0

html="$(aws s3 cp "s3://${SITE_BUCKET}/site/index.html" -)"
sed -n 's/.*<meta name="release" content="\([0-9a-f]\{40\}\)".*/\1/p;T;q' <<<"$html"
