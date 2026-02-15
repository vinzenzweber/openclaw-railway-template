# OpenClaw Remote CDP “Port Ownership” Bug (Railway) - Context

## TL;DR
OpenClaw currently blocks external/remote Chromium CDP profiles due to a buggy local preflight check:

- Error pattern: `Port <port> is in use for profile <name> but not by openclaw`
- Root cause: OpenClaw treats a remote CDP profile's `cdpPort` as a *local* managed port and checks
  "ownership" (process/port-in-use) even though the endpoint is remote.
- Status upstream: the fix PR is still open. See `openclaw/openclaw#15595`.

This repo (template) successfully provisions a dedicated `chromium-cdp` Railway service and wires
OpenClaw to it via `OPENCLAW_EXTERNAL_CHROMIUM_CDP_URL`, but OpenClaw itself must be patched/upgraded
to truly support remote CDP without the incorrect ownership check.

## Symptoms (Observed)
Inside the `openclaw` Railway service:

- `openclaw browser status` shows a remote profile:
  - `profile: remote`
  - `enabled: true`
  - `running: false`
  - `cdpUrl: http://chromium-cdp.railway.internal:<port>`
  - `cdpPort: <port>`
- Browser actions fail early with a misleading "port in use / not owned" error.
- The remote Chromium CDP endpoint is actually reachable and works:
  - `curl http://chromium-cdp.railway.internal:<port>/json/version` works (after Host header rewrite fix).

## Root Cause (Why It Happens)
OpenClaw runs a local "CDP port ownership / port-in-use" check intended for *local managed Chromium*.
For remote CDP profiles this check is invalid: OpenClaw will never "own" the remote process/port.
This causes OpenClaw to refuse to attach even when the remote WebSocket endpoint is healthy.

## Upstream Tracking
- Issue: `openclaw/openclaw#15582`
- PR (cleaner fix, open): `openclaw/openclaw#15595`
  - Purpose: skip local ownership checks for remote CDP profiles; add regression test.
  - Note: includes one unrelated commit; ideally split for easier maintainer merge.
- PR (noisier, open): `openclaw/openclaw#16495`

## Railway Deployment Context (How This Repo Is Set Up)
Two Railway services in one project/environment:

### 1) `chromium-cdp` service
- Path: `services/chromium/*`
- Base: `debian:bookworm-slim`
- Installs: `chromium`, `chromium-sandbox`, `nginx-light`, `curl`, `ca-certificates`
- Runs Chromium with CDP bound to loopback:
  - `--remote-debugging-address=127.0.0.1`
  - `--remote-debugging-port=18801`
  - `--user-data-dir=/data/chromium-user-data` (persistent volume)
- Nginx reverse-proxies Railway `PORT` -> internal `18801`.
- Critical fix: Chromium DevTools rejects Host headers like `chromium-cdp.railway.internal`, so nginx
  rewrites `Host: localhost` for all requests (including `/healthz` -> `/json/version`).
- Rolling overlap mitigations:
  - `services/chromium/railway.toml`: `overlapSeconds = 0`, `requiredMountPath = "/data"`
  - `services/chromium/start.sh`: best-effort removal of stale `Singleton*` and LevelDB `LOCK` files.

### 2) `openclaw` service
- Wrapper HTTP listens on `PORT=8080`.
- Uses external CDP via:
  - `OPENCLAW_EXTERNAL_CHROMIUM_CDP_URL=http://chromium-cdp.railway.internal:<port>`
- During `/setup`, wrapper configures:
  - `browser.enabled=true`
  - `browser.attachOnly=true` (avoid local browser launch/management)
  - creates `remote` profile via `openclaw browser create-profile --cdp-url ...`
  - sets `browser.defaultProfile=remote`
- OpenClaw still expects a Chromium executable to exist in this container even when using remote CDP,
  so the `Dockerfile` provides a tiny `/usr/bin/chromium` shim (not full chromium install).

## Common Red Herrings / Notes
- "Browser control service not responding on 18791":
  - Gateway logs show: `[browser/service] Browser control service ready (profiles=3)`.
  - Probing `18791` with HTTP can look dead if it is not an HTTP endpoint.
- Ensure you use the correct state dir when running `openclaw` manually via Railway SSH:
  - Wrapper uses `OPENCLAW_STATE_DIR=/data/.clawdbot`
  - Wrapper uses `OPENCLAW_WORKSPACE_DIR=/data/workspace`

## Correct Fix (What Must Change Upstream)
For remote CDP profiles, OpenClaw must:
- skip local "port ownership / port in use" checks
- validate remote attach by attempting to connect to the remote WebSocket/CDP endpoint and surface
  true connectivity errors.

## Workarounds Until Upstream Fix Lands
1. Build/deploy OpenClaw from a branch/commit including the fix (preferred).
2. Avoid the browser tool for Cloudflare-heavy targets; use HTTP fetch/extraction tools where possible.
3. Use a local managed browser (no external CDP), sacrificing persistent cookies across deploys.

## "Done" Criteria
- `openclaw browser status` shows `profile: remote` with the correct `cdpUrl`.
- Browser tool actions succeed without any "port in use but not by openclaw" errors.

