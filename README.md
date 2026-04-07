# GitHub Actions Dispatch Queue Limit Testing

Empirical testing of GitHub's dispatch queue size limits, rate limits, and failure behaviors.

## Questions

1. **What happens when you exceed the dispatch rate limit?**
2. **What happens when you exceed 50,000 queued runs?** *(testing in progress)*

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

*Testing not yet started. Requires ~50,000 API calls at a sustained rate, estimated ~10 hours.*

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
