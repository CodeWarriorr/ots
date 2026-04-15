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
7. Paste a 300 KiB blob into the create form. App rejects with a "secret size exceeds maximum" error. (If you can't type 300 KiB comfortably, skip — the API test in the plan's Task 5 covers this.)
8. `curl -si https://ots.blocklab.dev/metrics | head -1` — returns `HTTP/2 404`, not a 200 with a Prometheus body. `metricsAllowedSubnets: []` in `ots-customize.yaml` makes the mux matcher return false, so the route falls through to the asset-delivery 404 handler. If this returns `200` with `# HELP go_gc_...`, the allowlist has drifted — set it back to `[]` and restart the `app` service.

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
