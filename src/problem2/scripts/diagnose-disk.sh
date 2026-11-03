#!/usr/bin/env bash
# diagnose-disk.sh - read-only disk-usage triage for an Ubuntu 24.04 NGINX host.
#
# Prints a report and a "Findings" summary. It saves nothing, and anything that
# spills to a temp file (sort, large here-strings, growpart's dry-run work dir)
# is pointed at tmpfs, so it is safe to run on a full filesystem. Stream the
# report off the box instead of saving it locally:
#
#   ssh lb-01 'sudo bash -s -- /' < diagnose-disk.sh > lb-01-disk.txt
#   sudo ./diagnose-disk.sh [PATH]          # PATH defaults to /; its mount is analysed
#
# Tunables (environment): TOP=15  LARGE_MB=256  SCAN_TIMEOUT=300 (seconds per walk)
#
# Run as root. Otherwise /proc/<pid>/fd of other users (NGINX workers run as
# www-data) and root-only directories are invisible and the report under-counts.
# Only exception to "read-only": `nginx -T`, like any NGINX config test, would
# create a configured log file or temp directory if one were missing.

set -euo pipefail
export LC_ALL=C

TOP=${TOP:-15}
LARGE_MB=${LARGE_MB:-256}
SCAN_TIMEOUT=${SCAN_TIMEOUT:-300}
GiB=$((1024 * 1024 * 1024))

# Temp spill goes to RAM, never to the full disk.
for d in /dev/shm /run; do
  if [[ -w $d && $(findmnt -n -o FSTYPE -T "$d" 2>/dev/null) == tmpfs ]]; then
    export TMPDIR=$d
    break
  fi
done

FINDINGS=()
finding() { FINDINGS+=("$*"); }
have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n== %s\n' "$*"; }
# A failing probe is reported, never fatal to the report.
probe() { "$@" 2>&1 || printf '  (probe failed, exit %s: %s)\n' "$?" "$*"; }
# Filesystem walks: lowest CPU and I/O priority, hard time limit.
# (ionice's idle class is only honoured by the BFQ scheduler; elsewhere it is a no-op.)
IONICE=()
if have ionice && ionice -c 3 true 2>/dev/null; then IONICE=(ionice -c 3); fi
slow() { timeout "$SCAN_TIMEOUT" nice -n 19 "${IONICE[@]}" "$@"; }
# First N lines without closing the pipe early (no SIGPIPE under pipefail).
topn() { awk -v n="$TOP" 'NR <= n'; }
# Humanise the first tab-separated field.
hum() { numfmt -d $'\t' --field=1 --to=iec-i --suffix=B --invalid=ignore; }
h() { numfmt --to=iec-i --suffix=B -- "$1"; }
first_line_num() { awk 'NR == 2 { gsub(/[^0-9]/, ""); print; exit }'; }

[[ -e ${1:-/} ]] || { echo "usage: $0 [PATH]  (PATH must exist; its mount is analysed)" >&2; exit 2; }
[[ $EUID -eq 0 ]] || echo "WARNING: not running as root; results will under-count." >&2

TARGET=$(findmnt -n -o TARGET -T "${1:-/}")
SOURCE=$(findmnt -n -o SOURCE -T "$TARGET")
FSTYPE=$(findmnt -n -o FSTYPE -T "$TARGET")
TDEV=$(stat -c %d -- "$TARGET")
read -r SIZE USED AVAIL < <(df -B1 --output=size,used,avail -- "$TARGET" | tail -n 1)
read -r F_FREE F_AVAIL F_BSIZE < <(stat -f -c '%f %a %S' -- "$TARGET")
RESERVED=$(((F_FREE - F_AVAIL) * F_BSIZE))
START_TS=$(date +%s)
START_AVAIL=$AVAIL

section "Host"
# shellcheck source=/dev/null
printf '%s | %s | kernel %s | %s | %s\n' "$(hostname)" "$(. /etc/os-release && echo "$PRETTY_NAME")" \
  "$(uname -r)" "$(uptime -p)" "$(date -u +%FT%TZ)"

section "Target filesystem"
printf 'mount %s  source %s  type %s\n' "$TARGET" "$SOURCE" "$FSTYPE"
printf 'size %s  used %s  avail (non-root) %s  root-only reserve %s\n' \
  "$(h "$SIZE")" "$(h "$USED")" "$(h "$AVAIL")" "$(h "$RESERVED")"
