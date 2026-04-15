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
