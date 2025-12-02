ARG PHP_VERSION=${PHP_VERSION:-8.1}
FROM php:${PHP_VERSION}-fpm-bullseye

LABEL maintainer="Esdras Caleb"

# Variáveis de Ambiente Padrão (Podem ser mudadas no CapRover)
ENV MOODLE_GIT_REPO="https://github.com/moodle/moodle.git"
ENV MOODLE_VERSION="MOODLE_402_STABLE"
ENV MOODLE_LANG="pt_br"
ENV MOODLE_DIR="/var/www/moodle"
ENV MOODLE_DATA="/var/www/moodledata"
ENV DEBIAN_FRONTEND=noninteractive

# Variáveis de Performance PHP (Runtime)
ENV PHP_MEMORY_LIMIT="512M"
ENV PHP_UPLOAD_MAX_FILESIZE="100M"
ENV PHP_POST_MAX_SIZE="100M"
ENV PHP_MAX_EXECUTION_TIME="600"
ENV PHP_MAX_INPUT_VARS="5000"

# 1. Instalação de Dependências
RUN apt-get update && apt-get install -y \
    nginx supervisor cron git unzip jq \
    libpng-dev libjpeg-dev libfreetype6-dev libzip-dev \
    libicu-dev libxml2-dev libpq-dev libonig-dev libxslt1-dev \
    libsodium-dev graphviz aspell ghostscript clamav \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        gd intl zip soap opcache pdo pdo_pgsql pgsql mysqli pdo_mysql exif bcmath xsl sodium \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Configs PHP - Opcache (Geralmente fixo, mas pode ser movido se quiser)
RUN { \
        echo 'opcache.memory_consumption=128'; \
        echo 'opcache.interned_strings_buffer=8'; \
        echo 'opcache.max_accelerated_files=4000'; \
        echo 'opcache.revalidate_freq=60'; \
        echo 'opcache.fast_shutdown=1'; \
        echo 'opcache.enable_cli=1'; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini

# (Removido o bloco moodle-overrides.ini daqui, pois agora é gerado no entrypoint)

# 3. Estrutura de Pastas
RUN mkdir -p $MOODLE_DATA \
    && mkdir -p /var/log/supervisor \
    # O diretório do Moodle é criado vazio aqui
    && mkdir -p $MOODLE_DIR \
    && chown -R www-data:www-data $MOODLE_DATA \
    && chmod 777 $MOODLE_DATA

COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# Copiamos plugins.json apenas como fallback (padrão), mas a ENV terá prioridade
COPY plugins.json* /usr/local/bin/default_plugins.json

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80
WORKDIR $MOODLE_DIR

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]