#!/usr/bin/env bash
# =============================================================================
# restore-full.sh — Restauración de producción desde backup-full.sh
#
# ⚠️  CAUSA DOWNTIME. Sobrescribe nm_services y volúmenes de uploads.
#
# Uso en el VPS:
#   cd /opt/nm/nm-deploy
#   RESTORE_CONFIRM=YES ./scripts/restore-full.sh /opt/nm/nm-backup/2026-09-06_023000
#
# Opciones:
#   RESTORE_CONFIRM=YES     — obligatorio para ejecutar
#   PRE_BACKUP=1            — backup de emergencia antes de restaurar (default: 1)
#   SKIP_STORAGE=1          — solo restaurar BD
#   SKIP_CHATBOT=1          — no restaurar uploads del chatbot
#   COMPOSE_PROFILE=edge    — perfil docker compose (default: edge)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_ROOT="$(cd "$DEPLOY_ROOT/../nm-backend" && pwd)"
VERIFY_SCRIPT="${VERIFY_SCRIPT:-$DEPLOY_ROOT/../vps/verify-backup.sh}"

BACKUP_DIR="${1:-}"
BACKUP_BASE="${BACKUP_BASE:-/opt/nm/nm-backup}"
COMPOSE_PROFILE="${COMPOSE_PROFILE:-edge}"
PRE_BACKUP="${PRE_BACKUP:-1}"
SKIP_STORAGE="${SKIP_STORAGE:-0}"
SKIP_CHATBOT="${SKIP_CHATBOT:-0}"

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-nm_postgres}"
STORAGE_VOLUME="${STORAGE_VOLUME:-nm_storage_uploads}"
CHATBOT_VOLUME="${CHATBOT_VOLUME:-nm_chatbot_uploads}"

ENV_FILE="${ENV_FILE:-$BACKEND_ROOT/.env}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-nm_services}"

log() { printf '[restore-full] %s\n' "$*"; }
warn() { printf '[restore-full] WARN: %s\n' "$*" >&2; }
die() { printf '[restore-full] ERROR: %s\n' "$*" >&2; exit 1; }

if [ "${RESTORE_CONFIRM:-}" != "YES" ]; then
  die "Confirma con RESTORE_CONFIRM=YES (esto detiene la tienda y sobrescribe datos)."
fi

if [ -z "$BACKUP_DIR" ]; then
  BACKUP_DIR="$(find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort -r | head -1)"
fi

[ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] || die "Carpeta de backup no encontrada: ${BACKUP_DIR:-$BACKUP_BASE}"

if [ -f "$ENV_FILE" ]; then
  POSTGRES_USER="$(grep -E '^POSTGRES_USER=' "$ENV_FILE" | cut -d= -f2- || echo "$POSTGRES_USER")"
  POSTGRES_DB="$(grep -E '^POSTGRES_DB=' "$ENV_FILE" | cut -d= -f2- || echo "$POSTGRES_DB")"
fi

DB_FILE="$(find "$BACKUP_DIR/database" -name '*.sql.gz' -type f | head -1)"
STORAGE_FILE="$(find "$BACKUP_DIR/storage" -name '*.tar.gz' -type f | head -1)"
CHATBOT_FILE="$(find "$BACKUP_DIR/chatbot" -name '*.tar.gz' -type f | head -1)"

[ -n "$DB_FILE" ] || die "No hay dump SQL en $BACKUP_DIR/database"

if [ -x "$VERIFY_SCRIPT" ]; then
  log "Verificando integridad del backup..."
  bash "$VERIFY_SCRIPT" "$BACKUP_DIR"
fi

log "=== RESTAURACIÓN DE PRODUCCIÓN ==="
log "Backup:  $BACKUP_DIR"
log "BD:      $DB_FILE"
log "Storage: ${STORAGE_FILE:-omitido}"
log "Chatbot: ${CHATBOT_FILE:-omitido}"
log ""

