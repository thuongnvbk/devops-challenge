#!/usr/bin/env bash
# Switch the live site to a release and keep it only if it passes the smoke
# test; otherwise put back whatever was live before and verify that too.
# Deploys and manual rollbacks both go through here, so a rollback to a bad
# release is undone exactly like a bad deploy.
#
# Usage: release.sh deploy <site.tar.gz> <release-sha>
#        release.sh rollback <release-sha>
# Exit:  0  target is live and passed the smoke test
#        1  target failed; the previous release is live again and verified
#        2  target failed and the previous release could not be restored
#           (or there was none): the site needs a human
# Env:   SITE_URL, plus those of publish.sh / activate.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-}"
case "$mode" in
  deploy)
    tarball="${2:?usage: release.sh deploy <site.tar.gz> <release-sha>}"
    target="${3:?usage: release.sh deploy <site.tar.gz> <release-sha>}"
    ;;
  rollback)
    target="${2:?usage: release.sh rollback <release-sha>}"
    ;;
  *)
    echo "usage: release.sh {deploy <site.tar.gz> <sha>|rollback <sha>}" >&2
    exit 64
    ;;
esac
: "${SITE_URL:?}"

previous="$("$here/current.sh")"
echo "release: ${mode} ${target}; currently live: ${previous:-<none>}" >&2

switch() {
  if [[ "$mode" == deploy ]]; then
    "$here/publish.sh" "$tarball" "$target"
  else
    "$here/activate.sh" "$target"
  fi
}

if switch && "$here/smoke.sh" "$SITE_URL" "$target"; then
  echo "release: ${target} is live" >&2
  exit 0
fi

echo "::error::${mode} of ${target} failed" >&2
if [[ -z "$previous" || "$previous" == "$target" ]]; then
  echo "::error::no other release to restore (previous: ${previous:-<none>}); the site needs a human" >&2
  exit 2
fi
echo "release: restoring ${previous}" >&2
if "$here/activate.sh" "$previous" && "$here/smoke.sh" "$SITE_URL" "$previous"; then
  echo "::error::${target} was not kept; ${previous} is live again and verified" >&2
  exit 1
fi
echo "::error::restoring ${previous} failed too; the site needs a human (see SOLUTION.md section 5)" >&2
exit 2
