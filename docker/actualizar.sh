#!/usr/bin/env bash
# Trae los cambios de GitHub y aplica solo los pasos que hagan falta.
#
#   docker/actualizar.sh            → git pull + pasos necesarios (si no hay commits nuevos, no hace nada)
#   docker/actualizar.sh --todo     → sin pull: corre todos los pasos (úsalo si hiciste el git pull a mano)
#
# Para cron (cada 5 minutos):
#   */5 * * * * /opt/miproyecto/docker/actualizar.sh >> /opt/miproyecto/actualizar.log 2>&1
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$BASE/src"
BRANCH="${BRANCH:-main}"
cd "$BASE"

# Evita dos ejecuciones a la vez (cron + manual)
exec 9>"$BASE/.actualizar.lock"
flock -n 9 || { echo "Ya hay una actualización en curso."; exit 0; }

log() { echo "[$(date '+%F %T')] $*"; }
artisan() { docker compose exec -T -u www-data app php artisan "$@"; }

if [ "${1:-}" = "--todo" ]; then
  CAMBIOS="composer.lock package-lock.json database/migrations/ app/"
else
  git -C "$REPO" fetch --quiet origin "$BRANCH"
  ANTES=$(git -C "$REPO" rev-parse HEAD)
  DESPUES=$(git -C "$REPO" rev-parse "origin/$BRANCH")
  [ "$ANTES" = "$DESPUES" ] && exit 0      # nada nuevo: silencio (para que el log del cron no crezca)

  log "Actualizando ${ANTES:0:7} → ${DESPUES:0:7}: $(git -C "$REPO" log -1 --format=%s "$DESPUES")"
  if ! git -C "$REPO" merge --ff-only --quiet "origin/$BRANCH"; then
    log "ERROR: el pull no se pudo aplicar (¿hay cambios hechos a mano en el servidor? revisa: cd src && git status)."
    exit 1
  fi
  CAMBIOS=$(git -C "$REPO" diff --name-only "$ANTES" "$DESPUES")
fi

cambio() { grep -qE "$1" <<<"$CAMBIOS"; }

if cambio '^composer\.lock'; then
  log "composer.lock cambió → composer install"
  docker compose exec -T -u www-data app composer install --no-dev --optimize-autoloader --no-interaction
fi

if [ -f "$REPO/package.json" ] && { cambio '^(package(-lock)?\.json|vite\.config\.(js|ts)|tailwind\.config\.(js|ts)|postcss\.config\.(js|cjs)|resources/(css|js)/)' || [ "${1:-}" = "--todo" ]; }; then
  log "Assets cambiaron → npm run build"
  docker compose exec -T -u www-data app sh -c 'npm ci --no-audit --no-fund && npm run build'
fi

if cambio '^database/migrations/'; then
  log "Migraciones nuevas → migrate"
  artisan migrate --force
fi

# Siempre: el worker de colas y el scheduler son procesos largos que mantienen el código viejo en memoria.
artisan queue:restart >/dev/null
docker compose restart scheduler >/dev/null
log "OK"
