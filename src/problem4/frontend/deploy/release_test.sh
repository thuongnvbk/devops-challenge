#!/usr/bin/env bash
# End-to-end test of the SPA release path without AWS.
#
# A fake `aws` keeps S3 in a temp directory (honouring If-None-Match and the
# sha256 checksum), a fake `gh` stands in for attestation verification, and
# a small SPA server serves whatever is live under site/ so the real smoke.sh
# runs against it. Scenarios cover deploys, failed deploys, rollbacks,
# tampered archives and a failed restore, and assert both the exit code and
# which release users are left with.
#
# Usage: release_test.sh <dist-dir>   (a Vite build; needs python3, jq, curl, openssl)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dist="$(cd "${1:?usage: release_test.sh <dist-dir>}" && pwd)"
work="$(mktemp -d)"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

export FAKE_DIR="$work" FAKE_S3="$work/s3"
mkdir -p "$work/bin" "$FAKE_S3/site-bucket/site"

# --- fake aws: a minimal S3 + CloudFront ---------------------------------------
cat >"$work/bin/aws" <<'FAKE'
#!/usr/bin/env python3
import base64, fnmatch, hashlib, json, os, shutil, sys

args = sys.argv[1:]
root = os.environ["FAKE_S3"]
with open(os.path.join(os.environ["FAKE_DIR"], "calls"), "a") as log:
    log.write(" ".join(args) + "\n")

def opt(name, default=None):
    return args[args.index(name) + 1] if name in args else default

def path(bucket, key):
    return os.path.join(root, bucket, key)

def split(uri):
    bucket, _, key = uri[len("s3://"):].partition("/")
    return bucket, key

def b64sha(p):
    return base64.b64encode(hashlib.sha256(open(p, "rb").read()).digest()).decode()

def fail(msg, code=254):
    sys.stderr.write(msg + "\n")
    sys.exit(code)

cmd = " ".join(args[:2])
if cmd == "s3api list-objects-v2":
    bucket, prefix, query = opt("--bucket"), opt("--prefix"), opt("--query", "")
    if query.startswith("length("):
        key = query.split("Key=='")[1].split("'")[0]
        print(1 if os.path.isfile(path(bucket, key)) else 0)
    else:
        sys.exit("fake aws: unsupported query " + query)
elif cmd == "s3api put-object":
    dest, body = path(opt("--bucket"), opt("--key")), opt("--body")
    if os.path.exists(dest) and opt("--if-none-match") == "*":
        fail("An error occurred (PreconditionFailed) when calling the PutObject operation: "
             "At least one of the pre-conditions you specified did not hold")
    if opt("--checksum-sha256") and opt("--checksum-sha256") != b64sha(body):
        fail("An error occurred (BadDigest) when calling the PutObject operation")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copyfile(body, dest)
elif cmd == "s3api head-object":
    src = path(opt("--bucket"), opt("--key"))
    if not os.path.isfile(src):
        fail("An error occurred (404) when calling the HeadObject operation: Not Found")
    print(b64sha(src))
elif cmd == "s3 cp":
    flags = {"--recursive", "--only-show-errors"}
    pos, excludes, i = [], [], 2
    while i < len(args):
        a = args[i]
        if a in flags:
            i += 1
        elif a.startswith("--"):
            if a == "--exclude":
                excludes.append(args[i + 1])
            i += 2
        else:
            pos.append(a)
            i += 1
    src, dst = pos
    if src.startswith("s3://"):
        p = path(*split(src))
        if not os.path.isfile(p):
            fail("fatal error: An error occurred (404) when calling the HeadObject operation", 1)
        if dst == "-":
            sys.stdout.write(open(p).read())
        else:
            shutil.copyfile(p, dst)
    elif "--recursive" in args:
        bucket, prefix = split(dst)
        for d, _, files in os.walk(src):
            for f in files:
                rel = os.path.relpath(os.path.join(d, f), src)
                if any(fnmatch.fnmatch(rel, x) for x in excludes):
                    continue
                out = path(bucket, prefix + rel)
                os.makedirs(os.path.dirname(out), exist_ok=True)
                shutil.copyfile(os.path.join(d, f), out)
    else:
        out = path(*split(dst))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        shutil.copyfile(src, out)
