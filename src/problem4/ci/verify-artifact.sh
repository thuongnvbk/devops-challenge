#!/usr/bin/env bash
# Refuse an artifact unless it has the expected sha256 AND a SLSA provenance
# attestation signed by <workflow> in this repository, built from main on a
# GitHub-hosted runner. Used before every deploy and every SPA activation.
#
# Usage: verify-artifact.sh <file> <sha256> <workflow-path>
#   e.g. verify-artifact.sh site.tar.gz <hex> .github/workflows/frontend.yml
# Env: GITHUB_REPOSITORY, GH_TOKEN (attestations: read)
set -euo pipefail

file="${1:?usage: verify-artifact.sh <file> <sha256> <workflow-path>}"
want="${2:?usage: verify-artifact.sh <file> <sha256> <workflow-path>}"
workflow="${3:?usage: verify-artifact.sh <file> <sha256> <workflow-path>}"
: "${GITHUB_REPOSITORY:?}"

[[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "::error::not a sha256 digest: $want" >&2; exit 1; }
if ! echo "${want}  ${file}" | sha256sum --check --strict --status; then
  echo "::error::${file} does not match digest ${want}" >&2
  exit 1
fi

gh attestation verify "$file" \
  --repo "$GITHUB_REPOSITORY" \
  --signer-workflow "${GITHUB_REPOSITORY}/${workflow}" \
  --source-ref refs/heads/main \
  --deny-self-hosted-runners >&2
