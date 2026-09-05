#!/usr/bin/env bash
# =============================================================================
# deploy-prod.sh — Actualización en el VPS (sin depender de tu PC)
#
# Ejecutar EN EL SERVIDOR:
#   cd /opt/nm/nm-deploy && ./scripts/deploy-prod.sh
#
# O desde tu máquina (con llave SSH):
#   ./vps/deploy-update.sh
#
# Qué hace:
#   1. git pull en los 4 repos
#   2. docker compose --profile edge up -d --build  (Angular/Next/Nest se buildean AQUÍ)
#   3. Recarga nginx con config SSL
#
# Requisitos en el VPS:
#   - /opt/nm/nm-{backend-v3,ecommerce,frontend-v2,deploy} clonados con acceso git
#   - .env ya configurados (no se sobrescriben)
# =============================================================================
set -euo pipefail

NM_ROOT="${NM_ROOT:-/opt/nm}"
DEPLOY_DIR="${DEPLOY_DIR:-$NM_ROOT/nm-deploy}"
FRONTEND_BRANCH="${FRONTEND_BRANCH:-try-backend-v2}"

log() { echo "[deploy] $*"; }
die() { echo "[deploy] ERROR: $*" >&2; exit 1; }

pull_repo() {
  local dir="$1"
  local branch="${2:-main}"
  if [ ! -d "$dir/.git" ]; then
    die "No es repo git: $dir (clona primero o usa from-local-deploy.sh una vez)"
  fi
  log "git pull $dir ($branch)..."
  git -C "$dir" fetch origin
  git -C "$dir" checkout "$branch"
  git -C "$dir" pull --ff-only origin "$branch"
}

[ -f "$DEPLOY_DIR/docker-compose.yml" ] || die "No existe $DEPLOY_DIR/docker-compose.yml"
[ -f "$NM_ROOT/nm-backend-v3/.env" ] || die "Falta $NM_ROOT/nm-backend-v3/.env"
[ -f "$DEPLOY_DIR/.env" ] || die "Falta $DEPLOY_DIR/.env"

pull_repo "$NM_ROOT/nm-backend-v3" main
pull_repo "$NM_ROOT/nm-ecommerce" main
pull_repo "$NM_ROOT/nm-frontend-v2" "$FRONTEND_BRANCH"
pull_repo "$DEPLOY_DIR" main

log "Build + up (admin Angular, storefront Next, APIs — todo en Docker)..."
cd "$DEPLOY_DIR"
export RUN_LARAVEL_ETL=false
docker compose --profile edge up -d --build

if [ -f reverse-proxy/nginx.ssl.conf ]; then
  cp reverse-proxy/nginx.ssl.conf reverse-proxy/nginx.conf
  docker compose --profile edge restart reverse-proxy
fi

docker compose ps
log "Deploy OK — $(date -Is)"
