# APIcast `reports_batcher` lock race — repro and proposed fix

Unofficial reproduction case and proposed patch for a concurrency bug in
APIcast’s `3scale_batcher` policy
(`apicast/policy/3scale_batcher/reports_batcher.lua`).

Tested against the Red Hat APIcast image tag `3scale2.16.4`.

This repository is **not** affiliated with Red Hat or 3scale.

## Problem

Under concurrent APIcast workers, the stock `reports_batcher` hits a race in
`get_all()` that aborts a timer without releasing `resty.lock`. That turns into
lock timeouts on the request path and **dropped usage reports**.

Upstream already documents report loss when the lock cannot be acquired:

```lua
-- Note: When the lock cannot be acquired, the report will be lost.
-- TODO: Find a solution for this.
```

### Code bug

In original `get_all()` ([`original_reports_batcher.lua`](original_reports_batcher.lua)):

1. `storage:get_keys()` runs **before** `lock:lock(service_id)` (TOCTOU)
2. After another worker deletes those keys, `storage:get(key)` returns `nil`
3. `if value > 0` throws: `attempt to compare number with nil`
4. The Lua timer aborts **without** `unlock()`, so the lock stays held

There is **one flush timer per worker**. With ≥2 workers and the same hot
`service_id`, concurrent `get_all()` calls make this race reproducible.

### Design amplifier

| Decision | Effect |
|----------|--------|
| Same lock for `add()` and `get_all()` | A broken flush blocks the request path |
| `lock_timeout = 10` on `add()` | Clients can stall ~10s waiting for the lock |
| Timer per worker | Concurrent flushes of the same service are expected under load |
| No `pcall` / finally around locked work | One Lua error becomes reporting outage |

### Observed log sequence (lab)

With a fast mock Backend Listener (so Backend latency is ruled out), stock
APIcast under load shows this **chain** (nil first, then lock timeouts):

```text
~N requests  →  first concurrent flush (get_all across workers)
     │
     ▼
① runtime error in get_all:
   attempt to compare number with nil
     │  (timer aborts without clean unlock)
     ▼
② lock(service_id) remains held
     │
     ├─► add() on requests  → "failed to acquire the lock: timeout"
     └─► other get_all()    → same timeout
```

Example (timestamps illustrate the ~10s gap):

```text
[error] ... reports_batcher.lua:94: attempt to compare number with nil
        ... in function 'get_all'
...
[error] ... reports_batcher.lua: ... add(): failed to acquire the lock: timeout
[error] ... reports_batcher.lua: ... get_all(): failed to acquire the lock: timeout
```

The request count before the first error is **not** a magic threshold (e.g.
~12500 in one lab run). It is roughly the first time two workers flush the same
service under load. With `APICAST_WORKERS=1` the race is rare or absent; with
more workers and a hot service it appears reliably.

### Scope note

Batching is **per pod** (shared memory + locks are local to the APIcast
instance). Scaling replicas spreads contention but does not share one lock
cluster-wide. This repro targets the **in-pod** race, not cross-replica
coordination.

## Prerequisites

- OpenShift cluster with `oc` and an existing 3scale deployment
- APIcast production Deployment and a reachable API route (e.g. echo API)
- Ability to apply manifests in the 3scale namespace
- Optional (for the proposed fix): build/push rights and access to
  `registry.redhat.io` for the base APIcast image

## Reproduce

Work in the namespace where 3scale / APIcast is installed.

### Why a mock Backend Listener?

APIcast talks to Backend Listener mainly for authorize and batch reports
(`/transactions/authorize.xml`, `/transactions/oauth_authorize.xml`,
`/transactions.xml`, plus authrep variants without Batcher).

A permissive, instant mock isolates **internal Batcher locking** from slow
Backend/Valkey. If the nil + lock-timeout chain still appears against the mock,
Backend latency is not required to trigger the bug.

### 1. Deploy the mock backend-listener

```bash
oc apply -f mock-backend-listener/
```

### 2. Point APIcast at the mock

```bash
oc set data secret/backend-listener \
  --from-literal=service_endpoint=http://mock-backend-listener:3000
```

### 3. Raise APIcast workers

Multiple workers are required for concurrent flush timers:

```bash
oc set env deployment/apicast-production APICAST_WORKERS=5
oc rollout restart deployment/apicast-production
oc rollout status deployment/apicast-production
```

Optional control: repeat with `APICAST_WORKERS=1` — the nil/`get_all` race
should disappear.

### 4. Generate load

```bash
./genLoad.sh https://<your-apicast-route>/<path>
```

`genLoad.sh` sends many concurrent requests with random `app_id` / `app_key`.
That is fine against the mock (always authorized); a real Backend Listener
would reject those credentials.

### 5. Observe symptoms

```bash
oc logs -f deployment/apicast-production \
  | grep -e 'compare number with nil' \
         -e 'failed to acquire the lock' \
         -e 'failed to unlock' \
         -e error
```

Expect on stock APIcast: the nil compare in `get_all` first, then lock
timeouts on `add` / `get_all`.

### 6. Restore Backend Listener

```bash
oc set data secret/backend-listener \
  --from-literal=service_endpoint=http://backend-listener:3000
oc rollout restart deployment/apicast-production
```

## Proposed solution

[`reports_batcher.lua`](reports_batcher.lua) changes three things:

1. Wrap the critical sections of `add()` / `get_all()` in `pcall`
2. Always unlock via `unlock_safely()` (nested `pcall` around `unlock`)
3. Call `storage:get_keys()` **while holding the lock**, and guard nil values
   with `value and value > 0`

### Build a patched APIcast image

```bash
podman login registry.redhat.io
podman build -t <your-registry>/apicast-batcher-fix:2.16.4 -f Containerfile .
podman push <your-registry>/apicast-batcher-fix:2.16.4
```

The [`Containerfile`](Containerfile) starts from
`registry.redhat.io/3scale-amp2/apicast-gateway-rhel8:3scale2.16.4` and
overwrites `reports_batcher.lua` in the image.

Match the cluster CPU architecture. On Apple Silicon, Podman defaults to
`arm64`; for an `amd64` cluster:

```bash
podman build --platform linux/amd64 \
  -t <your-registry>/apicast-batcher-fix:2.16.4 -f Containerfile .
```

### Deploy the patched image (example)

Replace the placeholders with your APIManager name and image:

```bash
oc patch apimanager/<your-apimanager> --type='merge' \
  -p='{"spec":{"apicast":{"image":"<your-registry>/apicast-batcher-fix:2.16.4"}}}'
```

Re-run the same load test and confirm the nil error and lock timeouts no
longer appear.

A custom image is fine for **lab validation** and for attaching evidence to a
support/upstream report. It is **not** a supported production substitute for
an official fix.

This patch is a **proposal** for discussion / upstream contribution, not an
official Red Hat fix.

## Repository layout

| Path | Purpose |
|------|---------|
| `original_reports_batcher.lua` | Stock / broken baseline |
| `reports_batcher.lua` | Proposed fix |
| `Containerfile` | Builds APIcast image with the proposed fix |
| `genLoad.sh` | Concurrent load generator |
| `mock-backend-listener/` | Fast mock Backend Listener (ConfigMap, Deployment, Service) |

## License

Harness scripts and manifests in this repo are under the MIT License (see
[`LICENSE`](LICENSE)). The Lua files are derived from APIcast and remain
subject to upstream APIcast / Red Hat licensing for redistribution of that
code.
