# Wilvil — Infraestructura Docker

Este repositorio contiene **solo la infraestructura** para correr la app Wilvil
(Laravel 12 + Livewire) en un servidor con Docker: PHP, nginx, MySQL, colas, tareas programadas y scripts de actualización.

El **código de la app** vive en su propio repositorio
([AlanOrtiz020/newilvil](https://github.com/AlanOrtiz020/newilvil)) y se clona dentro de `src/`.
Este repo ignora `src/` por completo.

> 📘 La instalación paso a paso en AWS está en **[DEPLOY-AWS.md](DEPLOY-AWS.md)**.
> Este README explica cómo está armado y cómo se trabaja día a día.

---

## Índice

1. [Cómo funciona](#1-cómo-funciona)
2. [Estructura del repositorio](#2-estructura-del-repositorio)
3. [Instalación (resumen)](#3-instalación-resumen)
4. [Configuración: el archivo `.env`](#4-configuración-el-archivo-env)
5. [Trabajo diario: actualizar la app](#5-trabajo-diario-actualizar-la-app)
6. [Actualizar la infraestructura](#6-actualizar-la-infraestructura)
7. [Base de datos](#7-base-de-datos)
8. [Respaldos](#8-respaldos)
9. [Comandos útiles](#9-comandos-útiles)
10. [Solución de problemas](#10-solución-de-problemas)
11. [Probarlo en tu PC](#11-probarlo-en-tu-pc)
12. [Decisiones técnicas](#12-decisiones-técnicas)
13. [Costos y cuándo crecer](#13-costos-y-cuándo-crecer)

---

## 1. Cómo funciona

```
Internet ──► EC2 (Ubuntu 24.04 + Docker)
              │
              ├─ web        nginx :80        sirve public/ y /storage, pasa PHP a "app"
              ├─ app        php-fpm 8.5      ejecuta Laravel; al arrancar instala y migra
              ├─ queue      queue:work       envía los correos en cola (ShouldQueue)
              ├─ scheduler  schedule:work    tareas programadas de Laravel
              └─ mysql      MySQL 8.4 LTS    solo en 127.0.0.1; datos en el volumen "mysql-data"
                    ▲
                    └── /opt/wilvil/src      ← git clone de la app, MONTADO como volumen
```

**El código no está dentro de la imagen Docker.** La imagen solo trae el entorno: PHP 8.5 con sus extensiones, composer y node.
La carpeta `src/` del servidor se monta dentro de los contenedores. Por eso:

- Un `git pull` en `src/` **se ve al instante**, sin reconstruir ni reiniciar.
- Reconstruir la imagen (`--build`) solo hace falta si cambias el `Dockerfile`.

**Al arrancar por primera vez:**
1. `mysql` crea la base y el usuario definidos en `.env`.
2. `app` espera a MySQL y hace lo siguiente:
   - Si falta `vendor/`, ejecuta `composer install`.
   - Si falta `public/build/`, ejecuta `npm run build`.
   - Luego ejecuta `php artisan migrate --force`.
3. `queue` y `scheduler` arrancan cuando `app` ya está sano.

---

## 2. Estructura del repositorio

```
.
├─ README.md                  ← este archivo
├─ DEPLOY-AWS.md              ← instalación paso a paso en AWS
├─ Dockerfile                 ← imagen PHP 8.5-FPM + extensiones + composer + node
├─ docker-compose.yml         ← servicios mysql, app, queue, scheduler, web
├─ .env.production.example    ← plantilla de configuración (copiar a .env)
├─ .dockerignore / .gitignore
├─ docker/
│  ├─ entrypoint.sh           ← arranque de "app": permisos, composer, npm, migraciones
│  ├─ actualizar.sh           ← git pull de la app + pasos extra solo si hacen falta
│  ├─ nginx/default.conf      ← sitio nginx (subidas de 25 MB, /storage, caché de assets)
│  ├─ php/php.ini             ← límites de PHP y opcache
│  ├─ php/www.conf            ← procesos de PHP-FPM (ajustado a 1 GB de RAM)
│  └─ mysql/my.cnf            ← MySQL liviano (ajustado a 1 GB de RAM)
└─ src/                       ← (ignorado) git clone de la app
```

En el servidor también aparecen estos archivos, todos ignorados por git:

| Archivo | Qué es |
|---|---|
| `.env` | Configuración real con las contraseñas |
| `actualizar.log` | Historial de las actualizaciones automáticas |
| `backup-AAAA-MM-DD.tgz` | Respaldos diarios |

---

## 3. Instalación (resumen)

El detalle de cada paso está en [DEPLOY-AWS.md](DEPLOY-AWS.md).

```bash
# 1. EC2 Ubuntu 24.04 (t3.micro o mayor) con Docker y 2 GB de swap
# 2. Clonar los dos repos
git clone git@github-docker:AlanOrtiz020/REPO-DOCKER.git /opt/wilvil
git clone git@github-app:AlanOrtiz020/newilvil.git       /opt/wilvil/src

# 3. Configurar
cd /opt/wilvil
cp .env.production.example .env && nano .env

# 4. Levantar (la primera vez tarda 3-5 min)
docker compose up -d --build
docker compose logs -f app

# 5. Importar la base actual (ver sección 7)
```

> ⚠️ Las migraciones solo crean las tablas base (usuarios, permisos, sesiones, colas, sueldos).
> Las tablas del negocio (obras, pedidos, compras, materiales, herramientas, facturas…) **no tienen migración**.
> En una instalación nueva **hay que importar un respaldo de la base**.

---

## 4. Configuración: el archivo `.env`

- **Ubicación:** va en `/opt/wilvil/.env`, al lado de `docker-compose.yml`, **no** dentro de `src/`.
  Docker lo lee y entrega cada valor a los contenedores como variable de entorno. No crees un `src/.env` en el servidor.
- **Seguridad:** nunca se sube a git, porque `.gitignore` lo bloquea. La plantilla `.env.production.example` sí se sube y no tiene contraseñas reales.

**Variables clave:**

| Variable | Valor / nota |
|---|---|
| `APP_KEY` | Clave de cifrado. Si migras desde otro servidor, **usa la misma** o se cierran las sesiones |
| `APP_URL` | URL pública, ej. `https://tu-dominio.cl` |
| `APP_DEBUG` | Siempre `false` en producción |
| `HOST_UID` / `HOST_GID` | UID/GID del usuario del servidor (`id -u`, `id -g`; normalmente 1000) |
| `DB_HOST` | `mysql` (el nombre del servicio Docker, **no** `127.0.0.1`) |
| `DB_DATABASE` / `DB_USERNAME` / `DB_PASSWORD` | Base y usuario de la app |
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
> Si después cambias una contraseña en el `.env`, cámbiala también dentro de MySQL (ver sección 7).

---

## 5. Trabajo diario: actualizar la app

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
cd /opt/wilvil
./docker/actualizar.sh            # hace git pull + pasos necesarios (si no hay nada nuevo, no hace nada)
./docker/actualizar.sh --todo     # si ya hiciste el git pull a mano: corre todos los pasos
```

**Actualización automática con cron:** revisa GitHub cada 5 minutos.

```bash
crontab -e
*/5 * * * * /opt/wilvil/docker/actualizar.sh >> /opt/wilvil/actualizar.log 2>&1
```

Qué esperar:
- Si un commit trae un error, **el sitio lo muestra hasta que subas el arreglo**. En este esquema no hay vuelta atrás automática.
- **No edites archivos directamente en el servidor.** Si lo haces, el script no hace el pull, para no pisar tus cambios, y lo deja anotado en `actualizar.log`. Para limpiar: `cd src && git status`, luego `git stash` o `git checkout -- .`.
- El script corre una sola vez a la vez, aunque coincidan el cron y una ejecución manual.
- Por defecto actualiza la rama `main`. Para otra rama: `BRANCH=otra ./docker/actualizar.sh`.

---

## 6. Actualizar la infraestructura

Cuando cambies algo de **este** repo (Dockerfile, nginx, php.ini, my.cnf, compose):

```bash
cd /opt/wilvil
git pull
docker compose up -d --build
```

| Si cambiaste… | Basta con |
|---|---|
| `docker/nginx/default.conf` | `docker compose restart web` |
| `docker/php/*.ini`, `www.conf` o `Dockerfile` | `docker compose up -d --build` |
| `docker/mysql/my.cnf` | `docker compose restart mysql` (el sitio se corta unos segundos) |
| `.env` | `docker compose up -d` |

Actualizar las imágenes base (parches de seguridad de PHP, nginx y MySQL), una vez al mes:

```bash
docker compose pull && docker compose build --pull && docker compose up -d
```

---

## 7. Base de datos

MySQL 8.4 LTS corre en el contenedor `mysql`. Sus datos están en el volumen Docker `mysql-data`, que **no se borra** al reiniciar ni al reconstruir.

> ⚠️ **`docker compose down -v` BORRA la base de datos.** Nunca uses `-v` en producción.

**Importar un respaldo** (`.sql`):

```bash
cd /opt/wilvil
set -a; . ./.env; set +a
docker compose exec -T mysql mysql -u root -p"$DB_ROOT_PASSWORD" "$DB_DATABASE" < respaldo.sql
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

**Cambiar la contraseña** de la app:

```sql
ALTER USER 'wilvil_app'@'%' IDENTIFIED BY 'nueva-contraseña';
```

Después cambia `DB_PASSWORD` en `.env` y ejecuta `docker compose up -d`.

---

## 8. Respaldos

Con la base en la misma EC2, **los respaldos son responsabilidad tuya**: si se pierde la instancia o su disco, se pierde todo lo que no esté copiado afuera.

| Qué | Dónde está |
|---|---|
| Base de datos | Volumen `mysql-data` |
| PDF y adjuntos subidos | `src/storage/app/` |
| Respaldos generados por la app | `src/respaldos/` |

**Respaldo diario a las 03:00** (se guardan los últimos 7 días):

```bash
crontab -e
0 3 * * * cd /opt/wilvil && docker compose exec -T -u www-data app php artisan respaldo:bd >/dev/null && tar czf /opt/wilvil/backup-$(date +\%F).tgz -C src storage/app respaldos && find /opt/wilvil -name 'backup-*.tgz' -mtime +7 -delete
```

**Saca las copias fuera de la EC2.** Hay dos opciones:
- **Snapshots automáticos del disco:** EC2 → *Lifecycle Manager* → política diaria con 7 copias. Cuesta centavos al mes.
- **Bajarlos a tu PC:** `scp ubuntu@TU_IP:/opt/wilvil/backup-*.tgz .`

**Restaurar:** descomprime el `.tgz`. El `.sql` de `respaldos/` se importa como en la sección 7, y `storage/app` se copia de vuelta a `src/storage/app`.

---

## 9. Comandos útiles

Todos se ejecutan desde `/opt/wilvil`.

```bash
# Estado
docker compose ps                       # contenedores y su salud
docker stats --no-stream                # memoria y CPU por contenedor
free -h                                 # RAM y swap del servidor

# Logs
docker compose logs -f app              # arranque, migraciones, errores de PHP-FPM
docker compose logs -f queue            # envío de correos
docker compose logs -f web              # accesos nginx
tail -f src/storage/logs/laravel-$(date +%F).log   # errores de Laravel
tail -f actualizar.log                  # actualizaciones automáticas

# Artisan / composer / npm (siempre como www-data, para no dejar archivos de root)
docker compose exec -u www-data app php artisan tinker
docker compose exec -u www-data app php artisan migrate --force
docker compose exec -u www-data app php artisan respaldo:bd
docker compose exec -u www-data app composer install --no-dev
docker compose exec -u www-data app sh -c 'npm ci && npm run build'
docker compose exec -u www-data app bash   # entrar al contenedor (como la "workspace" de Laradock)

# Reiniciar
docker compose restart                  # todo
docker compose exec -u www-data app php artisan queue:restart   # solo el worker de correos
docker compose up -d                    # recrear (aplica cambios del .env)
```

---

## 10. Solución de problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| **502 Bad Gateway** | `app` no arrancó o se está instalando | `docker compose logs app`. La primera vez espera a que termine composer/npm |
| El login vuelve siempre a la pantalla de ingreso | `SESSION_SECURE_COOKIE=true` sin HTTPS | Ponlo en `false` y ejecuta `docker compose up -d` |
| Las URLs salen con `http://` estando detrás de Cloudflare/ALB | Laravel no confía en el proxy | En `src/bootstrap/app.php`, dentro de `withMiddleware`: `$middleware->trustProxies(at: '*');` |
| `Permission denied` en `storage/` o `vendor/` | `HOST_UID`/`HOST_GID` no coinciden con tu usuario | Revisa `id -u`/`id -g`, corrige el `.env` y ejecuta `docker compose up -d --build` |
| `SQLSTATE[HY000] [2002] Connection refused` | MySQL todavía arrancando, o `DB_HOST` mal | `DB_HOST=mysql`; `docker compose logs mysql` |
| `Access denied for user` | Cambiaste `DB_PASSWORD` después del primer arranque | Usa `ALTER USER` (sección 7) |
| MySQL se reinicia solo / sitio cae al azar | Sin memoria (OOM) | Verifica el swap con `free -h`. Si se repite, pasa a una t3.small (sección 13) |
| Los correos no salen | Worker caído o SMTP mal configurado | `docker compose logs queue`; revisa `MAIL_*`; mira la tabla `failed_jobs` |
| Un cambio de JS/CSS no se ve | Falta compilar assets | `./docker/actualizar.sh --todo` |
| Un cambio en un correo o job no se aplica | El worker tiene el código viejo | `docker compose exec -u www-data app php artisan queue:restart` |
| El cron no actualiza | Cambios locales en `src/` o error de git | `tail actualizar.log`; `cd src && git status` |
| Los PDF subidos no se ven (404) | Rutas de `store()` en la app | Ver nota en [§12](#12-decisiones-técnicas) |

---

## 11. Probarlo en tu PC

Se puede levantar igual que en el servidor:

```bash
git clone git@github.com:AlanOrtiz020/newilvil.git src     # si no lo tienes ya
cp .env.production.example .env
# en .env: APP_KEY, contraseñas, APP_URL=http://localhost:8088, SESSION_SECURE_COOKIE=false, MAIL_MAILER=log
```

Crea un `docker-compose.override.yml` (ignorado por git) para usar otros puertos y no chocar con tu Laradock o un MySQL local:

```yaml
services:
  web:   { ports: !override ["8088:80"] }
  mysql: { ports: !override ["127.0.0.1:33306:3306"] }
```

```bash
docker compose up -d --build
# abrir http://localhost:8088
docker compose down          # apagar (sin -v para conservar la base)
```

---

## 12. Decisiones técnicas

| Decisión | Por qué |
|---|---|
| **Código montado como volumen** (no copiado en la imagen) | Los cambios llegan con un `git pull`, sin reconstruir. A cambio, no hay vuelta atrás automática |
| **PHP 8.5** | El `composer.lock` de la app lo exige (`"php": "^8.5"`). OPcache ya viene incluido en PHP 8.5 |
| **Extensiones** `pdo_mysql`, `gd`, `zip`, `intl`, `bcmath`, `pcntl`, `exif` | MySQL, dompdf (PDF), ZipArchive (respaldos), worker de colas |
| **MySQL 8.4 LTS** | Soporte hasta 2032. La 8.0 ya no tiene soporte. La 9.7 LTS también serviría, pero hay que elegirla **antes** de cargar datos, porque no se puede volver de 9.x a 8.4 |
| **MySQL en Docker en vez de RDS** | Costo. RDS sumaba bastante a la factura. A cambio, los respaldos son manuales (sección 8) |
| **Sin `config:cache` ni `route:cache`** | Un `git pull` que toque `config/` o `routes/` funciona sin pasos extra. La diferencia de velocidad es mínima para esta app |
| **OPcache revisa cambios cada 2 s** | Necesario con código montado. Si no, PHP seguiría usando la versión vieja |
| **www-data con el UID del servidor** | Los archivos que crea PHP (vendor, storage, build) quedan a nombre de tu usuario y `git pull` no choca con permisos |
| **MySQL solo en 127.0.0.1** | No se puede atacar desde internet. Para conectarte, túnel SSH |
| **Dos repositorios** (infra + app) | La app no se ensucia con archivos del servidor, y la infraestructura se versiona aparte |

**Nota sobre archivos subidos:** `PedidomController`, `PedidohController`, `CompramController` y `ComprahController` guardan PDF con
`->store('public/pdf/...')` en el disco por defecto (`local`). En Laravel 12 ese disco apunta a `storage/app/private`,
así que los archivos quedan en `storage/app/private/public/pdf/...`. Pero los enlaces apuntan a `/storage/pdf/...`, y eso probablemente da 404.
Las facturas usan `store('facturas', 'public')`, que sí funciona. Es un tema de la app, no de Docker.

---

## 13. Costos y cuándo crecer

Precios aproximados para **us-east-1 (Virginia)**, 24/7, en US$ por mes:

| Recurso | t3.micro (1 GB) | t3.small (2 GB) |
|---|---|---|
| Instancia | ~7,60 | ~15,20 |
| Disco gp3 20 GB | ~1,60 | ~1,60 |
| IP pública | ~3,65 | ~3,65 |
| **Total** | **~13** | **~20** |
| **Con IVA 19%** | **~15,50** | **~24** |

- São Paulo (`sa-east-1`) cuesta ~50% más, pero responde más rápido desde Chile.
- Un *Savings Plan* de 1 año baja la instancia entre 30 y 40%.
- Medido: todo el stack usa ~350 MB de RAM en reposo.

**Señales de que hay que pasar a t3.small:**
- El swap está muy usado de forma constante (`free -h`).
- MySQL se reinicia por falta de memoria.
- El sitio se pone lento al generar varios PDF a la vez.

**Cambiar de tamaño:** EC2 → detener la instancia → *Change instance type* → iniciar.
Son unos minutos sin servicio y no se pierde nada: el disco, el volumen de MySQL y la Elastic IP se mantienen.

Con 2 GB conviene aprovechar la RAM extra:
- `docker/mysql/my.cnf` → `innodb_buffer_pool_size = 512M`
- `docker/php/www.conf` → `pm.max_children = 12`

Después ejecuta `docker compose up -d --build && docker compose restart mysql`.

**Volver a RDS más adelante:** importa un respaldo en la RDS, cambia `DB_HOST` al endpoint de la RDS en `.env`, quita del compose el servicio `mysql` y el `depends_on: mysql` de `app`, y ejecuta `docker compose up -d`.