if [ "$PRE_BACKUP" = "1" ]; then
  log "Backup de emergencia antes de restaurar..."
  export BACKUP_BASE="${BACKUP_BASE}"
  export POSTGRES_USER POSTGRES_DB RETENTION_DAYS=0
  EMERGENCY_DIR="$(bash "$SCRIPT_DIR/backup-full.sh" | tail -1)"
  log "Emergencia guardada en: $EMERGENCY_DIR"
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$POSTGRES_CONTAINER"; then
  die "Contenedor $POSTGRES_CONTAINER no está corriendo."
fi

log "Deteniendo servicios (postgres y redis siguen activos)..."
mapfile -t STOP_CONTAINERS < <(docker ps --format '{{.Names}}' | grep '^nm_' | grep -Ev 'postgres|redis' || true)
if [ "${#STOP_CONTAINERS[@]}" -gt 0 ]; then
  docker stop "${STOP_CONTAINERS[@]}" >/dev/null
  log "Detenidos: ${STOP_CONTAINERS[*]}"
else
  warn "No se encontraron contenedores nm_* para detener."
fi

log "Restaurando base de datos $POSTGRES_DB..."
docker exec -i "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${POSTGRES_DB}'
  AND pid <> pg_backend_pid();

DROP DATABASE IF EXISTS "${POSTGRES_DB}";
CREATE DATABASE "${POSTGRES_DB}";
SQL

gunzip -c "$DB_FILE" | docker exec -i "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q
log "Base de datos restaurada."

if [ "$SKIP_STORAGE" != "1" ] && [ -n "$STORAGE_FILE" ]; then
  if docker volume inspect "$STORAGE_VOLUME" >/dev/null 2>&1; then
    log "Restaurando volumen $STORAGE_VOLUME..."
    docker run --rm \
      -v "${STORAGE_VOLUME}:/data" \
      -v "$(dirname "$STORAGE_FILE"):/backup:ro" \
      alpine sh -c "rm -rf /data/* /data/.[!.]* 2>/dev/null || true; tar xzf /backup/$(basename "$STORAGE_FILE") -C /data"
    log "Storage restaurado."
  else
    warn "Volumen $STORAGE_VOLUME no existe — omitido."
  fi
elif [ "$SKIP_STORAGE" = "1" ]; then
  log "SKIP_STORAGE=1 — no se restauró storage."
else
  warn "No hay archivo storage en el backup."
fi

if [ "$SKIP_CHATBOT" != "1" ] && [ -n "$CHATBOT_FILE" ]; then
  if docker volume inspect "$CHATBOT_VOLUME" >/dev/null 2>&1; then
    log "Restaurando volumen $CHATBOT_VOLUME..."
    docker run --rm \
      -v "${CHATBOT_VOLUME}:/data" \
      -v "$(dirname "$CHATBOT_FILE"):/backup:ro" \
      alpine sh -c "rm -rf /data/* /data/.[!.]* 2>/dev/null || true; tar xzf /backup/$(basename "$CHATBOT_FILE") -C /data"
    log "Chatbot uploads restaurados."
  else
    warn "Volumen $CHATBOT_VOLUME no existe — omitido."
  fi
elif [ "$SKIP_CHATBOT" = "1" ]; then
  log "SKIP_CHATBOT=1 — no se restauró chatbot."
fi

log "Levantando stack..."
cd "$DEPLOY_ROOT"
if [ "$COMPOSE_PROFILE" = "edge" ]; then
  docker compose --profile edge up -d
else
  docker compose up -d
fi

log "Esperando gateway..."
RETRIES=0
until curl -sf "http://127.0.0.1:3000/health" >/dev/null 2>&1 || [ "$RETRIES" -ge 30 ]; do
  RETRIES=$((RETRIES + 1))
  sleep 2
done

if curl -sf "http://127.0.0.1:3000/health" >/dev/null 2>&1; then
  log "API health OK."
else
  warn "API no respondió health check — revisa: docker compose --profile edge ps"
fi

log "✅ Restauración completada desde $BACKUP_DIR"
log "Verifica: tienda, admin, un producto con imagen y login."