if ((AVAIL < SIZE / 100)); then
  finding "Non-root writers are at or near ENOSPC (avail $(h "$AVAIL")). NGINX workers run as www-data and cannot use the $(h "$RESERVED") root reserve: expect truncated proxied responses, 500s on buffered request bodies, failed cache fills, lost log lines."
fi

section "Real filesystems (snap squashfs loops always read 100% and are excluded)"
probe df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs
section "Inodes"
probe df -i -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs
IUSE=$(df --output=ipcent -- "$TARGET" | first_line_num || true)
IUSE=${IUSE:-0}
((IUSE < 95)) || finding "Inodes on $TARGET are ${IUSE}% used: ENOSPC with free blocks. See the inode section."
for p in /var/log/nginx /var/cache/nginx /var/lib/nginx; do
  [[ -e $p ]] && printf '%-18s is on %s\n' "$p" "$(findmnt -n -o TARGET -T "$p")"
done

section "Block devices and layout"
probe lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
if [[ $FSTYPE == ext4 && -b $SOURCE ]] && have tune2fs; then
  read -r BCOUNT BSIZE < <(tune2fs -l "$SOURCE" 2>/dev/null |
    awk -F: '/^Block count/ { c = $2 } /^Block size/ { s = $2 } END { printf "%.0f %.0f\n", c, s }')
  DEVSIZE=$(blockdev --getsize64 "$SOURCE" 2>/dev/null || echo 0)
  FSBYTES=$((BCOUNT * BSIZE))
  printf 'ext4 spans %s of a %s block device\n' "$(h "$FSBYTES")" "$(h "$DEVSIZE")"
  if ((DEVSIZE - FSBYTES > GiB)); then
    finding "Filesystem is $(h $((DEVSIZE - FSBYTES))) smaller than $SOURCE: grow it online with resize2fs $SOURCE."
  fi
fi
if [[ $(lsblk -dn -o TYPE "$SOURCE" 2>/dev/null) == lvm ]] && have lvs; then
  VG=$(lvs --noheadings -o vg_name "$SOURCE" 2>/dev/null | tr -d ' ' || true)
  probe vgs -o vg_name,vg_size,vg_free "$VG"
  probe pvs -o pv_name,vg_name,pv_size,dev_size
  while read -r pv pvsize devsize; do
    if ((devsize - pvsize > GiB)); then
      finding "PV $pv is $(h $((devsize - pvsize))) smaller than its device: pvresize $pv, then lvextend -r."
    fi
  done < <(pvs --noheadings --units b --nosuffix -o pv_name,pv_size,dev_size -S "vg_name=$VG" 2>/dev/null || true)
  VFREE=$(vgs --noheadings --units b --nosuffix -o vg_free "$VG" 2>/dev/null | tr -d ' ' || true)
  if ((${VFREE:-0} > GiB)); then
    finding "VG $VG has $(h "$VFREE") unallocated (Ubuntu's guided LVM install gives the root LV only half of a 20-200 GiB disk): lvextend -r -L +<size> $SOURCE, online."
  fi
elif [[ $(lsblk -dn -o TYPE "$SOURCE" 2>/dev/null) == part ]] && have growpart; then
  PART=$(basename "$(readlink -f "$SOURCE")")
  DISK=$(lsblk -dn -o PKNAME "$SOURCE")
  PARTNUM=$(cat "/sys/class/block/$PART/partition")
  if GP=$(growpart -N "/dev/$DISK" "$PARTNUM" 2>&1); then
    finding "Partition $SOURCE can grow (growpart -N: ${GP%%$'\n'*}): sudo env TMPDIR=/dev/shm growpart /dev/$DISK $PARTNUM && sudo resize2fs $SOURCE, online (SOLUTION.md section 1.3 step 5)."
  else
    echo "growpart: ${GP%%$'\n'*}"
  fi
fi

section "Space by directory on $TARGET (du -x, depth 3, top $TOP)"
DU_OUT=$(slow du -x -B1 -d 3 -- "$TARGET" 2>/dev/null || true)
DU_TOTAL=$(printf '%s\n' "$DU_OUT" | awk -F'\t' -v t="$TARGET" '$2 == t { print $1 }')
printf '%s\n' "$DU_OUT" | sort -t $'\t' -k1,1rn | topn | hum
if [[ $FSTYPE == overlay ]]; then
  echo "overlay root (container): df reflects the backing filesystem; df/du comparison skipped"
