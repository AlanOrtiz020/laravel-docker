# Despliegue en AWS (EC2 t3.micro + Docker + MySQL en Docker)

```
Internet ──► EC2 t3.micro (Ubuntu 24.04, Docker)
             ├─ web        nginx :80
             ├─ app        php-fpm 8.5
             ├─ queue      queue:work (correos)
             ├─ scheduler  schedule:work
             └─ mysql      MySQL 8.4 LTS  (solo 127.0.0.1:3306, datos en volumen "mysql-data")
                 ▲
                 └── /opt/wilvil/src  (git clone, montado como volumen)
```

**El código no va dentro de la imagen.** Docker solo aporta el entorno: PHP 8.5, extensiones, composer y node.
La carpeta `src/` del servidor se monta en los contenedores, así que **un `git pull` se ve al instante**.

| Archivo | Para qué |
|---|---|
| `Dockerfile` | PHP 8.5-FPM y extensiones (pdo_mysql, gd, zip, intl…), composer y node |
| `docker-compose.yml` | Servicios `mysql`, `app`, `queue`, `scheduler`, `web` |
| `.env.production.example` | Plantilla del `.env` de producción |
| `docker/actualizar.sh` | `git pull` y pasos extra solo cuando hacen falta (manual o por cron) |
| `docker/mysql/my.cnf` | MySQL ajustado para 1 GB de RAM |
| `docker/` | php.ini, pool de FPM, nginx y entrypoint |

Al arrancar por primera vez:
- MySQL crea la base y el usuario definidos en `.env`.
- `app` instala `vendor/`, compila los assets y ejecuta `migrate --force`.

Consumo medido: unos **350 MB de RAM** en total (MySQL ~150 MB, PHP ~110 MB y el resto).

---

## 1. Crear la EC2

1. **Ubuntu Server 24.04 LTS**, 64-bit (x86), **t3.micro**, disco **gp3 de 20–30 GB**. Asígnale una Elastic IP.
2. Security group: **22** (solo tu IP), **80** y **443**. **No abras el 3306.**
3. Instala Docker:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER && newgrp docker
```

4. **Crea swap de 2 GB (obligatorio con 1 GB de RAM).** Sin swap, la primera instalación o un pico de uso puede dejar sin memoria a MySQL y botarlo:

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swap.conf && sudo sysctl -p /etc/sysctl.d/99-swap.conf
free -h
```

## 2. Subir el proyecto

Son **dos repositorios**: uno con la infraestructura (este, con Docker y scripts) y otro con la app.
La app se clona dentro de `src/`, que este repo ignora.

Para que la EC2 pueda hacer `git pull`, necesita llaves de **solo lectura**.
GitHub no permite usar la misma *deploy key* en dos repos, así que crea una para cada uno:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/deploy_docker -N ""
ssh-keygen -t ed25519 -f ~/.ssh/deploy_app    -N ""
cat >> ~/.ssh/config <<'EOF'
Host github-docker
  HostName github.com
  IdentityFile ~/.ssh/deploy_docker
Host github-app
  HostName github.com
  IdentityFile ~/.ssh/deploy_app
EOF
cat ~/.ssh/deploy_docker.pub ~/.ssh/deploy_app.pub
```

Pega cada llave en su repo: GitHub → repo → *Settings → Deploy keys → Add*, sin marcar "write access".
Luego clona usando esos alias:

```bash
sudo mkdir -p /opt/wilvil && sudo chown $USER: /opt/wilvil
git clone git@github-docker:AlanOrtiz020/REPO-DOCKER.git /opt/wilvil       # infraestructura
git clone git@github-app:AlanOrtiz020/newilvil.git       /opt/wilvil/src   # app
```

**Actualizar la infraestructura** (si cambias el Dockerfile, nginx, php.ini, etc.):

```bash
cd /opt/wilvil && git pull && docker compose up -d --build
```

`docker/actualizar.sh` y el cron siguen actualizando **solo la app** (`src/`).

## 3. Configurar `.env`

```bash
cp .env.production.example .env
docker run --rm php:8.5-cli php -r "echo 'base64:'.base64_encode(random_bytes(32)).PHP_EOL;"   # → APP_KEY
openssl rand -base64 24    # úsalo para DB_PASSWORD y otro para DB_ROOT_PASSWORD
id -u; id -g               # → HOST_UID / HOST_GID (normalmente 1000)
nano .env
```

- El `.env` va en `/opt/wilvil/.env`, **no en `src/`**. No crees un `src/.env` en el servidor.
- `DB_HOST=mysql`: es el nombre del servicio en Docker, no `127.0.0.1`.
- Si traes una base existente, usa **la misma `APP_KEY`** que tenía el servidor anterior.
- **Define las contraseñas de MySQL antes del primer arranque.** MySQL las toma solo la primera vez. Si después cambias `DB_PASSWORD` en el `.env`, tienes que cambiarla también dentro de MySQL con `ALTER USER`.

## 4. Levantar

```bash
docker compose up -d --build
docker compose logs -f app     # la primera vez: composer, npm build y migraciones (3-5 min en t3.micro)
curl -I http://localhost/up    # 200
```

`--build` solo hace falta la primera vez o si cambias el `Dockerfile`. **Nunca por cambios de código.**

## 5. Importar la base de datos actual (importante)

Las migraciones **solo crean las tablas base** (users, roles/permisos, cache, jobs, sessions, sueldos).
Las tablas del negocio (obras, pedidos, compras, materiales…) **no tienen migración**: hay que importarlas.

Sube el respaldo a la EC2 y cárgalo en el contenedor:

```bash
scp respaldo.sql ubuntu@TU_IP:/opt/wilvil/          # desde tu PC (si es .zip, descomprímelo antes)

