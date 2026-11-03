#!/usr/bin/env bash
# Pack a directory into a byte-for-byte reproducible .tar.gz.
#
# The sha256 of this file is the release's identity: it is attested at build
# time, re-verified before every deploy, and pinned in what each environment
# runs. Identical inputs must therefore give identical bytes, so file order,
# timestamps, ownership and modes are all normalised.
#
# Usage: deterministic-tar.sh <source-dir> <output.tar.gz>
set -euo pipefail

src="${1:?usage: deterministic-tar.sh <source-dir> <output.tar.gz>}"
out="${2:?usage: deterministic-tar.sh <source-dir> <output.tar.gz>}"

[[ -d "$src" ]] || { echo "not a directory: $src" >&2; exit 1; }

tar --sort=name \
  --mtime="@${SOURCE_DATE_EPOCH:-0}" \
  --owner=0 --group=0 --numeric-owner \
  --mode='u+rwX,go+rX,go-w' \
  --pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' \
  -C "$src" -cf - . | gzip -9 --no-name >"$out"
