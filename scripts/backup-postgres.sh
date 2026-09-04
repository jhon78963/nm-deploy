#!/usr/bin/env bash
# =============================================================================
# backup-postgres.sh — Backup de nm_services (PostgreSQL en Docker)
#
# Uso manual:
#   cd nm-deploy
#   ./scripts/backup-postgres.sh
#
# Cron diario (ejemplo, 02:30 AM):
#   30 2 * * * BACKUP_DIR=/opt/nm/backups /opt/nm/nm-deploy/scripts/backup-postgres.sh >> /var/log/nm-backup.log 2>&1
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_ROOT/backups}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-nm_postgres}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-nm_services}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

log() { printf '[backup] %s\n' "$*"; }
err() { printf '[backup] ERROR: %s\n' "$*" >&2; }

if ! docker ps --format '{{.Names}}' | grep -qx "$POSTGRES_CONTAINER"; then
  err "Contenedor $POSTGRES_CONTAINER no está corriendo."
  err "Levanta el stack primero: cd $DEPLOY_ROOT && docker compose up -d postgres"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_FILE="$BACKUP_DIR/${POSTGRES_DB}_${TIMESTAMP}.sql.gz"

log "Volcando $POSTGRES_DB desde $POSTGRES_CONTAINER..."
docker exec -t "$POSTGRES_CONTAINER" \
  pg_dump -U "$POSTGRES_USER" --no-owner --no-acl "$POSTGRES_DB" \
  | gzip -9 > "$OUTPUT_FILE"

log "Backup guardado: $OUTPUT_FILE ($(du -h "$OUTPUT_FILE" | awk '{print $1}'))"

if [ "$RETENTION_DAYS" -gt 0 ]; then
  find "$BACKUP_DIR" -name "${POSTGRES_DB}_*.sql.gz" -type f -mtime +"$RETENTION_DAYS" -delete
  log "Retención: $RETENTION_DAYS días."
fi

log "Listo."
