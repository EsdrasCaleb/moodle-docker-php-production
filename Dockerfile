ARG PHP_VERSION=${PHP_VERSION:-8.1}
FROM php:${PHP_VERSION}-fpm-bullseye

LABEL maintainer="Esdras Caleb"

# --- Argumentos de Build (Alterar no docker build --build-arg se necessário) ---
ARG MOODLE_GIT_REPO="https://github.com/moodle/moodle.git"
ARG MOODLE_VERSION="MOODLE_405_STABLE"

# --- Variáveis de Ambiente de Execução (Runtime) ---
ENV MOODLE_LANG="pt_br"
ENV MOODLE_DIR="/var/www/moodle"
ENV DEBIAN_FRONTEND=noninteractive

# 1. Instalação de Dependências do SO
RUN apt-get update && apt-get install -y \
    nginx supervisor cron git unzip jq \
    libpng-dev libjpeg-dev libfreetype6-dev libzip-dev \
    libicu-dev libxml2-dev libpq-dev libonig-dev libxslt1-dev \
    libsodium-dev graphviz aspell ghostscript clamav \
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

# 3. Preparação da Estrutura
RUN mkdir -p /var/www/moodledata \
    && mkdir -p /var/log/supervisor \
    && mkdir -p $MOODLE_DIR

# 4. Copiar Scripts e Configs
COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY config-extra.php* /usr/local/bin/config-extra.php

# 5. O GRANDE PASSO: Build do Moodle (Código "Assado" na Imagem)
COPY build_assets.sh /usr/local/bin/build_assets.sh
COPY plugins.json /tmp/plugins.json

RUN chmod +x /usr/local/bin/build_assets.sh \
    && /usr/local/bin/build_assets.sh "$MOODLE_DIR" "$MOODLE_VERSION" "$MOODLE_GIT_REPO" \
    && chown -R www-data:www-data $MOODLE_DIR \
    && chown -R www-data:www-data /var/www/moodledata \
    && chmod 777 /var/www/moodledata \
    && rm /usr/local/bin/build_assets.sh /tmp/plugins.json

# 6. Cron (Apontando para o código já existente)
RUN echo "*/1 * * * * /usr/local/bin/php ${MOODLE_DIR}/admin/cli/cron.php > /dev/null" > /etc/cron.d/moodle-cron \
    && chmod 0644 /etc/cron.d/moodle-cron \
    && crontab /etc/cron.d/moodle-cron

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80
WORKDIR $MOODLE_DIR

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]