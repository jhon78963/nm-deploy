# nm-deploy — Orquestación Docker (producción)

Une **backend**, **tienda** y **admin** en un solo stack Docker Compose.

## Repos requeridos (hermanos en el mismo directorio)

```
/opt/nm/                    # o ~/nm-projects/
├── nm-backend-v3/            # API NestJS + Postgres + Redis
├── nm-ecommerce/             # Tienda Next.js
├── nm-frontend-v2/          # Admin Angular
└── nm-deploy/                # Este repo (compose + reverse-proxy)
```

`nm-backup/` **no** es un repo ni va al VPS en runtime. Solo contiene dumps `.backup` del sistema Laravel legacy para la **migración inicial** (ver abajo).

---

## Despliegue en VPS

### 1. Prerequisitos

- Ubuntu/Debian con Docker + Docker Compose v2
- DNS apuntando al VPS:
  - `novedadesmaritex.net.pe` → tienda
  - `app.novedadesmaritex.net.pe` → admin
  - `api.novedadesmaritex.net.pe` → API
- Puertos 80/443 abiertos (el resto solo red interna Docker)

### 2. Clonar repos

```bash
mkdir -p /opt/nm && cd /opt/nm

git clone https://github.com/jhon78963/nm-backend-v3.git
git clone https://github.com/jhon78963/nm-ecommerce.git
git clone https://github.com/jhon78963/nm-frontend-v2.git
git clone https://github.com/jhon78963/nm-deploy.git

# Admin está en try-backend-v2 hasta merge a main
cd nm-frontend-v2 && git checkout try-backend-v2 && cd ..
```

### 3. Configurar secrets

```bash
cp nm-backend-v3/.env.example nm-backend-v3/.env
cp nm-deploy/.env.example nm-deploy/.env
```

Editar `nm-backend-v3/.env`:

- `JWT_SECRET`, `JWT_REFRESH_SECRET` (generar únicos)
- `POSTGRES_PASSWORD` (fuerte)
- `FRONTEND_URL=https://app.novedadesmaritex.net.pe`
- `ECOMMERCE_STORE_URL=https://novedadesmaritex.net.pe`
- `CORS_ORIGINS` con dominios reales
- Mail (Zoho), storage keys, etc.

Editar `nm-deploy/.env`:

- `STORE_WAREHOUSE_ID`
- `NEXT_PUBLIC_APP_URL`, OAuth Google si aplica

### 4. Levantar stack

```bash
cd nm-deploy

# Sin reverse-proxy (acceso por puerto)
docker compose up -d --build

# Con reverse-proxy por dominio (producción)
docker compose --profile edge up -d --build
```

### 5. TLS (HTTPS)

El `reverse-proxy` actual escucha en puerto 80. Para HTTPS:

- **Opción A:** Cloudflare delante del VPS (más simple)
- **Opción B:** Certbot en el host + nginx/Caddy delante del compose
- **Opción C:** Extender `reverse-proxy/nginx.conf` con certificados Let's Encrypt

### 6. Actualizar en producción

```bash
cd /opt/nm/nm-backend-v3 && git pull
cd /opt/nm/nm-ecommerce && git pull
cd /opt/nm/nm-frontend-v2 && git pull
cd /opt/nm/nm-deploy && git pull

cd /opt/nm/nm-deploy
docker compose up -d --build
# Solo migraciones pendientes (sin rebuild):
docker compose run --rm migrate
```

---

## Migración de datos — ¿cómo funciona?

Hay **dos bases** involucradas en la migración inicial:

| Base | Contenido |
|------|-----------|
| `nm_db` | Esquema Laravel legacy (origen) |
| `nm_services` | Esquema Prisma nuevo (destino, lo que usa la app) |

El flujo automático (`docker-prisma-migrate.sh`):

1. Crea tablas Prisma en `nm_services` (`prisma migrate deploy`)
2. Lee datos de `nm_db` (Laravel)
3. Ejecuta **ETL** → copia/transforma a `nm_services`
4. La app en producción **solo usa `nm_services`**

`nm_db` queda como referencia histórica; en prod puedes borrarla después de validar.

### Diagrama

```
nm-backup/*.backup (archivo local)
        │
        ▼ pg_restore
     nm_db (Laravel)
        │
        ▼ ETL (scripts migrate-laravel-data.ts, etc.)
   nm_services (Prisma)  ←── la app usa ESTA base
```

---

## Tres caminos para llevar datos a producción

### Camino A — Recomendado: migrar local, exportar, importar en VPS

Útil cuando ya probaste todo en local y quieres subir datos validados.

