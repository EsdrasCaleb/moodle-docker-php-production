#!/bin/bash
set -e

# --- Default Environment Variables ---
: "${MOODLE_DIR:=/var/www/moodle}"
: "${MOODLE_DATA:=/var/www/moodledata}"
: "${DB_PORT:=5432}"
: "${MOODLE_LANG:=en}"
: "${MOODLE_GIT_REPO:=https://github.com/moodle/moodle.git}"
: "${MOODLE_VERSION:=MOODLE_405_STABLE}"

# --- PHP Defaults ---
: "${PHP_MEMORY_LIMIT:=512M}"
: "${PHP_UPLOAD_MAX_FILESIZE:=100M}"
: "${PHP_POST_MAX_SIZE:=100M}"
: "${PHP_MAX_EXECUTION_TIME:=600}"
: "${PHP_MAX_INPUT_VARS:=5000}"

echo ">>> Starting Container (Dynamic Mode)..."

# ----------------------------------------------------------------------
# 0. PHP Configuration (Runtime Overrides)
# ----------------------------------------------------------------------
echo ">>> Applying PHP configurations (Memory: $PHP_MEMORY_LIMIT, Upload: $PHP_UPLOAD_MAX_FILESIZE)..."
{
    echo "file_uploads = On"
    echo "memory_limit = ${PHP_MEMORY_LIMIT}"
    echo "upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE}"
    echo "post_max_size = ${PHP_POST_MAX_SIZE}"
    echo "max_execution_time = ${PHP_MAX_EXECUTION_TIME}"
    echo "max_input_vars = ${PHP_MAX_INPUT_VARS}"
} > /usr/local/etc/php/conf.d/moodle-overrides.ini

# ----------------------------------------------------------------------
# 1. Git Optimizations (Prevent RPC/GnuTLS errors)
# ----------------------------------------------------------------------
git config --global http.postBuffer 524288000
git config --global http.lowSpeedLimit 0
git config --global http.lowSpeedTime 999999
git config --global core.compression 0

