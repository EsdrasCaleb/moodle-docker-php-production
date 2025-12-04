#!/bin/bash
set -e

: "${MOODLE_DIR:=/var/www/moodle}"
: "${MOODLE_DATA:=/var/www/moodledata}"
: "${DB_PORT:=5432}"
: "${MOODLE_LANG:=pt_br}"
: "${MOODLE_GIT_REPO:=https://github.com/moodle/moodle.git}"
: "${MOODLE_VERSION:=MOODLE_402_STABLE}"

# Defaults para PHP se não definidos
: "${PHP_MEMORY_LIMIT:=512M}"
: "${PHP_UPLOAD_MAX_FILESIZE:=100M}"
: "${PHP_POST_MAX_SIZE:=100M}"
: "${PHP_MAX_EXECUTION_TIME:=600}"
: "${PHP_MAX_INPUT_VARS:=5000}"

echo ">>> Iniciando Container (Modo Dinâmico)..."

# ----------------------------------------------------------------------
# 0. Configuração Dinâmica do PHP (PHP.ini Overrides)
# ----------------------------------------------------------------------
echo ">>> Aplicando configurações de PHP (Memory: $PHP_MEMORY_LIMIT, Upload: $PHP_UPLOAD_MAX_FILESIZE)..."
{
    echo "file_uploads = On"
    echo "memory_limit = ${PHP_MEMORY_LIMIT}"
    echo "upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE}"
    echo "post_max_size = ${PHP_POST_MAX_SIZE}"
    echo "max_execution_time = ${PHP_MAX_EXECUTION_TIME}"
    echo "max_input_vars = ${PHP_MAX_INPUT_VARS}"
} > /usr/local/etc/php/conf.d/moodle-overrides.ini

