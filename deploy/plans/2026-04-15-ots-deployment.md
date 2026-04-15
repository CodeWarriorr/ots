# ots.blocklab.dev Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `ots.blocklab.dev` — a self-hosted one-time-secret service — on the openclaw VPS, fronted by a dedicated Cloudflare tunnel, with hardened docker-compose files committed to the public `CodeWarriorr/ots` fork under `deploy/`.

**Architecture:** Three hardened containers (`ots` app, `valkey`, `cloudflared`) on a single Docker bridge network, zero host ports, `.env` on VPS holds the tunnel token, deploy files are authoritative in git, manual version bumps only (no Watchtower).

**Tech Stack:** Docker Compose v2, `ghcr.io/luzifer/ots:v1.21.4`, `valkey/valkey:9.0.3-alpine`, `cloudflare/cloudflared:latest`, Bash.

**Spec:** [`deploy/specs/2026-04-15-ots-deployment-design.md`](../specs/2026-04-15-ots-deployment-design.md)

---

## Prerequisites

Before starting the local tasks:
- [ ] Docker Desktop running on your Mac with Compose v2 (`docker compose version` prints a version).
- [ ] Working directory is `/Users/mmach/git/2_AI/ots` with `origin` pointing at `git@github.com:CodeWarriorr/ots.git`.
- [ ] Current branch is `master`, clean working tree except for the already-committed spec.

Before starting the VPS tasks:
- [ ] You can `ssh openclaw` without password.
- [ ] Cloudflare account with access to the Zero Trust dashboard and control of the `blocklab.dev` zone.
- [ ] `ots.blocklab.dev` is not already in use by another service on the VPS.

---

## File Structure

Everything committed lives under `deploy/` in the fork. Each file has one clear job.

| File | Responsibility |
|---|---|
| `deploy/.gitignore` | Prevent `.env` and runtime state from landing in git |
| `deploy/.env.example` | Template for the VPS `.env`, with placeholder token |
| `deploy/ots-customize.yaml` | App-layer hardening (`maxSecretSize`, metrics allowlist) |
| `deploy/docker-compose.yml` | Three services with resource caps, healthchecks, logging |
| `deploy/deploy.sh` | One-liner wrapper for pull + compose up |
| `deploy/deploy.md` | Operator runbook (tunnel setup, first-run, bump, rollback) |
| `deploy/README.md` | One-paragraph pointer to deploy.md |

Files that live on the VPS only (never committed):
- `~/ots-prod/deploy/.env` — holds `CLOUDFLARE_TUNNEL_TOKEN` and `DATA_DIR`
- `~/ots-data/` — Valkey RDB snapshot directory (outside the repo clone)

---

## Part A — Local work (writing the deploy files)

### Task 1: Create `deploy/.gitignore`

**Why first:** We create `.gitignore` before `.env.example` so there's zero chance of a real `.env` sneaking into a commit during setup.

**Files:**
- Create: `deploy/.gitignore`

- [ ] **Step 1: Write the file**

```gitignore
# Never commit the live env file — it contains CLOUDFLARE_TUNNEL_TOKEN
.env

# Runtime state and any local override files
data/
docker-compose.override.yml
*.log
```

- [ ] **Step 2: Verify the ignore works**

Run:
```bash
cd /Users/mmach/git/2_AI/ots
echo "CLOUDFLARE_TUNNEL_TOKEN=fake-secret" > deploy/.env
git check-ignore -v deploy/.env
rm deploy/.env
```

Expected: output like `deploy/.gitignore:2:.env	deploy/.env` — confirming the rule matches. Then `rm` removes the dummy file.

- [ ] **Step 3: Commit**

```bash
cd /Users/mmach/git/2_AI/ots
git add deploy/.gitignore
git commit -m "chore(deploy): add gitignore to block secrets"
```

---

### Task 2: Create `deploy/.env.example`

**Files:**
- Create: `deploy/.env.example`

- [ ] **Step 1: Write the file**

```bash
# ots.blocklab.dev deployment environment
#
# Copy to `.env` on the VPS and fill in real values.
# `.env` is gitignored — NEVER commit it.

# Cloudflare tunnel token from the Zero Trust dashboard:
#   Networks → Tunnels → Create tunnel → Cloudflared → copy "Install connector" token
CLOUDFLARE_TUNNEL_TOKEN=your-token-from-cloudflare-dashboard

# Absolute path on the VPS where Valkey's RDB snapshots live.
# Must exist before `docker compose up`; create with: mkdir -p "$DATA_DIR"
DATA_DIR=/home/openclaw/ots-data
```

- [ ] **Step 2: Sanity check — no real token in the file**

