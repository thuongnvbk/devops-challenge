# Problem 4: Ship It Twice

Two GitHub Actions pipelines, one per app. Each builds an artifact once, attests it, and promotes the same bytes from staging to production. The backend is an HTTP API on EC2 behind an ALB, rolled out by Auto Scaling instance refresh. The frontend is an SPA on S3 behind CloudFront, published in an order that never leaves a broken window. Both roll back automatically, and both have a one-click manual rollback that uses the same code path as a deploy.

## 1. What "production ready" means here

Each item can be checked. Every workflow feature traces to one of them (section 3). Anything not on this list is out of scope (section 7).

| # | Requirement | Mechanism | Where |
|---|---|---|---|
| R1 | **Gated.** Nothing is built for release unless lint, unit tests and a dependency vulnerability scan pass on that exact commit. | `ci` job on every PR and on main. Go: gofmt, vet, staticcheck, `test -race`, govulncheck. SPA: `tsc --strict`, vitest, `npm audit`, `npm audit signatures`. | `backend.yml`, `frontend.yml` |
| R2 | **Built once, promoted by digest.** One reproducible artifact per commit. Staging and production get identical bytes, checked against the build-time sha256 before every deploy and rollback. | Deterministic tarball; its sha256 is passed as a job output and re-verified. Both apps store artifacts in S3 create-once (`If-None-Match`), and a commit can never be re-pointed at other bytes. | `ci/deterministic-tar.sh`, `ci/s3-put-once.sh`, `*-deploy.yml`, `rollout.sh publish`, `frontend/deploy/publish.sh` |
| R3 | **Provenance-verified.** Deploys, and SPA activations including rollbacks, reject an artifact unless it has a signed SLSA provenance attestation from this repo's build workflow, built from `main` on a GitHub-hosted runner. | `actions/attest` (provenance + SBOM), then `gh attestation verify --signer-workflow ... --source-ref refs/heads/main --deny-self-hosted-runners`. | `attest` jobs, `ci/verify-artifact.sh` |
| R4 | **No standing credentials.** There are no AWS keys or repository secrets. Each job gets 30-60 min credentials via OIDC, for a role that only its app's environment can assume and that can do only that app's deploy. | Per-app, per-environment roles. Trust is `StringEquals` on `aud` and on `sub = repo:...:environment:<app>-<stage>`. Policies are scoped to one ASG, one launch template, one bucket prefix, one distribution. | `infra/aws-deploy-roles/` |
| R5 | **Least privilege in CI.** Workflow default `permissions: {}`. Each job requests only what it uses. Every action is pinned to a full commit SHA. Untrusted input never reaches a shell unescaped. | Per-job `permissions`; `persist-credentials: false`; inputs passed via `env:` and regex-validated; no `pull_request_target`. Only the `attest` job holds `attestations: write`, and it runs no repository code. Deploys accept only attestations whose signer is the build workflow (`backend.yml`/`frontend.yml`), so a deploy job's own OIDC token cannot produce an acceptable one. | all workflows |
| R6 | **Controlled promotion.** Only `main` deploys. Staging is automatic and must pass before production. Production needs a second person's approval. | Four GitHub environments, each restricted to `main`. Production has reviewers, `prevent_self_review`, and no admin bypass. | `infra/github-environments/` |
| R7 | **Serialized and forward-only.** At most one deploy or rollback per environment at a time, and the automatic path never replaces a newer release with an older one. | Job-level `concurrency: deploy-<env>`, shared with the rollback workflows, never cancelled. `ci/forward-only.sh` compares the deployed and candidate commits through the GitHub compare API. | `*-deploy.yml`, `*-rollback.yml` |
| R8 | **No downtime.** Backend capacity never drops below desired during a deploy. The SPA never serves an `index.html` whose assets are not yet uploaded, and open tabs keep working. | Instance refresh with min 100% / max 200% healthy (launch before terminate) behind ELB health checks. SPA order: assets, then other files, then `index.html` last. Assets are never deleted. | `rollout.sh`, `frontend/deploy/activate.sh` |
| R9 | **Self-healing deploys.** A release that fails health checks, trips an alarm, fails the smoke test, or stalls is rolled back without a human, the restored release is smoke-tested too, and the job fails. Exit 2 means a human is needed. | Backend: `AutoRollback` + `AlarmSpecification` + `BakeTime`, smoke test during bake, timeout. Where AWS cannot roll back (bake window missed, rollback rejected, refresh `Failed`/`Cancelled`), a recovery refresh restores the previous version. Frontend: `release.sh` restores and re-verifies the previous release on any failure. | `rollout.sh`, `release.sh` |
| R10 | **Fast manual rollback, even mid-incident.** Any retained release can be restored with one dispatch, without a rebuild, through the deploy's own code path. This works while alarms are firing and while an earlier refresh is stuck. | Backend: a recovery-mode refresh to the release's launch template version (minutes). It has no alarm gate and no auto rollback, but stays health- and smoke-gated. A still-active refresh is first cancelled (never rolled back), then replaced. Frontend: re-verify the archived artifact, activate it (seconds), and undo it like a failed deploy if it fails. | rollback workflows |
| R11 | **Failure paths are tested.** The rollback logic of both apps runs as automated tests in CI. | 20 refresh scenarios (incl. recovery takeover and the cancel-before-id-recorded race) plus `current`/`publish`/`find`/`on-cancel`, against a fake `aws` and the real API binary. 8 SPA release scenarios against a fake S3, an SPA server and the real `smoke.sh`. | `rollout_test.sh`, `release_test.sh` |

