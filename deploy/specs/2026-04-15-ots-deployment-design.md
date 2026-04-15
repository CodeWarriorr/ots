---
title: ots.blocklab.dev — Deployment Design
date: 2026-04-15
status: draft
owner: mmach
repo: CodeWarriorr/ots (public fork of Luzifer/ots)
target_host: openclaw VPS
---

# ots.blocklab.dev — Deployment Design

## Summary

Deploy a self-hosted one-time-secret sharing service at `ots.blocklab.dev`, served from the openclaw VPS via a dedicated Cloudflare tunnel, using the upstream `ghcr.io/luzifer/ots` image pinned to a specific version. Deployment files live in the public fork under `deploy/` and are the authoritative source for the live stack.

The design mirrors the `newsletters-prod` pattern already running on openclaw: per-stack `docker-compose.yml`, per-stack Cloudflare tunnel, no host ports published, `.env` on the VPS holds secrets, `.env.example` committed as a template.

## Goals

- Reputable zero-knowledge secret sharing on a personal VPS with minimal maintenance burden.
- Own compose file and own Cloudflare tunnel so the stack is self-contained and can be stopped/started without touching other services.
- "Heavy restrictions" on the running containers to contain abuse impact if the URL gets attacked — resource caps, size caps, Valkey memory caps, log rotation, no unneeded capabilities.
- Deployment files committed to the public fork as the source of truth, with zero secrets in git.
- Simple manual upgrade path — no Watchtower, no CI build pipeline, no fork-rebuilds for now.

## Non-goals

- No automatic updates (Watchtower). The app rarely ships new versions; manual `docker compose pull && up -d` when a CVE or interesting feature lands is fine.
- No fork-built custom image. Deployment uses the pinned upstream image `ghcr.io/luzifer/ots:v1.21.4`. The compose file is pre-wired so switching to a fork-built image is a one-line `image:` change later.
- No backups. Secrets are ephemeral by design (7-day TTL, first-read destruction). Losing Valkey's RDB file on a disk failure loses only unclaimed secrets, which is acceptable.
- No metrics scraping. `/metrics` is exposed on the bridge network and IP-allowlisted, but no Prometheus instance is wired to it yet.
- No Cloudflare Access / auth gate. The instance is fully public — anyone with the URL can create a secret.
- No Ansible role. This stack is managed like `newsletters-prod`: standalone docker-compose on the VPS, not part of the OpenClaw Ansible infra.
- No customization of the ots frontend (branding, i18n extensions, etc.). Vanilla upstream image.

## Architecture

```
Internet ──TLS──▶ Cloudflare Edge ──tunnel──▶ cloudflared container
                                                        │
                                                   app-network (bridge, internal)
                                                        │
                                                     ┌──┴────────┐
                                                     ▼           ▼
                                                   ots:3000    valkey:6379
                                                                  │
                                                               ${DATA_DIR}
                                                               (RDB snapshots)
```

Three containers on a single Docker bridge network `app-network`:

- **`cloudflared`** — Cloudflare tunnel client, holds the tunnel token, routes inbound HTTPS traffic from the Cloudflare edge to `http://app:3000`.
- **`app`** — the ots Go binary serving the web UI and API.
- **`valkey`** — Redis-protocol store for encrypted secret blobs.

**Zero host ports published.** No inbound firewall rules needed on the VPS. All external ingress comes through the cloudflared tunnel's outbound connection to Cloudflare's edge.

Cloudflare DNS routes `ots.blocklab.dev` to the tunnel; the tunnel configuration (managed in the Cloudflare Zero Trust dashboard, not in this repo) points to `http://app:3000` as the origin service name — `app` resolves via Docker's internal DNS on the bridge network.

## Security model

The threat model is "random internet attacker with the public URL, trying to exhaust resources or extract secrets they shouldn't see":

- **Plaintext secrets never reach the server** — ots encrypts in the browser with AES-256, sends only ciphertext. The decryption key lives in the URL fragment and never leaves the client. Compromising the server yields only encrypted blobs.
- **First-read destruction + 7-day TTL** — even for the legitimate owner, data lifetime is short.
- **No authentication to create secrets** — the create endpoint is public. Abuse defense is layered through size limits, rate limits, and resource caps rather than auth.

### Hardening recipe (four layers)

**Layer 1 — ots (`deploy/ots-customize.yaml`):**
- `maxSecretSize: 262144` (256 KiB). Enough for passwords, SSH keys, API tokens, small files; blocks large-upload abuse. Upstream default is ~115 MiB.
- `metricsAllowedSubnets: [172.16.0.0/12]` — restrict `/metrics` endpoint to the Docker bridge range only.

