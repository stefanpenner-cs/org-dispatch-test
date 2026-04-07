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

#### What the 403 looks like

**Response headers:**
```
HTTP/2 403
retry-after: 60
content-type: application/json; charset=utf-8
```

**Response body:**
```json
{
  "documentation_url": "https://docs.github.com/free-pro-team@latest/rest/overview/rate-limits-for-the-rest-api#about-secondary-rate-limits",
  "message": "You have exceeded a secondary rate limit. Please wait a few minutes before you try again. ..."
}
```

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
