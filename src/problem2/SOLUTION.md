# Problem 2: Diagnose Me Doctor

## TL;DR

- **99% is not yet the outage; ENOSPC for NGINX workers is.** Workers run as `www-data` and cannot touch ext4's root reserve (5% by default), so they fail first while root daemons, SSH and sudo keep working. The box looks healthy while users get truncated downloads that NGINX logs as `200`, `500`s on request bodies, and empty replies on cache fills. All three reproduced on Ubuntu 24.04's nginx 1.24.
- **First 10 minutes:** confirm which filesystem and which resource (blocks or inodes) is full, measure time-to-full, look for `(28: No space left on device)` in NGINX's error log, then free space in order of risk: rotated logs, apt cache, journal vacuum, `kill -USR1` to drop deleted logs NGINX still holds, online volume/LV growth. Never `rm` a live log. Never restart NGINX to free space.
- **Diagnosis order:** right mount and metric → is the filesystem as big as the disk (the Ubuntu installer's default LVM layout gives `/` only half of a 64 GB disk) → df vs du (deleted-but-open files; NGINX's ordinary buffer files never show in `du`) → what is big → what is growing.
- **Likely causes on an NGINX LB in general, most likely first:** access-log volume outrunning daily rotation; broken rotation (NGINX still writing to a rotated or deleted file); unbounded `proxy_cache`; root LV never extended; debug-level `error_log`. A genuinely flat history shifts the odds toward a capped cache, a static blob or an undersized filesystem (§3.1). §3 gives, for each cause, how to confirm it, its impact, an immediate fix, and the permanent fix.
- **Prevention:** logs shipped off-box and rotated by size, cache bounded by `max_size` + `min_free` on its own volume, and alerts on time-to-full, a hard floor (a flat 99% line has no slope and never trips a trend alert), inodes, and bytes held by deleted files. The rules are unit-tested.

Supporting files: [`scripts/diagnose-disk.sh`](scripts/diagnose-disk.sh) (read-only triage, safe to run on a full disk), [`scripts/deleted-open-files.sh`](scripts/deleted-open-files.sh) (textfile collector), [`monitoring/`](monitoring/) (alert rules + promtool tests).

## 0. Reading the brief

- **"Two production issues"** is followed by a scenario with one symptom. I treat it as one incident with two problems, in this order: keep the LB serving (impact, mitigation), then find and remove the cause (diagnosis, root cause, prevention). I don't invent a second, unrelated issue.
- **"Consistently 99%"** most naturally reads as a sustained plateau, but rounding or repeated peaks can look the same. Confirm with the raw `avail` bytes history before leaning on its shape (§3.1).

Assumptions:

