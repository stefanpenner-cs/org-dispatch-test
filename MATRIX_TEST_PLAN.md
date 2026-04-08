# Question 3: Does the 50k limit count runs or jobs?

## Background

We know the queue pins at 50,000 and silently drops dispatches beyond that. But we only tested with single-job workflows — 1 dispatch = 1 run = 1 job. We don't know whether the limit counts:

- **Runs** — a 256-job matrix dispatch counts as 1 toward the 50k limit
- **Jobs** — a 256-job matrix dispatch counts as 256 toward the 50k limit

This matters enormously for capacity planning. If it's jobs, a single matrix workflow with 256 entries consumes 256x more queue capacity than a single-job workflow.

## Setup

- **Repo:** `stefanpenner-cs/dispatch-matrix-test` (fresh repo, zero queue)
- **Workflow:** `matrix-probe.yml` — `repository_dispatch` trigger, `strategy.matrix` with 256 entries (GitHub's max), `runs-on: self-hosted`, runner stopped so jobs queue
- **Runner:** Org-level self-hosted runner, stopped (same as previous tests)

## Experiment design

GitHub limits matrices to 256 jobs per workflow run. With 256 jobs per dispatch:

- If **runs** are counted: we'd need 50,000 dispatches to hit the limit (50,000 runs × 256 jobs = 12.8M jobs)
- If **jobs** are counted: we'd need ~196 dispatches to hit the limit (196 × 256 = 50,176 jobs)

This is a 255x difference — easy to distinguish.

### Protocol

1. Confirm runner is stopped
2. Send dispatches in batches of 10 (each creates 1 run with 256 jobs)
3. After each batch, check:
   - `total_count` from `?status=queued` (run count)
   - Total jobs = run count × 256
4. At batch 20 (20 runs, 5,120 jobs): still working? → likely runs-based
5. At batch 50 (50 runs, 12,800 jobs): still working? → likely runs-based
6. At batch 196 (196 runs, 50,176 jobs): if drops start here → jobs-based
7. Continue to 200+ runs if no drops at 196

### Key observations per batch

| Batch | Dispatches sent | HTTP status | Runs (queued) | Implied jobs |
|-------|----------------|-------------|---------------|-------------|
| 1     | 10             | ?           | ?             | ? × 256     |
| ...   | ...            | ...         | ...           | ...         |

### What to watch for

- **Silent drops** — dispatch returns 204 but queued run count doesn't increase
- **Explicit rejection** — dispatch returns 403 or 422
- **Partial matrix** — run is created but fewer than 256 jobs appear

### Cleanup

After the test, delete and recreate `dispatch-matrix-test` (faster than cancelling thousands of runs, as we learned).

## Expected outcomes

| If limit counts... | Drops start at | Dispatches needed | Easily distinguishable? |
|--------------------|---------------------------------|-------------------|-------------------------|
| Runs               | ~50,000 dispatches              | ~50,000           | Yes — we won't get close |
| Jobs               | ~196 dispatches                 | ~196              | Yes — very fast to reach |