# ----------------------------------------------------------------------
# 2. Download/Update Moodle Core
# ----------------------------------------------------------------------
if [ ! -d "$MOODLE_DIR/.git" ]; then
    echo ">>> Downloading Moodle Core ($MOODLE_VERSION) via Manual Fetch..."
    rm -rf "$MOODLE_DIR"/* "$MOODLE_DIR"/.* 2>/dev/null || true
    mkdir -p "$MOODLE_DIR"
    cd "$MOODLE_DIR"
    git init
    git config --global --add safe.directory "$MOODLE_DIR"
    git remote add origin "$MOODLE_GIT_REPO"

    if git fetch --depth 1 origin "$MOODLE_VERSION"; then
        git checkout FETCH_HEAD
        echo ">>> Core download complete."
    else
        echo "ERROR: Failed to download Moodle. Check connection or version: $MOODLE_VERSION"
        exit 1
    fi
else
    echo ">>> Checking for Moodle Core updates..."
    cd "$MOODLE_DIR"
    git config --global --add safe.directory "$MOODLE_DIR"
    git remote set-url origin "$MOODLE_GIT_REPO"
    if git fetch --depth 1 origin "$MOODLE_VERSION"; then
        git reset --hard FETCH_HEAD
    fi
fi

# ----------------------------------------------------------------------
# 3. Plugin Installation
# ----------------------------------------------------------------------
PLUGINS_CONTENT=""
if [ ! -z "$MOODLE_PLUGINS_JSON" ] && [ "$MOODLE_PLUGINS_JSON" != "[]" ]; then
    PLUGINS_CONTENT="$MOODLE_PLUGINS_JSON"
    echo ">>> Plugins found in environment variable."
elif [ -f "/usr/local/bin/default_plugins.json" ]; then
    PLUGINS_CONTENT=$(cat /usr/local/bin/default_plugins.json)
    echo ">>> Using fallback plugins file."
fi

if [ ! -z "$PLUGINS_CONTENT" ]; then
    echo ">>> Processing Plugins..."
    if echo "$PLUGINS_CONTENT" | jq . >/dev/null 2>&1; then
        echo "$PLUGINS_CONTENT" | jq -c '.[]' | while read i; do
            GIT_URL=$(echo "$i" | jq -r '.giturl')
            GIT_BRANCH=$(echo "$i" | jq -r '.branch // empty')
            INSTALL_PATH=$(echo "$i" | jq -r '.installpath')

            VERSION_NUM=$(echo "$MOODLE_VERSION" | tr -dc '0-9')

            # Moodle 5.1+ directory logic
            if [ "$VERSION_NUM" -ge 501 ] && [[ "$INSTALL_PATH" != public/* ]]; then
                FULL_PATH="$MOODLE_DIR/public/$INSTALL_PATH"
            else
                FULL_PATH="$MOODLE_DIR/$INSTALL_PATH"
            fi

            echo "--- Plugin: $INSTALL_PATH ($GIT_BRANCH) -> $FULL_PATH ---"
            [ -d "$FULL_PATH" ] && rm -rf "$FULL_PATH"
            mkdir -p "$(dirname "$FULL_PATH")"

            git clone --no-checkout "$GIT_URL" "$FULL_PATH"
            cd "$FULL_PATH"
            [ ! -z "$GIT_BRANCH" ] && git fetch --depth 1 origin "$GIT_BRANCH" && git checkout FETCH_HEAD || git checkout
            git submodule update --init --recursive --depth 1
            cd - > /dev/null
            rm -rf "$FULL_PATH/.git"
        done
    else
        echo "WARNING: Invalid Plugins JSON."
    fi
fi

# ----------------------------------------------------------------------
# 4. Configuration (config.php)
# ----------------------------------------------------------------------
if [ ! -f "$MOODLE_DIR/config.php" ]; then
    echo ">>> Generating config.php..."
    # Use single quotes for EOF to prevent shell expansion of $CFG
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

// --- EXTRAS ---
EOF

    # Safely append extra PHP without shell expansion
    if [ ! -z "$MOODLE_EXTRA_PHP" ]; then
        echo "$MOODLE_EXTRA_PHP" >> "$MOODLE_DIR/config.php"
    fi

    echo "require_once(__DIR__ . '/lib/setup.php');" >> "$MOODLE_DIR/config.php"
fi

# ----------------------------------------------------------------------
# 5. Permissions (Mandatory before DB Setup)
# ----------------------------------------------------------------------
echo ">>> Setting permissions..."
chown -R root:www-data "$MOODLE_DIR" "$MOODLE_DATA"
chmod -R 755 "$MOODLE_DIR"
chmod -R 777 "$MOODLE_DATA"

# ----------------------------------------------------------------------
# 6. Database Setup/Upgrade
# ----------------------------------------------------------------------
echo ">>> Waiting for Database ($DB_HOST)..."
until echo > /dev/tcp/$DB_HOST/$DB_PORT; do sleep 3; done 2>/dev/null || true

echo ">>> Checking Database status..."
if su -s /bin/sh www-data -c "php -r 'define(\"CLI_SCRIPT\", true); require(\"$MOODLE_DIR/config.php\"); if (\$DB->get_manager()->table_exists(\"config\")) { exit(0); } else { exit(1); }'" >/dev/null 2>&1; then
    echo ">>> Database exists. Running upgrades..."
    su -s /bin/sh www-data -c "php $MOODLE_DIR/admin/cli/upgrade.php --non-interactive"
else
    echo ">>> Database is empty. Starting fresh installation..."
    if su -s /bin/sh www-data -c "php $MOODLE_DIR/admin/cli/install_database.php \
        --lang='$MOODLE_LANG' \
        --adminuser='${MOODLE_ADMIN_USER:-admin}' \
        --adminpass='${MOODLE_ADMIN_PASS:-MoodleAdmin123!}' \
        --adminemail='${MOODLE_ADMIN_EMAIL:-admin@example.com}' \
        --agree-license"; then

        su -s /bin/sh www-data -c "php $MOODLE_DIR/admin/cli/cfg.php --name=fullname --set='${MOODLE_SITE_FULLNAME:-Moodle Site}'"
        su -s /bin/sh www-data -c "php $MOODLE_DIR/admin/cli/cfg.php --name=shortname --set='${MOODLE_SITE_SHORTNAME:-Moodle}'"
    else
        echo "ERROR: Installation failed!"
        exit 1
    fi
fi

# ----------------------------------------------------------------------
# 7. Web Server & Maintenance
# ----------------------------------------------------------------------
echo ">>> Purging caches..."
su -s /bin/sh www-data -c "php $MOODLE_DIR/admin/cli/purge_caches.php"

# Nginx public folder adjustment for Moodle 5.1+
VERSION_NUM=$(echo "$MOODLE_VERSION" | tr -dc '0-9')
if [ "$VERSION_NUM" -ge 501 ]; then
    echo ">>> Adjusting Nginx for Moodle 5.1+ (Root: /public)..."
    sed -i 's|root /var/www/moodle;|root /var/www/moodle/public;|g' /etc/nginx/nginx.conf
else
    echo ">>> Adjusting Nginx for legacy Moodle (Root: /)..."
    sed -i 's|root /var/www/moodle/public;|root /var/www/moodle;|g' /etc/nginx/nginx.conf
fi

echo ">>> Starting Supervisor..."
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf