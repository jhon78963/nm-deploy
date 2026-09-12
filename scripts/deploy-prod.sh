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
#   2. docker compose -f docker-compose.prod.yml --profile edge up -d --build
#   3. Recarga nginx con config SSL
#   4. Limpia residuos de Docker (build cache, imágenes viejas, contenedores muertos)
#
# Requisitos en el VPS:
#   - /opt/nm/nm-{backend,ecommerce,frontend,deploy} clonados con acceso git
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
    nm-frontend|nm-frontend-v2) echo "admin" ;;
    nm-backend|nm-backend-v3|nm-deploy|all|"") echo "" ;;
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
  # VPS must match remote; discard hotfix copies (e.g. scp) that block ff-only pull.
  git -C "$dir" reset --hard "origin/$branch"
}

[ -f "$DEPLOY_DIR/docker-compose.yml" ] || die "No existe $DEPLOY_DIR/docker-compose.yml"
[ -f "$NM_ROOT/nm-backend/.env" ] || die "Falta $NM_ROOT/nm-backend/.env"
[ -f "$DEPLOY_DIR/.env" ] || die "Falta $DEPLOY_DIR/.env"

pull_repo "$NM_ROOT/nm-backend" main
pull_repo "$NM_ROOT/nm-ecommerce" main
pull_repo "$NM_ROOT/nm-frontend" "$FRONTEND_BRANCH"
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

log "Limpieza pre-build (libera cache de deploys anteriores)..."
bash "$DEPLOY_DIR/scripts/docker-cleanup.sh" --pre

# migrate es one-shot con container_name fijo; un run anterior (u otro compose project) bloquea el nombre.
docker rm -f nm_migrate 2>/dev/null || true

if [ -n "$COMPOSE_SERVICES" ]; then
  # shellcheck disable=SC2086
  docker compose -f docker-compose.prod.yml --profile edge up -d --build $COMPOSE_SERVICES
else
  docker compose -f docker-compose.prod.yml --profile edge up -d --build
fi

if [ -f reverse-proxy/nginx.ssl.conf ]; then
  cp reverse-proxy/nginx.ssl.conf reverse-proxy/nginx.conf
fi

log "Reiniciando reverse-proxy (refresca DNS de contenedores tras rebuild)..."
docker compose -f docker-compose.prod.yml --profile edge restart reverse-proxy

docker compose -f docker-compose.prod.yml ps

log "Limpieza post-build (residuos de este deploy)..."
bash "$DEPLOY_DIR/scripts/docker-cleanup.sh"

log "Deploy OK — $(date -Is)"