1. Ubuntu 24.04 with the archive `nginx` package (1.24.0): systemd unit, logs in `/var/log/nginx`, temp files in `/var/lib/nginx/{body,proxy}`, config in `/etc/nginx`. Where nginx.org packages or containerised NGINX behave differently, I say so.
2. One 64 GB disk, ext4 root (Ubuntu's default), no separate `/var`. It was built either from a cloud image (one partition, grown by cloud-init) or from the server ISO with its default guided LVM layout.
3. One LB instance with no peer to drain to, so anything that drops connections is a full outage. Drain this node first only if you have verified that the remaining targets are healthy and have the headroom to absorb its traffic; a cloud LB in front proves neither.
4. Monitoring is node_exporter + Prometheus. The reasoning applies to any agent.
5. I have SSH, sudo, and API access to resize the volume.

## 1. Triage: impact first

### 1.1 What fails, and in what order

ext4 keeps 5% of blocks for root (3.2 GB of 64 GB). `df` shows 100% once *non-root* writers are out of space, but root can still write into the reserve. The behaviour below was reproduced in an `ubuntu:24.04` container with the archive nginx, a full ext4 loop filesystem and a `www-data` writer.

| Writer | Runs as | At ENOSPC | User-visible |
|---|---|---|---|
| Proxy response buffering (`/var/lib/nginx/proxy`): responses larger than `proxy_buffers` (8 x 4k) going to a client slower than the upstream, up to `proxy_max_temp_file_size` (1 GiB) each | worker, `www-data` | `pwritev() ... failed (28: No space left on device)`, then the connection is cut mid-body. **The access log records `200`.** | Yes. Status-code SLIs miss it |
| Request body buffering (`/var/lib/nginx/body`): bodies larger than `client_body_buffer_size` (8k) | worker | `500` before the request reaches upstream | Yes: uploads, large POST/PUT |
| `proxy_cache` fill | worker | Client gets an empty reply. **Logged as `200 0`.** | Yes on cached routes. The cache also stops shielding the upstreams |
| `access_log`, `error_log` | worker | Write fails; the request is still served; the line is lost | No, but you lose the audit trail and the evidence for this incident |
| rsyslog (`/var/log/syslog`) | `syslog` | Stops writing | No |
| journald | root | Stops growing its footprint and keeps logging inside it by deleting its oldest archived files | No, but history is lost |
| apt, unattended-upgrades | root | Download/unpack fails and can leave dpkg half-configured | Latent: security patching stops |
| SSH, sudo | root | Keep working on the reserve until it runs out too | Your ability to fix it |

### 1.2 Size the incident (5 minutes)

```bash
df -hT /; df -i /                       # blocks or inodes? which device?
sudo tail -n 5000 /var/log/nginx/error.log | grep -c 'No space left on device'
a=$(df -B1 --output=avail / | tail -n1); sleep 60; b=$(df -B1 --output=avail / | tail -n1)
echo "consuming $(( (a - b) / 60 )) B/s, $b B left for non-root writers"
```

The error log sits on the same full disk, so zero ENOSPC lines proves nothing. Get the truth from outside the box: edge 5xx rate, plus a synthetic check that downloads a large object and compares bytes received with `Content-Length`, because truncation is logged as success.

Severity: user-facing errors now → SEV2 (SEV1 if this LB is the only path for most traffic). No errors yet but full within 4 h → SEV3, fix within hours. Flat with no errors → fix today, and treat it as a monitoring gap, because a page should have fired earlier.

### 1.3 Buy headroom, lowest risk first

Every risky step is defined once, here. The rest of the document refers back to these steps.

| # | Action | Command | Frees | Risk |
|---|---|---|---|---|
| 1 | Remove what nothing holds open: compressed rotated logs (ship first if retention requires), apt cache, archived journal | `sudo rm /var/log/nginx/*.gz`; `sudo apt-get clean`; journal per **B** | Usually GBs | None |
| 2 | Make NGINX reopen its logs | `sudo kill -USR1 "$(cat /run/nginx.pid)"`, then `sudo lsof -nP -a +L1 /` to see what is still held | A deleted log, once no other process holds it. A still-linked `access.log.1` frees nothing; it only stops growing (clear it with 1 or **A**) | None. Works even if the on-disk config is broken, unlike `nginx -s reopen` |
| 3 | A deleted file held by another process | A shipper holding a rotated log: restart the shipper (not the LB). Agent queues and WALs: **C**. Truncate via `/proc/<PID>/fd/<FD>` only a file positively identified as a disposable log | Its size | Truncating anything else (a queue, a WAL, a memory-mapped file, NGINX's request buffers) can corrupt state or crash the holder |
| 4 | A huge live log | **A** | Its size | None |
| 5 | Grow capacity online, no restart | VG has free space: `sudo lvextend -r -L +20G /dev/ubuntu-vg/ubuntu-lv`. Cloud disk: resize the volume, then `sudo env TMPDIR=/dev/shm growpart /dev/nvme0n1 1` (growpart needs scratch space, so keep it off the full disk) and `sudo resize2fs /dev/nvme0n1p1`. Under LVM, `pvresize` the PV, then `lvextend -r`. Names from `lsblk` | As much as you add | None, but it only buys time. EBS rate-limits modifications of a volume, so check the current limit before counting on a second resize |
| 6 | Seconds-to-full emergency only: lend NGINX part of the root reserve | Record the current value first: `sudo tune2fs -l "$(findmnt -n -o SOURCE /)" \| grep -E '^(Block\|Reserved block) count'`. If it is above 1%: `sudo tune2fs -m 1 <dev>` | Reserve minus 1% (4% at the default 5%), instantly (verified online) | Spends root's safety margin. Restore the recorded value once there is headroom; never `-m 0` |

**A. Export a live log without losing lines or overwriting evidence.**

```bash
cd /var/log/nginx && f="access.log.$(date -u +%Y%m%dT%H%M%SZ)"
sudo mv -n access.log "$f" && sudo kill -USR1 "$(cat /run/nginx.pid)"  # mv -n exits 1 rather than overwrite
sudo lsof -- "$f" || echo "no holders"                                  # wait for (or restart) any reader first
set -o pipefail; sudo gzip -c -- "$f" | ssh ops@bastion "set -C; cat > lb-01-$f.gz" && sudo rm -- "$f"
```

The rename costs no space and the reopen freezes the file. `set -C` refuses to overwrite an earlier export, and the local file is removed only after a successful transfer. If the content is not needed, `sudo truncate -s 0 access.log` is enough: NGINX logs with `O_APPEND` (checked in `/proc/<pid>/fdinfo`).

**B. Journal and rsyslog.**

```bash
sudo journalctl --rotate --vacuum-size=500M   # vacuum removes only archived files; --rotate archives the active ones first
printf 'su root adm\ncreate\ninclude /etc/logrotate.d/rsyslog\n' | sudo tee /run/lr-rsyslog.conf >/dev/null
sudo logrotate -d -f /run/lr-rsyslog.conf     # read the dry run, then run it without -d
```

The temporary config carries the `su`/`create` globals from `/etc/logrotate.conf`. On its own, `logrotate -f /etc/logrotate.d/rsyslog` refuses to run because `/var/log` is group-writable (verified). Rotation renames for free; compressing the previous generation needs some room. The vacuum discards journal history beyond 500 MB.

**C. Agent queues and WALs** (Fluent Bit `storage.path`, Vector disk buffers, Alloy/Prometheus-agent WAL) are never truncated live, and none of this is live-safe. Fix the backend first. If the space is needed now: stop the agent, clear its queue with the agent's documented procedure, then start it. This discards every log line or sample not yet shipped, possibly including this incident's evidence. Record the agent and time window dropped in the incident log.

After each step, check that `avail` rises, no new ENOSPC lines appear, and the large-object synthetic passes. §4 lists what not to do.

## 2. Diagnosis: read-only, in this order

Ground rules on a hot, full box: `export TMPDIR=/dev/shm` first so sorts spill to RAM; walk the filesystem with `nice`/`ionice` and `-x`/`-xdev`; stream output to your workstation rather than the full disk; don't install tools (`ncdu`) onto it. [`scripts/diagnose-disk.sh`](scripts/diagnose-disk.sh) runs every step below in one pass and ends with a Findings list. It saves nothing and points temp spill (`sort`, `growpart -N`) at tmpfs:
`ssh lb-01 'sudo bash -s -- /' < scripts/diagnose-disk.sh > lb-01-disk.txt`.

**Step 1: is the alert right? Which mount, which resource?**

```bash
df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay
df -i  -x tmpfs -x devtmpfs -x squashfs -x overlay
findmnt -T /var/log/nginx; findmnt -T /var/lib/nginx
```

- Compare the alert's `mountpoint`/`device` labels with `df`. Common mismatches: `/boot` (a separate 2 GiB on LVM installs, which fills with kernels), snap squashfs loops (always 100%; node_exporter excludes squashfs by default, other agents may not), or a container's overlay.
- Inodes at 100% also return ENOSPC even with free blocks, and `df -h` looks fine.
- Both `df`'s Use% and node_exporter's `1 - avail/size` count the root reserve as unusable, so "99%" can mean ~94% of blocks hold data while root still has 3.2 GB.

**Step 2: is the filesystem as big as the disk?**

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
sudo vgs; sudo lvs; sudo pvs -o pv_name,pv_size,dev_size
sudo env TMPDIR=/dev/shm growpart -N /dev/nvme0n1 1   # dry run, scratch in RAM: CHANGE means unpartitioned space follows
sudo tune2fs -l "$(findmnt -n -o SOURCE /)" | grep -E '^(Block count|Reserved block count|Block size):'
```

- **ISO installs:** the 24.04 server installer's guided layout uses LVM with sizing policy `scaled`, which gives the root LV *half* the volume group on disks of 20-200 GiB (subiquity `scaled_rootfs_size`, checked at tags 24.04.1 and 24.04.5). On 64 GiB that is a ~1 GiB ESP, a 2 GiB `/boot`, a ~61 GiB VG and a **~30 GiB root LV, with ~30 GiB unallocated**. The "64 GB disk at 99%" may be a 30 GB filesystem. Fix: §1.3 step 5.
- **Cloud images:** one ext4 partition, which cloud-init's `growpart`/`resize_rootfs` grow at boot. If the volume was enlarged without a reboot or §1.3 step 5, the extra space sits unused. Also check that the PV filled its partition (`pvs`: `dev_size` > `pv_size` means `pvresize`).

**Step 3: df vs du. Is space held by files you can't see?**

```bash
df -B1 --output=used /          # the filesystem's view
sudo du -sxB1 /                 # files reachable by name on this filesystem
sudo lsof -nP -a +L1 /          # open files with link count 0, on / only
```

`-a` matters: without it lsof ORs the two selections and lists every open file on `/`. A large gap comes from one of three places:

1. **Logs rotated or `rm`'ed while NGINX holds them:** `access.log (deleted)` held by the master and every worker.
2. **NGINX buffer files:** nginx unlinks ordinary proxy and client-body buffer files right after creating them, so they only appear here, e.g. `/var/lib/nginx/proxy/1/00/0000000001 (deleted)` (verified). They free themselves when the request ends, so a `du` of `/var/lib/nginx` near zero tells you nothing. Two exceptions are linked and visible to `du`: cache fills, which write a named temp file that is renamed into the cache, and `client_body_in_file_only on`, which keeps every request body on disk forever (verified).
3. **Files shadowed by a mount point,** written before a volume was mounted over the directory. List them through a read-only bind mount:
   `sudo mkdir -p /mnt/rootfs && sudo mount -o bind,ro / /mnt/rootfs && sudo du -xh -d2 /mnt/rootfs/var | sort -rh | head; sudo umount /mnt/rootfs`

**Step 4: what is big, and what is growing now?**

```bash
sudo nice -n19 ionice -c3 du -xh -d2 / 2>/dev/null | sort -rh | head -n 20
sudo find / -xdev -type f -size +500M -printf '%s\t%TY-%Tm-%Td %TH:%TM\t%p\n' 2>/dev/null | sort -rn | numfmt --to=iec-i --field=1 | head -n 20
sudo find / -xdev -type f -mmin -60 -size +50M -printf '%s\t%p\n' 2>/dev/null | sort -rn | numfmt --to=iec-i --field=1 | head
sudo du --inodes -x -d3 / 2>/dev/null | sort -rn | head -n 15     # only if df -i is high
```

**Step 5: NGINX and its log rotation.**

```bash
sudo nginx -T 2>/dev/null | grep -nE '^\s*(access_log|error_log|proxy_cache_path|proxy_temp_path|client_body_temp_path|proxy_max_temp_file_size|client_max_body_size)\b'
sudo ls -l /proc/"$(cat /run/nginx.pid)"/fd | grep -E '\.log|deleted'     # what NGINX actually writes to
ls -lh /var/log/nginx/
systemctl list-timers --all logrotate.timer; systemctl status logrotate.service --no-pager
sudo grep nginx /var/lib/logrotate/status
sudo logrotate -d /etc/logrotate.conf 2>&1 | grep -E '^error|considering log'    # -d: dry run, changes nothing
```

Signals:

- An fd pointing at `access.log.1` or `(deleted)` means the reopen signal never arrived.
- `logrotate.service` failed, or `error: ... duplicate log entry`, which means a second config for the same files and the whole second file is skipped (verified).
- `error: Ignoring nginx because it is writable by group or others`: logrotate skips any config file that is group- or world-writable, and `logrotate -d` still exits 0 (verified).
- A log path that `logrotate -d` never "considers" (vhost logs in subdirectories, `*.access` names, `$host` in the path) is never rotated.

**Step 6: everything else on the box.**

```bash
journalctl --disk-usage; systemd-analyze cat-config systemd/journald.conf | grep -E '^(Storage|SystemMaxUse|SystemKeepFree)='
sudo du -sh /var/cache/apt/archives /var/lib/snapd/snaps /var/crash /usr/lib/modules /var/lib/docker 2>/dev/null
snap list --all | awk 'NR == 1 || /disabled/'
cat /proc/sys/kernel/core_pattern; ls -lh /var/crash
```

## 3. Root causes

### 3.1 Read the graph before the box

| Shape of usage over days | Points to |
|---|---|
| Daily sawtooth whose peaks reach the ceiling | Rotation works, but retention × daily volume > disk (traffic grew) |
| Steady ramp, no sawtooth | Rotation broken, unbounded cache, a new stray producer |
| **Flat at 99%** | A consumer that stops itself at the ceiling (`proxy_cache` whose `max_size` is sized to the disk, so the cache manager evicts at the cap), a static blob (pcap, backup, undersized LV), or **writes already failing, so usage cannot climb** |
| Spikes that recede | Temp buffering of large bodies; deleted-open files released when requests end |
| Drops only after a reload or restart | Deleted-but-open files |

If the raw history confirms the brief's plateau, suspect cache sizing, a static blob or an undersized filesystem before the general ranking below, and assume NGINX may already be failing writes.

### 3.2 Catalogue

Ranked by general likelihood on a dedicated NGINX LB. "Immediate" actions are safe under live traffic unless marked; risky ones point to their single definition in §1.3.

| # | Cause | Confirm (signal) | Impact | Immediate | Permanent fix |
|---|---|---|---|---|---|
| 1 | **Access-log volume outruns daily rotation** (traffic growth, bots, DDoS, retry storms, verbose `log_format`) | `/var/log/nginx` dominates `du`; multi-GB `access.log` within a day; sawtooth graph | Fills within a day, then §1.1 | §1.3 steps 1 and 4 | Ship logs off-box (Alloy/Fluent Bit → Loki) and keep ≤48 h locally; rotate by size, run often (§5.2); stop logging health checks with `if=` |
| 2 | **Broken rotation: NGINX never reopens** | NGINX fd on `access.log.1` or `(deleted)`; df/du gap; `logrotate.service` failed; `duplicate log entry`; logs outside the glob | Unbounded growth; deleting files frees nothing | §1.3 steps 2-3 | A postrotate that fails loudly (§3.3); cover every log path; config files root-owned 0644; alert on deleted-open bytes |
| 3 | **`proxy_cache` unbounded or mis-sized;** orphaned cache dirs after a zone or path rename | `du` of each `proxy_cache_path`; no `max_size`, or `max_size` close to disk size; dirs under the cache root that no `proxy_cache_path` uses | Flat at 99% or a ramp; cache fills fail with empty replies; upstream load rises | Lower `max_size`, add `min_free`, `nginx -t && systemctl reload nginx` (change only those: a new path or zone name orphans the old cache); delete orphaned dirs (NGINX never evicts them) | Cache on its own volume; `max_size` ≤ 70% of it plus `min_free`; alert on that volume |
| 4 | **Filesystem smaller than the disk:** installer-default root LV, or partition/fs not grown after a volume resize | `vgs` VFree; disk > partition in `lsblk`; `growpart -N` reports CHANGE; fs block count × block size < device | A "64 GB" alert on a ~30 GB fs | §1.3 step 5 | Pin the layout in IaC/autoinstall (`sizing-policy: all` or explicit sizes); deliberately leave ~10% of the VG free as break-glass |
| 5 | **Verbose `error_log`** (`debug`/`info`) or an error flood (upstream timeouts, `no live upstreams`, TLS handshake noise) | `error.log` large and fast-growing; `[debug]` lines; `error_log` level in `nginx -T` | GB/hour at debug. Ubuntu's nginx is built `--with-debug`, so `debug` really logs | Set `warn`; `nginx -t && systemctl reload nginx`; clear `error.log` with §1.3 **A** | CI lint rejects `debug`; use `debug_connection <ip>` for targeted debugging |
| 6 | **Temp buffering:** large responses to slow clients (up to 1 GiB each), large uploads (`client_max_body_size` raised or `0`); `client_body_in_file_only on` keeping every body | `lsof -a +L1 /` shows `/var/lib/nginx/{proxy,body}/… (deleted)`; for `in_file_only`, linked files piling up in `/var/lib/nginx/body` | Bursty: 200 slow clients × 1 GiB = 200 GiB of demand. `in_file_only on` is a steady ramp | Live buffers: nothing to delete. Rate-limit the offender, lower `proxy_max_temp_file_size`, reload (in-flight requests keep the old config). Retained bodies: set `clean` or `off`, reload, delete old files | Temp paths on the cache volume; per-location body limits; for uploads, `proxy_request_buffering off` plus `proxy_http_version 1.1` (chunked bodies are still buffered over HTTP/1.0, and retries can't resend an unbuffered body); `proxy_buffering off` for streaming endpoints |
| 7 | **journald / rsyslog**, fed by an LB-typical flood: `nf_conntrack: table full`, SYN-flood warnings, SSH brute force (`auth.log`, `btmp`) | `journalctl --disk-usage`; size of `/var/log/syslog*`, `kern.log`, `auth.log`, `btmp`; drop-ins raising `SystemMaxUse` | Persistent journal defaults to min(10% of fs, 4G) and keeps min(15%, 4G) free, so it is usually a contributor, not the cause. rsyslog's files rotate only weekly | §1.3 **B**, then stop the flood | `SystemMaxUse=1G` drop-in; never route access logs through syslog |
| 8 | **Agent buffers:** the log shipper or metrics agent spooling to disk while its backend is down (Fluent Bit `storage.path`, Vector disk buffers, Alloy/Prometheus-agent WAL), or holding rotated logs open while it lags | `du` of `/var/lib/{fluent-bit,vector,alloy}` or the configured buffer path; the holder in `lsof -a +L1 /` is the agent; agent logs show output errors | Ramp that starts when the backend went down; deleted logs held by the agent | **Not live-safe:** §1.3 **C** | Cap buffers (Fluent Bit `storage.total_limit_size`, Vector `buffer.max_size`); alert on agent output errors |
| 9 | **Crash dumps** | `/var/crash/*.crash` (apport ships on server images); `core_pattern`; `exited on signal 11 (core dumped)` in `error.log`; `worker_rlimit_core` | Disk usage, plus the real problem: workers crashing and dropping connections | Copy off for analysis, then delete | Fix the crasher (often a third-party module); cap dumps |
| 10 | **OS leftovers:** apt cache, old kernels, disabled snap revisions | `du` of `/var/cache/apt/archives`, `/usr/lib/modules`; `snap list --all` | Rarely over 2-3 GB: a quick win, rarely the cause | §1.3 step 1; `snap remove <name> --revision=<rev>`; `apt autoremove --purge` once there is room | Keep `Unattended-Upgrade::Remove-Unused-Kernel-Packages` at its default (`true`); `snap set system refresh.retain=2` |
| 11 | **Static blobs:** pcaps, tarballs, copied logs, backups; the installer's `/swap.img` (curtin sizes it from RAM, up to 8 GiB) | `find -size +500M`; `/root`, `/home`, `/tmp`, `/var/tmp`; `swapon --show` | A static blob (flat graph) | Confirm the owner, move off-box, delete. Leave an active swapfile alone (§4) | A scratch volume with a TTL; `tcpdump -C 100 -W 10` ring buffers |
| 12 | **Inode exhaustion** (millions of small cache objects) | `df -i` at 100%; `du --inodes` | ENOSPC with free blocks | Purge the producer | `max_size` doesn't cap inodes: size the cache volume for object count, or use XFS (dynamic inodes); inode alert |
| 13 | **Hidden or misplaced data:** files under a mount point; a data volume that failed to mount (`nofail`), so NGINX wrote cache/logs to `/` | df/du gap with empty `lsof +L1`; read-only bind mount; `findmnt --verify`; `findmnt -T /var/cache/nginx` resolves to `/` | Fills root silently | Mount properly, move the data | `RequiresMountsFor=` on `nginx.service`; alert on the mount being present |
| 14 | **NGINX in Docker** | `/var/lib/docker/containers/*/*-json.log` | The json-file log driver has no size limit by default | **Not safe, emergency only:** Docker does not support editing these files, though `truncate -s 0` is the usual last resort. Otherwise set `max-size` and recreate the container in a window, which is a restart on a single LB | `log-opts` `max-size`/`max-file` in `daemon.json` (applies to new containers) |
| 15 | **Monitoring on the wrong mount or metric** | Alert labels vs `df` | False alarm, or a real problem hidden | Fix the query | Alert per real mount (`fstype=~"ext4\|xfs"`), on `avail` |

### 3.3 The ones that bite

**Silent rotation failure.** Ubuntu's postrotate is `invoke-rc.d nginx rotate >/dev/null 2>&1`. That runs `/etc/init.d/nginx rotate`, which sends `start-stop-daemon --stop --signal USR1 --pidfile $PID --name nginx`. `$PID` is read only from a `pid` directive in `/etc/nginx/nginx.conf` itself, not from includes, and the function returns 0 whatever happens. A pid path set in an include, a self-built NGINX started by its own unit while Ubuntu's logrotate file stays behind, a renamed binary, or NGINX moved into a container all make it fail quietly while logrotate reports success. NGINX then keeps writing to `access.log.1`: rename preserves the inode. Once that file ages out, it writes to a deleted file. The fix is a postrotate that signals through systemd and does not discard errors, so a failure fails `logrotate.service` where an alert can see it (§5.2). `nginx -s reopen` is not a safe substitute: it parses the on-disk config to find the pid, and if someone left a broken config it fails, while `kill -USR1` still works (verified).

**`hourly` and `maxsize` do nothing on their own.** On 24.04, `logrotate.timer` is `OnCalendar=daily` (verified), and logrotate only checks sizes when it runs. Size-based rotation needs the timer to run more often.

**Cache bounds.** `inactive` defaults to 10 minutes, which caps the cache at the recent working set. Raise it to days without `max_size` and the cache is unbounded. The cache manager enforces `max_size` asynchronously, in batches (`manager_files`/`manager_threshold`/`manager_sleep`), so the cache overshoots during fill bursts and shrinks slowly after you lower the cap. `min_free` (nginx ≥ 1.19.1; 24.04 ships 1.24) ties eviction to actual free space on the filesystem.

## 4. Unsafe "fixes"

| Don't | Why | Instead |
|---|---|---|
| `rm /var/log/nginx/access.log` | NGINX keeps the inode open: zero bytes freed, the file disappears from `du`, and the evidence is gone | §1.3 **A** |
| `systemctl restart nginx`, or reboot, "to release space" | The unit's stop sends SIGQUIT, then SIGTERM after 5 s, then SIGKILL (`--retry QUIT/5`, `TimeoutStopSec=5`), cutting long downloads, uploads and websockets. If the on-disk config has drifted and fails `ExecStartPre=nginx -t`, NGINX does not come back: degraded becomes down | §1.3 step 2 to reopen logs; `nginx -t && systemctl reload nginx` for config changes (reload keeps old workers if the new config is invalid); temp files free themselves |
| `rm -rf /var/lib/nginx/*` | Frees nothing (temp files are already unlinked) and deletes the temp directories. Workers cannot recreate them, so buffered responses are truncated (`mkdir() "/var/lib/nginx/proxy/1" failed`) until a reload (verified) | Leave it alone |
| `rm -rf` of the active cache | Every request becomes an upstream fetch at once: a stampede that can take the upstreams down | §3.2 row 3 |
| `journalctl --vacuum-time=1s`, deleting `/var/log/journal` | Destroys the logs this incident and its postmortem need | §1.3 **B** |
| Deleting under `/var/lib/dpkg`, `/var/lib/apt`, `/var/lib/snapd` | Breaks package management and snaps (the cloud or monitoring agent may be a snap) | §1.3 step 1; §3.2 row 10 |
| `copytruncate` or manual copies on a full disk | Needs a full copy's worth of free space and loses lines written between copy and truncate | §1.3 **A** (rename costs no space) |
| `tune2fs -m 0` | Removes root's last margin: the next fill also takes out journald, logins and sudo | §1.3 step 6 (read the current reserve first) |
| `rm /swap.img` while it is active | Frees nothing (the kernel holds it), and `swapoff` on a memory-pressured LB can trigger the OOM killer | Leave it; resize swap in a change window if it is genuinely oversized |
| Shrinking a filesystem, offline fsck, rebooting | ext4 cannot shrink online; a reboot is an outage on a single LB | §1.3 step 5 |

## 5. Prevention and detection

### 5.1 Alerts

[`monitoring/disk-alerts.rules.yml`](monitoring/disk-alerts.rules.yml), with unit tests in [`monitoring/disk-alerts.test.yml`](monitoring/disk-alerts.test.yml) (`promtool test rules`).

| Alert | Condition (abridged) | For | Route |
|---|---|---|---|
| `FilesystemExhaustionImminent` | ETA `avail / -deriv(avail[10m]) < 30m`, no percentage gate | 2m | page |
| `FilesystemWillFillIn1h` | `avail/size < 10%` and `predict_linear(avail[30m], 1h) < 0` | 5m | page |
| `FilesystemWillFillIn4h` | `avail/size < 20%` and `predict_linear(avail[1h], 4h) < 0` | 15m | page |
| `FilesystemWillFillIn24h` | `avail/size < 40%` and `predict_linear(avail[6h], 24h) < 0` | 1h | ticket |
| `FilesystemAlmostFull` | `avail/size < 5%` | 10m | page |
| `FilesystemInodesExhaustionImminent` / `…WillFillIn4h` / `…AlmostFull` | Same three patterns on `files_free/files` | 2m / 15m / 10m | page |
| `FilesystemReadOnly` / `FilesystemStatsMissing` | `readonly == 1` on mounts NGINX must write / `device_error == 1` | 1m / 10m | page / ticket |
| `DeletedFilesHoldingSpace` | `filesystem_deleted_open_bytes > 1 GiB` | 30m | ticket |
| `DeletedOpenCollectorBroken` | Textfile stale, missing for a scraped node, or unparsable | 5m | ticket |

- **`avail`, not `free`:** `avail` is what `www-data` can use. The root reserve doesn't help NGINX.
- **Several horizons, like multi-window burn rates.** The percentage gates keep normal churn quiet, but they also delay a flood that starts from a half-empty disk: at 2 GiB/min from 32 GiB free, ENOSPC arrives at minute 16, before any gated rule could fire. The ungated ETA rule pages by minute 3 (unit-tested). The 1 h and 4 h rules page on moderate and steady growth; the 24 h rule is a ticket.
- **Trend alerts are blind to the brief's scenario.** A flat 99% has zero slope, so `predict_linear` never fires; the unit test "flat line at 99 percent" proves it. The 5% floor is the only static threshold and sits where action is mandatory, not at an arbitrary 80/90%.
- **Deleted-open bytes** come from [`scripts/deleted-open-files.sh`](scripts/deleted-open-files.sh), because node_exporter has no such metric. The collector leaves out NGINX's per-request buffer files (its `EXCLUDE_RE` must match every `*_temp_path`), and the alert reports aggregate pressure; the holder is identified with `lsof` before acting. Write the textfile directory to tmpfs so the metric keeps updating while the disk is full; the broken-collector alert covers stale, missing and unparsable output.
- **NGINX-side signals:** log `$request_completion` and watch the share of `2xx` with an empty value against its baseline (truncated responses show up there, not in status codes). Send a `crit` copy of the error log to journald (`error_log syslog:server=unix:/dev/log crit`): journald runs as root and keeps logging inside its own footprint, so ENOSPC errors are still recorded and shipped when `error.log` cannot be written. Add the large-object synthetic from §1.2.
- The space rules ignore read-only mounts; `FilesystemReadOnly` covers an ext4 error remount on the mounts NGINX writes to, and an intentional read-only bind mount does not page (both unit-tested). An `up == 0` alert is assumed.

Install the collector with the systemd service and timer in its header, and run node_exporter with `--collector.textfile.directory=/run/node-exporter/textfile`.

### 5.2 Guardrails

**Rotation that fails loudly and responds to size.** Replace the packaged `/etc/logrotate.d/nginx`; don't add a second file next to it, or logrotate rejects it as a duplicate log entry. Install it root-owned with mode 0644 (`install -o root -g root -m 0644`), because logrotate silently skips a group- or world-writable config. It is a dpkg conffile, so own it in config management. unattended-upgrades holds back a package whose update would raise a conffile prompt.

```
/var/log/nginx/*.log {
    hourly
    maxsize 1G
    rotate 48
    maxage 3
    missingok
    notifempty
    compress
    delaycompress
    create 0640 www-data adm
    sharedscripts
    postrotate
        systemctl kill --signal=USR1 --kill-whom=main nginx.service
    endscript
}
```

```ini
# /etc/systemd/system/logrotate.timer.d/frequency.conf
[Timer]
OnCalendar=
OnCalendar=*:0/15
AccuracySec=1m
```

**journald cap:**

```ini
# /etc/systemd/journald.conf.d/size.conf
[Journal]
SystemMaxUse=1G
```

**NGINX** (replaces the default `access_log`/`error_log` lines in `nginx.conf`):

```nginx
log_format edge '$remote_addr [$time_iso8601] "$request" $status $body_bytes_sent '
                'rt=$request_time urt=$upstream_response_time done=$request_completion';
map $request_uri $loggable { ~^/healthz 0; default 1; }
access_log /var/log/nginx/access.log edge if=$loggable;
error_log  /var/log/nginx/error.log warn;
error_log  syslog:server=unix:/dev/log,tag=nginx crit;

proxy_cache_path /var/cache/nginx/edge levels=1:2 keys_zone=edge:100m
                 max_size=20g min_free=5g inactive=7d use_temp_path=off;
proxy_max_temp_file_size 256m;   # per request, uncached only: cache fills are not capped by this
client_max_body_size 10m;        # raise per location, never globally to 0
```

(Ubuntu's package does not create `/var/cache/nginx`; NGINX creates only the last path component.)

**Layout and process:**

- Put `/var/log` and the cache/temp paths on their own volumes, so a log or cache bug degrades logging or caching rather than the OS.
- Leave unallocated VG space as break-glass capacity.
- Ship logs off-box and keep local retention short.
- CI for the NGINX config: `nginx -t`, plus a lint that rejects `debug` and any `proxy_cache_path` without `max_size`. `diagnose-disk.sh` runs the same checks on the host.

## 6. Runbook: NGINX LB disk usage critical

1. **Scope (2 min):** `df -hT /`, `df -i /`, time-to-full (§1.2), ENOSPC lines, edge 5xx and the large-object synthetic. Declare severity and open the incident channel.
2. **Mitigate (≤10 min):** steps 1-5 of §1.3, in order, until `avail` is above 10% and no new ENOSPC lines appear. Step 6 only if you are seconds from full.
3. **Diagnose:** run `diagnose-disk.sh` streamed off-box, read its Findings, and match them against §3.2.
4. **Fix the cause** with a reviewed change: config from git, `nginx -t`, `systemctl reload nginx`, and the permanent fix from §3.2.
5. **Verify:** usage back to a sawtooth well under 70%, deleted-open bytes near 0, alerts resolved, synthetic green for 1 h.
6. **Follow up:** postmortem with owners and dates for off-box logs, volume layout, and alert coverage (including why a flat 99% line did not page).

## 7. Files and verification

| File | Purpose | Validated with |
|---|---|---|
| [`scripts/diagnose-disk.sh`](scripts/diagnose-disk.sh) | One-pass, read-only triage with a Findings summary | shellcheck v0.10.0 clean. Run in `ubuntu:24.04` against a full ext4 loop filesystem seeded with faults (multi-line debug `error_log`, uncapped cache, uncovered and `$host` vhost logs, duplicate and group-writable logrotate configs, orphaned cache dir, `client_body_in_file_only on`, a 3 GiB deleted-open file, fs smaller than its device, ENOSPC). All were reported. No false positives on a capped multi-line cache, a `fastcgi_cache_path`, a commented directive, or a linked file named `* (deleted)` |
| [`scripts/deleted-open-files.sh`](scripts/deleted-open-files.sh) | Textfile collector: deleted-open bytes and count per filesystem | shellcheck clean; counts an inode held twice once; ignores linked files and NGINX buffer files; mount points with spaces; output passes `promtool check metrics` |
| [`monitoring/disk-alerts.rules.yml`](monitoring/disk-alerts.rules.yml), [`disk-alerts.test.yml`](monitoring/disk-alerts.test.yml) | Alert rules and unit tests | `promtool check rules` and `promtool test rules` (v3.5.0) pass, including flood-from-half-full, flat 99%, read-only remount and missing collector; a deliberately wrong expectation fails |

Behaviour marked "verified" was reproduced in `ubuntu:24.04` (nginx 1.24.0-2ubuntu7, logrotate 3.21.0, systemd 255):

- ENOSPC for `www-data` while root still writes, and the resulting NGINX failure modes.
- `tune2fs -m` taking effect online.
- Buffer files unlinked at creation; `client_body_in_file_only on` keeping body files.
- `rm` of a held log versus USR1 and `/proc` truncation.
- `nginx -s reopen` failing on a broken config while `kill -USR1` works.
- `O_APPEND` log fds.
- Removing `/var/lib/nginx/*`.
- logrotate's duplicate-entry and group-writable skips, and its daily timer.
- `lsof +L1 /` without `-a`.
- One-step `mount -o bind,ro`.
- The §5.2 snippets passing `logrotate -d` and `nginx -t`.

Installer LVM sizing was read from the subiquity source at 24.04 release tags. The journald defaults come from the 24.04 `systemd` package's man page.
