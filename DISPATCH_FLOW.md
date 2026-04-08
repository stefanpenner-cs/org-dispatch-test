# Dispatch Flow: API to Runner

A visual reference for how a `repository_dispatch` request becomes a running job on a self-hosted runner, including every token and credential involved.

## Overview

```
┌─────────────┐         ┌──────────────────┐         ┌──────────────┐
│  Your code  │  POST   │   GitHub API     │  queue   │  Job broker  │
│  (curl/gh)  │────────>│  api.github.com  │────────>│  broker.     │
│             │ 204/403 │                  │         │  actions.    │
│             │<────────│  Creates run +   │         │  github...   │
└─────────────┘         │  enqueues job    │         └──────┬───────┘
                        └──────────────────┘                │
                                                            │ long-poll GET
                                                            │ (runner asks
                                                            │  "any work?")
                                                            │
                                                     ┌──────▼───────┐
                                                     │    Runner    │
                                                     │  (your Mac)  │
                                                     │              │
                                                     │ Receives:    │
                                                     │  job ID      │
                                                     │  steps       │
                                                     │  env/secrets │
                                                     │  GITHUB_TOKEN│
                                                     │  result URLs │
                                                     └──────┬───────┘
                                                            │
                                                            │ POST results
                                                            ▼
                                                     results-receiver.
                                                     actions.github...
```

## Step 1: You dispatch

```http
POST /repos/stefanpenner-cs/org-dispatch-test/dispatches HTTP/2
Host: api.github.com
Authorization: Bearer gho_xxxx
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
Content-Type: application/json

{
  "event_type": "probe",
  "client_payload": {
    "probe_id": "test-1234",
    "sleep_seconds": "0"
  }
}
```

GitHub returns **204 No Content** (empty body) on success. Internally it:
1. Creates a workflow run record
2. Evaluates which workflows match the `repository_dispatch` trigger
3. Enqueues a job for each matching workflow's job

Or returns **403** if the secondary rate limit is hit (see README.md for details).

Or returns **204 but silently drops the job** if the repository already has ~50,000 queued jobs.

## Step 2: Runner long-polls for work

The runner **initiates all connections outbound** — no inbound ports, no webhooks to the runner. It works behind NATs and firewalls without port forwarding.

```http
GET /message?sessionId=6b2efe8a-...&status=Online&runnerVersion=2.333.1&os=macOS&architecture=ARM64 HTTP/2
Host: broker.actions.githubusercontent.com
Authorization: Bearer <runner-session-oauth-token>
```

This request **blocks for ~50 seconds** waiting for a job assignment. If nothing is queued, the broker returns empty and the runner immediately re-polls. When a job is available, the broker responds with the full job message.

The runner authenticates to the broker using an OAuth token derived from RSA credentials established during `./config.sh` registration. This is **not** a PAT or GitHub App token — it's a runner-specific credential stored in `.credentials_rsaparams`.

## Step 3: The job message

When the broker assigns a job, the runner receives a ~20KB JSON payload. Here's what matters, captured from real runner diagnostic logs:

