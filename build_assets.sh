#!/bin/bash
set -e

MOODLE_DIR=$1
MOODLE_VERSION=$2
MOODLE_GIT_REPO=$3
MOODLE_EXTRA_PHP=$4

echo "--- [BUILD] Baixando Core ($MOODLE_VERSION) ---"
git clone --branch "$MOODLE_VERSION" --depth 1 "$MOODLE_GIT_REPO" "$MOODLE_DIR"
rm -rf "$MOODLE_DIR/.git"

echo "--- [BUILD] Processando Plugins ---"
if [ -f "/tmp/plugins.json" ]; then
    if jq -e . >/dev/null 2>&1 <<< cat /tmp/plugins.json; then
        jq -c '.[]' /tmp/plugins.json | while read i; do
            GIT_URL=$(echo "$i" | jq -r '.giturl')
            GIT_BRANCH=$(echo "$i" | jq -r '.branch // empty')
            INSTALL_PATH=$(echo "$i" | jq -r '.installpath')
            FULL_PATH="$MOODLE_DIR/$INSTALL_PATH"

            echo "--- [BUILD] Plugin: $INSTALL_PATH ---"
            CLONE_ARGS="--depth 1 --recursive"
            # ^-- MUDANÇA IMPORTANTE: --recursive para baixar submodulos (H5P)

            [ ! -z "$GIT_BRANCH" ] && CLONE_ARGS="$CLONE_ARGS --branch $GIT_BRANCH"

            rm -rf "$FULL_PATH"
            # shellcheck disable=SC2086
            git clone $CLONE_ARGS "$GIT_URL" "$FULL_PATH"
            rm -rf "$FULL_PATH/.git"
        done
    fi
fi

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

# Injeta o conteúdo da variável de build diretamente no arquivo
if [ ! -z "$MOODLE_EXTRA_PHP" ]; then
    echo "$MOODLE_EXTRA_PHP" >> "$MOODLE_DIR/config.php"
fi

cat <<EOF >> "$MOODLE_DIR/config.php"

require_once(__DIR__ . '/lib/setup.php');
EOF

echo "--- [BUILD] Aplicando Permissões de Segurança (Root Only) ---"
# O código pertence ao root e o PHP (www-data) só pode ler
chown -R root:root "$MOODLE_DIR"
chmod -R 755 "$MOODLE_DIR"
chmod 644 "$MOODLE_DIR/config.php"

echo "--- [BUILD] Concluído."