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
: "${OPCAHE_STRINGS_BUFFER:=16}"
: "${OPCACHE_MAX_FILES:=20000}"
: "${FASTCGI_BUFFER:=64}"


# Nginx Adjustment

# Moodle 5.1+ requer /public, versões anteriores usam a raiz
VERSION_NUM=$(echo "$MOODLE_VERSION" | tr -dc '0-9')
if [ "$VERSION_NUM" -ge 501 ]; then
    NGINX_WEB_ROOT="/var/www/moodle/public"
else
    NGINX_WEB_ROOT="/var/www/moodle"
fi
echo "    -> Nginx Root configured to: $NGINX_WEB_ROOT"

# --- Auto-Correction: Upload vs Post ---
# Função auxiliar para converter strings (1G, 500M) em bytes numéricos para comparação
get_bytes() {
    local val=$1
    # Awk detecta a letra, multiplica e retorna o inteiro
    echo "$val" | awk '
        /G/ {printf "%.0f", $1 * 1024 * 1024 * 1024; exit}
        /M/ {printf "%.0f", $1 * 1024 * 1024; exit}
        /K/ {printf "%.0f", $1 * 1024; exit}
        {print $1}
    '
}

BYTES_UPLOAD=$(get_bytes "$PHP_UPLOAD_MAX_FILESIZE")
BYTES_POST=$(get_bytes "$PHP_POST_MAX_SIZE")

if [ "$BYTES_UPLOAD" -gt "$BYTES_POST" ]; then
    echo ">>> WARNING: PHP_UPLOAD_MAX_FILESIZE ($PHP_UPLOAD_MAX_FILESIZE) is larger than PHP_POST_MAX_SIZE ($PHP_POST_MAX_SIZE)."
    echo "    -> Auto-fixing: Setting PHP_POST_MAX_SIZE to match Upload Size."
    PHP_POST_MAX_SIZE="$PHP_UPLOAD_MAX_FILESIZE"
fi

# ----------------------------------------------------------------------
# 0. SERVER Configuration
# ----------------------------------------------------------------------
# Variável Mágica: Porcentagem de RAM para usar (Padrão 75%)
# Se for maquina dedicada, use 90. Se for dividida, use 50.
: "${SERVER_MEMORY_USAGE_PERCENT:=75}"
: "${NGINX_GZIP_LEVEL:=6}"  # Padrão 6 (Equilíbrio). Use 1 para performance máxima de CPU.

# --- 0.1. Cálculos Automáticos (Auto-Tuning) ---

echo ">>> Auto-Tuning PHP & Nginx..."

# Detecta Memória Total em MB
TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
echo "    Total RAM detected: ${TOTAL_RAM_MB}MB"

TARGET_RAM_MB=$(awk "BEGIN {print int($TOTAL_RAM_MB * $SERVER_MEMORY_USAGE_PERCENT / 100)}")
echo "    Target RAM (${SERVER_MEMORY_USAGE_PERCENT}%): ${TARGET_RAM_MB}MB"
# Calcula memória alvo
 PM_MAX_CHILDREN=$(awk "BEGIN {print int($TARGET_RAM_MB / 100)}")

# Segurança mínima

if [ "$PM_MAX_CHILDREN" -lt 5 ]; then PM_MAX_CHILDREN=5; fi


PM_START_SERVERS=$(awk "BEGIN {print int($PM_MAX_CHILDREN * 0.25)}")

if [ "$PM_START_SERVERS" -lt 2 ]; then PM_START_SERVERS=2; fi

PM_MIN_SPARE=$(awk "BEGIN {print int($PM_MAX_CHILDREN * 0.20)}")

if [ "$PM_MIN_SPARE" -lt 2 ]; then PM_MIN_SPARE=1; fi

PM_MAX_SPARE=$(awk "BEGIN {print int($PM_MAX_CHILDREN * 0.50)}")

if [ "$PM_MAX_SPARE" -lt 3 ]; then PM_MAX_SPARE=3; fi

# Garante que Max Spare seja pelomenos maior ao Start Servers
if [ "$PM_MAX_SPARE" -lt "$PM_START_SERVERS" ]; then
    PM_MAX_SPARE=$(( PM_START_SERVERS + 1 ))
fi

# Garante que Max Children seja maior que Max Spare (para não travar)
if [ "$PM_MAX_CHILDREN" -lt "$PM_MAX_SPARE" ]; then
    PM_MAX_CHILDREN=$(( PM_MAX_SPARE + 1 ))
fi

if [ "$TARGET_RAM_MB" -le 2048 ]; then
    PM_MAX_REQUESTS=500
