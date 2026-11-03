#!/usr/bin/env bash
# deleted-open-files.sh - node_exporter textfile collector: bytes held by
# deleted-but-still-open files, per filesystem.
#
# This is the signal behind "df says full, du says not": a log rotated or
# rm'ed while NGINX still holds it open. node_exporter has no such metric.
# NGINX's per-request buffer files are left out: under sustained traffic they
# are always present and would mask the persistent holders this metric is for.
# EXCLUDE_RE must match every *_temp_path NGINX uses (default: both distro
# layouts, /var/lib/nginx and /var/cache/nginx).
#
# Usage (as root, every minute):
#   deleted-open-files.sh [OUTPUT_DIR]      # default /run/node-exporter/textfile
#
# Keep OUTPUT_DIR on tmpfs and point node_exporter's
# --collector.textfile.directory at it, so the metric keeps updating while the
# filesystem it watches is full.
#
# /etc/systemd/system/deleted-open-files.service
#   [Service]
#   Type=oneshot
#   ExecStart=/usr/local/sbin/deleted-open-files.sh /run/node-exporter/textfile
#   #Environment=EXCLUDE_RE=^/srv/nginx-temp/
#   Nice=19
#   IOSchedulingClass=idle
# /etc/systemd/system/deleted-open-files.timer
#   [Timer]
#   OnCalendar=minutely
#   AccuracySec=10s
#   [Install]
#   WantedBy=timers.target
#
# Cost: one find(1) over /proc/*/fd (no fork per descriptor) plus one stat per
# deleted file; safe on an LB holding tens of thousands of sockets.

set -euo pipefail
export LC_ALL=C

OUT_DIR=${1:-/run/node-exporter/textfile}
FSTYPES_RE=${FSTYPES_RE:-'^(ext[234]|xfs|btrfs)$'}
EXCLUDE_RE=${EXCLUDE_RE:-'^/var/(lib|cache)/nginx/'}
OUT="$OUT_DIR/filesystem_deleted_open.prom"

# Prometheus label value escaping: backslash, double quote, newline.
esc() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "${s//$'\n'/\\n}"
}

# st_dev -> mount point, for the filesystem types we care about.
declare -A mount_of=()
while read -r _src mnt fstype _rest; do
  [[ $fstype =~ $FSTYPES_RE ]] || continue
  mnt=$(printf '%b' "$mnt") # /proc/mounts octal-escapes spaces etc. (\040)
  dev=$(stat -c %d -- "$mnt" 2>/dev/null) || continue
  [[ -n ${mount_of[$dev]+x} ]] || mount_of[$dev]=$mnt # first mount wins over bind mounts
done </proc/self/mounts

declare -A bytes=() files=() seen=()
for dev in "${!mount_of[@]}"; do
  bytes[$dev]=0
  files[$dev]=0
done

while IFS= read -r -d '' rec; do
  fd=${rec%%$'\t'*}
  tgt=${rec#*$'\t'}
  [[ ! $tgt =~ $EXCLUDE_RE ]] || continue
  st=$(stat -L -c '%d %i %b %B %h %F' -- "$fd" 2>/dev/null) || continue # fd closed meanwhile
  read -r dev ino blocks bsize nlink ftype <<<"$st"
  # Same stat, so an fd closed and reused for a linked file is not counted.
  [[ $nlink == 0 && $ftype == regular* ]] || continue
  [[ -n ${mount_of[$dev]+x} ]] || continue # memfd, tmpfs, unwatched filesystems
  [[ -z ${seen[$dev:$ino]+x} ]] || continue # same inode via master and workers
  seen[$dev:$ino]=1
  bytes[$dev]=$((${bytes[$dev]} + blocks * bsize))
  files[$dev]=$((${files[$dev]} + 1))
done < <(find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -lname '* (deleted)' -printf '%p\t%l\0' 2>/dev/null || true)

mkdir -p -- "$OUT_DIR"
tmp=$(mktemp -- "$OUT_DIR/.filesystem_deleted_open.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
{
  echo '# HELP filesystem_deleted_open_bytes Bytes allocated to deleted files still held open (NGINX request buffers excluded).'
  echo '# TYPE filesystem_deleted_open_bytes gauge'
  for dev in "${!mount_of[@]}"; do
    printf 'filesystem_deleted_open_bytes{mountpoint="%s"} %s\n' "$(esc "${mount_of[$dev]}")" "${bytes[$dev]}"
  done
  echo '# HELP filesystem_deleted_open_files Deleted files that are still held open.'
  echo '# TYPE filesystem_deleted_open_files gauge'
  for dev in "${!mount_of[@]}"; do
    printf 'filesystem_deleted_open_files{mountpoint="%s"} %s\n' "$(esc "${mount_of[$dev]}")" "${files[$dev]}"
  done
} >"$tmp"
chmod 0644 -- "$tmp" # mktemp creates 0600; node_exporter does not run as root
mv -f -- "$tmp" "$OUT" # atomic: the collector never reads a half-written file
trap - EXIT