Run:
```bash
grep -Ei '(eyJ|ghp_|github_pat_|sk_|[a-f0-9]{40,})' /Users/mmach/git/2_AI/ots/deploy/.env.example
```

Expected: **no output**. If this prints anything, a real secret has leaked — fix before committing.

- [ ] **Step 3: Commit**

```bash
cd /Users/mmach/git/2_AI/ots
git add deploy/.env.example
git commit -m "chore(deploy): add env example template"
```

---

### Task 3: Create `deploy/ots-customize.yaml`

**Why the name:** Upstream's root `.gitignore` excludes `customize.yaml` at any path, so we use `ots-customize.yaml` to side-step the ignore without touching inherited rules.

**Files:**
- Create: `deploy/ots-customize.yaml`

- [ ] **Step 1: Write the file**

```yaml
# ots app-layer hardening. Mounted read-only into the container at
# /etc/ots/ots-customize.yaml and loaded via the CUSTOMIZE env var.
#
# Upstream defaults ~115 MiB for maxSecretSize — far too generous for a
# public instance. 256 KiB fits passwords, SSH keys, API tokens, and small
# files while capping upload-bomb damage.

maxSecretSize: 262144

# Only allow /metrics scraping from the Docker bridge subnet. This is
# defense-in-depth — cloudflared forwards whatever the tunnel rule says,
# so this in-app subnet check is the layer that actually blocks public
# access to /metrics.
metricsAllowedSubnets:
  - 172.16.0.0/12
```

- [ ] **Step 2: Verify YAML parses**

Run:
```bash
python3 -c "import yaml; print(yaml.safe_load(open('/Users/mmach/git/2_AI/ots/deploy/ots-customize.yaml')))"
```

Expected: a Python dict printed with `maxSecretSize: 262144` and the subnet list.

- [ ] **Step 3: Verify the filename dodges upstream's gitignore**

Run:
```bash
cd /Users/mmach/git/2_AI/ots
git check-ignore -v deploy/ots-customize.yaml
```

Expected: **no output, exit code 1** (file is NOT ignored). If exit code is 0, the ignore rule still matches — rename or add a negation rule.

- [ ] **Step 4: Commit**

```bash
cd /Users/mmach/git/2_AI/ots
git add deploy/ots-customize.yaml
git commit -m "feat(deploy): add ots customize with 256KiB secret cap"
```

---

### Task 4: Create `deploy/docker-compose.yml`

This is the core of the plan. Three hardened services, one bridge network, zero host ports.

**Files:**
- Create: `deploy/docker-compose.yml`

- [ ] **Step 1: Write the file**

```yaml
# ots.blocklab.dev — production compose for the openclaw VPS.
#
# Spec: deploy/specs/2026-04-15-ots-deployment-design.md
#
# Run from ~/ots-prod/deploy/ on the VPS. `.env` (gitignored) must define
# CLOUDFLARE_TUNNEL_TOKEN and DATA_DIR.

name: ots

services:
  app:
    image: ghcr.io/luzifer/ots:v1.21.4
    restart: unless-stopped
    environment:
      STORAGE_TYPE: redis
      REDIS_URL: redis://valkey:6379/0
      SECRET_EXPIRY: "604800"
      CUSTOMIZE: /etc/ots/ots-customize.yaml
      LOG_LEVEL: info
    volumes:
      - ./ots-customize.yaml:/etc/ots/ots-customize.yaml:ro
    depends_on:
      valkey:
        condition: service_healthy
    networks:
      - app-network
    read_only: true
    tmpfs:
      - /tmp
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    deploy:
      resources:
        limits:
          cpus: "0.5"
          memory: 256M
          pids: 100
    healthcheck:
      # ots image is FROM scratch — no shell, no curl, no wget, no nc.
      # The Go binary itself is the only executable we can exec, so we
      # call it with --version (exits 0 without starting a server).
      test: ["CMD", "/usr/local/bin/ots", "--version"]
      interval: 30s
      timeout: 5s
      start_period: 10s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  valkey:
    image: valkey/valkey:9.0.3-alpine
    restart: unless-stopped
    command:
      - valkey-server
      - --maxmemory
      - 128mb
      - --maxmemory-policy
      - allkeys-lru
      - --save
      - "900 1"
      - --appendonly
      - "no"
    volumes:
      - ${DATA_DIR:?DATA_DIR must be set in .env}:/data
    networks:
      - app-network
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    deploy:
      resources:
        limits:
          cpus: "0.25"
          memory: 192M
          pids: 50
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 30s
      timeout: 5s
      start_period: 5s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  cloudflared:
    # Intentionally unpinned. Tunnel client negotiates wire protocol with
    # the Cloudflare edge and benefits from floating on :latest so protocol
    # upgrades land automatically. Matches the newsletters-prod pattern.
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      TUNNEL_TOKEN: ${CLOUDFLARE_TUNNEL_TOKEN:?CLOUDFLARE_TUNNEL_TOKEN must be set in .env}
    depends_on:
      app:
        condition: service_healthy
    networks:
      - app-network
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  app-network:
    driver: bridge
```

