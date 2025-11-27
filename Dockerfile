ARG PHP_VERSION=${PHP_VERSION:-8.3}
FROM php:${PHP_VERSION}-fpm-bullseye

LABEL maintainer="Esdras Caleb"

# --- Variáveis de Ambiente Padrão ---
ENV MOODLE_GIT_REPO="https://github.com/moodle/moodle.git"
ENV MOODLE_VERSION="MOODLE_402_STABLE"
ENV MOODLE_LANG="pt_br"
ENV MOODLE_URL="http://moodle.exemplo.com"
ENV MOODLE_PLUGINS_JSON="[]"
ENV MOODLE_EXTRA_PHP=""

# Banco de Dados
ENV DB_TYPE="pgsql"
ENV DB_HOST="srv-captain--postgres"
ENV DB_PORT="5432"
ENV DB_NAME="moodle"
ENV DB_USER="postgres"
ENV DB_PASS="CHANGE_ME_IMMEDIATELY"

ENV DEBIAN_FRONTEND=noninteractive

# 1. Instalação de Dependências
RUN apt-get update && apt-get install -y \
    nginx \
    supervisor \
    cron \
    git \
    unzip \
    jq \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libzip-dev \
    libicu-dev \
    libxml2-dev \
    libpq-dev \
    libonig-dev \
    libxslt1-dev \
    libsodium-dev \
    graphviz \
    aspell \
    ghostscript \
    clamav \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        gd intl zip soap opcache pdo pdo_pgsql pgsql mysqli pdo_mysql exif bcmath xsl sodium \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Configurações PHP
RUN { \
        echo 'opcache.memory_consumption=128'; \
        echo 'opcache.interned_strings_buffer=8'; \
        echo 'opcache.max_accelerated_files=4000'; \
        echo 'opcache.revalidate_freq=60'; \
        echo 'opcache.fast_shutdown=1'; \
        echo 'opcache.enable_cli=1'; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini

RUN { \
        echo 'file_uploads = On'; \
        echo 'memory_limit = 512M'; \
        echo 'upload_max_filesize = 100M'; \
        echo 'post_max_size = 100M'; \
        echo 'max_execution_time = 600'; \
        echo 'max_input_vars = 5000'; \
    } > /usr/local/etc/php/conf.d/moodle-overrides.ini

# 3. Preparação de Diretórios
# moodledata continua fora do webroot por segurança
RUN mkdir -p /var/www/moodledata \
    && chown -R www-data:www-data /var/www/moodledata \
    && chmod 777 /var/www/moodledata \
    && mkdir -p /var/log/supervisor

# 4. Cron (Atualizado para o novo caminho /var/www/moodle)
RUN echo "*/1 * * * * /usr/local/bin/php /var/www/moodle/admin/cli/cron.php > /dev/null" > /etc/cron.d/moodle-cron \
    && chmod 0644 /etc/cron.d/moodle-cron \
    && crontab /etc/cron.d/moodle-cron

# 5. Copiar Configurações
COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

COPY plugins.json* /usr/local/bin/default_plugins.json
COPY config-extra.php* /usr/local/bin/config-extra.php

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80

# Define o novo diretório de trabalho padrão
WORKDIR /var/www/moodle

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]