elif cmd == "cloudfront create-invalidation":
    print("I-FAKE")
elif cmd == "cloudfront wait":
    pass
else:
    fail("fake aws: unexpected call: " + " ".join(args), 64)
FAKE

# --- fake gh: attestation verification, deniable per digest ---------------------
cat >"$work/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >>"$FAKE_DIR/calls"
[[ "$1 $2" == "attestation verify" ]] || { echo "fake gh: unexpected $*" >&2; exit 64; }
if [[ -n "${FAKE_GH_DENY:-}" && "$(sha256sum "$3" | cut -d' ' -f1)" == "$FAKE_GH_DENY" ]]; then
  echo "fake gh: no valid attestation" >&2
  exit 1
fi
FAKE
chmod +x "$work/bin/aws" "$work/bin/gh"

# --- SPA server over the fake bucket's site/ prefix ------------------------------
cat >"$work/spa.py" <<'PY'
import functools, http.server, os, sys
root, port = sys.argv[1], int(sys.argv[2])
class SPA(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        name = self.path.split("?")[0].rsplit("/", 1)[-1]
        if "." not in name and self.path != "/":
            self.path = "/index.html"  # CloudFront function: extensionless -> index.html
        return super().send_head()
    def log_message(self, *a):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(SPA, directory=root)).serve_forever()
PY
port=$((20000 + RANDOM % 20000))
python3 -I "$work/spa.py" "$FAKE_S3/site-bucket/site" "$port" &
server_pid=$!

export PATH="$work/bin:$PATH" SITE_BUCKET=site-bucket DISTRIBUTION_ID=E2FAKE AWS_REGION=us-east-1 \
  SIGNER_WORKFLOW=.github/workflows/frontend.yml GITHUB_REPOSITORY=example-org/web-product \
  SITE_URL="http://127.0.0.1:${port}" CHECK_CACHE_HEADERS=false

# --- helpers -------------------------------------------------------------------------
# make_release <sha> <out.tar.gz> [broken|different]
make_release() {
  local sha="$1" out="$2" variant="${3:-}" tree
  tree="$(mktemp -d "$work/tree.XXXX")"
  cp -R "$dist/." "$tree/"
  sed -i -E "s/(<meta name=\"release\" content=\")[^\"]*/\\1${sha}/" "$tree/index.html"
  case "$variant" in
    # References an asset that exists nowhere. (Deleting a real asset would
    # not do: assets are append-only, so earlier releases' copies stay live.)
    broken) sed -i "s|</head>|<script type=\"module\" src=\"/assets/missing-${sha:0:8}.js\"></script></head>|" "$tree/index.html" ;;
    different) echo "# changed" >>"$tree/robots.txt" ;;
  esac
  "$here/../../ci/deterministic-tar.sh" "$tree" "$out"
}
digest_of() { sha256sum "$1" | cut -d' ' -f1; }
live() { sed -n 's/.*<meta name="release" content="\([^"]*\)".*/\1/p' "$FAKE_S3/site-bucket/site/index.html"; }
pass=0
expect() { # expect <name> <exit-code> <live-release> -- <release.sh args...>
  local name="$1" want_rc="$2" want_live="$3" rc=0
  shift 4
  "$here/release.sh" "$@" >"$work/$name.out" 2>&1 || rc=$?
  if [[ "$rc" != "$want_rc" || "$(live)" != "$want_live" ]]; then
    echo "FAIL $name: exit $rc (want $want_rc), live '$(live)' (want '$want_live')" >&2
    cat "$work/$name.out" >&2
    exit 1
  fi
  echo "ok   $name (exit $rc, live ${want_live:0:7})"
  pass=$((pass + 1))
}
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
because() { grep -q -- "$2" "$work/$1.out" || { cat "$work/$1.out" >&2; fail "$1 did not fail because: $2"; }; }

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccc
D=dddddddddddddddddddddddddddddddddddddddd
make_release "$A" "$work/a.tgz"
make_release "$B" "$work/b.tgz"
make_release "$C" "$work/c.tgz" broken
make_release "$D" "$work/d.tgz" broken
make_release "$B" "$work/b-other.tgz" different

