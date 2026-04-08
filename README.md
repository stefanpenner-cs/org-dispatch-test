# GitHub Actions Dispatch Queue Limit Testing

Empirical testing of GitHub's dispatch queue limits, rate limits, and failure behaviors. Tested 2026-04-07/08 against the [stefanpenner-cs](https://github.com/stefanpenner-cs) org.

## Summary

| Finding | Result |
|---------|--------|
| Secondary rate limit | Explicit **HTTP 403** at ~180 accepted/burst. Zero silent drops. |
| Queue limit | **~50,000 queued jobs.** API returns 204, run is created but **instantly fails** (`conclusion: failure`, 0 jobs). |
| Limit counts runs or jobs? | **Jobs.** 50k single-job runs and ~183 matrix runs (×256 jobs) both hit the same ceiling. |
| Blast radius of full queue | **Entire org.** All repos in the org fail, not just the one with the full queue. |
| Run ID from dispatch? | `workflow_dispatch`: **yes**, with `return_run_details` param ([since Feb 2026](https://github.blog/changelog/2026-02-19-workflow-dispatch-api-now-returns-run-ids/)). `repository_dispatch`: **no**, still returns empty 204. |
| Detect dropped dispatches? | **Yes** — after the fact. Dropped runs show `conclusion: failure` with 0 jobs. Query `?status=completed&conclusion=failure` and filter for `jobs.total_count == 0`. |
| Push events bypass rate limit? | **Yes.** ~40 branches/s, up to ~4010 per push. But still hit the 50k job queue limit. |
| Secondary rate limit per-token? | **No.** Appears shared across tokens on same org/IP. 11 tokens performed same as 1. |
| 500/10s workflow enqueue limit? | **Not exercised.** The secondary rate limit (~180/burst) always fired first. Both limits likely exist, but we couldn't reach the 500/10s limit from a single IP/org. |

## Setup

- **Org:** [stefanpenner-cs](https://github.com/stefanpenner-cs)
- **Repos:**
  - `org-dispatch-test` — primary test repo (single-job workflows)
  - `dispatch-matrix-test` — 256-job matrix workflow for run-vs-job counting
  - `dispatch-test-2` — cross-repo verification
- **Runner:** Org-level self-hosted runner on macOS (ARM64), controllable via `runner/start.sh` and `runner/stop.sh` to gate queue draining
- **Tokens:** 1 PAT + 10 GitHub App installation tokens (independent primary rate limits of 5,000/hr each)
- **Dispatch methods:**
  - `repository_dispatch` via REST API (`POST /repos/{owner}/{repo}/dispatches`)
  - Push events (branch creation) to bypass API secondary rate limit
  - 256-job matrix workflows to test run-vs-job counting

## Findings

### 1. Secondary rate limit (~180 per burst)

**Tested 2026-04-07.** Runner stopped so all accepted dispatches queue without draining.

| Test | Dispatches sent | Parallelism | Accepted (204) | Rejected (403) | Duration | Silent drops |
|------|----------------|-------------|----------------|----------------|----------|--------------|
| B1 | 400 | 50 | 183 | 217 | ~3s | 0 |
| B2 | 500 | 50 | 182 | 318 | ~4s | 0 |
| B3 | 600 | 100 | 181 | 419 | ~3s | 0 |
| B4 | 1000 | 100 | 181 | 819 | ~4s | 0 |

**Total: 729 dispatches accepted, 729 workflow runs created. Zero silent drops.**

The secondary (abuse) rate limit fires at ~180 accepted dispatches per burst, returning HTTP 403 with `retry-after: 60`. This fired before we could reach the documented 500/10s workflow enqueue limit. Both limits likely exist independently, but we could not exercise the 500/10s limit from a single IP/org — the secondary rate limit (which appears to be per-IP or per-org) always intervened first.

Key details:
- **HTTP 403, not 429.** The 403 includes `retry-after: 60` and **lacks the `x-ratelimit-*` headers** present on 204 responses — confirming this is the secondary (abuse) rate limit, not the primary.
- **The ~180 cap is consistent** regardless of dispatch count (400–1000) or parallelism (50–100).
- **Resets in ~10–15 seconds in practice**, despite the `retry-after: 60` header.
- **Appears to be per-IP or per-org, not per-token.** When we ran 11 tokens in parallel bursts, each token still only landed 0–1 per burst — the same throughput as a single token. This suggests the secondary rate limit is shared across all tokens originating from the same source.

<details>
<summary>HTTP 204 response headers (successful dispatch)</summary>

```
HTTP/2 204
date: Tue, 07 Apr 2026 19:59:41 GMT
x-oauth-scopes: admin:org, admin:public_key, gist, repo
x-accepted-oauth-scopes:
x-oauth-client-id: 178c6fc778ccc68e1d6a
x-github-media-type: github.v3; format=json
x-github-api-version-selected: 2022-11-28
x-ratelimit-limit: 5000
x-ratelimit-remaining: 4005
x-ratelimit-reset: 1775593261
x-ratelimit-used: 995
x-ratelimit-resource: core
access-control-expose-headers: ETag, Link, Location, Retry-After, ...
access-control-allow-origin: *
strict-transport-security: max-age=31536000; includeSubdomains; preload
x-frame-options: deny
x-content-type-options: nosniff
x-xss-protection: 0
referrer-policy: origin-when-cross-origin, strict-origin-when-cross-origin
content-security-policy: default-src 'none'
vary: Accept-Encoding, Accept, X-Requested-With
x-github-request-id: D2FD:22199:1F504A9:7C8CEDD:69D5622D
server: github.com
```

**Response body:** *(empty — 204 No Content)*

</details>

<details>
<summary>HTTP 403 response headers (secondary rate limit exceeded)</summary>

```
HTTP/2 403
date: Tue, 07 Apr 2026 19:57:11 GMT
content-type: application/json; charset=utf-8
content-length: 535
retry-after: 60
access-control-expose-headers: ETag, Link, Location, Retry-After, ...
access-control-allow-origin: *
x-github-media-type: github.v3; format=json
strict-transport-security: max-age=31536000; includeSubdomains; preload
x-frame-options: deny
x-content-type-options: nosniff
x-xss-protection: 0
referrer-policy: origin-when-cross-origin, strict-origin-when-cross-origin
content-security-policy: default-src 'none'; base-uri 'self'; ...
vary: Accept-Encoding, Accept, X-Requested-With
x-github-request-id: D24F:221686:28BC1:9F91F:69D56197
server: github.com
```

**Response body:**
```json
{
  "documentation_url": "https://docs.github.com/free-pro-team@latest/rest/overview/rate-limits-for-the-rest-api#about-secondary-rate-limits",
  "message": "You have exceeded a secondary rate limit. Please wait a few minutes before you try again. ..."
}
```

Note: the 403 **lacks the `x-ratelimit-*` headers** that appear on 204 responses.

</details>

### 2. Queue limit (~50,000 jobs)

**Tested 2026-04-07 and 2026-04-08.** Runner stopped throughout.

#### How the limit works

The queue limit is **per-repository** and counts **jobs, not workflow runs**:

| Test | Workflow type | Queue pinned at | Implied jobs at pin |
|------|-------------|-----------------|---------------------|
| Single-job (2026-04-07) | 1 job per run | 50,000 runs | 50,000 jobs |
| 256-job matrix (2026-04-08) | 256 jobs per run | ~183 runs | ~46,848 jobs |

With single-job workflows, it appeared to be a per-run limit because 1 run = 1 job. The matrix test revealed the true unit: a 256-job dispatch consumes 256× more queue capacity than a single-job dispatch.

The ~47k ceiling (vs exactly 50k) in the matrix test is likely due to per-run overhead or the 50 completed (0-job) failed runs from earlier org degradation also counting against the limit.

#### Dropped dispatches

Once the queue is full, additional dispatches are **accepted but immediately fail**:

- The API returns **HTTP 204** (success) — identical to a real success
- A workflow run **is created**, but instantly completes with `conclusion: failure` and **0 jobs**
- The UI shows: *"This workflow run cannot be executed because the maximum number of queued jobs has been exceeded."*
- The queued count stays pinned — it does not increase

```
# After reaching the limit:
$ curl -s -o /dev/null -w '%{http_code}' -X POST ... /dispatches
204                          # ← looks successful

$ gh api .../actions/runs/24145020562 --jq '{status, conclusion}'
{"status":"completed","conclusion":"failure"}   # ← instantly failed

$ gh api .../actions/runs/24145020562/jobs --jq '.total_count'
0                                               # ← no jobs created
```

The HTTP response is indistinguishable from a real success, but the **run is detectable after the fact**: query `?status=completed&conclusion=failure` and filter for runs with 0 jobs. These runs also have a characteristic ~1-2 second lifetime (`created_at` to `updated_at`).

<details>
<summary>HTTP 204 response headers (dropped dispatch — identical to real success)</summary>

```
HTTP/2 204
date: Wed, 08 Apr 2026 03:56:04 GMT
x-oauth-scopes: admin:org, admin:public_key, gist, repo
x-accepted-oauth-scopes:
x-oauth-client-id: 178c6fc778ccc68e1d6a
x-github-media-type: github.v3; format=json
x-github-api-version-selected: 2022-11-28
x-ratelimit-limit: 5000
x-ratelimit-remaining: 899
x-ratelimit-reset: 1775622104
x-ratelimit-used: 4101
x-ratelimit-resource: core
access-control-expose-headers: ETag, Link, Location, Retry-After, ...
access-control-allow-origin: *
strict-transport-security: max-age=31536000; includeSubdomains; preload
x-frame-options: deny
x-content-type-options: nosniff
x-xss-protection: 0
referrer-policy: origin-when-cross-origin, strict-origin-when-cross-origin
content-security-policy: default-src 'none'
vary: Accept-Encoding, Accept, X-Requested-With
x-github-request-id: CB6E:5500B:1E068C5:78E16F9:69D5D1D3
server: github.com
```

**Response body:** *(empty — 204 No Content, byte-for-byte identical to real success)*

</details>

#### Org-wide degradation

Leaving ~50k queued jobs for a sustained period degrades the **entire org**, not just the affected repo:

- All new workflow runs across *every* repo in the org fail immediately
- Runs complete in ~1 second with `conclusion: failure` and **0 jobs created**
- This affects repos with zero queued runs of their own
- The only fix is to drain or delete the queued runs (we deleted and recreated the repo)

During the *accumulation phase*, other repos work fine — the org-wide degradation only kicks in once the queue has been full for some time.

#### Matrix test details

We dispatched to a 256-job matrix workflow (`strategy.matrix` with 256 entries — GitHub's maximum) in a fresh repo:

- 177 runs (45,312 jobs) accumulated with zero drops
- Sent 500+ additional dispatches after that — all returned 204
- Queue oscillated between 177–186 runs, never growing past ~186
- Each batch of 100 204-accepted dispatches added only 0–6 actual runs
- Consistent with a job-based ceiling near 50,000

### 3. Push events

**Tested 2026-04-07.** Push events (branch creation) bypass the API secondary rate limit entirely because they don't use the dispatch API — they trigger via git push webhooks.

| Branches pushed | Duration | Runs created | Notes |
|----------------|----------|-------------|-------|
| 600 | ~15s | 600 | All created |
| 1,000 | ~25s | 1,000 | All created |
| 2,000 | ~50s | 2,000 | All created |
| 3,000 | ~75s | 3,000 | All created |
| 4,000 | ~100s | 4,000 | All created |
| 4,100+ | — | — | **Git server rejects push** (Internal Server Error at ~4,010 refs) |

The throughput is ~40 branches/second. This did not exercise the documented 500/10s workflow enqueue limit — a single `git push` of 4,000 branches takes ~100 seconds to transfer, spreading the enqueues well below 500/10s.

**Push events are also dropped** when the queue is at ~50k jobs — identical behavior to API dispatches (run created, instantly fails with 0 jobs).

### 4. API design gaps

#### Run ID from dispatch

As of [February 2026](https://github.blog/changelog/2026-02-19-workflow-dispatch-api-now-returns-run-ids/), `workflow_dispatch` supports an optional `return_run_details` parameter that returns the run ID and URLs in the response. `gh workflow run` (v2.87.0+) also returns the run URL by default.

`repository_dispatch` still returns an empty 204 — no run ID, no way to correlate the request to the resulting run(s) (which may be multiple, since `repository_dispatch` fans out to all matching workflows).

```bash
# workflow_dispatch with return_run_details — returns 200 with run ID
$ curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -d '{"ref":"main","return_run_details":true}' \
  "https://api.github.com/repos/{owner}/{repo}/actions/workflows/{workflow}/dispatches"
# → 200
# {
#   "workflow_run_id": 24147482484,
#   "run_url": "https://api.github.com/repos/.../actions/runs/24147482484",
#   "html_url": "https://github.com/.../actions/runs/24147482484"
# }

# workflow_dispatch without the param — old behavior
$ curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -d '{"ref":"main"}' \
  "https://api.github.com/repos/{owner}/{repo}/actions/workflows/{workflow}/dispatches"
# → 204 (empty)

# repository_dispatch — still no run ID
$ curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -d '{"event_type":"probe","client_payload":{"probe_id":"abc"}}' \
  "https://api.github.com/repos/{owner}/{repo}/dispatches"
# → 204 (empty)
```

**Key difference:** `return_run_details` changes the response from 204 (empty) to 200 with a JSON body. This also means you can detect a dropped dispatch — if the returned run immediately shows `conclusion: failure` with 0 jobs, it was dropped due to the queue limit.

<details>
<summary>Full HTTP response headers — workflow_dispatch with return_run_details (200)</summary>

```http
HTTP/2 200
date: Wed, 08 Apr 2026 16:55:14 GMT
content-type: application/json; charset=utf-8
content-length: 236
cache-control: private, max-age=60, s-maxage=60
x-oauth-scopes: admin:org, admin:public_key, gist, repo
x-github-api-version-selected: 2022-11-28
x-ratelimit-limit: 5000
x-ratelimit-remaining: 4991
x-ratelimit-used: 9
x-ratelimit-resource: core

{
  "workflow_run_id": 24147793639,
  "run_url": "https://api.github.com/repos/stefanpenner-cs/org-dispatch-test/actions/runs/24147793639",
  "html_url": "https://github.com/stefanpenner-cs/org-dispatch-test/actions/runs/24147793639"
}
```

</details>

<details>
<summary>Full HTTP response — checking the run status (dropped, queue full)</summary>

```bash
$ curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/stefanpenner-cs/org-dispatch-test/actions/runs/24147793639" \
  | jq '{id, status, conclusion, created_at, updated_at}'
{
  "id": 24147793639,
  "status": "completed",
  "conclusion": "failure",
  "created_at": "2026-04-08T16:55:13Z",
  "updated_at": "2026-04-08T16:55:17Z"
}

$ curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/stefanpenner-cs/org-dispatch-test/actions/runs/24147793639/jobs" \
  | jq '{total_count}'
{
  "total_count": 0
}
```

**Signature of a dropped dispatch:** `completed` + `failure` + 0 jobs + ~4 second lifetime. The UI shows: *"This workflow run cannot be executed because the maximum number of queued jobs has been exceeded."*

</details>

#### No way to predict job count

For simple workflows with static matrices, the job count is deterministic. But in the general case it's unknowable before runtime:

- **Dynamic matrices:** `fromJSON(needs.setup.outputs.matrix)` — values come from a prior job
- **Conditional jobs:** `if: github.event.client_payload.deploy == 'true'`
- **Reusable workflows:** called workflows have their own jobs, up to 4 levels deep

This means you can't reliably pre-calculate how much queue capacity a dispatch will consume.

## Detection and mitigation

Dropped dispatches **are detectable** — the HTTP 204 response is indistinguishable from success, but the run itself reveals the drop:

### 0. Dispatch with `return_run_details` + check (workflow_dispatch only, most direct)

```bash
# Step 1: dispatch and get run ID
RUN_ID=$(curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -d '{"ref":"main","return_run_details":true}' \
  "https://api.github.com/repos/{owner}/{repo}/actions/workflows/{workflow}/dispatches" \
  | jq -r '.workflow_run_id')

# Step 2: check status after a few seconds
curl -s \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/{owner}/{repo}/actions/runs/$RUN_ID" \
  | jq '{status, conclusion}'

# Dropped:  {"status": "completed", "conclusion": "failure"}  (within ~2-4s, 0 jobs)
# Normal:   {"status": "queued",    "conclusion": null}       → eventually "in_progress" → "success"
```

Two API calls, no webhooks, no polling. Only works for `workflow_dispatch` (which supports `return_run_details`). For `repository_dispatch`, push, PR, and other triggers, use the approaches below.

### 1. Query for failed runs with zero jobs (all trigger types)

```bash
# Find all runs that were dropped due to queue limit
gh api "repos/{owner}/{repo}/actions/runs?status=completed&conclusion=failure&per_page=100" \
  --jq '.workflow_runs[] | select(.id) | .id' | while read id; do
    jobs=$(gh api "repos/{owner}/{repo}/actions/runs/$id/jobs" --jq '.total_count')
    [ "$jobs" = "0" ] && echo "DROPPED: run $id"
done
```

A run with `conclusion: failure` and 0 jobs is the definitive signal. These runs also have a ~1-2 second lifetime. This works for **all trigger types** (push, PR, dispatch, schedule, UI) — no payload instrumentation needed.

Additional detection approaches:

### 1. Poll queue depth (per-repo, doesn't scale)

```bash
gh api repos/{owner}/{repo}/actions/runs?status=queued | jq '.total_count'
```

This works as a circuit breaker for a single repo: check before dispatching, refuse if count is above a threshold (e.g., 45,000). The `status=queued` filter correctly reports up to 50,000 (the unfiltered `total_count` caps at 40,000).

However, this requires one API call **per repo**. At 15k repos, polling them all is itself a rate-limit problem. There is no org-wide "total queued jobs across all repos" endpoint, so this approach only works if you know which repos are likely to accumulate deep queues.

### 2. Webhook listener (real-time)

Listen for `workflow_run` (fires once per run) or `workflow_job` (fires per job) webhooks:

```json
{"action": "requested", "workflow_run": {"id": 24101248322, "status": "queued"}}
```

If you dispatch and never receive a corresponding webhook, the dispatch was dropped. For `repository_dispatch` (which still doesn't return a run ID), this is also the only way to get the run ID.

### 3. Reconciliation via client_payload (dispatch-only)

Put a unique ID in every dispatch payload, then query runs and match:

```bash
# Dispatch with correlation ID
{"event_type": "probe", "client_payload": {"probe_id": "uuid-1234"}}

# Later: search for it in workflow run logs/annotations
```

This catches drops after the fact but requires the job to run and emit the ID. **Major limitation:** this only works for `repository_dispatch` and `workflow_dispatch` — runs triggered by pushes, PRs, the GitHub UI, schedule, etc. have no `client_payload` to correlate. For those, webhook-based tracking is the only option.

## Comparison table

| | Rate limit (secondary) | Queue limit (~50k jobs) |
|---|---|---|
| **HTTP status** | 403 | 204 (looks like success) |
| **Error message** | Yes, clear message + `retry-after` | None in response; visible in UI and on the created run |
| **Detectable from response** | Yes | No — but run shows `conclusion: failure` with 0 jobs |
| **Recovery** | Wait ~15s (despite `retry-after: 60`) | Drain queue below ~50k jobs |
| **Risk** | Low (you know it failed) | **Medium** (response looks successful, but detectable after the fact) |
| **Blast radius** | Just the rate-limited token | **Entire org (all repos)** |
| **Limit unit** | Requests per time window | Jobs (not runs) |
| **Scope** | Per-IP or per-org (shared across tokens) | Per-repository |

## Implications for production

1. **Monitor queue depth as a circuit breaker — but it doesn't scale.** Polling `?status=queued` per-repo works for known high-volume repos, but there's no org-wide endpoint. At 15k repos, polling them all burns your rate limit. Webhook-based tracking (see below) is the only approach that scales.

2. **Matrix workflows consume proportionally more queue capacity.** A 256-job matrix dispatch uses 256× more queue than a single-job dispatch. Factor this into capacity planning.

3. **Dropped dispatches are detectable — but only after the fact.** The dispatch API returns 204 (indistinguishable from success), but the created run will have `conclusion: failure` with 0 jobs. Query for these to detect and alert on drops. This works for all trigger types, not just dispatches.

4. **One runaway repo can take down the entire org's CI.** If any repo accumulates ~50k queued jobs and leaves them, all repos in the org start failing. Monitor and alert on queue depth org-wide.

5. **The secondary rate limit was our practical throughput ceiling.** At ~180 accepted dispatches per burst, we hit the secondary limit before reaching the documented 500/10s workflow enqueue limit. Both limits likely exist independently, but the secondary limit appears shared per-IP or per-org, so we couldn't bypass it with multiple tokens. Distributed clients across different IPs may be able to reach the 500/10s limit. Multiple tokens still help with sustained hourly throughput via independent primary rate limits of 5,000/hr each.

6. **Push events bypass the API rate limit but not the queue limit.** If you need high-throughput enqueuing, push events can deliver ~40 runs/second without hitting the secondary rate limit. But they still hit the ~50k job queue ceiling with identical drop behavior.

## Other docs

- **[DISPATCH_FLOW.md](DISPATCH_FLOW.md)** — Visual walkthrough of the full dispatch-to-runner pipeline: API request, broker long-poll, job message payload, and all five token types (PAT, runner RSA, session OAuth, GITHUB_TOKEN, OIDC). Sourced from actual runner diagnostic logs.

## Tools

| Script | Purpose |
|--------|---------|
| `scripts/flood.sh` | Serial dispatch flood with per-request HTTP status logging |
| `scripts/flood-parallel.sh` | Parallel dispatch flood via `xargs -P` for high throughput |
| `scripts/flood-sustained.sh` | Long-running sustained flood with rate limit awareness and backoff |
| `scripts/flood-multitoken.sh` | Multi-token flood using independent rate limits per GitHub App |
| `scripts/flood-push.sh` | Push-event flood via branch creation (bypasses API secondary rate limit) |
| `scripts/matrix-flood.sh` | Matrix dispatch flood for testing run-vs-job queue counting |
| `scripts/cancel-multitoken.sh` | Bulk cancel queued runs using multiple tokens in parallel |
| `scripts/generate-tokens.sh` | Generate GitHub App installation tokens from stored credentials |
| `scripts/monitor.sh` | Live dashboard of run statuses and API rate limit remaining |
| `scripts/reconcile.sh` | Compare accepted dispatches vs actual workflow runs to find dropped dispatches |
| `runner/setup.sh` | Download and register org-level self-hosted runner |
| `runner/start.sh` | Start the runner (queue drains) |
| `runner/stop.sh` | Stop the runner (queue accumulates) |

## Usage

```bash
# One-time setup
bash runner/setup.sh
bash runner/start.sh

# Send test dispatches
bash scripts/flood.sh 10                    # 10 serial dispatches
bash scripts/flood-parallel.sh 500 50       # 500 parallel dispatches, 50 concurrent
bash scripts/flood-push.sh 600              # 600 branches pushed (bypasses API rate limit)

# Multi-token flood (for reaching 50k)
bash scripts/generate-tokens.sh             # Generate fresh app tokens
bash scripts/flood-multitoken.sh 50500 credentials/tokens.txt

# Monitor
bash scripts/monitor.sh --watch

# Reconcile after a test
bash scripts/reconcile.sh results/<run_id>

# Bulk cancel
bash scripts/cancel-multitoken.sh
```
