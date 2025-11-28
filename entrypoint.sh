#!/bin/bash
set -e

# Defaults
: "${MOODLE_DIR:=/var/www/moodle}"
: "${DB_PORT:=5432}"
: "${MOODLE_LANG:=pt_br}"

echo ">>> Iniciando Moodle Container (Stateless & Hardened)..."

echo ">>> Aguardando Banco ($DB_HOST:$DB_PORT)..."
until echo > /dev/tcp/$DB_HOST/$DB_PORT; do sleep 3; done 2>/dev/null || true

cd "$MOODLE_DIR"

echo ">>> Verificando Banco de Dados..."

# Verificação se instalado
if php -r "define('CLI_SCRIPT', true); require('$MOODLE_DIR/config.php'); if (\$DB->get_manager()->table_exists('config')) { exit(0); } else { exit(1); }" >/dev/null 2>&1; then

    echo ">>> Banco existente. Executando Upgrade..."
    # Executa como www-data sem usar sudo
    su -s /bin/sh www-data -c "php admin/cli/upgrade.php --non-interactive"

else
    echo ">>> Banco vazio. Executando Instalação..."

    if su -s /bin/sh www-data -c "php admin/cli/install_database.php \
        --lang='$MOODLE_LANG' \
        --adminuser='${MOODLE_ADMIN_USER:-admin}' \
        --adminpass='${MOODLE_ADMIN_PASS:-MoodleAdmin123!}' \
        --adminemail='${MOODLE_ADMIN_EMAIL:-admin@example.com}' \
        --agree-license"; then

        echo ">>> Instalação concluída!"
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