# --- scenarios -----------------------------------------------------------------------
expect first-deploy 0 "$A" -- deploy "$work/a.tgz" "$A"

before="$(wc -l <"$work/calls")"
expect deploy-over-previous 0 "$B" -- deploy "$work/b.tgz" "$B"
tail -n +"$((before + 1))" "$work/calls" >"$work/b.calls"
line_of() { { grep -nE -- "$1" "$work/b.calls" || true; } | "$2" -n1 | cut -d: -f1; }
archive="$(line_of "--key releases/$(digest_of "$work/b.tgz").tar.gz" head)"
record="$(line_of "--key releases/${B}.digest" head)"
verified="$(line_of 'gh attestation verify' head)"
write='^s3 cp /[^ ]* s3://site-bucket/site/' # local file -> live site (reads excluded)
first_live="$(line_of "$write" head)"
assets_live="$(line_of "${write}assets/" tail)"
index_live="$(line_of "${write}index.html" tail)"
last_live="$(line_of "$write" tail)"
invalidation="$(line_of 'cloudfront create-invalidation' tail)"
[[ -n "$archive" && -n "$record" && -n "$verified" && -n "$index_live" && -n "$invalidation" ]] ||
  fail "expected archive, record, verification, switch and invalidation calls"
((archive < record)) || fail "commit->digest record written before the archive"
((record < first_live && verified < first_live)) || fail "site changed before the release was recorded and verified"
((assets_live < index_live)) || fail "index.html went live before its assets"
((index_live == last_live)) || fail "something was written to site/ after index.html"
((index_live < invalidation)) || fail "invalidated before index.html was switched"
grep 'cloudfront create-invalidation' "$work/b.calls" | grep -q '/assets/' && fail "invalidation covers hashed assets"
grep 'cloudfront create-invalidation' "$work/b.calls" | grep -q ' /index.html' || fail "index.html not invalidated"
grep -E "${write}assets/" "$work/b.calls" | grep -q immutable || fail "assets not cached as immutable"
grep -E "${write}index.html" "$work/b.calls" | grep -q no-cache || fail "index.html not no-cache"
grep -Eq '(^| )(rm|mv|delete-object|delete-objects)( |$)|--delete' "$work/calls" && fail "something was deleted"
echo "ok   publish order: archive -> record -> verify -> assets -> other files -> index.html -> invalidate"

expect failed-deploy-restores-previous 1 "$B" -- deploy "$work/c.tgz" "$C"
because failed-deploy-restores-previous "smoke: GET /assets/missing-"

FAKE_GH_DENY="$(digest_of "$work/b.tgz")" \
  expect restore-also-fails-needs-human 2 "$D" -- deploy "$work/d.tgz" "$D"
because restore-also-fails-needs-human "no valid attestation"

expect manual-rollback 0 "$A" -- rollback "$A"

expect rollback-to-unpublished-refused 1 "$A" -- rollback eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
because rollback-to-unpublished-refused "was never published"

expect same-sha-different-bytes-refused 1 "$A" -- deploy "$work/b-other.tgz" "$B"
because same-sha-different-bytes-refused "already exists with different content"
[[ "$(tr -d '[:space:]' <"$FAKE_S3/site-bucket/releases/${B}.digest")" == "$(digest_of "$work/b.tgz")" ]] ||
  fail "commit -> digest record for B was overwritten"

cp "$work/c.tgz" "$FAKE_S3/site-bucket/releases/$(digest_of "$work/b.tgz").tar.gz"
expect tampered-archive-refused 1 "$A" -- rollback "$B"
because tampered-archive-refused "does not match digest"

echo "$pass release scenarios passed"
