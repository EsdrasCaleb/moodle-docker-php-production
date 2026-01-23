#!/bin/bash
set -e

# --- Default Environment Variables ---
: "${MOODLE_DIR:=/var/www/moodle}"
: "${MOODLE_DATA:=/var/www/moodledata}"
: "${CODE_CACHE_DIR:=$MOODLE_DATA/sitecode}"     # Cache do Core
: "${PLUGIN_CACHE_ROOT:=$MOODLE_DATA/plugincode}" # Cache dos Plugins
: "${DB_PORT:=5432}"
: "${MOODLE_LANG:=en}"
: "${MOODLE_GIT_REPO:=https://github.com/moodle/moodle.git}"
: "${MOODLE_VERSION:=MOODLE_405_STABLE}"

# --- Update Control ---
# static: only download if do not exists.
# reset:  reseet to the last download state
# update:  reseet to the last download state and upates with remote
: "${SITE_CODE_STATUS:=reset}"
: "${PLUGIN_CODE_STATUS:=reset}"

# --- PHP Defaults ---
: "${PHP_MEMORY_LIMIT:=512M}"
: "${PHP_UPLOAD_MAX_FILESIZE:=100M}"
: "${PHP_POST_MAX_SIZE:=100M}"
: "${PHP_MAX_EXECUTION_TIME:=600}"
: "${PHP_MAX_INPUT_VARS:=5000}"

