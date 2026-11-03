#!/usr/bin/env bash
# First-boot install of one pinned backend release (EC2 user data body).
#
# rollout.sh prepends a header defining RELEASE, RELEASE_URI, RELEASE_SHA256
# and AWS_REGION, and stores the result as a new launch template version, so
# every instance launched from that version runs exactly those bytes.
#
# There is no in-place upgrade path: a new release means new instances. If
# anything here fails the service never answers /healthz, the ALB never sends
# it traffic, and the instance refresh fails and rolls back.
set -euo pipefail

: "${RELEASE:?}" "${RELEASE_URI:?}" "${RELEASE_SHA256:?}" "${AWS_REGION:?}"

release_dir="/opt/api/releases/${RELEASE}"
bundle="$(mktemp)"
trap 'rm -f "$bundle"' EXIT

aws s3 cp --region "$AWS_REGION" --only-show-errors "$RELEASE_URI" "$bundle"
echo "${RELEASE_SHA256}  ${bundle}" | sha256sum --check --strict --status

mkdir -p "$release_dir"
tar -xzf "$bundle" -C "$release_dir" --no-same-owner
ln -sfn "$release_dir" /opt/api/current

install -m 0644 "$release_dir/api.service" /etc/systemd/system/api.service
systemctl daemon-reload
systemctl enable --now api.service
