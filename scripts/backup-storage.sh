#!/usr/bin/env bash
# =============================================================================
# backup-storage.sh — Backup del volumen de uploads (storage-service)
#
# Uso:
#   cd nm-deploy
#   ./scripts/backup-storage.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_ROOT/backups}"
STORAGE_VOLUME="${STORAGE_VOLUME:-nm_storage_uploads}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

log() { printf '[backup-storage] %s\n' "$*"; }
err() { printf '[backup-storage] ERROR: %s\n' "$*" >&2; }

if ! docker volume inspect "$STORAGE_VOLUME" >/dev/null 2>&1; then
  err "Volumen Docker $STORAGE_VOLUME no existe."
  exit 1
fi

mkdir -p "$BACKUP_DIR"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_FILE="$BACKUP_DIR/storage_uploads_${TIMESTAMP}.tar.gz"

log "Empaquetando volumen $STORAGE_VOLUME..."
docker run --rm \
  -v "${STORAGE_VOLUME}:/data:ro" \
  -v "${BACKUP_DIR}:/backup" \
  alpine tar czf "/backup/storage_uploads_${TIMESTAMP}.tar.gz" -C /data .

log "Backup guardado: $OUTPUT_FILE"

if [ "$RETENTION_DAYS" -gt 0 ]; then
  find "$BACKUP_DIR" -name 'storage_uploads_*.tar.gz' -type f -mtime +"$RETENTION_DAYS" -delete
fi

log "Listo."
