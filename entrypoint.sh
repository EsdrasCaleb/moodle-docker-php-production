#!/bin/bash
set -e

# Variáveis (MOODLE_DIR vem do Dockerfile)
: "${MOODLE_DIR:=/var/www/moodle}"
: "${DB_TYPE:=pgsql}"
: "${DB_PORT:=5432}"
: "${MOODLE_LANG:=pt_br}"

echo ">>> Iniciando Moodle Container (Versão Production Ready)..."

# ----------------------------------------------------------------------
# 1. Geração Dinâmica do config.php
# ----------------------------------------------------------------------
# Precisamos fazer isso no runtime pois DB_HOST e MOODLE_URL mudam por ambiente
if [ ! -f "$MOODLE_DIR/config.php" ]; then
    echo ">>> Gerando config.php..."

    EXTRA_CONFIG_CONTENT=""
    if [ ! -z "$MOODLE_EXTRA_PHP" ]; then
        EXTRA_CONFIG_CONTENT="$MOODLE_EXTRA_PHP"
    elif [ -f "/usr/local/bin/config-extra.php" ]; then
        EXTRA_CONFIG_CONTENT=$(cat /usr/local/bin/config-extra.php | sed 's/<?php//g' | sed 's/?>//g')
    fi

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

// --- INICIO CONFIGURACAO EXTRA ---
EOF

    if [ ! -z "$EXTRA_CONFIG_CONTENT" ]; then
        echo "$EXTRA_CONFIG_CONTENT" >> "$MOODLE_DIR/config.php"
    fi

    cat <<EOF >> "$MOODLE_DIR/config.php"
// --- FIM CONFIGURACAO EXTRA ---

require_once(__DIR__ . '/lib/setup.php');
EOF

    chown www-data:www-data "$MOODLE_DIR/config.php"
    chmod 644 "$MOODLE_DIR/config.php"
fi

# ----------------------------------------------------------------------
# 2. Instalação/Upgrade do Banco
# ----------------------------------------------------------------------
# Aguarda o banco estar online
echo ">>> Aguardando Banco ($DB_HOST:$DB_PORT)..."
until echo > /dev/tcp/$DB_HOST/$DB_PORT; do sleep 3; done 2>/dev/null || true

cd "$MOODLE_DIR"

# Verifica se o Moodle já está instalado no BANCO DE DADOS
# Usamos install_database.php com --agree-license. Se já instalado, ele falha seguro.
if sudo -u www-data php admin/cli/install_database.php \
    --lang="$MOODLE_LANG" \
    --adminuser="${MOODLE_ADMIN_USER:-admin}" \
    --adminpass="${MOODLE_ADMIN_PASS:-MoodleAdmin123!}" \
    --adminemail="${MOODLE_ADMIN_EMAIL:-admin@localhost}" \
    --agree-license > /dev/null 2>&1; then

    echo ">>> BANCO NOVO: Instalação concluída!"
    sudo -u www-data php admin/cli/cfg.php --name=fullname --set="${MOODLE_SITE_FULLNAME:-Moodle Site}"
    sudo -u www-data php admin/cli/cfg.php --name=shortname --set="${MOODLE_SITE_SHORTNAME:-Moodle}"
else
    echo ">>> BANCO EXISTENTE: Executando Upgrade..."
    # Se falhar a instalação, assumimos que é um upgrade
    sudo -u www-data php admin/cli/upgrade.php --non-interactive
fi

echo ">>> Limpando caches..."
sudo -u www-data php admin/cli/purge_caches.php

# ----------------------------------------------------------------------
# 3. Start
# ----------------------------------------------------------------------
echo ">>> Iniciando Supervisor..."
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf