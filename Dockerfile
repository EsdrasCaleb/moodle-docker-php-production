ARG PHP_VERSION=${PHP_VERSION:-8.3}
FROM php:${PHP_VERSION}-fpm-trixie

LABEL maintainer="Esdras Caleb"

ENV MOODLE_DIR="/var/www/moodle"
ENV MOODLE_DATA="/var/www/moodledata"
ENV DEBIAN_FRONTEND=noninteractive

# 1. Dependências de Sistema e MS SQL Server
RUN apt-get update && apt-get install -y --no-install-recommends \
    gnupg2 curl ca-certificates lsb-release nginx supervisor git \
    libpng-dev libjpeg-dev libfreetype6-dev libzip-dev \
    libicu-dev libxml2-dev libpq-dev libonig-dev libxslt1-dev \
    libsodium-dev unixodbc-dev libmemcached-dev zlib1g-dev libssl-dev \
    graphviz aspell ghostscript poppler-utils \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-archive-keyring.gpg \
    && echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y msodbcsql18 mssql-tools18 \
    && rm -rf /var/lib/apt/lists/*

# 2. Instalação de Extensões PHP (Nativas + PECL incluindo APCu)
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        gd intl zip soap opcache pdo pdo_pgsql pgsql mysqli pdo_mysql exif bcmath xsl sodium \
    && pecl install redis sqlsrv pdo_sqlsrv memcached apcu \
    && docker-php-ext-enable redis sqlsrv pdo_sqlsrv memcached apcu

# 3. Configurações Estáticas (Opcache e APCu base)
RUN { \
        echo 'opcache.memory_consumption=256'; \
        echo 'opcache.interned_strings_buffer=16'; \
        echo 'opcache.max_accelerated_files=20000'; \
        echo 'opcache.revalidate_freq=60'; \
        echo 'opcache.enable_cli=1'; \
        echo 'opcache.jit=tracing'; \
        echo 'opcache.jit_buffer_size=100M'; \
        echo 'apc.enabled=1'; \
        echo 'apc.shm_size=128M'; \
        echo 'apc.enable_cli=1'; \
    } > /usr/local/etc/php/conf.d/moodle-performance.ini

# 4. Estrutura e Arquivos
RUN mkdir -p $MOODLE_DATA /var/log/supervisor $MOODLE_DIR \
    && chown -R www-data:www-data $MOODLE_DATA \
    && chmod 777 $MOODLE_DATA

COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80
WORKDIR $MOODLE_DIR
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]