```json
{
  "messageType": "RunnerJobRequest",

  "jobId": "bf2a3d56-b845-5f53-b56c-a5902eaba61e",
  "jobDisplayName": "probe",
  "requestId": 0,

  "plan": {
    "planId": "ba3e4921-fac8-42ac-ad72-e1605893669e",
    "planType": "actions"
  },

  "fileTable": [
    ".github/workflows/dispatch-probe.yml"
  ],

  "steps": [
    {
      "type": "action",
      "contextName": "__run",
      "displayNameToken": { "lit": "Record probe" },
      "condition": "success()",
      "inputs": {
        "script": "format('if [ \"{0}\" = \"repository_dispatch\" ]; then\n  PROBE_ID=\"{1}\" ...',\n  github.event_name,\n  github.event.client_payload.probe_id, ...)"
      }
    }
  ],

  "contextData": {
    "github": {
      "event_name": "repository_dispatch",
      "repository": "stefanpenner-cs/org-dispatch-test",
      "sha": "e6513fb9aa95ccc98e99530a30ef796c7b7cf0ea",
      "ref": "refs/heads/main",
      "actor": "stefanpenner",
      "run_id": "24101248322",
      "run_number": "1",
      "repository_visibility": "public",
      "event": {
        "action": "probe",
        "branch": "main",
        "client_payload": {
          "probe_id": "flood-1775591428-1",
          "sleep_seconds": "0"
        }
      }
    }
  },

  "resources": {
    "endpoints": [
      {
        "name": "SystemVssConnection",
        "url": "https://run-actions-3-azure-eastus.actions.githubusercontent.com/182/",
        "authorization": { "scheme": "OAuth", "parameters": { "AccessToken": "***" } },
        "data": {
          "CacheServerUrl": "https://artifactcache.actions.githubusercontent.com/...",
          "ResultsServiceUrl": "https://results-receiver.actions.githubusercontent.com/",
          "PipelinesServiceUrl": "https://pipelinesghubeus11.actions.githubusercontent.com/...",
          "FeedStreamUrl": "wss://results-receiver.actions.githubusercontent.com/_ws/ingest.sock",
          "GenerateIdTokenUrl": "",
          "ConnectivityChecks": "[\"https://broker.actions.githubusercontent.com/health\",\"https://token.actions.githubusercontent.com/ready\",\"https://run.actions.githubusercontent.com/health\"]"
        }
      }
    ]
  },

  "variables": {
    "github_token": { "value": "***", "isSecret": true },
    "system.github.token": { "value": "***", "isSecret": true },
    "system.github.token.permissions": {
      "value": "{\"Actions\":\"write\",\"Contents\":\"write\",\"Issues\":\"write\",\"Metadata\":\"read\",\"Packages\":\"write\",\"PullRequests\":\"write\",\"SecurityEvents\":\"write\",\"Statuses\":\"write\"}"
    },
    "system.runnerEnvironment": { "value": "self-hosted" },
    "system.runnerGroupName": { "value": "default" },
    "system.orchestrationId": { "value": "ba3e4921-...probe.__default" }
  },

  "mask": [
    { "type": "regex", "value": "***" }
  ]
}
```

### Key observations

- **`contextData.github.event.client_payload`** — your dispatch payload arrives intact in the job message. GitHub doesn't transform it; the runner's expression evaluator expands `github.event.client_payload.probe_id` at step execution time.

- **`fileTable`** — the workflow YAML file path. The runner doesn't fetch the file from git; the step definitions are already compiled into the `steps` array.

- **`steps[].inputs.script`** — the `run:` block from your YAML, but wrapped in a `format()` expression with context variable references. The runner's template engine evaluates this.

- **`mask`** — 18 regex patterns for secrets. The runner redacts any matching string from all log output. This is how `***` appears in logs.

## Tokens and credentials

There are **five distinct tokens** in the dispatch flow. Understanding which is which prevents a lot of confusion.

### 1. Your dispatch token (PAT or App installation token)

```
Authorization: Bearer gho_xxxx
```

**What:** The token you use to call `POST /repos/.../dispatches`.
**Scope:** `repo` scope for PATs, or `contents:write` for App installation tokens.
**Lifetime:** PATs don't expire (unless fine-grained). App installation tokens expire after 1 hour.
**Rate limit:** 5,000/hr for PATs, 5,000/hr per App installation (independent limits — this is why we used multiple App tokens to reach 50k queued).

### 2. Runner registration credentials (RSA key pair)

```
Stored in: runner/_work/.credentials_rsaparams
```

**What:** An RSA key pair created during `./config.sh`. The runner uses this to authenticate to the broker and obtain session-scoped OAuth tokens.
**Scope:** Runner session management only — can poll for jobs and report results. Cannot access the GitHub API.
**Lifetime:** Persists until the runner is removed (`./config.sh remove`).

### 3. Runner session OAuth token

```
Authorization: Bearer <derived-from-RSA-credentials>
```

**What:** A short-lived token the runner obtains from GitHub using its RSA credentials. Used for the long-poll connection to `broker.actions.githubusercontent.com`.
**Scope:** Receive job assignments, report runner status.
**Lifetime:** Refreshed automatically by the runner process.

### 4. Job-scoped GITHUB_TOKEN

```
variables.github_token: "***" (isSecret: true)
```

**What:** A unique token generated for each workflow run, delivered inside the job message. This is what `${{ github.token }}` and `${{ secrets.GITHUB_TOKEN }}` resolve to in workflow steps.
**Scope:** Defined by `permissions:` in the workflow YAML. Our probe workflow gets the default set (Actions:write, Contents:write, Issues:write, Metadata:read, etc.).
**Lifetime:** Valid for the duration of the job, or 24 hours, whichever is shorter.
**Key point:** This token is scoped to the *repository*, not the user who dispatched. A dispatch from a PAT with `admin:org` scope still produces a GITHUB_TOKEN with only the workflow's declared permissions.

### 5. OIDC token (not used in our tests)

```
resources.endpoints[0].data.GenerateIdTokenUrl: ""   <-- empty because we didn't request it
```

