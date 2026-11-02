# laravel-docker

Estructura Docker **reutilizable** para correr proyectos **Laravel en producción**: PHP-FPM, nginx, MySQL, colas, tareas programadas y scripts de actualización y respaldo.

La idea es parecida a Laradock, pero enfocada en un servidor (por ejemplo, una EC2 de AWS):
pocos servicios, consumo bajo de RAM y actualizaciones con un simple `git pull`.

- **Este repo** contiene solo la infraestructura.
- **El código de tu app** vive en su propio repositorio y se clona dentro de `src/`. Este repo ignora esa carpeta.

> 📘 La instalación paso a paso en AWS está en **[DEPLOY-AWS.md](DEPLOY-AWS.md)**.

---

## Índice

1. [Cómo funciona](#1-cómo-funciona)
2. [Requisitos de la app](#2-requisitos-de-la-app)
3. [Estructura del repositorio](#3-estructura-del-repositorio)
4. [Usar en un proyecto nuevo](#4-usar-en-un-proyecto-nuevo)
5. [Configuración: el archivo `.env`](#5-configuración-el-archivo-env)
6. [Trabajo diario: actualizar la app](#6-trabajo-diario-actualizar-la-app)
7. [Actualizar la infraestructura](#7-actualizar-la-infraestructura)
8. [Base de datos](#8-base-de-datos)
9. [Respaldos](#9-respaldos)
10. [Comandos útiles](#10-comandos-útiles)
11. [Solución de problemas](#11-solución-de-problemas)
12. [Probarlo en tu PC](#12-probarlo-en-tu-pc)
13. [Varios proyectos en el mismo servidor](#13-varios-proyectos-en-el-mismo-servidor)
14. [Decisiones técnicas](#14-decisiones-técnicas)
15. [Costos en AWS y cuándo crecer](#15-costos-en-aws-y-cuándo-crecer)

---

## 1. Cómo funciona

```
Internet ──► Servidor (Ubuntu 24.04 + Docker)
              │
              ├─ web        nginx            sirve public/ y /storage, pasa PHP a "app"
              ├─ app        php-fpm          ejecuta Laravel; al arrancar instala y migra
              ├─ queue      queue:work       procesa los jobs y correos en cola
              ├─ scheduler  schedule:work    tareas programadas de Laravel
              └─ mysql      MySQL LTS        solo en 127.0.0.1; datos en el volumen "mysql-data"
                    ▲
                    └── /opt/miproyecto/src  ← git clone de tu app, MONTADO como volumen
```

**El código no está dentro de la imagen Docker.** La imagen solo trae el entorno: PHP con sus extensiones, composer y node.
La carpeta `src/` del servidor se monta dentro de los contenedores. Por eso:

- Un `git pull` en `src/` **se ve al instante**, sin reconstruir ni reiniciar.
- Reconstruir la imagen (`--build`) solo hace falta si cambias el `Dockerfile` o la versión de PHP.

**Al arrancar por primera vez:**
1. `mysql` crea la base y el usuario definidos en `.env`.
2. `app` espera a MySQL y hace lo siguiente:
   - Si falta `vendor/`, ejecuta `composer install`.
   - Si la app tiene `package.json` y falta `public/build/`, ejecuta `npm run build`.
   - Luego ejecuta `php artisan migrate --force`.
3. `queue` y `scheduler` arrancan cuando `app` ya está sano.

---

## 2. Requisitos de la app

- **Laravel 10, 11 o 12** con base de datos **MySQL**.
- `PHP_VERSION` del `.env` debe cumplir el `"php"` del `composer.json` de la app. Por ejemplo, `^8.5` necesita `PHP_VERSION=8.5`.
- **Frontend opcional:** si hay `package.json`, se compila con `npm run build` (Vite). Si no lo hay, se omite.
- **Extensiones PHP incluidas:** `pdo_mysql`, `gd`, `zip`, `intl`, `bcmath`, `pcntl`, `exif` y `opcache`.
  Si tu app necesita otra, agrégala en el `Dockerfile`, en la línea de `docker-php-ext-install`.

> Si la app **no tiene todas sus tablas en migraciones** (por ejemplo, una base creada a mano o heredada),
> en una instalación nueva hay que **importar un respaldo de la base** (ver [sección 8](#8-base-de-datos)).

---

## 3. Estructura del repositorio

```
.
├─ README.md                  ← este archivo
├─ DEPLOY-AWS.md              ← instalación paso a paso en AWS
├─ Dockerfile                 ← imagen PHP-FPM + extensiones + composer + node
├─ docker-compose.yml         ← servicios mysql, app, queue, scheduler, web
├─ .env.production.example    ← plantilla de configuración (copiar a .env)
├─ .dockerignore / .gitignore
├─ docker/
│  ├─ entrypoint.sh           ← arranque de "app": permisos, composer, npm, migraciones
│  ├─ actualizar.sh           ← git pull de la app + pasos extra solo si hacen falta
│  ├─ respaldar.sh            ← respaldo de la base (mysqldump) y de storage/app
│  ├─ nginx/default.conf      ← sitio nginx (subidas de 25 MB, /storage, caché de assets)
│  ├─ php/php.ini             ← límites de PHP, zona horaria y opcache
│  ├─ php/www.conf            ← procesos de PHP-FPM (ajustado a 1 GB de RAM)
│  └─ mysql/my.cnf            ← MySQL liviano (ajustado a 1 GB de RAM)
└─ src/                       ← (ignorado) git clone de tu app
```

En el servidor también aparecen estos archivos y carpetas, todos ignorados por git:

| Archivo | Qué es |
|---|---|
| `.env` | Configuración real con las contraseñas |
| `backups/` | Respaldos generados por `respaldar.sh` |
| `actualizar.log`, `respaldar.log` | Historial de los cron |

---

## 4. Usar en un proyecto nuevo

```bash
# 1. Clonar esta estructura y, dentro, tu app en src/
git clone git@github.com:AlanOrtiz020/laravel-docker.git /opt/miproyecto
git clone git@github.com:USUARIO/MI-APP.git              /opt/miproyecto/src

# 2. Configurar
cd /opt/miproyecto
cp .env.production.example .env
nano .env        # APP_NAME, APP_KEY, APP_URL, contraseñas, PHP_VERSION, TZ, MAIL_*...

# 3. Levantar (la primera vez tarda 3-5 min: composer, npm, migraciones)
docker compose up -d --build
docker compose logs -f app
curl -I http://localhost/up      # 200
```

En un servidor nuevo, primero sigue [DEPLOY-AWS.md](DEPLOY-AWS.md): crear la EC2, instalar Docker, crear el swap y configurar las llaves de GitHub.

---

## 5. Configuración: el archivo `.env`

- **Ubicación:** va en `/opt/miproyecto/.env`, al lado de `docker-compose.yml`, **no** dentro de `src/`.
  Docker lo lee y entrega cada valor a los contenedores como variable de entorno. No crees un `src/.env` en el servidor.
- **Seguridad:** nunca se sube a git, porque `.gitignore` lo bloquea. La plantilla `.env.production.example` sí se sube y no tiene contraseñas reales.

**Variables de la infraestructura:**

| Variable | Por defecto | Para qué |
|---|---|---|
| `PHP_VERSION` | `8.5` | Versión de PHP de la imagen. Cambiarla requiere `docker compose up -d --build` |
| `MYSQL_VERSION` | `8.4` | Versión de MySQL. **Elígela antes de cargar datos**: se puede subir de versión, pero no bajar |
| `APP_IMAGE` | `laravel-app` | Nombre de la imagen. Usa uno distinto por proyecto si comparten servidor |
| `TZ` | `UTC` | Zona horaria de PHP y MySQL, ej. `America/Santiago` |
| `WEB_PORT` | `80` | Puerto público de nginx |
| `DB_FORWARD_PORT` | `3306` | Puerto de MySQL en `127.0.0.1` del servidor (para el túnel SSH) |
| `HOST_UID` / `HOST_GID` | `1000` | UID/GID del usuario dueño de `src/` (`id -u`, `id -g`) |
| `BACKUP_DAYS` | `7` | Días que se guardan los respaldos |

**Variables de Laravel más importantes:**

| Variable | Nota |
|---|---|
| `APP_KEY` | Clave de cifrado. Si migras desde otro servidor, **usa la misma** o se cierran las sesiones |
| `APP_URL` | URL pública, ej. `https://tu-dominio.com` |
| `APP_DEBUG` | Siempre `false` en producción |
| `DB_HOST` | `mysql` (el nombre del servicio Docker, **no** `127.0.0.1`) |
| `DB_DATABASE` / `DB_USERNAME` / `DB_PASSWORD` | Base y usuario de la app; MySQL los crea en el primer arranque |
| `DB_ROOT_PASSWORD` | Contraseña de root de MySQL (solo para administrar) |
| `SESSION_SECURE_COOKIE` | `true` con HTTPS; **`false` mientras no tengas HTTPS** (si no, el login no funciona) |
| `MAIL_*` | Servidor SMTP para los correos (ej. Amazon SES) |

Generar valores:

```bash
docker run --rm php:8.5-cli php -r "echo 'base64:'.base64_encode(random_bytes(32)).PHP_EOL;"   # APP_KEY
openssl rand -base64 24                                                                         # contraseñas
```

**Para que un cambio en `.env` se aplique**, recrea los contenedores con `docker compose up -d`. Un `restart` no basta.

> ⚠️ MySQL lee `DB_*` y `DB_ROOT_PASSWORD` **solo la primera vez que arranca**, cuando crea la base.
> Si después cambias una contraseña en el `.env`, cámbiala también dentro de MySQL (ver sección 8).

---

## 6. Trabajo diario: actualizar la app

Haces tus cambios en tu PC, los subes a GitHub y el servidor los trae con `git pull`.

**¿Basta el `git pull`?**

| Qué cambió en el commit | ¿Solo `git pull`? | Paso extra |
|---|---|---|
| Controladores, modelos, servicios | ✅ Sí | — |
| Vistas Blade, rutas, archivos de `config/` | ✅ Sí | — |
| `composer.lock` (paquete nuevo) | ❌ | `composer install` |
| JS/CSS en `resources/`, `package.json`, `vite`/`tailwind` | ❌ | `npm run build` |
| Migraciones nuevas | ❌ | `php artisan migrate` |
| Correos, jobs, tareas programadas | ❌ | Reiniciar `queue` y `scheduler`, que guardan el código viejo en memoria |

**`docker/actualizar.sh`** hace todo eso por ti: revisa qué archivos cambiaron y ejecuta solo los pasos que correspondan.

```bash
cd /opt/miproyecto
./docker/actualizar.sh            # hace git pull + pasos necesarios (si no hay nada nuevo, no hace nada)
./docker/actualizar.sh --todo     # si ya hiciste el git pull a mano: corre todos los pasos
```

**Actualización automática con cron:** revisa GitHub cada 5 minutos.

```bash
crontab -e
*/5 * * * * /opt/miproyecto/docker/actualizar.sh >> /opt/miproyecto/actualizar.log 2>&1
```

Qué esperar:
- Si un commit trae un error, **el sitio lo muestra hasta que subas el arreglo**. En este esquema no hay vuelta atrás automática.
- **No edites archivos directamente en el servidor.** Si lo haces, el script no hace el pull, para no pisar tus cambios, y lo deja anotado en `actualizar.log`. Para limpiar: `cd src && git status`, luego `git stash` o `git checkout -- .`.
- El script corre una sola vez a la vez, aunque coincidan el cron y una ejecución manual.
- Por defecto actualiza la rama `main`. Para otra rama: `BRANCH=otra ./docker/actualizar.sh`.

---

## 7. Actualizar la infraestructura

Cuando cambies algo de **este** repo (Dockerfile, nginx, php.ini, my.cnf, compose):

```bash
cd /opt/miproyecto
git pull
docker compose up -d --build
```

| Si cambiaste… | Basta con |
|---|---|
| `docker/nginx/default.conf` | `docker compose restart web` |
| `docker/php/*.ini`, `www.conf`, `Dockerfile` o `PHP_VERSION` | `docker compose up -d --build` |
| `docker/mysql/my.cnf` | `docker compose restart mysql` (el sitio se corta unos segundos) |
| `.env` | `docker compose up -d` |

Actualizar las imágenes base (parches de seguridad de PHP, nginx y MySQL), una vez al mes:

```bash
docker compose pull && docker compose build --pull && docker compose up -d
```

---

## 8. Base de datos

MySQL corre en el contenedor `mysql`. Sus datos están en el volumen Docker `mysql-data`, que **no se borra** al reiniciar ni al reconstruir.

> ⚠️ **`docker compose down -v` BORRA la base de datos.** Nunca uses `-v` en producción.

**Importar un respaldo** (`.sql` o `.sql.gz`):

```bash
cd /opt/miproyecto
set -a; . ./.env; set +a
docker compose exec -T mysql mysql -u root -p"$DB_ROOT_PASSWORD" "$DB_DATABASE" < respaldo.sql
gunzip -c backups/db-AAAA-MM-DD_HHMM.sql.gz | docker compose exec -T mysql mysql -u root -p"$DB_ROOT_PASSWORD" "$DB_DATABASE"
```

**Consola MySQL en el servidor:**

```bash
docker compose exec mysql mysql -u root -p
```

**Conectarte desde tu PC** (DBeaver, Workbench, HeidiSQL): MySQL no está expuesto a internet, así que se entra por un túnel SSH.

```bash
ssh -N -L 3307:127.0.0.1:3306 ubuntu@TU_IP -i tu-llave.pem
# luego, en tu cliente: host 127.0.0.1, puerto 3307, usuario/contraseña de DB_USERNAME/DB_PASSWORD
```

Si cambiaste `DB_FORWARD_PORT` en el `.env`, usa ese puerto en lugar del 3306.

**Cambiar la contraseña** de la app (reemplaza el usuario por tu `DB_USERNAME`):

```sql
ALTER USER 'laravel_app'@'%' IDENTIFIED BY 'nueva-contraseña';
```

Después cambia `DB_PASSWORD` en `.env` y ejecuta `docker compose up -d`.

---

## 9. Respaldos

Con la base en el mismo servidor, **los respaldos son responsabilidad tuya**: si se pierde la instancia o su disco, se pierde todo lo que no esté copiado afuera.

| Qué | Dónde está |
|---|---|
| Base de datos | Volumen `mysql-data` |
| Archivos subidos por los usuarios | `src/storage/app/` |

**`docker/respaldar.sh`** genera en `backups/` dos archivos:
- `db-AAAA-MM-DD_HHMM.sql.gz`: la base completa, con `mysqldump` consistente y sin bloquear tablas.
- `storage-AAAA-MM-DD_HHMM.tgz`: los archivos subidos.

Además, borra los de más de `BACKUP_DAYS` días y avisa si el dump quedó incompleto.

```bash
./docker/respaldar.sh                  # manual

crontab -e                             # automático, todos los días a las 03:00
0 3 * * * /opt/miproyecto/docker/respaldar.sh >> /opt/miproyecto/respaldar.log 2>&1
```

**Saca las copias fuera del servidor.** Hay dos opciones:
- **Snapshots automáticos del disco:** EC2 → *Lifecycle Manager* → política diaria con 7 copias. Cuesta centavos al mes.
- **Bajarlos a tu PC:** `scp ubuntu@TU_IP:/opt/miproyecto/backups/* .`

**Restaurar:**
- La base: importa el `db-*.sql.gz` como en la [sección 8](#8-base-de-datos).
- Los archivos: `tar xzf backups/storage-*.tgz -C src`.

---

## 10. Comandos útiles

Todos se ejecutan desde la carpeta del proyecto (`/opt/miproyecto`).

```bash
# Estado
docker compose ps                       # contenedores y su salud
docker stats --no-stream                # memoria y CPU por contenedor
free -h                                 # RAM y swap del servidor

# Logs
docker compose logs -f app              # arranque, migraciones, errores de PHP-FPM
docker compose logs -f queue            # jobs y correos
docker compose logs -f web              # accesos nginx
tail -f src/storage/logs/laravel*.log   # errores de Laravel
tail -f actualizar.log                  # actualizaciones automáticas

# Artisan / composer / npm (siempre como www-data, para no dejar archivos de root)
docker compose exec -u www-data app php artisan tinker
docker compose exec -u www-data app php artisan migrate --force
docker compose exec -u www-data app composer install --no-dev
docker compose exec -u www-data app sh -c 'npm ci && npm run build'
docker compose exec -u www-data app bash   # entrar al contenedor (como la "workspace" de Laradock)

# Reiniciar
docker compose restart                  # todo
docker compose exec -u www-data app php artisan queue:restart   # solo el worker de colas
docker compose up -d                    # recrear (aplica cambios del .env)
```

---

## 11. Solución de problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| **502 Bad Gateway** | `app` no arrancó o se está instalando | `docker compose logs app`. La primera vez espera a que termine composer/npm |
| `composer install` falla por la versión de PHP | `PHP_VERSION` no cumple el `composer.json` | Ajusta `PHP_VERSION` y ejecuta `docker compose up -d --build` |
| El login vuelve siempre a la pantalla de ingreso | `SESSION_SECURE_COOKIE=true` sin HTTPS | Ponlo en `false` y ejecuta `docker compose up -d` |
| Las URLs salen con `http://` estando detrás de Cloudflare/ALB | Laravel no confía en el proxy | En `src/bootstrap/app.php`, dentro de `withMiddleware`: `$middleware->trustProxies(at: '*');` |
| `Permission denied` en `storage/` o `vendor/` | `HOST_UID`/`HOST_GID` no coinciden con tu usuario | Revisa `id -u`/`id -g`, corrige el `.env` y ejecuta `docker compose up -d --build` |
| `SQLSTATE[HY000] [2002] Connection refused` | MySQL todavía arrancando, o `DB_HOST` mal | `DB_HOST=mysql`; `docker compose logs mysql` |
| `Access denied for user` | Cambiaste `DB_PASSWORD` después del primer arranque | Usa `ALTER USER` (sección 8) |
| `Bind for 0.0.0.0:80 failed: port is already allocated` | Otro servicio o proyecto usa el puerto | Cambia `WEB_PORT` / `DB_FORWARD_PORT` (sección 13) |
| MySQL se reinicia solo / sitio cae al azar | Sin memoria (OOM) | Verifica el swap con `free -h`. Si se repite, usa una instancia más grande (sección 15) |
| Los correos no salen | Worker caído o SMTP mal configurado | `docker compose logs queue`; revisa `MAIL_*`; mira la tabla `failed_jobs` |
| Un cambio de JS/CSS no se ve | Falta compilar assets | `./docker/actualizar.sh --todo` |
| Un cambio en un job o correo no se aplica | El worker tiene el código viejo | `docker compose exec -u www-data app php artisan queue:restart` |
| El cron no actualiza | Cambios locales en `src/` o error de git | `tail actualizar.log`; `cd src && git status` |
| Archivos subidos dan 404 | Se guardaron en el disco `local` (`storage/app/private`) y no en `public` | En la app, usa `->store('carpeta', 'public')` para lo que deba verse por URL |

---

## 12. Probarlo en tu PC

Se puede levantar igual que en el servidor:

```bash
git clone git@github.com:USUARIO/MI-APP.git src
cp .env.production.example .env
# en .env: APP_KEY, contraseñas, APP_URL=http://localhost:8088, SESSION_SECURE_COOKIE=false,
#          MAIL_MAILER=log, WEB_PORT=8088, DB_FORWARD_PORT=33306, HOST_UID/HOST_GID = id -u / id -g
docker compose up -d --build
# abrir http://localhost:8088
docker compose down          # apagar (sin -v para conservar la base)
```

Con `WEB_PORT` y `DB_FORWARD_PORT` distintos no choca con Laradock ni con un MySQL local.

---

## 13. Varios proyectos en el mismo servidor

Cada proyecto va en su propia carpeta, con su propio clon de este repo, su `src/` y su `.env`.
Docker separa contenedores y volúmenes por el nombre de la carpeta. Solo cambia esto en cada `.env`:

| Variable | Proyecto A | Proyecto B |
|---|---|---|
| `APP_IMAGE` | `proyecto-a` | `proyecto-b` |
| `WEB_PORT` | `80` | `8081` |
| `DB_FORWARD_PORT` | `3306` | `3307` |

Para que los dos respondan por el puerto 80/443 con dominios distintos, pon un proxy delante que enrute por dominio:
Cloudflare Tunnel, Caddy o nginx-proxy. Ojo con la RAM: cada proyecto suma unos 350 MB.

---

## 14. Decisiones técnicas

| Decisión | Por qué |
|---|---|
| **Código montado como volumen** (no copiado en la imagen) | Los cambios llegan con un `git pull`, sin reconstruir. A cambio, no hay vuelta atrás automática |
| **PHP configurable** (`PHP_VERSION`, por defecto 8.5) | Cada app exige su versión en `composer.json`. OPcache se instala solo cuando la versión no lo trae (anteriores a 8.5) |
| **MySQL LTS** (`MYSQL_VERSION`, por defecto 8.4) | 8.4 tiene soporte hasta 2032. La 8.0 ya no tiene soporte. La 9.7 LTS también sirve, pero hay que elegirla **antes** de cargar datos |
| **MySQL en Docker en vez de RDS** | Costo. A cambio, los respaldos son responsabilidad tuya (sección 9) |
| **Sin `config:cache` ni `route:cache`** | Un `git pull` que toque `config/` o `routes/` funciona sin pasos extra. La diferencia de velocidad es mínima en apps medianas |
| **OPcache revisa cambios cada 2 s** | Necesario con código montado. Si no, PHP seguiría usando la versión vieja |
| **www-data con el UID del servidor** | Los archivos que crea PHP (vendor, storage, build) quedan a nombre de tu usuario y `git pull` no choca con permisos |
| **MySQL solo en 127.0.0.1** | No se puede atacar desde internet. Para conectarte, túnel SSH |
| **Respaldo con `mysqldump`** | Funciona con cualquier app, sin depender de comandos propios del proyecto |
| **Dos repositorios** (infra + app) | La app no se ensucia con archivos del servidor, y la misma infraestructura sirve para varios proyectos |

---

## 15. Costos en AWS y cuándo crecer

Precios aproximados para **us-east-1 (Virginia)**, 24/7, en US$ por mes:

| Recurso | t3.micro (1 GB) | t3.small (2 GB) |
|---|---|---|
| Instancia | ~7,60 | ~15,20 |
| Disco gp3 20 GB | ~1,60 | ~1,60 |
| IP pública | ~3,65 | ~3,65 |
| **Total** | **~13** | **~20** |

- No incluye impuestos locales; por ejemplo, en Chile se suma 19% de IVA.
- São Paulo (`sa-east-1`) cuesta ~50% más, pero responde más rápido desde Sudamérica.
- Un *Savings Plan* de 1 año baja la instancia entre 30 y 40%.
- Medido con una app Laravel mediana: todo el stack usa ~350 MB de RAM en reposo.

**Señales de que hay que pasar a t3.small:**
- El swap está muy usado de forma constante (`free -h`).
- MySQL se reinicia por falta de memoria.
- El sitio se pone lento con varios usuarios o generando PDF.

**Cambiar de tamaño:** EC2 → detener la instancia → *Change instance type* → iniciar.
Son unos minutos sin servicio y no se pierde nada: el disco, el volumen de MySQL y la Elastic IP se mantienen.

Con 2 GB conviene aprovechar la RAM extra:
- `docker/mysql/my.cnf` → `innodb_buffer_pool_size = 512M`
- `docker/php/www.conf` → `pm.max_children = 12`

Después ejecuta `docker compose up -d --build && docker compose restart mysql`.

**Usar RDS en lugar de MySQL en Docker:** cambia `DB_HOST` al endpoint de la RDS en `.env`, quita del compose el servicio `mysql` y el `depends_on: mysql` de `app`, y ejecuta `docker compose up -d`.