**Layer 2 — Valkey (`command` in compose):**
- `--maxmemory 128mb --maxmemory-policy allkeys-lru` — hard memory cap, evict oldest if flooded.
- `--save 900 1 --appendonly no` — RDB snapshot if ≥1 key changed in last 15 minutes, no AOF. Survives restart without fsync overhead.

**Layer 3 — Docker Compose (per-service):**
- `deploy.resources.limits`: `app` → 0.5 CPU, 256 MiB memory; `valkey` → 0.25 CPU, 192 MiB memory.
- `pids_limit: 100` on `app`, `50` on `valkey`.
- `security_opt: ["no-new-privileges:true"]` on both.
- `cap_drop: [ALL]` on `app` (runs as UID 1000 from a `FROM scratch` image, needs zero Linux capabilities).
- `read_only: true` on `app` with `tmpfs: /tmp` for scratch.
- `logging.driver: json-file`, `options: { max-size: "10m", max-file: "3" }` on all three services — caps log disk at 30 MiB per service.
- `restart: unless-stopped`.

**Layer 4 — Cloudflare edge (manual, documented in `deploy/deploy.md`):**
- Basic DDoS protection and WAF managed rules come with the free plan by default.
- Recommended rate-limit rule (configured in the CF dashboard, not baked into the spec because the free-plan rate-limit feature set is a moving target): `POST /api/create` → 10 requests per minute per IP → block for 1 hour.
- Recommended security level: `high` for the `ots.blocklab.dev` hostname.

## Services (docker-compose outline)

Final compose will be written in the implementation plan. Shape:

### `app`
- `image: ghcr.io/luzifer/ots:v1.21.4` (pinned; bumped manually)
- `environment`:
  - `STORAGE_TYPE=redis`
  - `REDIS_URL=redis://valkey:6379/0`
  - `SECRET_EXPIRY=604800` (7 days)
  - `CUSTOMIZE=/etc/ots/ots-customize.yaml`
  - `LOG_LEVEL=info`
- `volumes`: `./ots-customize.yaml:/etc/ots/ots-customize.yaml:ro`
- `depends_on`: `valkey` (condition: `service_healthy`)
- `healthcheck`: HTTP GET `/` on `localhost:3000` returns 200
- Limits / hardening: see Layer 3 above
- `networks: [app-network]`

### `valkey`
- `image: valkey/valkey:9.0.3-alpine` (pinned)
- `command`: `valkey-server --maxmemory 128mb --maxmemory-policy allkeys-lru --save 900 1 --appendonly no`
- `volumes`: `${DATA_DIR}:/data`
- `healthcheck`: `valkey-cli ping` returns `PONG`
- Limits / hardening: see Layer 3 above
- `networks: [app-network]`

### `cloudflared`
- `image: cloudflare/cloudflared:latest` — intentionally unpinned, unlike `app` and `valkey`. The tunnel client negotiates its wire protocol with the Cloudflare edge and benefits from floating on `latest` so protocol upgrades land automatically. Matches the `newsletters-prod` pattern for the same reason.
- `command: tunnel --no-autoupdate run`
- `environment`: `TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN}`
- `depends_on`: `app` (condition: `service_healthy`)
- `restart: unless-stopped`
- `networks: [app-network]`

## File inventory

Everything committed to the public fork under `deploy/`. Everything else lives on the VPS and is gitignored or external.

### Committed to the fork (public, no secrets)

```
deploy/
├── docker-compose.yml         # the three services above
├── ots-customize.yaml         # maxSecretSize + metricsAllowedSubnets
├── .env.example               # template with placeholders, no real values
├── .gitignore                 # ignores .env and any runtime state
├── deploy.sh                  # git pull + docker compose pull + up -d
├── deploy.md                  # runbook: tunnel setup, first-run, bump, rollback, incident
├── README.md                  # one-paragraph pointer to deploy.md
└── specs/
    └── 2026-04-15-ots-deployment-design.md   # this file
```

### NOT committed (lives on VPS only)

```
~/ots-prod/deploy/.env         # contains CLOUDFLARE_TUNNEL_TOKEN, DATA_DIR
~/ots-data/                    # Valkey RDB snapshot directory, outside the repo clone
```

### Public-repo discipline