**What:** A short-lived JWT issued by GitHub's OIDC provider (`token.actions.githubusercontent.com`). The workflow step requests it at runtime by calling the `GenerateIdTokenUrl` endpoint.
**When available:** Only when the workflow declares `permissions: { id-token: write }`. Our probe workflow doesn't, so the URL is empty.
**Scope:** The JWT contains claims about the workflow run:

```json
{
  "iss": "https://token.actions.githubusercontent.com",
  "sub": "repo:stefanpenner-cs/org-dispatch-test:ref:refs/heads/main",
  "aud": "https://github.com/stefanpenner-cs",
  "ref": "refs/heads/main",
  "sha": "e6513fb...",
  "repository": "stefanpenner-cs/org-dispatch-test",
  "repository_owner": "stefanpenner-cs",
  "actor": "stefanpenner",
  "workflow": "dispatch-probe",
  "event_name": "repository_dispatch",
  "run_id": "24101248322",
  "run_attempt": "1",
  "runner_environment": "self-hosted"
}
```

**Lifetime:** 5 minutes (non-configurable, set by GitHub).
**Purpose:** Federated authentication to external systems (AWS, GCP, Azure, Vault, etc.) without storing long-lived secrets. The external system validates the JWT signature against GitHub's OIDC discovery document and trusts the claims.
**Key point for dispatch:** The `sub` claim includes `ref:refs/heads/main` — the ref at dispatch time. For `repository_dispatch`, this is always the default branch. The external system can use `sub` or `repository`/`workflow` claims to restrict which workflows can assume which roles.

### Token flow diagram

```
 Dispatch time                    Job execution time
 ─────────────                    ──────────────────

 [1] PAT / App token              [4] GITHUB_TOKEN (job-scoped)
      │                                │
      │ POST /dispatches               │ used in workflow steps
      ▼                                │ for API calls back to GitHub
  api.github.com                       │
      │                                │
      │ enqueue                   [5] OIDC token (optional)
      ▼                                │
  job broker                           │ requested at runtime via
      │                                │ GenerateIdTokenUrl
      │ long-poll              ┌───────▼──────────┐
      ▼                        │ token.actions.   │
 [2] Runner RSA creds          │ githubusercontent│
 [3] Session OAuth             │ .com             │
      │                        └───────┬──────────┘
      │                                │
      ▼                                │ JWT with run claims
  runner process                       ▼
                               external cloud (AWS/GCP/etc)
```

### What this means for dispatch-at-scale

- **Tokens [1] and [4] are completely independent.** Your PAT's permissions don't flow to the job. A compromised self-hosted runner only gets the GITHUB_TOKEN's declared permissions, not your PAT.

- **Token [5] (OIDC) is the modern replacement for stored cloud credentials.** Instead of putting AWS keys in GitHub Secrets (which get delivered via the `mask`/`variables` fields), the workflow requests a short-lived JWT and exchanges it for cloud credentials. The cloud provider decides trust based on the JWT claims, not on a shared secret.

- **For repository_dispatch specifically**, the OIDC `sub` claim is always `repo:{owner}/{repo}:ref:refs/heads/{default_branch}` because dispatches run against the default branch. This means you can't use ref-based OIDC policies to distinguish between different dispatch callers — use `client_payload` for that instead.

## Runner internals

The runner is two processes:

```
Runner.Listener (PID parent)
    │
    │  IPC pipe (fd 151, 154)
    │  sends 20KB job message
    ▼
Runner.Worker (PID child, spawned per job)
    │
    │  executes steps
    │  streams logs via WebSocket to FeedStreamUrl
    │  uploads results to ResultsServiceUrl
    │
    ▼  exits with code 100 (success) or non-zero (failure)
```

- **Listener** manages the broker connection, session, and job dispatch
- **Worker** is spawned fresh for each job, receives the full job message over an IPC pipe, executes it, and exits
- The Listener reports the Worker's exit code back to GitHub as the job result

### Service endpoints delivered per job

| Endpoint | Purpose |
|----------|---------|
| `CacheServerUrl` | `actions/cache` — cross-run artifact caching |
| `ResultsServiceUrl` | Step results, annotations, job summaries |
| `PipelinesServiceUrl` | Job status updates, timeline records |
| `FeedStreamUrl` | WebSocket for real-time log streaming |
| `GenerateIdTokenUrl` | OIDC token endpoint (empty unless `id-token: write`) |

Each endpoint URL is unique per job and contains an opaque path segment that acts as an authorization token — the runner doesn't need to present additional credentials to these services beyond the URL itself.