else
    PM_MAX_REQUESTS=1000
fi

# Cálculos de Cache (APCu e OPCache)
# Aloca ~5% da RAM alvo para cada cache (ajuste fino)
CACHE_SIZE=$(awk "BEGIN {print int($TARGET_RAM_MB * 0.05)}")
if [ "$CACHE_SIZE" -lt 128 ]; then CACHE_SIZE=128; fi
# Teto para não exagerar em máquinas gigantes
if [ "$CACHE_SIZE" -gt 512 ]; then CACHE_SIZE=512; fi

echo "    Calculated settings:"
echo "    -> pm.max_children = $PM_MAX_CHILDREN"
echo "    -> Cache Size (APCu/OPCache) = ${CACHE_SIZE}M"

# ---  Geração de Arquivos de Configuração ---

#  PHP-FPM Pool (Sobrescreve se AUTO_TUNE=true ou se não existir)
echo "    -> Generating php-fpm pool config..."
#rm -f /usr/local/etc/php-fpm.d/www.conf /usr/local/etc/php-fpm.d/zz-docker.conf

    cat <<EOF > /usr/local/etc/php-fpm.d/zz-docker.conf
[global]
daemonize = no

[www]
pm = dynamic
pm.max_children = $PM_MAX_CHILDREN
pm.start_servers = $PM_START_SERVERS
pm.min_spare_servers = $PM_MIN_SPARE
pm.max_spare_servers = $PM_MAX_SPARE
pm.max_requests = $PM_MAX_REQUESTS

catch_workers_output = yes
decorate_workers_output = no
EOF

#  OPCache
cat <<EOF > /usr/local/etc/php/conf.d/10-opcache-tuning.ini
opcache.enable=1
opcache.memory_consumption=${CACHE_SIZE}
opcache.interned_strings_buffer=${OPCAHE_STRINGS_BUFFER}
opcache.max_accelerated_files=${OPCACHE_MAX_FILES}
opcache.revalidate_freq=0
opcache.validate_timestamps=0
opcache.enable_cli=1
EOF


#  APCu

cat <<EOF > /usr/local/etc/php/conf.d/20-apcu-tuning.ini
apc.enabled=1
apc.shm_size=${CACHE_SIZE}M
apc.ttl=7200
apc.enable_cli=1
EOF

#  Configuração Geral PHP (Uploads/Memory)
echo "    -> Generating General PHP config..."
cat <<EOF > /usr/local/etc/php/conf.d/00-general.ini
memory_limit = ${PHP_MEMORY_LIMIT}
upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE}
post_max_size = ${PHP_POST_MAX_SIZE}
max_execution_time = ${PHP_MAX_EXECUTION_TIME}
max_input_vars = ${PHP_MAX_INPUT_VARS}
date.timezone = America/Sao_Paulo
EOF

MAX_BUFFER_SIZE=$(awk "BEGIN {print int($FASTCGI_BUFFER * 2)}")
# Nginx Config
echo "    -> Generating Nginx config..."
cat <<EOF > /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /var/run/nginx.pid;

