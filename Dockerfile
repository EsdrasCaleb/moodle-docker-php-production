ARG PHP_VERSION=${PHP_VERSION:-8.3}
FROM php:${PHP_VERSION}-fpm-trixie

LABEL maintainer="Esdras Caleb"

ENV MOODLE_DIR="/var/www/moodle"
ENV MOODLE_DATA="/var/www/moodledata"
ENV DEBIAN_FRONTEND=noninteractive

# 1. Dependências de Sistema e MS SQL Server
RUN apt-get update && apt-get install -y --no-install-recommends \
    gnupg2 curl ca-certificates lsb-release nginx supervisor git jq \
    libpng-dev libjpeg-dev libfreetype6-dev libzip-dev \
    libicu-dev libxml2-dev libpq-dev libonig-dev libxslt1-dev \
    libsodium-dev unixodbc-dev zlib1g-dev libssl-dev \
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
    && pecl install redis sqlsrv pdo_sqlsrv apcu \
    && docker-php-ext-enable redis sqlsrv pdo_sqlsrv apcu



# 3. Estrutura e Arquivos
RUN mkdir -p $MOODLE_DATA /var/log/supervisor $MOODLE_DIR \
    && chown -R www-data:www-data $MOODLE_DATA \
    && chmod 770 $MOODLE_DATA

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY plugins.json* /usr/local/bin/default_plugins.json
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80
WORKDIR $MOODLE_DIR
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]