```bash
# ── EN LOCAL (una sola vez) ──────────────────────────────────────────────

# 1. Restaurar backup Laravel + ETL (si aún no lo hiciste)
cd nm-backend-v3
./scripts/restore-nm-db-backup.sh ../nm-backup/tu_backup.backup

# 2. Probar tienda, admin, pedidos, etc. con datos reales

# 3. Exportar nm_services ya migrada
docker exec nm_postgres pg_dump -U postgres --no-owner --no-acl nm_services \
  | gzip > nm_services_prod_ready.sql.gz

# 4. (Opcional) Exportar imágenes/uploads
cd ../nm-deploy && ./scripts/backup-storage.sh

# ── EN VPS ───────────────────────────────────────────────────────────────

# 5. Clonar repos y configurar .env (sin levantar apps aún)
cd /opt/nm/nm-deploy
docker compose up -d postgres   # solo Postgres

# 6. Importar dump
gunzip -c nm_services_prod_ready.sql.gz | \
  docker exec -i nm_postgres psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS nm_services;" && \
  docker exec -i nm_postgres psql -U postgres -d postgres -c "CREATE DATABASE nm_services;" && \
  gunzip -c nm_services_prod_ready.sql.gz | \
  docker exec -i nm_postgres psql -U postgres -d nm_services

# 7. Importar uploads si los exportaste
#    (restaurar el .tar.gz al volumen nm_storage_uploads)

# 8. Levantar todo el stack
RUN_LARAVEL_ETL=false docker compose up -d --build
```

En `nm-backend-v3/.env` del VPS pon `RUN_LARAVEL_ETL=false` para que el servicio `migrate` **no** intente ETL de Laravel (ya tienes datos).

### Camino B — Migrar directamente en el VPS

Útil si el dump Laravel solo existe en un servidor o es muy grande para mover dos veces.

```bash
# 1. Subir el .backup al VPS
scp nm-backup/tu_backup.backup user@vps:/opt/nm/backups/

# 2. En VPS, clonar repos y configurar .env
cd /opt/nm/nm-backend-v3
./scripts/restore-nm-db-backup.sh /opt/nm/backups/tu_backup.backup

# 3. Levantar el resto del stack
cd ../nm-deploy
docker compose --profile edge up -d --build
```

Mismo ETL que en local, pero corre en el servidor.

### Camino C — Producción ya viva (solo actualizaciones)

Cuando `nm_services` ya existe en el VPS con datos reales:

- **No** uses `nm-backup` ni ETL
- Solo `docker compose run --rm migrate` → aplica migraciones Prisma nuevas
- Backups periódicos con los scripts de este repo

---

## ¿Qué subir al VPS y qué no?

| Artefacto | ¿Subir al VPS? | Notas |
|-----------|----------------|-------|
| Código (git clone) | ✅ Sí | 4 repos hermanos |
| `nm-backup/*.backup` | ⚠️ Solo migración inicial | No queda en prod; borrar después |
| `nm_services` exportado (`.sql.gz`) | ✅ Sí (camino A) | BD lista para la app |
| Uploads / imágenes | ✅ Sí | Volumen `nm_storage_uploads` |
| `.env` locales | ✅ Sí (en servidor) | Nunca en git |

---

## Backups en producción

Scripts en `scripts/`:

```bash
cd nm-deploy
chmod +x scripts/*.sh

# Base de datos (nm_services)
./scripts/backup-postgres.sh

# Archivos subidos (imágenes productos, etc.)
./scripts/backup-storage.sh
```

Por defecto guarda en `nm-deploy/backups/` (gitignored). En prod:

```bash
export BACKUP_DIR=/opt/nm/backups
export RETENTION_DAYS=14
./scripts/backup-postgres.sh
```

### Cron ejemplo

```cron
# /etc/cron.d/nm-backup
30 2 * * * root BACKUP_DIR=/opt/nm/backups /opt/nm/nm-deploy/scripts/backup-postgres.sh >> /var/log/nm-backup.log 2>&1
0  3 * * 0 root BACKUP_DIR=/opt/nm/backups /opt/nm/nm-deploy/scripts/backup-storage.sh >> /var/log/nm-backup.log 2>&1
```

### Restaurar un backup de BD

```bash
gunzip -c /opt/nm/backups/nm_services_YYYYMMDD_HHMMSS.sql.gz | \
  docker exec -i nm_postgres psql -U postgres -d nm_services
```

---

## Acceso rápido

| Servicio | Sin edge | Con `--profile edge` |
|----------|----------|----------------------|
| Tienda | http://IP:3015 | https://novedadesmaritex.net.pe |
| Admin | http://IP:8080 | https://app.novedadesmaritex.net.pe |
| API | http://IP:3000 | https://api.novedadesmaritex.net.pe |

---

## Checklist pre-lanzamiento

- [ ] Datos migrados y probados (`nm_services` con productos, usuarios, pedidos)
- [ ] Uploads/imágenes copiados al volumen storage
- [ ] JWT y passwords fuertes en `.env`
- [ ] CORS y URLs públicas correctas
- [ ] HTTPS activo
- [ ] Backup cron configurado y **restauración probada**
- [ ] Pedido de prueba end-to-end en staging/prod
- [ ] `RUN_LARAVEL_ETL=false` en prod si ya no necesitas Laravel

---

## Referencias

- Migración Laravel → Prisma: `nm-backend-v3/scripts/docker-prisma-migrate.sh`
- Restaurar backup legacy: `nm-backend-v3/scripts/restore-nm-db-backup.sh`
- Roadmap seguridad/SEO: `docs/ecommerce-production-roadmap.md` (en monorepo local)
