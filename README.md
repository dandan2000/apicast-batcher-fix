# APIcast `reports_batcher` lock race — repro and proposed fix

Unofficial reproduction case and proposed patch for a concurrency bug in
APIcast’s `3scale_batcher` policy
(`apicast/policy/3scale_batcher/reports_batcher.lua`).

Tested against the Red Hat APIcast image tag `3scale2.16.4`.

This repository is **not** affiliated with Red Hat or 3scale.

## Problem

Under concurrent workers, the stock `reports_batcher` can fail to release
`resty.lock` locks and can race when enumerating batched report keys.

### 1. Lock not released on errors

In `add()` and `get_all()`, work runs **after** `lock:lock(...)` with no
`pcall` / finally. If shared-dict ops or key parsing throw, `lock:unlock()`
never runs. The lock stays held until timeout (`lock_timeout = 10`). Other
workers then fail with `failed to acquire the lock` and **drop reports**
(already noted in upstream comments).

### 2. `get_keys()` outside the lock

In original `get_all()`, the key list is taken **before** acquiring the lock.
With multiple APIcast workers, concurrent flushers can see a stale key list
and race on get/delete of batched usage reports.

See [`original_reports_batcher.lua`](original_reports_batcher.lua) for the
stock behavior.

## Prerequisites

- OpenShift cluster with `oc` and an existing 3scale deployment
- APIcast production Deployment and a reachable API route (e.g. echo API)
- Ability to apply manifests in the 3scale namespace
- Optional (for the proposed fix): build/push rights and access to
  `registry.redhat.io` for the base APIcast image

## Reproduce

Work in the namespace where 3scale / APIcast is installed.

### 1. Deploy the mock backend-listener

The mock always authorizes and accepts batch reports, so Backend Listener
latency does not hide the race:

```bash
oc apply -f mock-backend-listener/
```

### 2. Point APIcast at the mock

```bash
oc set data secret/backend-listener \
  --from-literal=service_endpoint=http://mock-backend-listener:3000
```

### 3. Raise APIcast workers

Multiple workers are needed to stress the lock:

```bash
oc set env deployment/apicast-production APICAST_WORKERS=5
oc rollout restart deployment/apicast-production
oc rollout status deployment/apicast-production
```

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
  | grep -e 'failed to acquire the lock' -e 'failed to unlock' -e error
```

Typical signals under stock APIcast: repeated `failed to acquire the lock`
(and related unlock / batching errors) while load is running.

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

### Deploy the patched image (example)

Replace the placeholders with your APIManager name and image:

```bash
oc patch apimanager/<your-apimanager> --type='merge' -p='{"spec":{"apicast":{"image":"<your-registry>/apicast-batcher-fix:2.16.4"}}}'
```

Re-run the load test and confirm lock-related errors no longer appear.

This patch is a **proposal** for discussion / upstream contribution, not an
official Red Hat fix.

## Repository layout

| Path | Purpose |
|------|---------|
| `original_reports_batcher.lua` | Upstream / broken baseline |
| `reports_batcher.lua` | Proposed fix |
| `Containerfile` | Builds APIcast image with the proposed fix |
| `genLoad.sh` | Concurrent load generator |
| `mock-backend-listener/` | Fast mock Backend Listener (ConfigMap, Deployment, Service) |

## License

Harness scripts and manifests in this repo are under the MIT License (see
[`LICENSE`](LICENSE)). The Lua files are derived from APIcast and remain
subject to upstream APIcast / Red Hat licensing for redistribution of that
code.
