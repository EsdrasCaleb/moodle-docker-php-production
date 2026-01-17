ARG PHP_VERSION=${PHP_VERSION:-8.3}
FROM php:${PHP_VERSION}-fpm-bullseye

LABEL maintainer="Esdras Caleb"

# Standard Environment Variables
ENV MOODLE_DIR="/var/www/moodle"
ENV MOODLE_DATA="/var/www/moodledata"
ENV DEBIAN_FRONTEND=noninteractive

# PHP Performance Variables (Runtime)
ENV PHP_MEMORY_LIMIT="512M"
ENV PHP_UPLOAD_MAX_FILESIZE="100M"
ENV PHP_POST_MAX_SIZE="100M"
ENV PHP_MAX_EXECUTION_TIME="600"
ENV PHP_MAX_INPUT_VARS="5000"

# 1. Install Dependencies, System Binaries, and Database Drivers
RUN apt-get update && apt-get install -y gnupg2 \
    nginx supervisor cron git unzip jq \
    # Standard Moodle PHP extension requirements
    libpng-dev libjpeg-dev libfreetype6-dev libzip-dev \
    libicu-dev libxml2-dev libpq-dev libonig-dev libxslt1-dev \
    libsodium-dev \
    # Database dependencies (MSSQL, PostgreSQL)
    unixodbc-dev \
    # --- Moodle System Binaries (Requested) ---
    graphviz \
    aspell \
    ghostscript \
    poppler-utils \
    python3 \
    # coreutils (includes 'du') is usually present, but we ensure tools are here
    # --- Memcached & MongoDB System Dependencies ---
    libmemcached-dev \
    zlib1g-dev \
    libssl-dev \
    # ------------------------------------------
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        gd intl zip soap opcache pdo pdo_pgsql pgsql mysqli pdo_mysql exif bcmath xsl sodium \
    # --- Install PECL Extensions (Redis, SQL Server, Memcached, MongoDB) ---
    && pecl install redis sqlsrv pdo_sqlsrv memcached mongodb \
    && docker-php-ext-enable redis sqlsrv pdo_sqlsrv memcached mongodb \
    # -------------------------------------
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Optimized PHP Configs - Opcache for Moodle
RUN { \
        echo 'opcache.memory_consumption=256'; \
        echo 'opcache.interned_strings_buffer=16'; \
        echo 'opcache.max_accelerated_files=20000'; \
        echo 'opcache.revalidate_freq=60'; \
        echo 'opcache.fast_shutdown=1'; \
        echo 'opcache.enable_cli=1'; \
        echo 'opcache.jit=tracing'; \
        echo 'opcache.jit_buffer_size=100M'; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini

# 3. Folder Structure & Permissions
RUN mkdir -p $MOODLE_DATA \
    && mkdir -p /var/log/supervisor \
    && mkdir -p $MOODLE_DIR \
    && chown -R www-data:www-data $MOODLE_DATA \
    && chmod 777 $MOODLE_DATA

# 4. Configuration files
COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY plugins.json* /usr/local/bin/default_plugins.json

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80
WORKDIR $MOODLE_DIR

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]