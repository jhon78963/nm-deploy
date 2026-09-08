#!/usr/bin/env bash
# =============================================================================
# docker-cleanup.sh — Libera espacio de residuos Docker (build cache, capas viejas)
#
# Seguro en producción:
#   - NO borra volúmenes (postgres, uploads, etc.)
#   - NO toca contenedores en ejecución ni sus imágenes activas
#
# Uso:
#   ./scripts/docker-cleanup.sh          # limpieza completa
#   ./scripts/docker-cleanup.sh --pre    # solo build cache (antes de build)
# =============================================================================
set -euo pipefail

MODE="${1:-post}"

log() { echo "[docker-cleanup] $*"; }

report_disk() {
  log "Docker:"
  docker system df 2>/dev/null || true
  log "Disco (/):"
  df -h / 2>/dev/null | tail -1 || true
}

prune_build_cache() {
  log "Build cache..."
  docker builder prune -af 2>/dev/null || true
}

prune_post_build() {
  log "Imágenes sin uso (incluye capas <none> de rebuilds anteriores)..."
  docker image prune -af 2>/dev/null || true

  log "Contenedores detenidos..."
  docker container prune -f 2>/dev/null || true

  log "Redes huérfanas..."
  docker network prune -f 2>/dev/null || true
}

log "=== Inicio ($MODE) ==="
report_disk

prune_build_cache

if [ "$MODE" != "--pre" ]; then
  prune_post_build
  prune_build_cache
fi

log "=== Fin ($MODE) ==="
report_disk
