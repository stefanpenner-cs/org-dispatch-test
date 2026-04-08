# GitHub Actions Dispatch Queue Limit Testing

Empirical testing of GitHub's dispatch queue size limits, rate limits, and failure behaviors.

## Questions

1. **What happens when you exceed the dispatch rate limit?**
2. **What happens when you exceed 50,000 queued runs?**

## Setup

- **Org:** [stefanpenner-cs](https://github.com/stefanpenner-cs)
- **Runner:** Org-level self-hosted runner on macOS (ARM64), controllable via `runner/start.sh` and `runner/stop.sh` to gate queue draining
- **Dispatch method:** `repository_dispatch` via REST API (`POST /repos/{owner}/{repo}/dispatches`)

## Findings

### Question 1: What happens when you exceed the dispatch rate limit?

**Tested 2026-04-07.** Runner stopped so all accepted dispatches queue without draining.

| Test | Dispatches sent | Parallelism | Accepted (HTTP 204) | Rejected (HTTP 403) | Duration | Silent drops |
|------|----------------|-------------|---------------------|---------------------|----------|--------------|
| B1 | 400 | 50 | 183 | 217 | ~3s | 0 |
| B2 | 500 | 50 | 182 | 318 | ~4s | 0 |
| B3 | 600 | 100 | 181 | 419 | ~3s | 0 |
| B4 | 1000 | 100 | 181 | 819 | ~4s | 0 |

**Total: 729 dispatches accepted, 729 workflow runs created. Zero silent drops.**

#### HTTP 204 — Successful dispatch

**Response headers:**
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
access-control-expose-headers: ETag, Link, Location, Retry-After, X-GitHub-OTP, X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Used, X-RateLimit-Resource, X-RateLimit-Reset, X-OAuth-Scopes, X-Accepted-OAuth-Scopes, X-Poll-Interval, X-GitHub-Media-Type, X-GitHub-SSO, X-GitHub-Request-Id, Deprecation, Sunset
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

#### HTTP 403 — Secondary rate limit exceeded

**Response headers:**
```
HTTP/2 403
date: Tue, 07 Apr 2026 19:57:11 GMT
content-type: application/json; charset=utf-8
content-length: 535
retry-after: 60
access-control-expose-headers: ETag, Link, Location, Retry-After, X-GitHub-OTP, X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Used, X-RateLimit-Resource, X-RateLimit-Reset, X-OAuth-Scopes, X-Accepted-OAuth-Scopes, X-Poll-Interval, X-GitHub-Media-Type, X-GitHub-SSO, X-GitHub-Request-Id, Deprecation, Sunset
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
  "message": "You have exceeded a secondary rate limit. Please wait a few minutes before you try again. For more on scraping GitHub and how it may affect your rights, please review our Terms of Service (https://docs.github.com/en/site-policy/github-terms/github-terms-of-service) If you reach out to GitHub Support for help, please include the request ID D24F:221686:28BC1:9F91F:69D56197."
}
```

Notable differences: the 403 includes `retry-after: 60` and notably **lacks the `x-ratelimit-*` headers** that appear on 204 responses — confirming this is the secondary (abuse) rate limit, not the primary rate limit.

#### Key takeaways

1. **The secondary (abuse) rate limit fires before the documented 500/10s workflow queue limit.** We never reached the workflow-level limit — the API-level secondary rate limit capped us at ~180 accepted dispatches per burst.

2. **The error is HTTP 403, not 429.** The `retry-after: 60` header tells you to back off for 60 seconds.

3. **The error is explicit, not silent.** The API clearly rejects the request. You know immediately whether your dispatch was accepted (204) or rejected (403).

4. **Zero silent drops.** Every dispatch that received HTTP 204 became a workflow run. Out of 729 accepted dispatches across 4 test runs, exactly 729 workflow runs were created.

5. **The ~180 per-burst cap is consistent.** Regardless of how many dispatches we sent (400–1000) or what parallelism we used (50–100), the number accepted was always ~180–183. This aligns with the secondary rate limit documentation which describes ~80 content-creation requests per minute, though our observed throughput was higher — likely because the limit applies across a sliding window rather than a hard per-minute cap.

6. **The limit resets within 10–15 seconds in practice**, despite the `retry-after: 60` header suggesting a 60-second wait.

### Question 2: What happens when you exceed 50,000 queued runs?

**Tested 2026-04-07.** Runner stopped, accumulated 50,000+ queued runs using 7 tokens (6 GitHub App installation tokens + 1 PAT) over ~2 hours.

#### Result: Silent drops — API returns 204 but runs are never created

Once the queue reaches 50,000, additional dispatches are **silently dropped**:

- The API returns **HTTP 204** (success) — no error, no indication of failure
- The queued count stays pinned at exactly **50,000**
- The dispatched workflow runs **never appear** in the runs list

This is the most dangerous failure mode: your client thinks the dispatch succeeded, but the workflow never runs.

#### Verification

```
# After reaching 50,000 queued:
$ curl -s -o /dev/null -w '%{http_code}' -X POST ... /dispatches
204                          # ← looks successful

$ gh api .../actions/runs?status=queued | jq '.total_count'
50000                        # ← still 50,000, didn't increase
```

We sent 5 dispatches after hitting 50k, all returned 204, queue stayed at 50,000.

#### HTTP 204 response past 50k (identical to normal success)

**Response headers:**
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
access-control-expose-headers: ETag, Link, Location, Retry-After, X-GitHub-OTP, X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Used, X-RateLimit-Resource, X-RateLimit-Reset, X-OAuth-Scopes, X-Accepted-OAuth-Scopes, X-Poll-Interval, X-GitHub-Media-Type, X-GitHub-SSO, X-GitHub-Request-Id, Deprecation, Sunset
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

**Response body:** *(empty — 204 No Content)*

This is byte-for-byte identical to a real successful dispatch. There is **no way to distinguish a silently dropped dispatch from a successful one** based on the HTTP response alone. You must check the queue count independently.

#### Key takeaways

1. **The 50,000 queued run limit is real and enforced.** The queue count pins at exactly 50,000.

2. **Drops are completely silent.** The API returns 204 (success) with identical headers to a real success. There is no error, no warning, no special header.

3. **The limit is per-repository**, not per-org or per-token. All tokens (PAT and app tokens) see the same 50,000 ceiling. During accumulation, other repos in the same org can still dispatch and queue runs normally.

4. **This contrasts sharply with the rate limit behavior.** The secondary rate limit returns an explicit 403 with a clear error message. The queue limit returns a fake 204.

5. **The total_count API has its own display cap.** The `total_count` for all runs caps at 40,000, but the `status=queued` filter correctly reports 50,000.

6. **Leaving 50k queued runs degrades the entire org.** Once the queue sits at 50,000 for a sustained period, all new workflow runs across *every* repo in the org begin failing immediately — runs complete in ~1 second with `conclusion: failure` and 0 jobs created. This affects repos that have zero queued runs of their own. The only fix is to drain or delete the queued runs (we ultimately deleted and recreated the repo).

#### Comparison: Rate limit vs Queue limit

| | Rate limit (secondary) | Queue limit (50k) |
|---|---|---|
| **HTTP status** | 403 | 204 (fake success) |
| **Error message** | Yes, clear message | None |
| **Detectable from response** | Yes | No |
| **Recovery** | Wait and retry | Drain queue below 50k |
| **Risk** | Low (you know it failed) | **High (you think it succeeded)** |
| **Blast radius** | Just the rate-limited token | **Entire org (all repos)** |

### Question 3: Does the 50k limit count runs or jobs?

**Tested 2026-04-08.** Used a 256-job matrix workflow (`strategy.matrix` with 256 entries) in a fresh repo (`dispatch-matrix-test`). Runner stopped so all jobs queue.

#### Result: The limit counts runs, not jobs

We sent 250 dispatches, each creating 1 workflow run with 256 queued jobs. At the end:

- **177 queued runs** (175 accepted via 204, 75 rejected via 403 rate limit, +2 from earlier testing)
- **45,312 queued jobs** (177 × 256)
- **Zero silent drops** — every accepted dispatch became a queued run

If the limit counted jobs, drops would have started at ~196 dispatches (196 × 256 = 50,176 jobs). Instead, all 250 dispatches were processed normally.

#### Key takeaways

1. **The 50,000 limit counts workflow runs, not individual jobs.** A single dispatch that creates a 256-job matrix run counts as 1 toward the limit, not 256.

2. **This means the effective job capacity is much higher than 50k.** With 256-job matrices, you could theoretically queue 50,000 × 256 = **12.8 million jobs** before hitting the limit.

3. **GitHub's maximum matrix size is 256 jobs per workflow run.** This is a hard limit that cannot be overridden through configuration (though it can be bypassed via nested reusable workflows).

## Tools

| Script | Purpose |
|--------|---------|
| `scripts/flood.sh` | Serial dispatch flood with per-request HTTP status logging |
| `scripts/flood-parallel.sh` | Parallel dispatch flood via `xargs -P` for high throughput |
| `scripts/monitor.sh` | Live dashboard of run statuses and API rate limit remaining |
| `scripts/reconcile.sh` | Compare accepted dispatches vs actual workflow runs to find silent drops |
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
bash scripts/flood-parallel.sh 500 50       # 500 parallel dispatches

# Monitor
bash scripts/monitor.sh --watch

# Reconcile after a test
bash scripts/reconcile.sh results/<run_id>
```
