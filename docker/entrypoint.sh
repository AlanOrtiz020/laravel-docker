#!/usr/bin/env bash
# El código viene montado desde ./src. Este script prepara lo que no está en git.
set -e
cd /var/www/html
as_app() { su-exec www-data "$@"; }

if [ ! -f artisan ]; then
  echo "ERROR: no encuentro el proyecto en /var/www/html (¿clonaste el repo en ./src?)" >&2
  exit 1
fi
if [ -z "$APP_KEY" ]; then
  echo "ERROR: falta APP_KEY en el .env" >&2
  exit 1
fi

mkdir -p storage/app/public storage/app/private storage/framework/cache/data \
         storage/framework/sessions storage/framework/views storage/logs bootstrap/cache respaldos
chown -R www-data:www-data storage bootstrap/cache respaldos

# Solo el contenedor "app" (RUN_SETUP=true) instala dependencias y migra
if [ "${RUN_SETUP:-false}" = "true" ]; then
  # Configuración leída del entorno en cada petición (sin config/route cache),
  # así un git pull que toque config/ o routes/ funciona sin pasos extra.
  rm -f bootstrap/cache/config.php bootstrap/cache/routes-v7.php bootstrap/cache/events.php

  if [ ! -f vendor/autoload.php ]; then
    echo "Instalando dependencias PHP (primera vez)..."
    as_app composer install --no-dev --optimize-autoloader --no-interaction
  fi
  if [ ! -f public/build/manifest.json ]; then
    echo "Compilando assets (primera vez)..."
    as_app npm ci --no-audit --no-fund && as_app npm run build
  fi

  echo "Esperando la base de datos ${DB_HOST}:${DB_PORT:-3306}..."
  for i in $(seq 1 30); do
    php -r 'try{new PDO("mysql:host=".getenv("DB_HOST").";port=".(getenv("DB_PORT")?:3306), getenv("DB_USERNAME"), getenv("DB_PASSWORD"));exit(0);}catch(Exception $e){exit(1);}' && break
    echo "  intento $i/30..."; sleep 2
  done
  if [ "${RUN_MIGRATIONS:-true}" = "true" ]; then
    as_app php artisan migrate --force
  fi
  as_app php artisan view:clear >/dev/null
fi

exec "$@"
