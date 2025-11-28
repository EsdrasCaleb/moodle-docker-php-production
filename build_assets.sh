#!/bin/bash
set -e

MOODLE_DIR=$1
MOODLE_VERSION=$2
MOODLE_GIT_REPO=$3
MOODLE_EXTRA_PHP=$4
# Novo argumento recebendo a string JSON
MOODLE_PLUGINS_JSON_ARG=$5

echo "--- [BUILD] Baixando Core ($MOODLE_VERSION) ---"
git clone --branch "$MOODLE_VERSION" --depth 1 "$MOODLE_GIT_REPO" "$MOODLE_DIR"
rm -rf "$MOODLE_DIR/.git"

# ----------------------------------------------------------------------
# Lógica de Seleção de Plugins
# ----------------------------------------------------------------------
TARGET_JSON="/tmp/final_plugins.json"

if [ ! -z "$MOODLE_PLUGINS_JSON_ARG" ] && [ "$MOODLE_PLUGINS_JSON_ARG" != "[]" ]; then
    echo "--- [BUILD] Usando JSON via Argumento de Build ---"
    echo "$MOODLE_PLUGINS_JSON_ARG" > "$TARGET_JSON"
elif [ -f "/tmp/plugins_file.json" ]; then
    echo "--- [BUILD] Usando arquivo plugins.json local ---"
    cp "/tmp/plugins_file.json" "$TARGET_JSON"
else
    echo "[]" > "$TARGET_JSON"
fi

echo "--- [BUILD] Processando Plugins ---"
if [ -f "$TARGET_JSON" ]; then
    if jq -e . >/dev/null 2>&1 <<< cat "$TARGET_JSON"; then
        jq -c '.[]' "$TARGET_JSON" | while read i; do
            GIT_URL=$(echo "$i" | jq -r '.giturl')
            GIT_BRANCH=$(echo "$i" | jq -r '.branch // empty')
            INSTALL_PATH=$(echo "$i" | jq -r '.installpath')
            FULL_PATH="$MOODLE_DIR/$INSTALL_PATH"

            echo "--- [BUILD] Plugin: $INSTALL_PATH ---"
            CLONE_ARGS="--depth 1 --recursive"

            [ ! -z "$GIT_BRANCH" ] && CLONE_ARGS="$CLONE_ARGS --branch $GIT_BRANCH"

            rm -rf "$FULL_PATH"
            # shellcheck disable=SC2086
            git clone $CLONE_ARGS "$GIT_URL" "$FULL_PATH"
            rm -rf "$FULL_PATH/.git"
        done
    else
        echo "AVISO: JSON de plugins inválido."
    fi
fi
# Limpeza
rm -f "$TARGET_JSON" "/tmp/plugins_file.json"

# ----------------------------------------------------------------------
# GERAÇÃO DO CONFIG.PHP
# ----------------------------------------------------------------------
echo "--- [BUILD] Gerando config.php (Hardened) ---"

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
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = array (
  'dbport' => getenv('DB_PORT') ?: '',
  'dbpersist' => 0,
  'dbscent' => 0,
);

\$CFG->wwwroot   = getenv('MOODLE_URL');
\$CFG->dataroot  = '/var/www/moodledata';
\$CFG->admin     = 'admin';
\$CFG->directorypermissions = 0777;

// --- CONFIGURAÇÃO INJETADA NO BUILD (IMUTÁVEL) ---
EOF

if [ ! -z "$MOODLE_EXTRA_PHP" ]; then
    echo "$MOODLE_EXTRA_PHP" >> "$MOODLE_DIR/config.php"
fi

cat <<EOF >> "$MOODLE_DIR/config.php"

require_once(__DIR__ . '/lib/setup.php');
EOF

echo "--- [BUILD] Aplicando Permissões de Segurança (Root Only) ---"
chown -R root:root "$MOODLE_DIR"
chmod -R 755 "$MOODLE_DIR"
chmod 644 "$MOODLE_DIR/config.php"

echo "--- [BUILD] Concluído."