- `.env` MUST be in `deploy/.gitignore`. The example file is `.env.example` with placeholder values only.
- The `CLOUDFLARE_TUNNEL_TOKEN` is the only hard secret. It MUST never appear in any committed file, spec doc, or commit message.
- Hostnames (`ots.blocklab.dev`), VPS paths (`~/ots-prod`), Docker image tags, and resource limits are NOT secrets — committing them is fine and makes the deployment reproducible.
- A pre-commit check in the deploy runbook reminds operators to `git diff --cached | grep -i token` before every commit from the VPS.

## Tunnel token injection

The `CLOUDFLARE_TUNNEL_TOKEN` is injected via a `.env` file on the VPS that compose reads at `docker compose up` time. The flow:

1. Operator creates the tunnel in the Cloudflare Zero Trust dashboard → Networks → Tunnels → Cloudflared → name = `ots-blocklab-dev`.
2. Dashboard shows the tunnel token. Operator copies it.
3. On the VPS: `cd ~/ots-prod/deploy && cp .env.example .env`.
4. Operator edits `.env`, pastes the token into `CLOUDFLARE_TUNNEL_TOKEN=...`, sets `DATA_DIR=/home/openclaw/ots-data`.
5. `chmod 600 .env` — restrict read access to the owning user.
6. `docker compose up -d` — compose reads the `.env` file automatically, injects the token as an environment variable into the `cloudflared` container only.
7. Dashboard: configure the public hostname `ots.blocklab.dev` → service `http://app:3000`.

The token never touches the repo, never appears in compose config, never lands in git history. It is scoped to one tunnel and can be rotated from the Cloudflare dashboard without touching any committed code (just edit `.env` and `docker compose up -d` again).

**`.env.example` template (committed):**
```bash
# Copy to .env and fill in real values. Never commit .env.
CLOUDFLARE_TUNNEL_TOKEN=your-token-from-cloudflare-dashboard
DATA_DIR=/home/openclaw/ots-data
```

## Secret lifecycle

1. User loads `https://ots.blocklab.dev/` — Cloudflare serves the request, tunnel forwards to `cloudflared` → `app` → returns the static SPA (embedded in the Go binary).
2. SPA generates a random AES-256 key client-side, encrypts the user's secret in the browser, POSTs ciphertext to `/api/create`.
3. `app` validates `len(ciphertext) ≤ 262144`, stores under Valkey key `io.luzifer.ots:<uuid>` with TTL 604800 seconds.
4. `app` returns `{ secret_id: "<uuid>", success: true }`. SPA constructs share URL `https://ots.blocklab.dev/#<uuid>|<aes-key>`.
5. User shares the URL out-of-band (Signal, email, chat).
6. Recipient opens the URL → SPA fetches `/api/get/<uuid>` → `app` atomically reads + deletes from Valkey, returns ciphertext → SPA decrypts in the browser using the key from the URL fragment.
7. Unclaimed secrets auto-expire from Valkey after 7 days. If Valkey hits 128 MiB, `allkeys-lru` policy evicts the least-recently-used entries.

At no point does the server see plaintext or the decryption key. A full-server compromise yields only encrypted blobs.

## Operations

### First-time deploy
Walkthrough lives in `deploy/deploy.md`. High-level:
1. SSH to VPS as `openclaw`.
2. `git clone https://github.com/CodeWarriorr/ots.git ~/ots-prod`.
3. `cd ~/ots-prod/deploy && cp .env.example .env && chmod 600 .env`.
4. Edit `.env`, add `CLOUDFLARE_TUNNEL_TOKEN` and `DATA_DIR`.
5. `set -a && source .env && set +a && mkdir -p "$DATA_DIR"` (sources the `.env` into the current shell and creates the data directory). Or just use the absolute path: `mkdir -p /home/openclaw/ots-data`.
6. `docker compose up -d`.
7. Create tunnel public hostname in CF dashboard: `ots.blocklab.dev` → `http://app:3000`.
8. Run verification checklist (see below).

### Version bump
1. Edit `deploy/docker-compose.yml`, change `image: ghcr.io/luzifer/ots:vX.Y.Z`.
2. Commit + push to the fork.
3. On VPS: `cd ~/ots-prod && git pull && cd deploy && docker compose pull && docker compose up -d`.
4. Verify health (see checklist).

### Rollback
1. On VPS: `cd ~/ots-prod && git revert <bad-commit> && cd deploy && docker compose pull && docker compose up -d`.
2. Or: edit image tag back manually, `docker compose up -d`.

### Tunnel token rotation
1. Dashboard → rotate tunnel token, copy new value.
2. On VPS: edit `~/ots-prod/deploy/.env`, paste new token.
3. `docker compose up -d` (recreates only `cloudflared` since only its env changed).