cd /opt/wilvil
set -a; . ./.env; set +a
docker compose exec -T mysql mysql -u root -p"$DB_ROOT_PASSWORD" "$DB_DATABASE" < respaldo.sql
docker compose exec -u www-data app php artisan migrate --force   # por si faltara alguna migración
```

## 6. Conectarte a MySQL desde tu PC (DBeaver, Workbench, HeidiSQL…)

MySQL **solo escucha en 127.0.0.1 de la EC2**: no es accesible desde internet, y así debe quedar.
Para entrar desde tu PC, usa un túnel SSH:

```bash
ssh -N -L 3307:127.0.0.1:3306 ubuntu@TU_IP -i tu-llave.pem
```

Mientras el túnel esté abierto, conéctate desde tu cliente con:
- Host `127.0.0.1`, puerto `3307`.
- Usuario `DB_USERNAME` y contraseña `DB_PASSWORD`.

DBeaver y Workbench también traen la opción "SSH tunnel" en la configuración de la conexión.

Consola directa en el servidor:

```bash
docker compose exec mysql mysql -u root -p
```

## 7. Actualizar el código

| Qué cambió | Qué hacer |
|---|---|
| Controladores, modelos, vistas Blade, rutas, config | **Solo `git pull`**. Se ve al instante |
| `composer.lock` (paquete nuevo) | `composer install` |
| JS/CSS de `resources/`, `package.json` | `npm run build` |
| Migraciones nuevas | `php artisan migrate` |
| Correos, jobs o tareas programadas | Reiniciar `queue` y `scheduler`, porque mantienen el código viejo en memoria |

`docker/actualizar.sh` revisa qué archivos cambiaron y ejecuta solo los pasos que correspondan:

```bash
cd /opt/wilvil
./docker/actualizar.sh            # hace el pull y los pasos necesarios
./docker/actualizar.sh --todo     # si ya hiciste el git pull a mano: corre todos los pasos
```

**Automático con cron** (cada 5 minutos; si no hay commits nuevos, no hace nada):

```bash
crontab -e
*/5 * * * * /opt/wilvil/docker/actualizar.sh >> /opt/wilvil/actualizar.log 2>&1
```

> No edites archivos directamente en el servidor. Si lo haces, el pull automático se detiene para no pisar tus cambios
> y lo deja anotado en `actualizar.log`. Para volver a dejarlo limpio: `cd src && git status`, luego `git stash` o `git checkout -- .`.

## 8. HTTPS

- **Cloudflare:** proxy naranja + SSL "Full".
- **O ALB + certificado ACM** que reenvíe al puerto 80.

En los dos casos, agrega esto en `src/bootstrap/app.php`, dentro de `withMiddleware`:

```php
$middleware->trustProxies(at: '*');
```

Mientras no tengas HTTPS, deja `SESSION_SECURE_COOKIE=false`.

## 9. Respaldos (importante: ahora son responsabilidad tuya)

Con MySQL en la misma EC2, **si la instancia o su disco se dañan, se pierden la base y los archivos**.
Los datos están en tres lugares:

| Qué | Dónde |
|---|---|
| Base de datos | Volumen Docker `mysql-data` |
| PDF y adjuntos subidos | `src/storage/app/` |
| Respaldos de la app | `src/respaldos/` |

**Respaldo diario automático** (cron a las 03:00): genera el respaldo de la base con el comando de la app y comprime todo:

```bash
crontab -e
0 3 * * * cd /opt/wilvil && docker compose exec -T -u www-data app php artisan respaldo:bd >/dev/null && tar czf /opt/wilvil/backup-$(date +\%F).tgz -C src storage/app respaldos && find /opt/wilvil -name 'backup-*.tgz' -mtime +7 -delete
```

**Saca las copias de la EC2.** Un respaldo que vive en el mismo disco no te salva si se pierde la instancia. Hay dos opciones:
- **Snapshots automáticos del disco:** en EC2 → *Lifecycle Manager*, crea una política diaria con 7 copias. Cuesta unos centavos al mes.
- **Bajarlos a tu PC:** `scp ubuntu@TU_IP:/opt/wilvil/backup-*.tgz .`

**Restaurar** un respaldo `.sql`: es el mismo comando del paso 5.

## Comandos útiles

```bash
docker compose exec -u www-data app php artisan tinker
docker compose exec -u www-data app php artisan respaldo:bd
docker compose exec mysql mysql -u root -p
docker compose logs -f queue mysql
docker stats --no-stream            # memoria de cada contenedor
free -h                             # RAM y swap de la EC2
tail -f /opt/wilvil/src/storage/logs/laravel-$(date +%F).log
tail -f /opt/wilvil/actualizar.log
```