# ----------------------------------------------------------------------
# 1. Download/Update do Core Moodle (Runtime)
# ----------------------------------------------------------------------
if [ ! -d "$MOODLE_DIR/.git" ]; then
    echo ">>> Baixando Moodle Core ($MOODLE_VERSION)..."
    # Clone limpo se a pasta estiver vazia ou não for git
    rm -rf "$MOODLE_DIR"/* "$MOODLE_DIR"/.* 2>/dev/null || true
    git clone --branch "$MOODLE_VERSION" --depth 1 "$MOODLE_GIT_REPO" "$MOODLE_DIR"
else
    echo ">>> Verificando atualizações do Core..."
    cd "$MOODLE_DIR"
    git config --global --add safe.directory "$MOODLE_DIR"
    git fetch origin "$MOODLE_VERSION"
    git reset --hard FETCH_HEAD
fi

# ----------------------------------------------------------------------
# 2. Instalação de Plugins (Runtime via ENV)
# ----------------------------------------------------------------------
PLUGINS_CONTENT=""

# Prioridade: 1. ENV Var, 2. Arquivo default
if [ ! -z "$MOODLE_PLUGINS_JSON" ] && [ "$MOODLE_PLUGINS_JSON" != "[]" ]; then
    PLUGINS_CONTENT="$MOODLE_PLUGINS_JSON"
elif [ -f "/usr/local/bin/default_plugins.json" ]; then
    PLUGINS_CONTENT=$(cat /usr/local/bin/default_plugins.json)
fi

if [ ! -z "$PLUGINS_CONTENT" ]; then
    echo ">>> Processando Plugins..."
    # Validamos o JSON
    if echo "$PLUGINS_CONTENT" | jq . >/dev/null 2>&1; then
        echo "$PLUGINS_CONTENT" | jq -c '.[]' | while read i; do
            GIT_URL=$(echo "$i" | jq -r '.giturl')
            GIT_BRANCH=$(echo "$i" | jq -r '.branch // empty')
            INSTALL_PATH=$(echo "$i" | jq -r '.installpath')
            FULL_PATH="$MOODLE_DIR/$INSTALL_PATH"

            echo "--- Plugin: $INSTALL_PATH ---"

            CLONE_ARGS="--depth 1 --recursive"
            [ ! -z "$GIT_BRANCH" ] && CLONE_ARGS="$CLONE_ARGS --branch $GIT_BRANCH"

            if [ -d "$FULL_PATH" ]; then
                # Remove e clona de novo para garantir estado limpo e trocar branch se necessário
                rm -rf "$FULL_PATH"
            fi

            # shellcheck disable=SC2086
            git clone $CLONE_ARGS "$GIT_URL" "$FULL_PATH"
            rm -rf "$FULL_PATH/.git"
        done
    else
        echo "AVISO: JSON de plugins inválido."
    fi
fi

# ----------------------------------------------------------------------
# 3. Permissões e Config.php
# ----------------------------------------------------------------------
# Como estamos baixando agora, temos que garantir permissões
# Para segurança, mantemos root como dono, mas damos permissão de leitura
echo ">>> Aplicando permissões..."
chown -R root:root "$MOODLE_DIR"
chmod -R 755 "$MOODLE_DIR"
chown -R www-data:www-data "$MOODLE_DATA"
chmod -R 777 "$MOODLE_DATA"

# Gera config.php se não existir
if [ ! -f "$MOODLE_DIR/config.php" ]; then
    echo ">>> Gerando config.php..."
    cat <<EOF > "$MOODLE_DIR/config.php"
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = getenv('DB_TYPE') ?: 'pgsql';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = getenv('DB_HOST') ?: 'localhost';
\$CFG->dbname    = getenv('DB_NAME') ?: 'moodle';
\$CFG->dbuser    = getenv('DB_USER') ?: 'moodle';
\$CFG->dbpass    = getenv('DB_PASS') ?: '';
\$CFG->prefix    = getenv('DB_PREFIX') ?: 'mdl_';
\$CFG->dboptions = array (
  'dbport' => getenv('DB_PORT') ?: '',
  'dbpersist' => 0,
  'dbscent' => 0,
);

\$CFG->wwwroot   = getenv('MOODLE_URL');
\$CFG->dataroot  = '/var/www/moodledata';
\$CFG->admin     = 'admin';
\$CFG->directorypermissions = 0777;

// --- EXTRAS ---
EOF

    # Injeta a ENV MOODLE_EXTRA_PHP (agora via append runtime)
    if [ ! -z "$MOODLE_EXTRA_PHP" ]; then
        echo "$MOODLE_EXTRA_PHP" >> "$MOODLE_DIR/config.php"
    fi

    cat <<EOF >> "$MOODLE_DIR/config.php"
require_once(__DIR__ . '/lib/setup.php');
EOF
    chown root:root "$MOODLE_DIR/config.php"
    chmod 644 "$MOODLE_DIR/config.php"
fi

# ----------------------------------------------------------------------
# 4. Banco de Dados
# ----------------------------------------------------------------------
echo ">>> Aguardando Banco ($DB_HOST)..."
until echo > /dev/tcp/$DB_HOST/$DB_PORT; do sleep 3; done 2>/dev/null || true

echo ">>> Verificando Banco..."
# Verifica se instalado (usando www-data)
if su -s /bin/sh www-data -c "php -r 'define(\"CLI_SCRIPT\", true); require(\"$MOODLE_DIR/config.php\"); if (\$DB->get_manager()->table_exists(\"config\")) { exit(0); } else { exit(1); }'" >/dev/null 2>&1; then
    echo ">>> Banco existente. Upgrade..."
    su -s /bin/sh www-data -c "php admin/cli/upgrade.php --non-interactive"
else
    echo ">>> Banco vazio. Instalação..."
    if su -s /bin/sh www-data -c "php admin/cli/install_database.php \
        --lang='$MOODLE_LANG' \
        --adminuser='${MOODLE_ADMIN_USER:-admin}' \
        --adminpass='${MOODLE_ADMIN_PASS:-MoodleAdmin123!}' \
        --adminemail='${MOODLE_ADMIN_EMAIL:-admin@example.com}' \
        --agree-license"; then

        su -s /bin/sh www-data -c "php admin/cli/cfg.php --name=fullname --set='${MOODLE_SITE_FULLNAME:-Moodle Site}'"
        su -s /bin/sh www-data -c "php admin/cli/cfg.php --name=shortname --set='${MOODLE_SITE_SHORTNAME:-Moodle}'"
    else
        echo "❌ ERRO NA INSTALAÇÃO!"
        exit 1
    fi
fi

echo ">>> Limpando caches..."
su -s /bin/sh www-data -c "php admin/cli/purge_caches.php"

echo ">>> Iniciando Supervisor..."
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf
