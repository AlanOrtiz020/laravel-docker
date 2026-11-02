#!/usr/bin/env bash
# Respaldo de la base de datos y de los archivos subidos (storage/app).
# Funciona con cualquier proyecto Laravel: usa mysqldump desde el contenedor "mysql".
#
#   docker/respaldar.sh
#
# Deja en backups/:
#   db-AAAA-MM-DD_HHMM.sql.gz       → base de datos completa
#   storage-AAAA-MM-DD_HHMM.tgz     → archivos subidos (src/storage/app)
# y borra los de más de BACKUP_DAYS días (por defecto 7).
#
# Para cron (todos los días a las 03:00):
#   0 3 * * * /opt/miproyecto/docker/respaldar.sh >> /opt/miproyecto/respaldar.log 2>&1
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE"
DIR="$BASE/backups"
DIAS="$(grep -E '^BACKUP_DAYS=' .env 2>/dev/null | cut -d= -f2 || true)"
DIAS="${DIAS:-7}"
FECHA="$(date +%F_%H%M)"
mkdir -p "$DIR"
log() { echo "[$(date '+%F %T')] $*"; }

# 1) Base de datos (consistente sin bloquear tablas InnoDB)
DB_OUT="$DIR/db-$FECHA.sql.gz"
docker compose exec -T mysql sh -c \
  'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --quick --routines --events --triggers \
   --set-gtid-purged=OFF --no-tablespaces "$MYSQL_DATABASE" 2>/dev/null' | gzip > "$DB_OUT.tmp"
# Un dump válido termina con "-- Dump completed"; si no, el respaldo está incompleto.
if ! gzip -dc "$DB_OUT.tmp" | tail -n 1 | grep -q "Dump completed"; then
  rm -f "$DB_OUT.tmp"
  log "ERROR: el respaldo de la base quedó incompleto (revisa: docker compose logs mysql)."
  exit 1
fi
mv "$DB_OUT.tmp" "$DB_OUT"
log "Base:     $DB_OUT ($(du -h "$DB_OUT" | cut -f1))"

# 2) Archivos subidos
if [ -d src/storage/app ]; then
  ST_OUT="$DIR/storage-$FECHA.tgz"
  tar czf "$ST_OUT" -C src storage/app
  log "Archivos: $ST_OUT ($(du -h "$ST_OUT" | cut -f1))"
fi

# 3) Limpieza
find "$DIR" -maxdepth 1 -type f \( -name 'db-*.sql.gz' -o -name 'storage-*.tgz' \) -mtime +"$DIAS" -delete
log "OK (se guardan $DIAS días)"
