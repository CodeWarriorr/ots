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
