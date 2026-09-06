#!/usr/bin/env bash
# =============================================================================
# backup-full.sh — Backup completo organizado (PostgreSQL + storage + chatbot)
#
# Estructura:
#   ${BACKUP_BASE}/YYYY-MM-DD_HHMMSS/
#     manifest.txt
#     database/nm_services_*.sql.gz
#     storage/storage_uploads_*.tar.gz
#     chatbot/chatbot_uploads_*.tar.gz
#
# Uso en VPS:
#   BACKUP_BASE=/opt/nm/nm-backup cd /opt/nm/nm-deploy && ./scripts/backup-full.sh
#
# Uso local (con stack Docker levantado):
#   BACKUP_BASE=../nm-backup cd nm-deploy && ./scripts/backup-full.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BACKUP_BASE="${BACKUP_BASE:-$DEPLOY_ROOT/../nm-backup}"
TIMESTAMP="$(date +%Y-%m-%d_%H%M%S)"
RUN_DIR="$BACKUP_BASE/$TIMESTAMP"
RETENTION_DAYS="${RETENTION_DAYS:-0}"

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-nm_postgres}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-nm_services}"
STORAGE_VOLUME="${STORAGE_VOLUME:-nm_storage_uploads}"
CHATBOT_VOLUME="${CHATBOT_VOLUME:-nm_chatbot_uploads}"

log() { printf '[backup-full] %s\n' "$*" >&2; }
err() { printf '[backup-full] ERROR: %s\n' "$*" >&2; }

mkdir -p "$RUN_DIR/database" "$RUN_DIR/storage" "$RUN_DIR/chatbot"

if ! docker ps --format '{{.Names}}' | grep -qx "$POSTGRES_CONTAINER"; then
  err "Contenedor $POSTGRES_CONTAINER no está corriendo."
  exit 1
fi

DB_FILE="$RUN_DIR/database/${POSTGRES_DB}_${TIMESTAMP}.sql.gz"
log "Volcando $POSTGRES_DB..."
docker exec -t "$POSTGRES_CONTAINER" \
  pg_dump -U "$POSTGRES_USER" --no-owner --no-acl "$POSTGRES_DB" \
  | gzip -9 > "$DB_FILE"
log "BD: $DB_FILE ($(du -h "$DB_FILE" | awk '{print $1}'))"

if docker volume inspect "$STORAGE_VOLUME" >/dev/null 2>&1; then
  STORAGE_FILE="$RUN_DIR/storage/storage_uploads_${TIMESTAMP}.tar.gz"
  log "Empaquetando $STORAGE_VOLUME..."
  docker run --rm \
    -v "${STORAGE_VOLUME}:/data:ro" \
    -v "$RUN_DIR/storage:/backup" \
    alpine tar czf "/backup/storage_uploads_${TIMESTAMP}.tar.gz" -C /data .
  log "Storage: $STORAGE_FILE ($(du -h "$STORAGE_FILE" | awk '{print $1}'))"
else
  log "Volumen $STORAGE_VOLUME no encontrado — omitido."
fi

if docker volume inspect "$CHATBOT_VOLUME" >/dev/null 2>&1; then
  CHATBOT_FILE="$RUN_DIR/chatbot/chatbot_uploads_${TIMESTAMP}.tar.gz"
  log "Empaquetando $CHATBOT_VOLUME..."
  docker run --rm \
    -v "${CHATBOT_VOLUME}:/data:ro" \
    -v "$RUN_DIR/chatbot:/backup" \
    alpine tar czf "/backup/chatbot_uploads_${TIMESTAMP}.tar.gz" -C /data .
  log "Chatbot: $CHATBOT_FILE ($(du -h "$CHATBOT_FILE" | awk '{print $1}'))"
else
  log "Volumen $CHATBOT_VOLUME no encontrado — omitido."
fi

{
  echo "timestamp=$TIMESTAMP"
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "postgres_container=$POSTGRES_CONTAINER"
  echo "postgres_db=$POSTGRES_DB"
  echo "storage_volume=$STORAGE_VOLUME"
  echo "chatbot_volume=$CHATBOT_VOLUME"
  echo ""
  echo "files:"
  find "$RUN_DIR" -type f | sort | while read -r file; do
    du -h "$file"
  done
} > "$RUN_DIR/manifest.txt"

if [ "$RETENTION_DAYS" -gt 0 ]; then
  find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} +
  log "Retención: $RETENTION_DAYS días en $BACKUP_BASE"
fi

log "Backup completo en: $RUN_DIR"
log "Listo."
printf '%s\n' "$RUN_DIR"
