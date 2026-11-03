#!/usr/bin/env bash
# Post-deploy smoke test through CloudFront, as a browser would see the site.
#
# Checks that / and a deep link both serve the expected release's index.html
# (SPA fallback works), and that every asset it references resolves. With
# CHECK_CACHE_HEADERS=true (the default) it also checks the caching contract:
# index.html no-cache, hashed assets immutable.
#
# Usage: smoke.sh <site-url> <expected-release>
set -euo pipefail

site="${1:?usage: smoke.sh <site-url> <expected-release>}"
site="${site%/}"
want="${2:?usage: smoke.sh <site-url> <expected-release>}"
check_headers="${CHECK_CACHE_HEADERS:-true}"

fail() {
  echo "::error::smoke: $*" >&2
  exit 1
}
fetch() { curl --fail --silent --show-error --max-time 10 --retry 3 --retry-all-errors --retry-delay 2 "$@"; }
header() { grep -i -m1 "^$1:" | cut -d: -f2- | tr -d '\r' | sed 's/^ *//' || true; }

for path in / /__smoke/deep/link; do
  html="$(fetch "${site}${path}")" || fail "GET ${path} failed"
  grep -q "<meta name=\"release\" content=\"${want}\"" <<<"$html" ||
    fail "GET ${path} did not serve release ${want}"
done

if [[ "$check_headers" == true ]]; then
  cc="$(fetch --head "${site}/" | header cache-control)"
  [[ "$cc" == *no-cache* ]] || fail "index.html Cache-Control is '${cc}', want no-cache"
fi

mapfile -t assets < <(grep -oE '(src|href)="/assets/[^"]+"' <<<"$html" | cut -d'"' -f2 | sort -u)
((${#assets[@]} > 0)) || fail "index.html references no /assets/ files"
for asset in "${assets[@]}"; do
  headers="$(fetch --head "${site}${asset}")" || fail "GET ${asset} failed"
  if [[ "$check_headers" == true ]]; then
    cc="$(header cache-control <<<"$headers")"
    [[ "$cc" == *immutable* ]] || fail "${asset} Cache-Control is '${cc}', want immutable"
  fi
done
echo "smoke: release ${want} served at / and deep links; ${#assets[@]} assets resolve" >&2
