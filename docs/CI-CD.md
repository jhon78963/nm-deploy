# CI/CD — Novedades Maritex

Arquitectura multi-repo: **CI en cada aplicación**, **CD centralizado en nm-deploy**.

```text
nm-ecommerce ──CI──► dispatch ──┐
nm-backend-v3 ──CI──► dispatch ──┼──► nm-deploy (CD) ──SSH──► VPS deploy-prod.sh
nm-frontend-v2 ──CI──► dispatch ──┘
```

## 1. Secrets en `jhon78963/nm-deploy`

| Secret | Valor |
|--------|-------|
| `VPS_HOST` | `82.39.109.241` |
| `VPS_USER` | `root` |
| SSH private key | → secret `VPS_SSH_KEY` |

## 2. Token para `repository_dispatch`

Crea un **Personal Access Token** (classic `repo` scope, o fine-grained con acceso a `nm-deploy`).

Añádelo como secret **`DEPLOY_DISPATCH_TOKEN`** en:

- `jhon78963/nm-ecommerce`
- `jhon78963/nm-backend-v3`
- `jhon78963/nm-frontend-v2`

## 3. Flujo automático

| Repo | CI (branch) | Deploy tras CI |
|------|-------------|----------------|
| `nm-ecommerce` | `main` | solo `storefront` (~5 min) |
| `nm-backend-v3` | `main` | stack completo (~18 min) |
| `nm-frontend-v2` | `try-backend-v2` | solo `admin` (~5 min) |
| `nm-deploy` | push `main` | stack completo |

Los PRs ejecutan CI pero **no** despliegan.

## 4. Deploy manual

GitHub → `nm-deploy` → Actions → **Deploy production** → Run workflow.

O desde tu PC:

```bash
./vps/deploy-update.sh
```

## 5. Verificación post-deploy

El workflow comprueba:

- `https://novedadesmaritex.net.pe`
- `https://api.novedadesmaritex.net.pe/health`
- `https://app.novedadesmaritex.net.pe`

## 6. VPS

Requisitos en `/opt/nm/` (ya configurado):

- 4 repos git con `git pull` funcional
- `.env` en `nm-deploy` y `nm-backend-v3`
- Docker + compose v2

El script `scripts/deploy-prod.sh` hace `git pull` en los 4 repos y luego `docker compose --profile edge up -d --build`.
