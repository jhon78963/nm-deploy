#!/usr/bin/env bash
# =============================================================================
# validate-restore-backup.sh — Prueba que un backup se puede restaurar SIN tocar prod
#
# Levanta un Postgres temporal, importa el dump SQL y ejecuta consultas mínimas.
# No modifica nm_postgres ni los volúmenes de producción.
#
# Uso:
#   ./scripts/validate-restore-backup.sh
#   ./scripts/validate-restore-backup.sh /opt/nm/nm-backup/2026-09-06_023000
#   BACKUP_BASE=/opt/nm/nm-backup ./scripts/validate-restore-backup.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFY_SCRIPT="${VERIFY_SCRIPT:-$DEPLOY_ROOT/../vps/verify-backup.sh}"

BACKUP_DIR="${1:-}"
BACKUP_BASE="${BACKUP_BASE:-/opt/nm/nm-backup}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
VALIDATE_CONTAINER="${VALIDATE_CONTAINER:-nm_restore_validate_$$}"
POSTGRES_DB="${POSTGRES_DB:-nm_services}"

log() { printf '[validate-restore] %s\n' "$*"; }
die() { printf '[validate-restore] ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  docker rm -f "$VALIDATE_CONTAINER" >/dev/null 2>&1 || true
  [ -n "${TMP_STORAGE:-}" ] && [ -d "$TMP_STORAGE" ] && rm -rf "$TMP_STORAGE"
}
trap cleanup EXIT

if [ -z "$BACKUP_DIR" ]; then
  BACKUP_DIR="$(find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort -r | head -1)"
fi

[ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] || die "No hay carpeta de backup en $BACKUP_BASE"

if [ -x "$VERIFY_SCRIPT" ]; then
  log "Verificando integridad de archivos..."
  bash "$VERIFY_SCRIPT" "$BACKUP_DIR"
else
  log "verify-backup.sh no encontrado — omitiendo chequeo previo"
fi

DB_FILE="$(find "$BACKUP_DIR/database" -name '*.sql.gz' -type f | head -1)"
[ -n "$DB_FILE" ] || die "No se encontró dump SQL en $BACKUP_DIR/database"

STORAGE_FILE="$(find "$BACKUP_DIR/storage" -name '*.tar.gz' -type f | head -1)"
CHATBOT_FILE="$(find "$BACKUP_DIR/chatbot" -name '*.tar.gz' -type f | head -1)"

log "Backup: $BACKUP_DIR"
log "SQL:    $DB_FILE ($(du -h "$DB_FILE" | awk '{print $1}'))"

log "Levantando Postgres temporal ($VALIDATE_CONTAINER)..."
docker run -d --name "$VALIDATE_CONTAINER" \
  -e POSTGRES_PASSWORD=validate_only \
  "$POSTGRES_IMAGE" >/dev/null

RETRIES=0
until docker exec "$VALIDATE_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; do
  RETRIES=$((RETRIES + 1))
  if [ "$RETRIES" -ge 30 ]; then
    die "Postgres temporal no respondió a tiempo."
  fi
  sleep 1
done

log "Creando base $POSTGRES_DB e importando dump (puede tardar unos minutos)..."
docker exec -i "$VALIDATE_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE \"$POSTGRES_DB\";" >/dev/null

if ! gunzip -c "$DB_FILE" | docker exec -i "$VALIDATE_CONTAINER" psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q; then
  die "Falló la importación SQL del backup."
fi

log "Consultas de sanidad en la BD restaurada:"
for query in \
  "SELECT 'users=' || COUNT(*) FROM users WHERE is_deleted = false" \
  "SELECT 'products=' || COUNT(*) FROM products WHERE is_deleted = false" \
  "SELECT 'ecommerce_orders=' || COUNT(*) FROM ecommerce_orders" \
  "SELECT 'warehouses=' || COUNT(*) FROM warehouses WHERE is_deleted = false"
do
  result="$(docker exec "$VALIDATE_CONTAINER" psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -t -A -c "$query")"
  log "  $result"
done

if [ -n "$STORAGE_FILE" ]; then
  TMP_STORAGE="$(mktemp -d)"
  log "Extrayendo storage de prueba: $STORAGE_FILE"
  tar -xzf "$STORAGE_FILE" -C "$TMP_STORAGE"
  FILE_COUNT="$(find "$TMP_STORAGE" -type f | wc -l | tr -d ' ')"
  log "Storage OK: $FILE_COUNT archivos extraíbles"
fi

if [ -n "$CHATBOT_FILE" ]; then
  tar -tzf "$CHATBOT_FILE" >/dev/null
  log "Chatbot tar OK: $CHATBOT_FILE"
fi

log "✅ Backup validado: se puede restaurar en producción con restore-full.sh"
log "   Carpeta: $BACKUP_DIR"