## 2. Assumptions

- **`src/problem4/` is the product repository's root.** GitHub only runs workflows from the root `.github/workflows/`. To use this, make `src/problem4/` its own repository, or move `.github/` to this repo's root and prefix every path with `src/problem4/`. That covers `paths:` filters, `working-directory`, script paths, the `--signer-workflow` path, and Dependabot directories. Nothing else changes.
- **The apps.** No app code was provided, so I added the smallest real ones. That way the CI half genuinely runs, and the smoke tests have something to assert against:
  - The backend is Go, stdlib only. It produces a static binary, needs no runtime on the host, builds reproducibly, and has zero third-party dependencies.
  - The SPA is Vite + TypeScript. Vite content-hashes every asset by default, which is what the caching strategy relies on.
  - Both expose their release (git SHA): `/api/version` for the backend, `<meta name="release">` in `index.html` for the SPA. Smoke tests prove the new build is what users get, not just that something answers 200.
- **Backend infrastructure (owned by an infra stack, not here):**
  - An ASG of 2 or more instances behind an ALB with ELB health checks on `/healthz`.
  - The ASG pins a **numbered** launch template version; AWS rollback is unavailable with `$Latest`/`$Default` or an SSM AMI alias. The infra stack sets `ignore_changes` on that field, because the pipeline owns it.
  - An Amazon Linux 2023 AMI with the AWS CLI and systemd, and IMDSv2.
  - An instance profile that can read `s3://<release-bucket>/backend/*`.
  - Headroom for 2x desired capacity during a deploy.
  - At least one CloudWatch alarm per environment, ideally target 5xx rate and `UnHealthyHostCount`, with missing data treated as `notBreaching`. Instance refresh refuses alarms in `INSUFFICIENT_DATA`. The pipeline refuses to deploy without alarms.
  - If the backend is a single hand-built instance today, putting it in an ASG is the prerequisite. No deploy can avoid downtime on one host.
- **Frontend infrastructure:**
  - A private bucket served only through CloudFront OAC, with origin path `/site`. `releases/` is never served.
  - The cache policy honours origin `Cache-Control` (min TTL 0).
  - A viewer-request function rewrites extensionless paths to `/index.html`, so one cache key covers every deep link.
  - `/api/*` routes to the ALB with caching disabled. Same origin means the bundle contains no environment-specific URL, and that is what makes build-once possible for an SPA. If the API had to live on another origin, I would serve a per-environment `config.json` (no-cache) rather than rebuild per environment.