echo ">>> Starting Container (Optimization Mode: $CODE_STATUS)..."
# ----------------------------------------------------------------------
# Helper Function: Manage Git Repositories
# ----------------------------------------------------------------------
manage_repo() {
    local path="$1"
    local repo_url="$2"
    local target="$3"
    local code_status="$4"

    if [ -z "$target" ]; then target="$MOODLE_VERSION"; fi

    echo ">>> Managing Repo at: $path"
    echo "    Target: $target | Mode: $code_status"

    # 1. Clone inicial
    if [ ! -d "$path/.git" ]; then
        echo "    -> [NEW] Initializing and fetching..."
        mkdir -p "$path"
        if [ -n "$(ls -A "$path" 2>/dev/null)" ]; then rm -rf "$path"/*; fi

        cd "$path"
        git init --quiet
        git remote add origin "$repo_url"
        # O segredo: fetch direto do target e checkout do FETCH_HEAD
        git fetch --depth 1 origin "$target"
        git checkout -f FETCH_HEAD
        git submodule update --init --recursive --depth 1
        cd - > /dev/null
        return
    fi

    cd "$path"
    git config --global --add safe.directory "$path"
    git remote set-url origin "$repo_url"

    case "$code_status" in
        "update")
            echo "    -> [UPDATE] Fetching latest..."
            git clean -fdx
            git fetch --depth 1 origin "$target"
            # Checkout do que acabou de ser baixado
            git checkout -f FETCH_HEAD
            git reset --hard FETCH_HEAD
            git submodule update --init --recursive --depth 1
            ;;
        "reset")
            echo "    -> [RESET] Restoring..."
            git clean -fdx
            # Tenta usar o que já tem, se falhar, busca e usa o FETCH_HEAD
            if ! git checkout -f "$target" 2>/dev/null; then
                echo "       ! Target not found locally. Fetching..."
                git fetch --depth 1 origin "$target"
                git checkout -f FETCH_HEAD
                git reset --hard FETCH_HEAD
            else
                git reset --hard "$target"
            fi
            git submodule update --init --recursive --depth 1
            ;;
    esac
    # Log para confirmar o que foi baixado
    echo "    -> Current Commit: $(git rev-parse HEAD)"
    cd - > /dev/null
}

# ----------------------------------------------------------------------
# 0. PHP Configuration
# ----------------------------------------------------------------------
echo ">>> Applying PHP configurations..."
{
    echo "file_uploads = On"
    echo "memory_limit = ${PHP_MEMORY_LIMIT}"
    echo "upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE}"
    echo "post_max_size = ${PHP_POST_MAX_SIZE}"
    echo "max_execution_time = ${PHP_MAX_EXECUTION_TIME}"
    echo "max_input_vars = ${PHP_MAX_INPUT_VARS}"
} > /usr/local/etc/php/conf.d/moodle-overrides.ini

# ----------------------------------------------------------------------
# 1. Git Optimizations
# ----------------------------------------------------------------------
git config --global http.postBuffer 524288000
git config --global core.compression 0

# ----------------------------------------------------------------------
# 2. Moodle Core Layer (Cache -> Deploy)
# ----------------------------------------------------------------------
echo ">>> [LAYER 1] Moodle Core..."

# A. Atualiza o Cache (Code base)
manage_repo "$CODE_CACHE_DIR" "$MOODLE_GIT_REPO" "$MOODLE_VERSION" "$SITE_CODE_STATUS"

# B. Limpeza Radical do Destino (Garante consistência)
# Se não é volume persistente, já estaria vazio, mas garantimos aqui.
if [ -d "$MOODLE_DIR" ]; then
    echo ">>> Cleaning deployment directory..."
    rm -rf "$MOODLE_DIR"/* "$MOODLE_DIR"/.* 2>/dev/null || true
fi
mkdir -p "$MOODLE_DIR"

# C. Sincroniza Cache -> Produção (Usando CP ao invés de RSYNC)
echo ">>> [DEPLOY] Copying Core to $MOODLE_DIR..."
# cp -a preserva permissões e links simbólicos
cp -a "$CODE_CACHE_DIR/." "$MOODLE_DIR/"
# Removemos o .git do destino para economizar espaço e segurança
rm -rf "$MOODLE_DIR/.git"

# ----------------------------------------------------------------------
# 3. Generate Config.php (Always Fresh)
# ----------------------------------------------------------------------
echo ">>> Generating config.php..."
cat <<'EOF' > "$MOODLE_DIR/config.php"
<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();

$CFG->dbtype    = getenv('DB_TYPE') ?: 'pgsql';
$CFG->dblibrary = 'native';
$CFG->dbhost    = getenv('DB_HOST') ?: 'localhost';
$CFG->dbname    = getenv('DB_NAME') ?: 'moodle';
$CFG->dbuser    = getenv('DB_USER') ?: 'moodle';
$CFG->dbpass    = getenv('DB_PASS') ?: '';
$CFG->prefix    = getenv('DB_PREFIX') ?: 'mdl_';
$CFG->dboptions = array (
  'dbport' => getenv('DB_PORT') ?: '',
  'dbpersist' => 0,
  'dbscent' => 0,
);

$CFG->wwwroot   = getenv('MOODLE_URL');
$CFG->dataroot  = '/var/www/moodledata';
$CFG->admin     = 'admin';
$CFG->directorypermissions = 0777;
EOF

if [ ! -z "$MOODLE_EXTRA_PHP" ]; then echo "$MOODLE_EXTRA_PHP" >> "$MOODLE_DIR/config.php"; fi
echo "require_once(__DIR__ . '/lib/setup.php');" >> "$MOODLE_DIR/config.php"

# ----------------------------------------------------------------------
# 4. Plugins Layer (Cache -> Deploy)
# ----------------------------------------------------------------------
PLUGINS_CONTENT=""
if [ ! -z "$MOODLE_PLUGINS_JSON" ] && [ "$MOODLE_PLUGINS_JSON" != "[]" ]; then
    PLUGINS_CONTENT="$MOODLE_PLUGINS_JSON"
elif [ -f "/usr/local/bin/default_plugins.json" ]; then
    PLUGINS_CONTENT=$(cat /usr/local/bin/default_plugins.json)
fi

if [ ! -z "$PLUGINS_CONTENT" ]; then
    echo ">>> [LAYER 2] Plugins..."
    # Validação do JSON com feedback de erro
    if ! echo "$PLUGINS_CONTENT" | jq . >/dev/null 2>&1; then
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "ERROR: Invalid JSON format in MOODLE_PLUGINS_JSON"
        echo "$PLUGINS_CONTENT" | jq .;
        exit 1
    else
        echo "$PLUGINS_CONTENT" | jq -c '.[]' | while read i; do
            GIT_URL=$(echo "$i" | jq -r '.giturl')
            GIT_BRANCH=$(echo "$i" | jq -r '.branch // empty')
            INSTALL_PATH=$(echo "$i" | jq -r '.installpath')

            VERSION_NUM=$(echo "$MOODLE_VERSION" | tr -dc '0-9')

            # Ajuste de caminho para Moodle 5.1+
            if [ "$VERSION_NUM" -ge 501 ] && [[ "$INSTALL_PATH" != public/* ]]; then
                REL_PATH="public/$INSTALL_PATH"
            else
                REL_PATH="$INSTALL_PATH"
            fi

            PLUGIN_CACHE_PATH="$PLUGIN_CACHE_ROOT/$REL_PATH"
            PLUGIN_DEST_PATH="$MOODLE_DIR/$REL_PATH"

            # A. Atualiza Cache
            manage_repo "$PLUGIN_CACHE_PATH" "$GIT_URL" "$GIT_BRANCH" "$PLUGIN_CODE_STATUS"

            # B. Copia Cache -> Produção
            echo "--- Installing Plugin: $REL_PATH ---"
            mkdir -p "$(dirname "$PLUGIN_DEST_PATH")"

            # Limpa destino antigo se existir (garante clean install do plugin)
            rm -rf "$PLUGIN_DEST_PATH"

            # Copia e remove .git
            cp -a "$PLUGIN_CACHE_PATH/." "$PLUGIN_DEST_PATH/"
            rm -rf "$PLUGIN_DEST_PATH/.git"
        done
    fi
fi

# ----------------------------------------------------------------------
# 5. Final Permissions & Web Server
# ----------------------------------------------------------------------
echo ">>> Finalizing permissions..."
chown -R root:www-data "$MOODLE_DIR" "$MOODLE_DATA"
chmod -R 755 "$MOODLE_DIR"
chmod -R 777 "$MOODLE_DATA"
chmod -R 755 "$CODE_CACHE_DIR"
[ -d "$PLUGIN_CACHE_ROOT" ] && chmod -R 755 "$PLUGIN_CACHE_ROOT"

# Nginx Adjustment
VERSION_NUM=$(echo "$MOODLE_VERSION" | tr -dc '0-9')
if [ "$VERSION_NUM" -ge 501 ]; then
    sed -i 's|root /var/www/moodle;|root /var/www/moodle/public;|g' /etc/nginx/nginx.conf
else
    sed -i 's|root /var/www/moodle/public;|root /var/www/moodle;|g' /etc/nginx/nginx.conf
fi

# ----------------------------------------------------------------------
# 6. Database & Upgrade
# ----------------------------------------------------------------------
echo ">>> Waiting for Database..."
until echo > /dev/tcp/$DB_HOST/$DB_PORT; do sleep 3; done 2>/dev/null || true

echo ">>> Database Status..."
# Check rápido via PHP para ver se tabelas existem
if su -s /bin/sh www-data -c "php -r 'define(\"CLI_SCRIPT\", true); require(\"$MOODLE_DIR/config.php\"); if (\$DB->get_manager()->table_exists(\"config\")) { exit(0); } else { exit(1); }'" >/dev/null 2>&1; then
    echo ">>> Database exists. Running upgrades..."
    su -s /bin/sh www-data -c "php $MOODLE_DIR/admin/cli/upgrade.php --non-interactive"
else
    echo ">>> Installing Moodle..."
    su -s /bin/sh www-data -c "php $MOODLE_DIR/admin/cli/install_database.php \
        --lang='$MOODLE_LANG' \
        --adminuser='${MOODLE_ADMIN_USER:-admin}' \
        --adminpass='${MOODLE_ADMIN_PASS:-MoodleAdmin123!}' \
        --adminemail='${MOODLE_ADMIN_EMAIL:-admin@example.com}' \
        --fullname='${MOODLE_SITE_FULLNAME:-Moodle Site}' \
        --shortname='${MOODLE_SITE_SHORTNAME:-Moodle}' \
        --agree-license" || exit 1
fi

echo ">>> Starting Supervisor..."
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf