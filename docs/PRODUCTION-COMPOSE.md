# Producción — Docker Compose

Guía del stack de producción en VPS. El entry point oficial es **`docker-compose.prod.yml`** en la raíz de `nm-deploy`.

## Mapa de archivos Compose

| Archivo | Uso | Dónde |
|---------|-----|-------|
| `nm-backend/docker-compose.yml` | Dev local: Postgres + Redis + servicios sueltos | Solo desarrollo |
| `nm-backend/docker-compose.full.yml` | Stack backend completo (todos los microservicios) | Incluido por nm-deploy |
| `nm-deploy/docker-compose.yml` | Orquestación unificada (backend + tienda + admin + edge) | Dev/staging unificado |
| `nm-deploy/docker-compose.observability.yml` | Loki + Promtail + Grafana | Profile `observability` |
| **`nm-deploy/docker-compose.prod.yml`** | **Producción VPS** — cierra puertos internos | **Usar en prod** |

```
nm-deploy/docker-compose.prod.yml
        │
        ├── include → docker-compose.yml
        │                 ├── include → nm-backend/docker-compose.full.yml
        │                 ├── include → docker-compose.observability.yml
        │                 └── services: storefront, admin, reverse-proxy, certbot
        └── overrides: sin ports en host (excepto reverse-proxy 80/443)
```

## Comandos en producción

### Primer deploy

```bash
cd /opt/nm/nm-deploy

# Secrets (una sola vez)
cp .env.example .env
cp ../nm-backend/.env.example ../nm-backend/.env
nano .env ../nm-backend/.env

# Stack con HTTPS
docker compose -f docker-compose.prod.yml --profile edge up -d --build
```

### Actualización (manual o vía CI)

```bash
cd /opt/nm/nm-deploy
./scripts/deploy-prod.sh
```

El script hace `git pull` en los 4 repos y ejecuta:

```bash
docker compose -f docker-compose.prod.yml --profile edge up -d --build
```

### Con observabilidad

```bash
docker compose -f docker-compose.prod.yml --profile edge --profile observability up -d --build
```

| Servicio | URL prod |
|----------|----------|
| Tienda | https://novedadesmaritex.net.pe |
| Admin ERP | https://app.novedadesmaritex.net.pe |
| API | https://api.novedadesmaritex.net.pe |
| Chatbot webhook | https://chatbot.novedadesmaritex.net.pe |
| Grafana | https://grafana.novedadesmaritex.net.pe |

### Migraciones Prisma (sin rebuild)

```bash
cd /opt/nm/nm-deploy
docker compose -f docker-compose.prod.yml run --rm migrate
```

## Perfiles Docker

| Profile | Servicios | Cuándo |
|---------|-----------|--------|
| *(ninguno)* | Backend + tienda + admin | Dev local por puertos directos |
| `edge` | `reverse-proxy`, `certbot` | **Producción obligatorio** |
| `observability` | `loki`, `promtail`, `grafana` | Opcional — logs centralizados |
| `tools` | `pgadmin` | Solo emergencia; no en prod habitual |

## Puertos: dev vs prod

| Servicio | Dev (`docker-compose.yml`) | Prod (`docker-compose.prod.yml` + `edge`) |
|----------|----------------------------|-------------------------------------------|
| Tienda | `:3015` host | Solo vía nginx → `storefront:3015` |
| Admin | `:8080` host | Solo vía nginx → `admin:80` |
| API gateway | `:3000` host | Solo vía nginx → `gateway:3000` |
| Postgres | `:5433` host | Red interna Docker |
| Redis | `:6379` host | Red interna Docker |
| Grafana | `:3010` host | Solo vía nginx → `grafana:3000` |
| **Público** | Varios puertos | **Solo `:80` y `:443`** (reverse-proxy) |

## Variables de entorno

### `nm-deploy/.env` (producción)

```bash
DEPLOY_ENV=production
NG_CONFIGURATION=production
NEXT_PUBLIC_APP_URL=https://novedadesmaritex.net.pe
FRONTEND_URL=https://app.novedadesmaritex.net.pe
ECOMMERCE_STORE_URL=https://novedadesmaritex.net.pe
CORS_ORIGINS=https://app.novedadesmaritex.net.pe,https://novedadesmaritex.net.pe,https://www.novedadesmaritex.net.pe
RUN_LARAVEL_ETL=false
STORE_WAREHOUSE_ID=<uuid almacén tienda>

# Observabilidad (si usas profile observability)
GRAFANA_ADMIN_PASSWORD=<fuerte>
GRAFANA_ROOT_URL=https://grafana.novedadesmaritex.net.pe
```

### `nm-backend/.env` (producción)

```bash
NODE_ENV=production
POSTGRES_PASSWORD=<fuerte>
JWT_SECRET=<generado>
JWT_REFRESH_SECRET=<generado>
FRONTEND_URL=https://app.novedadesmaritex.net.pe
ECOMMERCE_STORE_URL=https://novedadesmaritex.net.pe
CORS_ORIGINS=<mismos dominios>
STORAGE_PUBLIC_BASE_URL=https://api.novedadesmaritex.net.pe/api/v1/storage/files
RUN_LARAVEL_ETL=false
# Mail, Culqi, Meta WhatsApp, SUNAT, Sentry…
```

Ver también: [`vps/README.md`](../../vps/README.md) (conexión SSH, restore BD, checklist).

## TLS / nginx

1. Primera vez: levantar con `nginx.conf` (HTTP) para ACME challenge.
2. Emitir certificados Let's Encrypt (certbot).
3. Copiar `reverse-proxy/nginx.ssl.conf` → `reverse-proxy/nginx.conf` (lo hace `deploy-prod.sh`).
4. `docker compose -f docker-compose.prod.yml --profile edge restart reverse-proxy`

## CI/CD

GitHub Actions en `nm-deploy` ejecuta `scripts/deploy-prod.sh` vía SSH tras CI verde en cada repo de app.

Detalle: [CI-CD.md](./CI-CD.md).

## Troubleshooting

```bash
# Estado de contenedores
docker compose -f docker-compose.prod.yml ps

# Logs de un servicio
docker compose -f docker-compose.prod.yml logs -f gateway

# Health API
curl -fsS https://api.novedadesmaritex.net.pe/health

# Verificar que no hay puertos internos expuestos (prod)
ss -tlnp | grep -E '3000|3015|5433|6379'   # debería estar vacío salvo 80/443
```

## Qué NO usar en producción

- `nm-backend/docker-compose.yml` solo — incompleto (falta tienda/admin/nginx).
- `docker compose up` sin `-f docker-compose.prod.yml` — expone puertos de dev al host.
- Profile `tools` (pgAdmin) expuesto a internet.
- `RUN_LARAVEL_ETL=true` después de la migración inicial.
