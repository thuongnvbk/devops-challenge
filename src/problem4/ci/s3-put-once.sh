#!/usr/bin/env bash
# Create an S3 object exactly once.
#
# S3 rejects the write (412) if the key exists (If-None-Match: *) and
# verifies the upload against our sha256. If the key already exists it must
# hold the same bytes; anything else is refused. This is what makes a
# published release immutable: a key can never be repointed at other content.
#
# Usage: s3-put-once.sh <bucket> <key> <file>
set -euo pipefail

bucket="${1:?usage: s3-put-once.sh <bucket> <key> <file>}"
key="${2:?usage: s3-put-once.sh <bucket> <key> <file>}"
file="${3:?usage: s3-put-once.sh <bucket> <key> <file>}"
[[ -f "$file" ]] || { echo "::error::no such file: $file" >&2; exit 1; }

sha="$(sha256sum "$file" | cut -d' ' -f1)"
sha_b64="$(openssl dgst -sha256 -binary "$file" | base64)"
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

if aws s3api put-object --bucket "$bucket" --key "$key" --body "$file" \
  --checksum-sha256 "$sha_b64" --if-none-match '*' >/dev/null 2>"$err"; then
  echo "put-once: created s3://${bucket}/${key}" >&2
  exit 0
fi
grep -q PreconditionFailed "$err" || { cat "$err" >&2; exit 1; }

stored="$(aws s3api head-object --bucket "$bucket" --key "$key" --checksum-mode ENABLED \
  --query ChecksumSHA256 --output text)"
stored_hex="$(base64 -d <<<"$stored" 2>/dev/null | od -An -v -tx1 | tr -d ' \n')"
if [[ "$stored_hex" != "$sha" ]]; then
  echo "::error::s3://${bucket}/${key} already exists with different content; published releases are immutable" >&2
  exit 1
fi
echo "put-once: s3://${bucket}/${key} already holds identical content" >&2