**Three things the reader should notice:**

1. The `app` healthcheck uses `ots --version` because the upstream image is `FROM scratch` — no shell, no curl, no wget. The only thing in the image is the Go binary at `/usr/local/bin/ots`. Running it with `--version` exits 0 and doesn't start a server, which is exactly what a healthcheck needs.
2. `${DATA_DIR:?...}` and `${CLOUDFLARE_TUNNEL_TOKEN:?...}` use Compose's required-variable syntax — if `.env` is missing or either var is empty, `docker compose up` refuses to start and prints a clear error. Better than silently defaulting to a broken state.
3. `pids` lives inside `deploy.resources.limits`, NOT as a top-level `pids_limit:` shortcut. Docker Compose v5+ treats the two forms as the same field and errors with `can't set distinct values on 'pids_limit' and 'deploy.resources.limits.pids'` if you use both. Keep everything inside the `deploy.resources.limits` block for consistency.

- [ ] **Step 2: Write a local-only dummy `.env` so compose can validate**

Run:
```bash
cd /Users/mmach/git/2_AI/ots/deploy
cat > .env <<'EOF'
CLOUDFLARE_TUNNEL_TOKEN=dummy-token-for-local-validation
DATA_DIR=/tmp/ots-data-local
EOF
mkdir -p /tmp/ots-data-local
```

