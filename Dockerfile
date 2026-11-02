# syntax=docker/dockerfile:1
# laravel-docker: imagen SOLO con el entorno (PHP + extensiones + composer + node).
# El código NO va dentro: se monta desde ./src como volumen (ver docker-compose.yml),
# así un `git pull` en el servidor se refleja sin reconstruir la imagen.
ARG PHP_VERSION=8.5
FROM php:${PHP_VERSION}-fpm-alpine

# Extensiones comunes en Laravel: pdo_mysql, gd (imágenes/PDF), zip, intl, bcmath, pcntl (colas), exif.
# OPcache viene incluido desde PHP 8.5; en versiones anteriores se instala como extensión.
RUN apk add --no-cache \
        bash git fcgi tzdata shadow su-exec nodejs npm \
        libpng libjpeg-turbo freetype libzip icu-libs \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
        libpng-dev libjpeg-turbo-dev freetype-dev libzip-dev icu-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql gd zip intl bcmath pcntl exif \
    && { php -m | grep -qi '^Zend OPcache$' || docker-php-ext-install opcache; } \
    && apk del .build-deps

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# www-data con el mismo UID/GID que el usuario del servidor (ubuntu = 1000),
# para que los archivos que crea PHP (vendor, storage, build) sean editables y `git pull` no choque con permisos.
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN groupmod -o -g "$HOST_GID" www-data && usermod -o -u "$HOST_UID" -g "$HOST_GID" www-data

ENV TZ=UTC \
    COMPOSER_HOME=/tmp/composer \
    npm_config_cache=/tmp/npm
COPY docker/php/php.ini /usr/local/etc/php/conf.d/zz-app.ini
COPY docker/php/www.conf /usr/local/etc/php-fpm.d/zz-www.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

WORKDIR /var/www/html

HEALTHCHECK --interval=15s --timeout=5s --start-period=10m --retries=3 \
    CMD SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000 || exit 1

ENTRYPOINT ["entrypoint"]
CMD ["php-fpm"]