- **Accounts and GitHub plan:**
  - Staging and production are separate AWS accounts, with one OIDC provider each.
  - The repository is public or on GitHub Enterprise Cloud; artifact attestations need one of the two.
  - Repositories created after 2026-07-15 send the immutable OIDC subject `repo:OWNER@ID/REPO@ID:...`. The Terraform uses that format when the IDs are set (recommended, since it also defeats name re-registration) and the legacy form otherwise. GitHub documents the immutable form for `ref:` subjects; the `environment:` variant follows the same pattern but is extrapolated. Confirm it once with a job that prints its `sub` claim.
- **Release identity and cadence:** the release ID is the full commit SHA. Every merge to `main` is a release candidate. Delivery is continuous to staging, with approval for production.

## 3. How the pipelines work

```
PR ──────► ci ─┐                                      (no deploy, no signing permissions)
main ────► ci ─┴► attest ─► staging ─► [approval] ─► production
                  (sign)    (auto)                   (same artifact, same digest)
```

Path filters (`backend/**` or `frontend/**`, plus `ci/**` and the app's own workflow files) mean each app builds only when its own code changes. Superseded PR runs are cancelled; runs on `main` are not.

### Backend (`backend.yml` -> `backend-deploy.yml`)

1. **ci** (R1, R2, R11):
   - lint (gofmt, vet, staticcheck), race-enabled unit tests, the rollout state-machine tests, and govulncheck (reports only vulnerabilities reachable from our code).
   - `package.sh` builds a static binary (`-trimpath`, no build ID, release stamped in) and tars it reproducibly with its systemd unit.
   - Syft produces an SPDX SBOM from the Go build info embedded in the binary.
   - `GOTOOLCHAIN=local` makes every `go` invocation use the toolchain pinned in `go.mod`.
2. **attest** (R3, main only): verifies the digest, then signs SLSA provenance and the SBOM. This is the only job with `attestations: write`, and it runs no repository code: only `sha256sum` and pinned actions.
3. **deploy**, one per environment (R2-R4, R7-R9):
   - verify the digest and attestation
   - assume the environment's role via OIDC
   - run the forward-only guard
   - `rollout.sh publish`:
     - upload the artifact with S3 `If-None-Match: *` (write-once) and a server-side sha256 check
     - create a launch template version, described as the commit SHA, that copies the running version and replaces only user data. That user data pins the artifact's S3 URI and sha256.
   - `rollout.sh refresh`: instance refresh with min 100 / max 200, `SkipMatching`, `AutoRollback`, the alarms, and `BakeTime` 300s.
     - New instances boot, install exactly those bytes (`bootstrap.sh` checks the sha256), and start a sandboxed systemd service. Old instances keep serving until the replacements pass ELB health checks.
     - During the bake window, `smoke.sh` sends 20 requests through the ALB, each on a fresh connection, and every one must report the new release. A mixed or stale fleet fails.
     - On failure the script requests rollback, then smoke-tests the restored release. If AWS cannot roll back (bake window missed, request rejected, or the refresh ended `Failed`/`Cancelled` with instances possibly mixed), it starts a **recovery** refresh back onto the previous version.
   - Recovery mode (also used by `backend-rollback`) drops the alarm gate and auto rollback. AWS refuses to start a refresh while a listed alarm is in `ALARM`, which is exactly the state an incident is in, and auto-rolling back a recovery would bring back the broken release. Launch-before-terminate health checks, the timeout and the smoke test still apply.

**Why instance refresh, and not the alternatives:**

| Option | Verdict |
|---|---|
| SSM Run Command (in place) | Rejected. I would have to rebuild batching, ALB draining, health gating, and fleet-wide rollback in shell. A failure leaves half-upgraded hosts, and rollback restores only the binary. |
| CodeDeploy in-place | A sound choice for hosts that can't be replaced quickly: native ALB integration, alarm-based rollback. Rejected because it still mutates long-lived hosts (drift, partial installs), needs an agent baked into every AMI, and adds appspec, lifecycle hooks, and another service and IAM surface. |
| **ASG instance refresh (chosen)** | Immutable hosts with no agent, no SSH and no inbound access. Old capacity serves until new capacity is healthy. AWS runs the state machine (health gating, alarm watch, bake, auto rollback), so it keeps protecting the fleet even if the runner dies. A release is a launch template version, so rollback restores the AMI and instance settings too, not just the binary. Cost: deploys take minutes (instance boot), and it needs 2x capacity headroom. |

### Frontend (`frontend.yml` -> `frontend-deploy.yml`)

1. **ci** (R1, R2, R11):
   - `npm ci --ignore-scripts` (exact lockfile; dependency install scripts never run)
   - `npm audit signatures` (registry signatures and provenance)
   - `tsc --strict`, vitest
   - `npm audit --omit=dev --audit-level=high`. This gates on code that ships to browsers; Dependabot keeps build tooling current instead of a dev-server advisory blocking releases.
   - `vite build` with `VITE_RELEASE=<sha>`, the release-path tests, a reproducible tarball, and an SBOM.
2. **attest**: same as the backend.
3. **deploy**:
   - verify the artifact and guard against going backwards. `release.sh` then records the live release as `previous` and runs:
   - `publish.sh` stores the attested tarball create-once as `releases/<digest>.tar.gz`, then writes `releases/<sha>.digest` create-once, **last**. An interrupted publish leaves no record a rollback could pick up.
   - `activate.sh` resolves the commit to its digest and downloads that tarball. It re-checks the sha256 and the provenance attestation and unpacks locally; only then does anything under `site/` change, in this order:

| Order | Objects | Cache-Control |
|---|---|---|
| 1 | `site/assets/*` (content-hashed) | `public, max-age=31536000, immutable`, never invalidated, never deleted |
| 2 | other public files (`robots.txt`, ...) | `public, max-age=300`, invalidated |
| 3 | `site/index.html`, **last**: the single switch | `no-cache`, invalidated |

   - Invalidation covers `/` and the non-hashed paths only, then waits for completion.
   - `smoke.sh` then checks through CloudFront that `/` and a deep link both serve the new release, and that every referenced asset resolves with `immutable` caching. On any failure, `release.sh` re-activates `previous`, smoke-tests it, and fails.

Deploys and manual rollbacks both go through `release.sh` and `activate.sh`, so every deploy also exercises the rollback path. The frontend deploy role has no `s3:DeleteObject`, so no deploy or rollback can remove a release.

## 4. What happens when something fails mid-deploy

**Backend**

| Fails at | Live traffic | What happens |
|---|---|---|
| Digest or attestation check | untouched | Job fails before AWS is touched. |
| Artifact upload or launch template creation | untouched | Re-run is idempotent: the write-once object and the launch template version are reused, and an artifact with different bytes for the same SHA is refused. |
| New instances fail bootstrap or health checks | old instances serve; the ALB never routes to unhealthy targets | The `UnHealthyHostCount` alarm triggers AWS auto rollback. Otherwise `rollout.sh` times out at 20 min and requests rollback. As a last resort, AWS's own 1-hour retry fails and auto-rolls back. |
| Healthy but erroring (5xx alarm) during refresh or bake | mixed, briefly | AWS auto rollback replaces the new instances with the previous version. |
| Smoke test fails during bake | new release | `rollback-instance-refresh`, then the restored release is smoke-tested. If AWS rejects it, or the bake window was missed, a recovery refresh restores the previous version. The job fails either way. |
| Refresh ends `Failed` or `Cancelled` (e.g. cancelled in the console) | possibly mixed | Not treated as a rollback: a recovery refresh restores the previous version and smoke-tests it. |
| An alarm is already firing when a deploy starts | untouched | AWS refuses the guarded refresh, so a new release never ships into an incident. Recovery is unaffected. |
| Runner dies or job is cancelled | whatever AWS is doing | The refresh, its alarms and its auto rollback keep running in AWS. The cancel step rolls back only the guarded refresh this job started, and only while it is still the active one. It never touches a recovery, or a request whose id was not yet recorded (intent is written before the AWS call). Any new refresh is rejected while one is active, so nothing overlaps. |
| Rollback or restore fails (`RollbackFailed`, restored release fails smoke, recovery times out) | possibly mixed | Exit code 2 and a loud error. A human runs `backend-rollback`, which works while alarms fire and takes over a refresh that is still running. |

**Frontend**

| Fails at | Live traffic | What happens |
|---|---|---|
| Storing the tarball or the commit record | untouched | No record yet, so nothing can activate it. Re-runs are idempotent; other bytes under the same SHA are refused. |
| Archive missing, tampered with, or unattested | untouched | `activate.sh` refuses before touching `site/`. |
| After some assets went live | untouched (the new files aren't referenced yet) | `previous` is re-activated, a no-op for users, and the job fails. |
| Between the `index.html` switch and invalidation completing | old or new, both complete, because both asset sets exist | `previous` is restored and verified; the job fails. |
| Smoke test fails | new release | `previous` is re-activated, which takes seconds, and smoke-tested again (exit 1). |
| Restore fails too, or the first-ever deploy fails | target | Exit 2: a human picks a release for `frontend-rollback`. |
| Job cancelled mid-activate | old or new, both complete | No corruption is possible; re-run or roll back. |

Open tabs on an older `index.html` keep loading their lazy chunks, because assets are append-only.

## 5. Manual rollback and operations

- Run `backend-rollback` or `frontend-rollback` with an environment and a full SHA. Each deploy's job summary prints the release it replaced, ready to paste.
- Rollbacks share the deploy concurrency group, so a rollback and a deploy never race.
- A production rollback needs the same second-person approval as a deploy. That is deliberate: it carries the same blast radius. If on-call must be able to roll back alone, add a dedicated rollback environment and role scoped to "existing versions only".
- The backend rollback restores the whole previous launch template version: artifact, AMI and instance settings. It refuses if that release's artifact is missing or no longer matches its pinned sha256, and runs in recovery mode, so firing alarms cannot block it. Pick a release from a deploy summary: a release that never passed its own smoke test gets no alarm safety net here.
- **Runbook, when a deploy or restore exits 2:**
  1. Read the job summary for the last good release.
  2. Dispatch `backend-rollback` with it. If a refresh is still active (for example a recovery that timed out and was left running), the rollback cancels it, waits for `Cancelled`, then starts its own recovery. Cancelling keeps the instances already replaced; it never rolls back, so it cannot bring the broken release back.
  3. If that also exits 2, the fault is below the release (AMI, capacity, dependencies). Escalate with the refresh's `StatusReason` from the log.
- The frontend rollback re-verifies the archived artifact's digest and provenance. If the target fails its smoke test, it puts back what was live, exactly like a failed deploy.
- If a production deploy is sitting in "waiting for approval", reject it before dispatching a rollback, so the rollback is not queued behind it in the same concurrency group.

## 6. Local validation (all passing)

| Check | Command | Result |
|---|---|---|
| Workflow lint (with embedded shellcheck of `run:` blocks) | `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7 -color`, on a copy of `src/problem4` with `git init` so it is the project root | 6 workflows, 0 errors |
| Scripts | `docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.10.0 ci/*.sh backend/deploy/*.sh frontend/deploy/*.sh` | clean |
| Terraform | `terraform fmt -check -recursive`, then `init -backend=false` and `validate` in both modules | valid (aws 6.71.0, github 6.13.0; lock files committed) |
| Backend | `gofmt -l`, `go vet`, `go test -race`, `staticcheck@v0.8.2`, `govulncheck@v1.9.0` on Go 1.27.3 | pass; no vulnerabilities |
| Backend rollout | `backend/deploy/rollout_test.sh` | 20 refresh scenarios (guarded, recovery, takeover, cancel race) plus `current`, `publish`, `find` and `on-cancel` |
| Frontend | `npm ci --ignore-scripts`, `npm audit signatures`, `npm run typecheck`, `npm test`, `npm audit` | 37 packages verified, 10 tests pass, 0 vulnerabilities |
| SPA release path | `frontend/deploy/release_test.sh dist` | 8 scenarios (deploy, failed deploy, failed restore, rollback, unpublished, same-SHA-other-bytes, tampered archive) plus upload order |
| Mutation checks | reintroduce each defect fixed in review on a scratch copy | caught: text-paginated `find`, `Failed`/`Cancelled` read as rolled back, alarm-gated recovery, cancel rolling back a recovery, API error read as "nothing deployed", no restore, skipped digest check, overwritable records, assets after `index.html` |
| Reproducibility | build each artifact twice, compare sha256 | identical for both apps |
| Smoke tests | against the real API binary and `vite preview` | pass on the right release, fail on the wrong one, flag missing `immutable` headers |

The AWS half cannot run without an account. Every AWS call is real CLI syntax, written against current AWS docs. I couldn't verify one thing: whether `StartInstanceRefresh` with alarms checks the caller's `cloudwatch:DescribeAlarms`. If the first staging deploy says so, grant it read-only, scoped to those alarm ARNs.

## 7. Deliberately left out

- **The infrastructure itself** (VPC, ALB, ASG, CloudFront, buckets, alarms). Its contract is in section 2. The Terraform here covers only what the pipeline owns: the deploy identities and the environment protection rules.
- **Canary or traffic-weighted releases.** Launch-before-terminate plus alarms plus bake is proportionate at this scale. `CheckpointPercentages` or ALB weighted target groups are the next step if error budgets demand it.
- **End-to-end browser tests, load tests, DAST.** Valuable, but they are product test suites, not pipeline structure. They would slot in as a staging gate between `staging` and `production`.
- **Database migrations, runtime config and secrets.** The sample API is stateless and has no config. A real one needs expand/contract migrations decoupled from deploys, and secrets read at boot from SSM or Secrets Manager by the instance role, never baked into the artifact.
- **Retention jobs.** Unreferenced SPA assets, old `releases/` and `backend/` objects, and launch template versions (capped at 10,000) accumulate. S3 lifecycle rules and a periodic pruning job belong to the infra stack.
- **Required status checks with path filters.** A path-filtered workflow that doesn't run never reports, so making `ci` a required check would block unrelated PRs. In a real repo, add an always-running aggregate job and require that instead.
- **Storage-enforced immutability.** Create-once is enforced by the scripts (`If-None-Match`), not by the bucket. A compromised deploy job could still overwrite a record with a plain PUT. For the SPA that yields a refused rollback, not wrong bytes: activation re-checks digest, provenance and the release stamp. For the backend, the digest pinned in the launch template is checked before every refresh and again by every booting instance. Closing even the denial case needs a bucket policy that denies `s3:PutObject` on `releases/*` and `backend/*` without `s3:if-none-match`. Object Lock alone does not do it: it protects old versions, but a plain PUT still creates a new current version that unpinned reads resolve to. Backend rollback also doesn't re-run `gh attestation verify`; it relies on the digest pinned at publish.
- **Stronger OIDC binding.** A custom subject template that adds `job_workflow_ref` would tie each role to the deploy workflow file itself, not just the environment. It is worth adding once the environment model has settled.
- **Runner hardening** (egress allow-listing such as harden-runner), self-hosted runners, ESLint (strict `tsc` is the static gate for this code size), chat notifications (GitHub deployment history and job summaries cover it), and multi-region.

## Files

```
.github/workflows/backend.yml           PR + main pipeline: ci, attest, staging, production
.github/workflows/backend-deploy.yml    reusable deploy to one environment
.github/workflows/backend-rollback.yml  manual rollback
.github/workflows/frontend*.yml         same three for the SPA
.github/dependabot.yml                  actions, gomod, npm, terraform; 7-day cooldown
backend/                                Go API, tests, deploy/ (package, bootstrap, rollout, smoke, tests, systemd unit)
frontend/                               Vite SPA, tests, deploy/ (release, publish, activate, current, smoke, tests)
ci/                                     deterministic tar, create-once upload, artifact verification, forward-only guard
infra/aws-deploy-roles/                 OIDC provider + per-app deploy roles, applied per account
infra/github-environments/              environments, protection rules, variables
```