events {
    worker_connections 2048;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /dev/stdout;
    error_log /dev/stderr;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout ${PHP_MAX_EXECUTION_TIME};
    client_body_timeout ${PHP_MAX_EXECUTION_TIME};
    client_header_timeout ${PHP_MAX_EXECUTION_TIME};
    fastcgi_read_timeout ${PHP_MAX_EXECUTION_TIME};
    types_hash_max_size 2048;

    # Upload limits from ENV
    client_max_body_size ${PHP_UPLOAD_MAX_FILESIZE};

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level ${NGINX_GZIP_LEVEL}; # Mais compressão, usa um pouco mais de CPU (ok na sua máquina dedicada)
    gzip_min_length 256;
    gzip_types
        text/plain
        text/css
        text/javascript
        application/javascript
        application/json
        application/x-javascript
        application/xml
        application/xml+rss
        image/svg+xml
        image/x-icon
        font/ttf
        font/opentype;

    # Logs
    access_log /var/log/nginx/access.log;

    server {
        listen 80;
        listen [::]:80;

        server_name _;
        root ${NGINX_WEB_ROOT};
        index index.php index.html;

        location / {
            try_files \$uri \$uri/ /index.php?\$query_string;
        }

        location ~ (/\.git|/\.env|/vendor/|/node_modules/|composer\.json|/readme|/README|/LICENSE|/COPYING|/tests/|/classes/|/cli/|/\.) {
            deny all;
            return 404;
        }

        location ~ [^/]\.php(/|$) {
            fastcgi_split_path_info ^(.+?\.php)(/.*)$;

            if (!-f \$document_root\$fastcgi_script_name) {
                return 404;
            }

            fastcgi_pass 127.0.0.1:9000;
            fastcgi_index index.php;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_param PATH_INFO \$fastcgi_path_info;

            # BUFFERS CRUCIAIS PARA O MOODLE (Headers Grandes)
            fastcgi_buffers 4 ${MAX_BUFFER_SIZE}k;
            fastcgi_buffer_size ${FASTCGI_BUFFER}k;
            fastcgi_busy_buffers_size ${MAX_BUFFER_SIZE}k;

            # Timeout longo para scripts de instalação/backup
            fastcgi_read_timeout ${PHP_MAX_EXECUTION_TIME};
        }

        location ~* \.(jpg|jpeg|gif|png|css|js|ico|xml|svg|woff|woff2|ttf|eot)$ {
            expires 365d;
            add_header Cache-Control "public, no-transform";
            try_files \$uri \$uri/ /index.php?\$query_string;
        }


        # Bloqueio de segurança padrão do Moodle
        location ~ (/vendor/|/node_modules/|composer\.json|/readme|/README|/LICENSE|/COPYING|/tests/|/classes/|/cli/) {
            deny all;
            return 404;
        }
    }
}
EOF


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

    # 1. Clone inicial (se não existir, não tem lock pra limpar ainda)
    if [ ! -d "$path/.git" ]; then
        echo "    -> [NEW] Initializing and fetching..."
        mkdir -p "$path"
        # Limpa diretório se não estiver vazio (mas sem .git)
        if [ -n "$(ls -A "$path" 2>/dev/null)" ]; then rm -rf "$path"/*; fi

        cd "$path"
        git init --quiet
        git remote add origin "$repo_url"
        git fetch --depth 1 origin "$target"
        git checkout -f FETCH_HEAD
        git submodule update --init --recursive --depth 1
        cd - > /dev/null
        return
    fi

    # Entra no diretório existente
    cd "$path"

    # --- CORREÇÃO AQUI ---
    # Remove travas estagnadas antes de qualquer operação
    if [ -d ".git" ]; then
        # Remove locks comuns que impedem o git de rodar
        rm -f .git/index.lock \
              .git/HEAD.lock \
              .git/shallow.lock \
              .git/config.lock \
              .git/refs/heads/*.lock \
              .git/refs/remotes/origin/*.lock

        # Opcional: Se for muito crítico, remove locks de submodules também
        find . -name "*.lock" -type f -path "*/.git/*" -delete 2>/dev/null
    fi
    # ---------------------

    git config --global --add safe.directory "$path"

    # Verifica se a URL mudou (útil se você mudou o repo no env)
    local current_url=$(git remote get-url origin 2>/dev/null)
    if [ "$current_url" != "$repo_url" ]; then
         git remote set-url origin "$repo_url"
    fi

    case "$code_status" in
        "update")
            echo "    -> [UPDATE] Fetching latest..."
            git clean -fdx
            git fetch --depth 1 origin "$target"
            git checkout -f FETCH_HEAD
            git reset --hard FETCH_HEAD
            git submodule update --init --recursive --depth 1
            ;;
        "reset")
            echo "    -> [RESET] Restoring..."
            git clean -fdx
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

    echo "    -> Current Commit: $(git rev-parse HEAD)"
    cd - > /dev/null
}

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
    if su -s /bin/sh www-data -c "php $MOODLE_DIR/admin/cli/install_database.php \
            --lang='$MOODLE_LANG' \
            --adminuser='${MOODLE_ADMIN_USER:-admin}' \
            --adminpass='${MOODLE_ADMIN_PASS:-MoodleAdmin123!}' \
            --adminemail='${MOODLE_ADMIN_EMAIL:-admin@example.com}' \
            --fullname='${MOODLE_SITE_FULLNAME:-Moodle Site}' \
            --shortname='${MOODLE_SITE_SHORTNAME:-Moodle}' \
            --supportemail='${MOODLE_SUPPORT_EMAIL:-support@example.com}' \
            --agree-license";
      then
          su -s /bin/sh www-data -c "php $MOODLE_DIR/admin/cli/cfg.php --name=noreplyaddress --set='${MOODLE_NOREPLY_EMAIL:-noreply@example.com}'"
          echo ">>> Installation completed successfully!"
      else
          echo "ERROR: Installation failed!"
          exit 1
      fi
fi

echo ">>> Starting Supervisor..."
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf