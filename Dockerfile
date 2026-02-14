ARG PHP_VERSION=${PHP_VERSION:-8.3}
FROM php:${PHP_VERSION}-fpm-trixie

LABEL maintainer="Esdras Caleb"

ENV MOODLE_DIR="/var/www/moodle"
ENV MOODLE_DATA="/var/www/moodledata"
ENV DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# 1. Dependências de Runtime (Estratégia "A Prova de Futuro")
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Utilitários Básicos
    gnupg2 curl ca-certificates lsb-release nginx supervisor git jq unzip locales \
    # Binários Moodle
    graphviz aspell ghostscript poppler-utils \
    # Bibliotecas Essenciais (Nomes estáveis)
    zlib1g \
    libxml2 \
    libpq5 \
    libxslt1.1 \
    libjpeg62-turbo \
    libfreetype6 \
    libpng16-16 \
    unixodbc \
    openssl \
    \
    # --- A CORREÇÃO: Usamos ferramentas para puxar as libs corretas ---
    # Ao invés de adivinhar 'libzip4t64', instalamos 'zip'. Ele puxa a libzip correta.
    zip \
    # Ao invés de adivinhar 'libicu72/74/75', instalamos 'icu-devtools'.
    icu-devtools \
    # Puxa libmemcached correta
    libmemcached-tools \
    # Puxa libsodium correta (se não achar, tente libsodium23 explicitamente na próxima, mas tools costuma funcionar)
    libsodium23 \
    # Regex e Oniguruma
    libonig5 \
    \
    # --- Instalação do MS SQL Server (Driver ODBC) ---
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-archive-keyring.gpg \
    && echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y msodbcsql18 mssql-tools18 \
    \
    # Locales
    && echo "en_US.UTF-8 UTF-8" > /etc/locale.gen \
    && echo "pt_BR.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 2. Build das Extensões (Instala DEV -> Compila -> Remove DEV)
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    $PHPIZE_DEPS \
    libpng-dev libjpeg-dev libfreetype6-dev libzip-dev \
    libicu-dev libxml2-dev libpq-dev libonig-dev libxslt1-dev \
    libsodium-dev unixodbc-dev zlib1g-dev libssl-dev libmemcached-dev \
    \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        gd intl zip soap opcache pdo pdo_pgsql pgsql mysqli pdo_mysql exif bcmath xsl sodium \
    \
    && pecl install redis sqlsrv pdo_sqlsrv memcached apcu \
    && docker-php-ext-enable redis sqlsrv pdo_sqlsrv memcached apcu \
    \
    && apt-get purge -y --auto-remove \
       $PHPIZE_DEPS \
       libpng-dev libjpeg-dev libfreetype6-dev libzip-dev \
       libicu-dev libxml2-dev libpq-dev libonig-dev libxslt1-dev \
       libsodium-dev unixodbc-dev zlib1g-dev libssl-dev libmemcached-dev \
    \
    && rm -rf /var/lib/apt/lists/* /tmp/pear


# 3. Estrutura e Arquivos
RUN mkdir -p $MOODLE_DATA /var/log/supervisor $MOODLE_DIR \
    && chown -R www-data:www-data $MOODLE_DATA \
    && chmod 777 $MOODLE_DATA

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY plugins.json* /usr/local/bin/default_plugins.json
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80
WORKDIR $MOODLE_DIR
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]