### Stop / tear down
- Stop: `docker compose down` (preserves `$DATA_DIR`).
- Full tear down: `docker compose down && rm -rf "$DATA_DIR"` (destroys all unclaimed secrets).

### Incident response
- If the hostname is being hammered: toggle Cloudflare "Under Attack Mode" on the hostname. This is a single click in the dashboard.
- If a CVE lands in ots: bump the image tag, `deploy.sh`.
- If a CVE lands in valkey: bump the valkey image tag, `deploy.sh`.
- If the VPS is compromised: `.env` leaks the tunnel token — rotate immediately via the CF dashboard.

## Verification checklist

Run after any deploy. Lives in `deploy/deploy.md`.

1. `docker compose ps` — all three services show `running (healthy)`.
2. `docker compose logs cloudflared | grep -i registered` — tunnel connected and advertised to CF edge.
3. `curl -sf https://ots.blocklab.dev/` — returns HTTP 200 with HTML body.
4. Create a test secret through the web UI. Open the returned URL in a private window. Secret displays. Reload the page. Second read returns 404.
5. `docker compose exec valkey valkey-cli info memory | grep maxmemory` — `maxmemory_human:128.00M`.
6. Try pasting 300 KiB of text into the create form. `app` should reject with `secret_size` error.
7. `docker compose logs app` — no startup errors; CSP / `X-Frame-Options: DENY` / `Referrer-Policy` headers present in response.
8. Confirm `/metrics` is NOT reachable from the public internet: `curl -si https://ots.blocklab.dev/metrics`. Expected: blocked by `metricsAllowedSubnets` in `ots-customize.yaml`. The subnet allowlist is the defense-in-depth layer — `cloudflared` itself will forward any path that the tunnel rule matches, so the in-app subnet check is what actually blocks the request. If this test fails, check `ots-customize.yaml` first.

## Open questions / future work

- **Cloudflare rate-limit specifics.** The CF free-plan rate-limiting feature set is a moving target. The implementation plan should include a verification step at deploy time to check what's currently available, and either bake the rule into the deploy runbook or leave it as a manual configuration task. If the free plan doesn't meaningfully rate-limit, consider a nginx sidecar with `limit_req_zone` as a fallback, but only if abuse actually materializes.
- **Metrics scraping.** Deferred. When a Prometheus instance exists on the VPS, add a scrape job for `http://app:3000/metrics` over the bridge network.
- **Backup of `~/ots-data/`.** Not needed for ephemeral secrets. If the data model changes (e.g., long-lived secrets), revisit.
- **Switch to fork-built image.** Pre-wired. When the fork accumulates actual customizations, add a GitHub Actions workflow that builds and pushes `ghcr.io/codewarriorr/ots:<tag>`, then flip the compose file's `image:` line. No other changes required.
- **Customization beyond `maxSecretSize`.** Upstream's `customize.yaml` supports branding, i18n filtering, custom templates. Not in scope for initial deploy; add to `deploy/ots-customize.yaml` when needed.

## Decisions log

| Decision | Choice | Reason |
|---|---|---|
| Image source | Upstream `ghcr.io/luzifer/ots:v1.21.4`, pinned | Zero build/CI overhead; fork stays as insurance; one-line flip later |
| Storage | Valkey 9.0.3 alpine | Drop-in Redis fork, BSD license, matches upstream compose |
| Valkey persistence | RDB every 15 min, no AOF | Survives restart; ephemeral secrets don't need fsync durability |
| Secret size | 256 KiB | Fits passwords/keys/tokens/small files; blocks upload bombs |
| Expiry | 7 days (upstream default) | Matches UI expectations; short enough to bound Valkey growth |
| Hostname | `ots.blocklab.dev` | User-specified |
| Access model | Fully public, no auth | Use case is sharing secrets with arbitrary external recipients |
| Auto-updates | None (no Watchtower) | App rarely changes; manual bumps are intentional |
| Backups | None | Ephemeral data by design |
| Deploy layout | `deploy/` subdir in fork, on `master` | Clean boundary from upstream; upstream never touches `deploy/` |
| Spec location | `deploy/specs/` | Same boundary principle |
| Customize filename | `ots-customize.yaml` | Upstream `.gitignore` excludes `customize.yaml` at any path |
| Token injection | `.env` on VPS, gitignored, 0600 | Matches newsletters pattern; zero secrets in git |
| Data directory | `${DATA_DIR}` env var, absolute path outside repo | Keeps git clone clean; matches newsletters pattern |