elif [[ -n $DU_TOTAL ]]; then
  GAP=$((USED - DU_TOTAL))
  printf 'df used %s, du reaches %s, unaccounted %s\n' "$(h "$USED")" "$(h "$DU_TOTAL")" "$(h "$GAP")"
  if ((GAP > GiB && GAP > SIZE / 50)); then
    finding "df/du gap of $(h "$GAP"): space held by deleted-but-open files (next section) or files hidden under a mount point (inspect with: mount -o bind,ro / /mnt/rootfs)."
  fi
else
  echo "du did not finish within ${SCAN_TIMEOUT}s; df/du comparison skipped"
fi

section "Deleted but still open on $TARGET (invisible to du; freed only when every holder closes it)"
# NGINX unlinks its ordinary proxy/client-body buffer files as soon as it
# creates them, so /var/lib/nginx/{proxy,body}/... (deleted) entries are live
# buffered requests: leave them alone.
DELETED=$(
  while IFS= read -r -d '' fd; do
    # Same stat gives link count and type: an fd closed and reused between
    # find and stat must not be counted as a deleted file.
    st=$(stat -L --printf '%d\t%i\t%b\t%B\t%h\t%F' -- "$fd" 2>/dev/null) || continue
    [[ $st == *$'\t'0$'\t'regular* ]] || continue
    st=${st%$'\t'*}
    st=${st%$'\t'*}
    tgt=$(readlink -- "$fd" 2>/dev/null) || continue
    pid=${fd#/proc/}
    pid=${pid%%/*}
    comm='?'
    read -r comm 2>/dev/null <"/proc/$pid/comm" || true
    printf '%s\t%s\t%s\t%s\n' "$st" "$pid" "$comm" "$tgt"
  done < <(find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -lname '* (deleted)' -print0 2>/dev/null || true) |
    awk -F'\t' -v OFS='\t' -v dev="$TDEV" '
      $1 != dev { next }
      { k = $1 ":" $2 }
      !(k in bytes) { bytes[k] = $3 * $4; path[k] = $7; who[k] = $6 "[" $5 "]"; n[k] = 1; next }
      { n[k]++ }
      END { for (k in bytes) printf "%.0f\t%s\t%s\n", bytes[k], who[k] (n[k] > 1 ? " +" n[k] - 1 " fds" : ""), path[k] }' |
    sort -t $'\t' -k1,1rn
)
DELETED_BYTES=$(printf '%s\n' "$DELETED" | awk -F'\t' '{ s += $1 } END { printf "%.0f\n", s }')
if [[ -n $DELETED ]]; then
  printf '%s\n' "$DELETED" | topn | hum
  printf 'total held: %s\n' "$(h "$DELETED_BYTES")"
else
  echo "none"
fi
if ((DELETED_BYTES > GiB)); then
  finding "$(h "$DELETED_BYTES") held by deleted-but-open files. NGINX logs: kill -USR1 <master pid>. Any other holder: follow SOLUTION.md section 1.3 step 3 (never truncate a queue, WAL or mapped file). NGINX request buffers free themselves when the request ends."
fi

section "Large files (>= ${LARGE_MB} MiB) and large files written in the last 60 min"
NOW=$(date +%s)
FIND_OUT=$(slow find "$TARGET" -xdev -type f -size +50M \
  -printf '%s\t%T@\t%TY-%Tm-%Td %TH:%TM\t%p\n' 2>/dev/null || true)
echo "-- largest"
printf '%s\n' "$FIND_OUT" | awk -F'\t' -v min=$((LARGE_MB * 1024 * 1024)) 'NF >= 4 && $1 >= min' |
  sort -t $'\t' -k1,1rn | topn | cut -f1,3,4 | hum
echo "-- modified in the last 60 min (what is growing now)"
printf '%s\n' "$FIND_OUT" | awk -F'\t' -v now="$NOW" 'NF >= 4 && $2 >= now - 3600' |
  sort -t $'\t' -k1,1rn | topn | cut -f1,3,4 | hum

if ((IUSE >= 50)); then
  section "Inodes by directory (top $TOP)"
  slow du --inodes -x -d 3 -- "$TARGET" 2>/dev/null | sort -rn | topn || true
fi

section "NGINX"
# Master from the pid file if it is alive, else by process title (skips zombies).
MPID=""
[[ -r /run/nginx.pid ]] && { read -r MPID </run/nginx.pid || true; }
[[ -n $MPID && -e /proc/$MPID/exe ]] || MPID=$(pgrep -o -f '^nginx: master process' || true)
NGINX_T=""
NGINX_S=""
if [[ -z $MPID ]]; then
  echo "no nginx process"
else
  NGINX_BIN=$(readlink -f "/proc/$MPID/exe")
  printf 'master pid %s, workers %s, binary %s\n' "$MPID" "$(pgrep -c -P "$MPID" || true)" "$NGINX_BIN"
  probe "$NGINX_BIN" -v
  # Effective config, filtered to directives that consume disk. The full
  # config is never printed: it can contain credentials.
  # Use the master's -c if it was started with one.
  # Reuse the master's -p/-c so relative paths resolve as they did at start-up.
  TITLE=$(tr '\0' ' ' <"/proc/$MPID/cmdline")
  NGINX_ARGS=()
  for opt in p c; do
    v=$(sed -nE "s/.* -$opt ([^ ]+).*/\\1/p" <<<"$TITLE")
    [[ -z $v ]] || NGINX_ARGS+=("-$opt" "$v")
  done
  NGINX_T=$("$NGINX_BIN" "${NGINX_ARGS[@]}" -T 2>/dev/null || true)
  # One directive per line: comments dropped, multi-line directives joined.
  NGINX_S=$(printf '%s\n' "$NGINX_T" | sed 's/#.*$//' |
    awk 'BEGIN { RS = "[;{}]" } { gsub(/[ \t\r\n]+/, " "); sub(/^ /, ""); sub(/ $/, ""); if (length($0)) print }')
  if [[ -z $NGINX_T ]]; then
    finding "nginx -T fails: the on-disk config does not parse. 'nginx -s reopen' and 'nginx -s reload' will fail too; reopen logs with kill -USR1 $MPID."
  else
    echo "-- disk-relevant directives (file: directive)"
    printf '%s\n' "$NGINX_T" | awk '
      /^# configuration file / { f = $4; sub(/:$/, "", f); next }
      $1 ~ /^(access_log|error_log|[a-z]+_cache_path|[a-z_]+_temp_path|proxy_max_temp_file_size|client_max_body_size|client_body_in_file_only|proxy_buffering|proxy_request_buffering|worker_rlimit_core|working_directory|pid|open_log_file_cache)$/ {
        line = $0; sub(/^[ \t]+/, "", line); print "  " f ": " line }'
    if [[ -n $(awk '$1 == "error_log" && $NF ~ /^(debug|info|notice)$/' <<<"$NGINX_S") ]]; then
      finding "error_log at debug/info/notice level (this nginx is built --with-debug, so debug really logs): set warn and reload."
    fi
    while IFS= read -r c; do
      finding "Cache without max_size ($c): bounded only by inactive= and the disk. Add max_size= and min_free=."
    done < <(awk '$1 ~ /^(proxy|fastcgi|uwsgi|scgi)_cache_path$/ && !/max_size=/ { print $2 }' <<<"$NGINX_S")
    if [[ -n $(awk '$1 == "client_body_in_file_only" && $2 == "on"' <<<"$NGINX_S") ]]; then
      finding "client_body_in_file_only on: every request body is kept on disk after the request, and NGINX never deletes it."
    fi
    if [[ -n $(awk '$1 == "client_max_body_size" && $2 == "0"' <<<"$NGINX_S") ]]; then
      finding "client_max_body_size 0 (unlimited): any upload is buffered to client_body_temp_path."
    fi
  fi

  echo "-- files the master holds open (logs are opened by the master, inherited by workers)"
  declare -A SEEN_FD=()
  while IFS= read -r -d '' fd; do
    tgt=$(readlink -- "$fd" 2>/dev/null) || continue
    [[ $tgt == /* && $tgt != /dev/* && -z ${SEEN_FD[$tgt]+x} ]] || continue
    SEEN_FD[$tgt]=1
    sz=$(stat -L -c %s -- "$fd" 2>/dev/null || echo 0)
    printf '%s\t%s\n' "$sz" "$tgt" | hum
    case $tgt in
      *' (deleted)') finding "NGINX holds deleted file $tgt ($(h "$sz")): rotation removed it without a reopen. Fix now: kill -USR1 $MPID." ;;
      *.log.[0-9]* | *.log-[0-9]*) finding "NGINX is still writing to rotated file $tgt: postrotate never reached the master. Fix now: kill -USR1 $MPID." ;;
    esac
  done < <(find "/proc/$MPID/fd" -mindepth 1 -maxdepth 1 -type l -print0 2>/dev/null || true)

  echo "-- ENOSPC in the last 5000 lines of each error_log file (absence is not proof: the log is on the full disk too)"
  while IFS= read -r f; do
    [[ -f $f ]] || continue
    n=$(tail -n 5000 -- "$f" | grep -c 'No space left on device' || true)
    printf '  %s: %s\n' "$f" "$n"
    ((${n:-0} == 0)) || finding "$f has $n recent '(28: No space left on device)' errors: user traffic is already affected."
  done < <(awk '$1 == "error_log" { print $2 }' <<<"$NGINX_S" | sort -u)
fi

section "logrotate"
probe systemctl list-timers --all --no-pager logrotate.timer
probe systemctl show -p Result -p ExecMainStatus -p ExecMainExitTimestamp logrotate.service
if [[ $(systemctl show -p Result --value logrotate.service 2>/dev/null || true) == exit-code ]]; then
  finding "logrotate.service last run failed: journalctl -u logrotate.service."
fi
probe journalctl -u logrotate.service -n 10 --no-pager -o short-iso
echo "-- state for NGINX logs (/var/lib/logrotate/status)"
grep -F nginx /var/lib/logrotate/status 2>/dev/null || echo "  none"
if have logrotate; then
  # -d: dry run; changes nothing, state file untouched.
  LR=$(logrotate -d /etc/logrotate.conf 2>&1 || true)
  echo "-- logrotate -d errors"
  printf '%s\n' "$LR" | grep -E '^error' || echo "  none"
  if printf '%s\n' "$LR" | grep -q 'duplicate log entry'; then
    finding "logrotate reports a duplicate log entry: the second config for the same files is skipped entirely."
  fi
  while IFS= read -r f; do
    finding "logrotate ignores config '$f': it is group- or world-writable (install it root-owned, mode 0644)."
  done < <(printf '%s\n' "$LR" | sed -n 's/^error: Ignoring \(.*\) because it is writable by group or others.*/\1/p')
  CONSIDERED=$(printf '%s\n' "$LR" | sed -n 's/^considering log //p' | sort -u)
  while IFS= read -r f; do
    case $f in off | stderr | syslog:* | memory:* | /dev/*) continue ;; esac
    [[ $f == /* ]] || { echo "  coverage not checked for relative log path $f"; continue; }
    # A path with variables ($host...) is checked through the files it produced.
    while IFS= read -r g; do
      [[ -f $g ]] || continue
      grep -qxF -- "$g" <<<"$CONSIDERED" ||
        finding "NGINX log $g matches no logrotate rule: unless something else rotates it, it grows forever."
    done < <(if [[ $f == *'$'* ]]; then compgen -G "$(sed -E 's/\$[A-Za-z0-9_]+/*/g' <<<"$f")" || true; else printf '%s\n' "$f"; fi)
  done < <(awk '$1 == "access_log" || $1 == "error_log" { print $2 }' <<<"$NGINX_S" | sort -u)
fi

section "journald"
probe journalctl --disk-usage
systemd-analyze cat-config systemd/journald.conf 2>/dev/null |
  grep -E '^(Storage|SystemMaxUse|SystemKeepFree|SystemMaxFileSize|MaxRetentionSec)=' ||
  echo "  no overrides: persistent journal capped at min(10% of fs, 4G), keeps min(15%, 4G) free"

section "Usual suspects on $TARGET"
SUSPECTS=(/var/log /var/log/journal /var/log/nginx /var/cache/nginx /var/lib/nginx /var/cache/apt/archives
  /var/lib/snapd/snaps /var/crash /var/lib/systemd/coredump /usr/lib/modules /tmp /var/tmp /root /home /var/lib/docker)
while IFS= read -r p; do
  SUSPECTS+=("$p")
done < <(awk '$1 ~ /_(cache|temp)_path$/ { print $2 }' <<<"$NGINX_S" | sort -u)
echo "(NGINX temp files are unlinked at creation: a small /var/lib/nginx here proves nothing, see the deleted-but-open section)"
for d in "${SUSPECTS[@]}"; do
  [[ -d $d && $(stat -c %d -- "$d") == "$TDEV" ]] || continue
  slow du -sxB1 -- "$d" 2>/dev/null || true
done | sort -u | sort -t $'\t' -k1,1rn | hum
# Directories under /var/cache/nginx that no *_cache_path or *_temp_path uses
# (configured, or compiled in: nginx.org packages keep temp dirs here) are left
# over from a renamed or removed cache zone: NGINX never evicts them.
KNOWN=""
if [[ -n $NGINX_T ]]; then
  KNOWN=$( {
    awk '$1 ~ /_(cache|temp)_path$/ { print $2 }' <<<"$NGINX_S"
    "$NGINX_BIN" -V 2>&1 | grep -o -- '--http-[a-z-]*-temp-path=[^ ]*' | cut -d= -f2 || true
  } | sed 's:/*$::' | sort -u)
fi
if grep -qv '^/' <<<"$KNOWN"; then
  echo "orphaned-cache check skipped: relative cache/temp paths in the config"
elif [[ -n $KNOWN && -d /var/cache/nginx ]]; then
  for d in /var/cache/nginx/*/; do
    [[ -d $d ]] || continue
    d=${d%/}
    used=no
    while IFS= read -r k; do
      [[ -n $k && ($k == "$d" || $k == "$d"/* || $d == "$k"/*) ]] && used=yes
    done <<<"$KNOWN"
    [[ $used == yes ]] ||
      finding "$d is not referenced by any *_cache_path or *_temp_path in the on-disk config. If the master has been reloaded since the last config change and nothing else uses it, it is an orphaned cache NGINX never evicts."
  done
fi

section "Kernels, snaps, crash dumps, containers"
echo "running kernel: $(uname -r)"
# shellcheck disable=SC2016 # dpkg-query format, not shell expansion
dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | awk '$1 == "ii" { print "  installed: " $2 }' || true
if have snap; then
  snap list --all 2>/dev/null | awk 'NR == 1 || /disabled/' || true
fi
echo "core_pattern: $(cat /proc/sys/kernel/core_pattern)"
if [[ -d /var/crash ]]; then
  find /var/crash -maxdepth 1 -type f -printf '%s\t%TY-%Tm-%Td\t%f\n' 2>/dev/null | sort -rn | topn | hum
fi
if [[ -d /var/lib/docker/containers ]]; then
  echo "-- docker json-file logs > 100 MiB"
  find /var/lib/docker/containers -name '*-json.log' -size +100M -printf '%s\t%p\n' 2>/dev/null | sort -rn | topn | hum
fi

section "Consumption rate"
ELAPSED=$(($(date +%s) - START_TS))
if ((ELAPSED < 10)); then
  sleep $((10 - ELAPSED))
  ELAPSED=10
fi
NOW_AVAIL=$(df -B1 --output=avail -- "$TARGET" | tail -n 1 | tr -d ' ')
RATE=$(((START_AVAIL - NOW_AVAIL) / ELAPSED))
printf 'avail changed by %s over %ss (%s/s)\n' "$(h $((START_AVAIL - NOW_AVAIL)))" "$ELAPSED" "$(h "$RATE")"
if ((RATE > 0)); then
  ETA_MIN=$((NOW_AVAIL / RATE / 60))
  printf 'at this rate non-root writers hit ENOSPC in ~%s min\n' "$ETA_MIN"
  ((ETA_MIN > 240)) || finding "Filling at $(h "$RATE")/s: ENOSPC for NGINX in ~${ETA_MIN} min. Mitigate before diagnosing further."
fi

section "Findings"
if ((${#FINDINGS[@]} > 0)); then
  printf ' - %s\n' "${FINDINGS[@]}"
else
  echo " - no automated check fired; work through the du and find sections above"
fi
