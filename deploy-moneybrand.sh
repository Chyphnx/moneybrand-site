#!/usr/bin/env bash
set -euo pipefail

PROJ="$HOME/moneybrand-site"
DOMAIN="https://www.moneybrandclothing.com"

echo "[MoneyBrand] ===== Deploy start ====="

cd "$PROJ"

echo "[MoneyBrand] Pulling latest from origin/main..."
git pull --rebase --autostash origin main

# Ensure data folder exists
mkdir -p data

# If clipboard has content, treat it as the latest products.json
if command -v pbpaste >/dev/null 2>&1; then
  CLIP="$(pbpaste)"
else
  CLIP=""
fi

if [ -n "${CLIP:-}" ]; then
  echo "[MoneyBrand] Updating data/products.json from clipboard..."
  printf '%s\n' "$CLIP" > data/products.json
else
  echo "[MoneyBrand] Clipboard empty – keeping existing data/products.json."
fi

# Stage JSON + any new/updated images
git add data/products.json img 2>/dev/null || true

# Nothing to commit?
if git diff --cached --quiet; then
  echo "[MoneyBrand] No changes staged. Nothing to deploy."
  exit 0
fi

COMMIT_MSG="MoneyBrand deploy $(date '+%Y-%m-%d %H:%M:%S')"
echo "[MoneyBrand] Committing: $COMMIT_MSG"
git commit -m "$COMMIT_MSG"

echo "[MoneyBrand] Pushing to origin/main..."
git push origin main

echo "[MoneyBrand] Deployed → $DOMAIN"
echo "[MoneyBrand] ===== Deploy complete ====="