Expected: `deploy/.env` exists, `/tmp/ots-data-local/` exists. The `.env` will be auto-ignored by git (Task 1's rule).

- [ ] **Step 3: Validate compose parses**

Run:
```bash
cd /Users/mmach/git/2_AI/ots/deploy
docker compose config --quiet
```

Expected: **empty output, exit code 0**. Compose parsed the file and resolved all env vars. Any error here (indentation, missing var, bad type) will fail fast.

- [ ] **Step 4: Inspect resolved config visually (one-time sanity check)**

Run:
```bash
cd /Users/mmach/git/2_AI/ots/deploy
docker compose config | head -60
```

Expected output includes:
- `image: ghcr.io/luzifer/ots:v1.21.4`
- `REDIS_URL: redis://valkey:6379/0`
- `CUSTOMIZE: /etc/ots/ots-customize.yaml`
- `read_only: true`

- [ ] **Step 5: Commit (compose file only, NOT the local .env)**

```bash
cd /Users/mmach/git/2_AI/ots
git status --short
# Expected: only deploy/docker-compose.yml and deploy/.env shown,
# and git should report deploy/.env as "??" (untracked, ignored means
# it won't show at all — newer git may hide it entirely).
git add deploy/docker-compose.yml
git status --short
# Expected: deploy/docker-compose.yml staged (A). No .env staged.
git commit -m "feat(deploy): add hardened docker compose for ots.blocklab.dev"
```

---

### Task 5: Local smoke test (app + valkey only, no cloudflared)

**Goal:** Prove that `app` and `valkey` come up cleanly, healthchecks pass, the API works end-to-end, and the size limit is enforced. We skip `cloudflared` because we don't have a real tunnel token.

**Files:**
- None created (uses existing compose file + the local `.env` from Task 4)

- [ ] **Step 1: Start app + valkey, skip cloudflared**

Run:
```bash
cd /Users/mmach/git/2_AI/ots/deploy
docker compose up -d app valkey
```

Expected: two containers created + started. Output includes `Network deploy_app-network Created`, `Container deploy-valkey-1 Started`, `Container deploy-app-1 Started`.

- [ ] **Step 2: Wait for healthchecks (up to ~45s), then verify**

Run:
```bash
cd /Users/mmach/git/2_AI/ots/deploy
# Give healthchecks time to run at least once
sleep 15
docker compose ps
```

Expected: both services show `Up (healthy)` in the STATUS column.

If `app` is `(unhealthy)`, check logs: `docker compose logs app | tail -30`. Common cause: typo in `REDIS_URL` or `valkey` not yet ready.

- [ ] **Step 3: Smoke test — note on `/metrics` behavior locally**

**This test cannot prove the allowlist works locally.** Docker's default bridge assigns IPs in `172.17.0.0/16`, which is a subset of our allowed `172.16.0.0/12`, so any test container on the bridge will successfully reach `/metrics` and get a 200. The real proof that `metricsAllowedSubnets` blocks public access happens in Task 13 Step 4, where we curl `https://ots.blocklab.dev/metrics` from outside the VPS.

For local curiosity only — this WILL return a 200 with Prometheus metrics:
```bash
cd /Users/mmach/git/2_AI/ots/deploy
docker run --rm --network deploy_app-network alpine/curl:latest -sf http://app:3000/metrics | head -5
```

Expected: `# HELP` lines (Prometheus metrics). Not a failure. Skip if you want and move to Step 4.

- [ ] **Step 4: Smoke test — create a secret via the API**

Run:
```bash
cd /Users/mmach/git/2_AI/ots/deploy
SECRET_BODY='{"secret":"U2FsdGVkX18wJtHr6YpTe8QrvMUUdaLZ+JMBNi1OvOQ="}'
docker run --rm --network deploy_app-network alpine/curl:latest \
  -sf -X POST -H 'content-type: application/json' \
  -d "$SECRET_BODY" http://app:3000/api/create
```

Expected output like:
```json
{"secret_id":"<some-uuid>","success":true}
```

Copy the `secret_id` — you'll need it in the next step.

- [ ] **Step 5: Smoke test — read the secret back (and confirm it's destroyed on read)**

Run (substitute `<uuid>` with the ID from Step 4):
```bash
cd /Users/mmach/git/2_AI/ots/deploy
UUID='<paste-uuid-here>'
# First read: should return the secret
docker run --rm --network deploy_app-network alpine/curl:latest \
  -sf http://app:3000/api/get/$UUID
# Expected: JSON containing the ciphertext we sent

# Second read: should 404
docker run --rm --network deploy_app-network alpine/curl:latest \
  -si http://app:3000/api/get/$UUID | head -1
# Expected: "HTTP/1.1 404 Not Found"
```

- [ ] **Step 6: Smoke test — size limit is enforced**

Run:
```bash
cd /Users/mmach/git/2_AI/ots/deploy
# Generate a 300 KiB string (larger than our 256 KiB cap)
OVERSIZED=$(python3 -c "print('A'*307200)")
docker run --rm --network deploy_app-network alpine/curl:latest \
  -si -X POST -H 'content-type: application/json' \
  -d "{\"secret\":\"$OVERSIZED\"}" http://app:3000/api/create | head -5
```

Expected: HTTP `400 Bad Request` with a body mentioning `secret_size` (the error reason from `api.go`).

- [ ] **Step 7: Tear down the smoke test**

Run:
```bash
cd /Users/mmach/git/2_AI/ots/deploy
docker compose down
rm -rf /tmp/ots-data-local
# Keep deploy/.env — it's gitignored and useful for future local tests.
# If you want it gone: rm deploy/.env
```

Expected: network + containers removed. No commit for this task — smoke test is validation, not source.

---

### Task 6: Create `deploy/deploy.sh`

**Files:**
- Create: `deploy/deploy.sh`

- [ ] **Step 1: Write the file**

```bash
#!/usr/bin/env bash
# deploy.sh — pull latest deploy files, pull latest images, restart stack.
#
# Run from ~/ots-prod/deploy/ on the VPS:
#   ./deploy.sh
#
# Requires: .env present, docker + compose v2, network access to ghcr.io.

set -euo pipefail

cd "$(dirname "$0")/.."
echo "==> Pulling latest deploy files from git"
git pull --ff-only

cd deploy
if [[ ! -f .env ]]; then
    echo "ERROR: deploy/.env is missing. Copy .env.example and fill it in." >&2
    exit 1
fi
chmod 600 .env

echo "==> Pulling latest images"
docker compose pull

echo "==> Recreating stack"
docker compose up -d

echo "==> Waiting 15s for healthchecks"
sleep 15

echo "==> Status:"
docker compose ps
```

- [ ] **Step 2: Make it executable**

Run:
```bash
chmod +x /Users/mmach/git/2_AI/ots/deploy/deploy.sh
ls -la /Users/mmach/git/2_AI/ots/deploy/deploy.sh
```

Expected: `-rwxr-xr-x` permissions on the file.

- [ ] **Step 3: Lint with shellcheck if available (non-blocking)**

Run:
```bash
shellcheck /Users/mmach/git/2_AI/ots/deploy/deploy.sh 2>&1 || echo "shellcheck not installed — skipping"
```

Expected: no warnings. If shellcheck isn't installed, skip this step.

- [ ] **Step 4: Commit**

```bash
cd /Users/mmach/git/2_AI/ots
git add deploy/deploy.sh
git commit -m "feat(deploy): add deploy.sh wrapper script"
```

---

### Task 7: Create `deploy/deploy.md`

**Files:**
- Create: `deploy/deploy.md`

- [ ] **Step 1: Write the file**

````markdown
# ots.blocklab.dev — Operator Runbook

Hardened self-hosted ots deployment on the openclaw VPS. Spec: [`specs/2026-04-15-ots-deployment-design.md`](specs/2026-04-15-ots-deployment-design.md).

## First-time setup

### 1. Create the Cloudflare tunnel

1. Go to [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/) → Networks → Tunnels.
2. Click **Create a tunnel** → **Cloudflared** → name it `ots-blocklab-dev`.
3. On the "Install connector" page, copy the tunnel token (starts with `eyJ`). Save it somewhere secure for the next step.
4. Click **Next**, then configure a public hostname:
   - Subdomain: `ots`
   - Domain: `blocklab.dev`
   - Type: `HTTP`
   - URL: `app:3000`
5. Save.

### 2. Clone and configure on the VPS

```bash
ssh openclaw
git clone https://github.com/CodeWarriorr/ots.git ~/ots-prod
cd ~/ots-prod/deploy

cp .env.example .env
chmod 600 .env
vim .env
# Paste CLOUDFLARE_TUNNEL_TOKEN, set DATA_DIR=/home/openclaw/ots-data

set -a && source .env && set +a
mkdir -p "$DATA_DIR"

docker compose up -d
```

### 3. Verify (run the checklist below)

### 4. (Optional) Cloudflare WAF hardening

In the Cloudflare dashboard for `blocklab.dev`:
- Security → WAF → Rate limiting rules → Create rule
  - Match: `hostname eq "ots.blocklab.dev" and http.request.method eq "POST" and http.request.uri.path eq "/api/create"`
  - Characteristics: IP address
  - Rate: 10 requests per 1 minute
  - Action: Block for 1 hour
- Security → Settings → Security level: **High** (for the `ots.blocklab.dev` hostname only if you can target per-hostname; else leave zone default)

Rate-limiting availability on the Cloudflare free plan has changed repeatedly. If "Rate limiting rules" isn't visible or is paywalled, skip and revisit when abuse actually materializes.

## Verification checklist

After any deploy, run every step:

1. `docker compose ps` — all 3 services `Up (healthy)`.
2. `docker compose logs cloudflared 2>&1 | grep -i "registered tunnel connection"` — tunnel connected to CF edge.
3. `curl -sfo /dev/null -w '%{http_code}\n' https://ots.blocklab.dev/` — prints `200`.
4. Open `https://ots.blocklab.dev/` in a private window. Create a test secret. Copy the URL. Open it in a second private window. Secret decrypts. Reload. Second read → 404.
5. `docker compose exec valkey valkey-cli info memory | grep maxmemory_human` — shows `maxmemory_human:128.00M`.
6. `docker compose exec valkey valkey-cli info stats | grep evicted_keys` — shows a number (0 is fine; confirms LRU eviction is armed).
7. Paste a 300 KiB blob into the create form. App rejects with a "secret size exceeds maximum" error. (If you can't type 300 KiB comfortably, skip — Task 5's API test covers this.)
8. `curl -si https://ots.blocklab.dev/metrics | head -1` — does NOT return a 200 with prometheus metrics body. Blocked by `metricsAllowedSubnets`, not by cloudflared — so if a future tunnel rule change routes differently, check `ots-customize.yaml` first.

## Bump version

When a new upstream ots release lands:

```bash
# On your Mac (in the fork repo)
cd ~/git/2_AI/ots
vim deploy/docker-compose.yml     # change image tag for 'app'
git add deploy/docker-compose.yml
git commit -m "chore(deploy): bump ots to vX.Y.Z"
git push origin master

# On the VPS
ssh openclaw
cd ~/ots-prod/deploy
./deploy.sh
# Run the verification checklist above
```

## Rollback

```bash
ssh openclaw
cd ~/ots-prod
git log --oneline deploy/docker-compose.yml | head -5
git revert <bad-sha>
cd deploy
./deploy.sh
```

## Rotate tunnel token

1. Cloudflare dashboard → Zero Trust → Networks → Tunnels → `ots-blocklab-dev` → refresh token.
2. Copy new token.
3. On VPS:
   ```bash
   vim ~/ots-prod/deploy/.env        # paste new CLOUDFLARE_TUNNEL_TOKEN
   cd ~/ots-prod/deploy
   docker compose up -d              # recreates cloudflared only
   ```
4. Run verification checklist.

## Tear down

```bash
ssh openclaw
cd ~/ots-prod/deploy
docker compose down                  # keeps ~/ots-data
# Full destroy (wipes unclaimed secrets):
# docker compose down && rm -rf ~/ots-data
```

## Incident: hostname under attack

1. Cloudflare dashboard for `blocklab.dev` → Security → Settings → toggle **Under Attack Mode** on.
2. `ssh openclaw && cd ~/ots-prod/deploy && docker compose logs -f app` to watch the actual request flow.
3. Once the spike passes, toggle Under Attack Mode off.

## Incident: VPS compromise or `.env` leak

1. Cloudflare dashboard → Tunnels → `ots-blocklab-dev` → refresh token.
2. On VPS (if it's still yours): update `.env`, `docker compose up -d`.
3. If you no longer trust the VPS: delete the tunnel in the Cloudflare dashboard — DNS goes offline immediately, `ots.blocklab.dev` returns a CF error page.
````

- [ ] **Step 2: Verify the file renders as sane markdown**

Run:
```bash
head -30 /Users/mmach/git/2_AI/ots/deploy/deploy.md
```

Expected: heading renders, sections visible.

- [ ] **Step 3: Commit**

```bash
cd /Users/mmach/git/2_AI/ots
git add deploy/deploy.md
git commit -m "docs(deploy): add operator runbook"
```

---

### Task 8: Create `deploy/README.md`

**Files:**
- Create: `deploy/README.md`

- [ ] **Step 1: Write the file**

```markdown
# deploy/

Deployment assets for `ots.blocklab.dev` on the openclaw VPS. This directory is owned by the fork operator — upstream (`Luzifer/ots`) does not touch it, so `git merge upstream/master` stays conflict-free.

## Contents

- [`specs/2026-04-15-ots-deployment-design.md`](specs/2026-04-15-ots-deployment-design.md) — design rationale, threat model, hardening recipe.
- [`plans/2026-04-15-ots-deployment.md`](plans/2026-04-15-ots-deployment.md) — the implementation plan that built this directory.
- [`deploy.md`](deploy.md) — **operator runbook.** Start here for first-time setup, version bumps, rollbacks, incidents.
- [`docker-compose.yml`](docker-compose.yml) — three services: `app`, `valkey`, `cloudflared`.
- [`ots-customize.yaml`](ots-customize.yaml) — app-layer hardening (256 KiB size cap, metrics subnet allowlist).
- [`.env.example`](.env.example) — template for the VPS `.env`. The real `.env` is gitignored.
- [`deploy.sh`](deploy.sh) — one-liner wrapper for `git pull && compose pull && compose up -d`.

No secrets are committed. Everything a real deploy needs comes from `.env` on the VPS.
```

- [ ] **Step 2: Commit**

```bash
cd /Users/mmach/git/2_AI/ots
git add deploy/README.md
git commit -m "docs(deploy): add deploy directory README"
```

---

### Task 9: Pre-push sanity check and push

- [ ] **Step 1: Review the commit series**

Run:
```bash
cd /Users/mmach/git/2_AI/ots
git log --oneline origin/master..HEAD
```

Expected: 8 commits, all with `(deploy)` scope or `docs:` prefix, in this order:
1. `docs: add ots.blocklab.dev deployment design spec` (from brainstorming)
2. `chore(deploy): add gitignore to block secrets`
3. `chore(deploy): add env example template`
4. `feat(deploy): add ots customize with 256KiB secret cap`
5. `feat(deploy): add hardened docker compose for ots.blocklab.dev`
6. `feat(deploy): add deploy.sh wrapper script`
7. `docs(deploy): add operator runbook`
8. `docs(deploy): add deploy directory README`

One commit from brainstorming plus seven from this plan.

- [ ] **Step 2: Verify no secret leaked into any commit**

Run:
```bash
cd /Users/mmach/git/2_AI/ots
git diff origin/master..HEAD | grep -Ei '(eyJ[A-Za-z0-9_\-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_|sk_live_|cloudflare.*token.*=.*[a-zA-Z0-9]{20,})'
```

Expected: **no output**. The only substring that should match is the literal placeholder in `.env.example` (`your-token-from-cloudflare-dashboard`), and that won't match the regex.

- [ ] **Step 3: Confirm `.env` is not staged or tracked**

Run:
```bash
cd /Users/mmach/git/2_AI/ots
git ls-files deploy/ | grep -E '\.env$' || echo "no .env tracked — ok"
```

Expected: `no .env tracked — ok`.

- [ ] **Step 4: Push to origin**

Run:
```bash
cd /Users/mmach/git/2_AI/ots
git push origin master
```

Expected: push succeeds to `github.com:CodeWarriorr/ots.git`.

**Checkpoint:** After this push, Part A is complete. Stop and confirm before starting Part B — VPS work is human-supervised (per deployment-caution policy).

---

## Part B — VPS deployment (human-supervised)

**Before each VPS task, confirm with the operator ("go ahead?") and check for drift on `newsletters-prod` — same host, busy neighbor.** Each task touches live state or the Cloudflare dashboard.

### Task 10: VPS prerequisites and clone

- [ ] **Step 1: Confirm openclaw has space and docker is healthy**

Run:
```bash
ssh openclaw 'df -h ~ | tail -1 && docker version --format "{{.Server.Version}}" && docker compose version --short'
```

Expected: home partition has ≥2 GiB free; docker server version printed; compose v2.x printed.

- [ ] **Step 2: Confirm port and resource headroom (informational)**

Run:
```bash
ssh openclaw 'docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | head -20'
```

Expected: a short table. We're just eyeballing that the host isn't already saturated. Three new containers will add ~0.75 CPU and ~450 MiB to the budget.

- [ ] **Step 3: Clone the fork on the VPS**

Run:
```bash
ssh openclaw 'test -d ~/ots-prod && echo "EXISTS — stop, investigate drift" || git clone https://github.com/CodeWarriorr/ots.git ~/ots-prod'
```

Expected: if `~/ots-prod` does not exist, clone runs and succeeds. If it already exists, **stop** — another agent may have created it; verify with the operator before touching.

- [ ] **Step 4: Create the data directory**

Run:
```bash
ssh openclaw 'mkdir -p ~/ots-data && ls -ld ~/ots-data'
```

Expected: `drwxrwxr-x ... ots-data` printed.

---

### Task 11: Create the Cloudflare tunnel (MANUAL — dashboard)

**This is entirely in the Cloudflare dashboard. No automation — the operator clicks through.**

- [ ] **Step 1: Ask the operator to create the tunnel**

Hand the operator this instruction block:

> In the Cloudflare Zero Trust dashboard ([one.dash.cloudflare.com](https://one.dash.cloudflare.com/)):
> 1. Networks → Tunnels → **Create a tunnel** → **Cloudflared** → name it `ots-blocklab-dev`.
> 2. On the "Install connector" page, **copy the tunnel token** (long base64-ish string starting with `eyJ`). Do NOT paste it into this chat — paste it directly into the VPS `.env` in the next task.
> 3. Click **Next**, then **Add a public hostname**:
>    - Subdomain: `ots`
>    - Domain: `blocklab.dev`
>    - Type: `HTTP`
>    - URL: `app:3000`
> 4. Save.

Wait for operator confirmation: "tunnel created, token saved, public hostname configured."

---

### Task 12: Inject token and start the stack

- [ ] **Step 1: Create `.env` from the template on the VPS**

Run:
```bash
ssh openclaw 'cd ~/ots-prod/deploy && cp .env.example .env && chmod 600 .env && ls -la .env'
```

Expected: `.env` exists with mode `-rw-------`.

- [ ] **Step 2: Prompt operator to paste the real token**

Hand the operator this instruction:

> SSH to the VPS yourself and edit `.env`. Do NOT paste the token through this chat.
> ```bash
> ssh openclaw
> vim ~/ots-prod/deploy/.env
> # Replace the CLOUDFLARE_TUNNEL_TOKEN placeholder with the real token from the dashboard
> # Confirm DATA_DIR=/home/openclaw/ots-data
> # :wq
> ```
> Tell me when `.env` is ready.

Wait for operator confirmation.

- [ ] **Step 3: Verify `.env` shape without printing the token**

Run:
```bash
ssh openclaw 'cd ~/ots-prod/deploy && cut -d= -f1 .env'
```

Expected: prints `CLOUDFLARE_TUNNEL_TOKEN` and `DATA_DIR` — key names only, no values. If you see anything extra, investigate.

- [ ] **Step 4: Start the stack**

Run:
```bash
ssh openclaw 'cd ~/ots-prod/deploy && docker compose up -d'
```

Expected: three containers created (`deploy-app-1`, `deploy-valkey-1`, `deploy-cloudflared-1`).

- [ ] **Step 5: Wait for healthchecks, then show status**

Run:
```bash
ssh openclaw 'sleep 20 && cd ~/ots-prod/deploy && docker compose ps'
```

Expected: `app` and `valkey` both `Up (healthy)`. `cloudflared` shows `Up` (it has no healthcheck) — confirm connection in the next step.

- [ ] **Step 6: Verify the tunnel registered with the edge**

Run:
```bash
ssh openclaw 'cd ~/ots-prod/deploy && docker compose logs cloudflared 2>&1 | grep -Ei "(Registered tunnel connection|connIndex)" | tail -5'
```

Expected: at least one line like `Registered tunnel connection connIndex=0 ...`. If nothing — token wrong, tunnel deleted, or network issue.

---

### Task 13: Run the verification checklist from `deploy.md`

- [ ] **Step 1: Hit the public URL**

Run:
```bash
curl -sfo /dev/null -w '%{http_code}\n' https://ots.blocklab.dev/
```

Expected: `200`.

- [ ] **Step 2: Create a real secret via the web UI**

Manual: operator opens `https://ots.blocklab.dev/` in a browser, pastes a test string, clicks create. Copies the resulting URL. Opens it in a second private window, confirms it decrypts. Reloads the page, confirms 404 on second read.

- [ ] **Step 3: Check valkey memory cap is live**

Run:
```bash
ssh openclaw 'cd ~/ots-prod/deploy && docker compose exec -T valkey valkey-cli info memory | grep -E "(maxmemory_human|maxmemory_policy)"'
```

Expected:
```
maxmemory_human:128.00M
maxmemory_policy:allkeys-lru
```

- [ ] **Step 4: Confirm `/metrics` is blocked from the public internet**

Run:
```bash
curl -si https://ots.blocklab.dev/metrics | head -3
```

Expected: something other than `200 OK` with Prometheus output. Either 404 or an empty response. If it returns 200 with `# HELP` lines, `metricsAllowedSubnets` is not gating correctly — revisit `ots-customize.yaml` before considering the deploy complete.

- [ ] **Step 5: Confirm log rotation is in effect (no immediate disk blowup)**

Run:
```bash
ssh openclaw 'cd ~/ots-prod/deploy && docker inspect $(docker compose ps -q app) | grep -A3 LogConfig'
```

Expected: `"Type": "json-file"`, `"max-size": "10m"`, `"max-file": "3"`. Using `docker compose ps -q app` resolves the container ID regardless of the compose-generated name.

- [ ] **Step 6: Run the full checklist from `deploy.md` manually and tick every item.**

---

### Task 14: (Optional) Configure Cloudflare WAF rate limiting

Per the spec, this is left as a dashboard task. Recommended rule:
- Hostname: `ots.blocklab.dev`
- Method: `POST`
- Path: `/api/create`
- Rate: 10 req/minute per IP
- Action: block for 1 hour

Hand this to the operator:

> In the Cloudflare dashboard for `blocklab.dev` → Security → WAF → Rate limiting rules:
> 1. Create a new rule named `ots-create-ratelimit`.
> 2. Expression: `(http.host eq "ots.blocklab.dev" and http.request.method eq "POST" and http.request.uri.path eq "/api/create")`
> 3. Characteristics: IP address
> 4. Rate: 10 requests per 1 minute
> 5. Action: Block, duration 1 hour
> 6. Save.
>
> If "Rate limiting rules" isn't available on your plan, skip and revisit if abuse materializes.

- [ ] **Step 1: Wait for operator to confirm the rule is saved or explicitly skipped.**

---

### Task 15: Final commit of any VPS-only changes

If during Part B you edited `deploy/*.md` with clarifications or fixed a typo, commit those now from the Mac (not from the VPS).

- [ ] **Step 1: Check for uncommitted changes**

Run:
```bash
cd /Users/mmach/git/2_AI/ots
git status --short
```

Expected: clean, or only intentional doc fixes. If there are changes, commit + push with the `git-commit` skill. If clean, skip to Step 2.

- [ ] **Step 2: Tag the successful deploy**

Run:
```bash
cd /Users/mmach/git/2_AI/ots
git tag -a "deploy/ots-blocklab-$(date -u +%Y%m%d)" -m "first production deploy of ots.blocklab.dev"
git push origin --tags
```

Expected: tag pushed. Gives us a rollback anchor.

---

## Out of scope for this plan

Explicitly deferred, documented in the spec:

- Fork-built image and CI pipeline (tracked as "open question / future work" in the spec).
- Prometheus metrics scraping from `/metrics`.
- Backups of `~/ots-data/`.
- Watchtower or any auto-updater.
- Cloudflare Access auth gate.
- Ansible integration.

Do not add any of these in this plan. If they become necessary, they get their own spec + plan.

---

## Done criteria

- All 15 tasks above checked off.
- `https://ots.blocklab.dev/` serves the ots web UI over TLS terminated at Cloudflare.
- Verification checklist in `deploy.md` passes end-to-end.
- Fork `origin/master` contains the entire `deploy/` tree, zero secrets.
- Tag `deploy/ots-blocklab-<date>` pushed to origin.
