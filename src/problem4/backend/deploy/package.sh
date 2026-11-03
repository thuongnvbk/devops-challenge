#!/usr/bin/env bash
# Build the backend release bundle: a static binary plus its systemd unit,
# packed reproducibly. Same commit + same toolchain => same sha256.
#
# Usage: package.sh <release> <out-dir>
# Writes <out-dir>/api.tar.gz and <out-dir>/api.tar.gz.sha256.
set -euo pipefail

release="${1:?usage: package.sh <release> <out-dir>}"
out="${2:?usage: package.sh <release> <out-dir>}"
[[ "$release" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid release id: $release" >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backend="$(dirname "$here")"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

(
  cd "$backend"
  CGO_ENABLED=0 GOOS=linux GOARCH="${GOARCH:-amd64}" \
    go build -trimpath -buildvcs=false \
    -ldflags "-s -w -buildid= -X main.release=${release}" \
    -o "$stage/api" .
)
install -m 0644 "$here/api.service" "$stage/api.service"
printf '%s\n' "$release" >"$stage/RELEASE"

mkdir -p "$out"
"$backend/../ci/deterministic-tar.sh" "$stage" "$out/api.tar.gz"
(cd "$out" && sha256sum api.tar.gz >api.tar.gz.sha256)
cat "$out/api.tar.gz.sha256"
