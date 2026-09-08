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
#   4. Limpia build cache de Docker (evita acumular ~100GB+ en el VPS)
#
# Requisitos en el VPS:
#   - /opt/nm/nm-{backend-v3,ecommerce,frontend-v2,deploy} clonados con acceso git
#   - .env ya configurados (no se sobrescriben)
# =============================================================================
set -euo pipefail

NM_ROOT="${NM_ROOT:-/opt/nm}"
DEPLOY_DIR="${DEPLOY_DIR:-$NM_ROOT/nm-deploy}"
FRONTEND_BRANCH="${FRONTEND_BRANCH:-main}"
SOURCE_REPO="${SOURCE_REPO:-all}"
SOURCE_SHA="${SOURCE_SHA:-unknown}"

log() { echo "[deploy] $*"; }
die() { echo "[deploy] ERROR: $*" >&2; exit 1; }

resolve_compose_services() {
  case "$SOURCE_REPO" in
    nm-ecommerce) echo "storefront" ;;
    nm-frontend-v2) echo "admin" ;;
    nm-backend-v3|nm-deploy|all|"") echo "" ;;
    *) log "WARN: SOURCE_REPO desconocido ($SOURCE_REPO) — rebuild completo"; echo "" ;;
  esac
}

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

COMPOSE_SERVICES="$(resolve_compose_services)"
log "Origen: $SOURCE_REPO @ $SOURCE_SHA"
if [ -n "$COMPOSE_SERVICES" ]; then
  log "Build + up (servicios: $COMPOSE_SERVICES)..."
else
  log "Build + up (admin Angular, storefront Next, APIs — todo en Docker)..."
fi
cd "$DEPLOY_DIR"
export RUN_LARAVEL_ETL=false
if [ -n "$COMPOSE_SERVICES" ]; then
  # shellcheck disable=SC2086
  docker compose --profile edge up -d --build $COMPOSE_SERVICES
else
  docker compose --profile edge up -d --build
fi

if [ -f reverse-proxy/nginx.ssl.conf ]; then
  cp reverse-proxy/nginx.ssl.conf reverse-proxy/nginx.conf
  docker compose --profile edge restart reverse-proxy
fi

docker compose ps

log "Limpiando residuos de Docker (build cache + imágenes huérfanas)..."
# Seguro post-build: las imágenes taggeadas (nm-*) ya están guardadas; esto solo borra capas intermedias.
docker builder prune -af || true
docker image prune -f || true

log "Deploy OK — $(date -Is)"
