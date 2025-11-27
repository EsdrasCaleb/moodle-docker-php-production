#!/bin/bash
set -e

# Argumentos vindos do Dockerfile
MOODLE_DIR=$1
MOODLE_VERSION=$2
MOODLE_GIT_REPO=$3

echo "--- [BUILD] Baixando Core do Moodle ($MOODLE_VERSION) ---"
git clone --branch "$MOODLE_VERSION" --depth 1 "$MOODLE_GIT_REPO" "$MOODLE_DIR"

echo "--- [BUILD] Processando plugins.json ---"
if [ -f "/tmp/plugins.json" ]; then
    # Verifica se é um JSON válido
    if jq -e . >/dev/null 2>&1 <<< cat /tmp/plugins.json; then
        jq -c '.[]' /tmp/plugins.json | while read i; do
            GIT_URL=$(echo "$i" | jq -r '.giturl')
            GIT_BRANCH=$(echo "$i" | jq -r '.branch // empty')
            INSTALL_PATH=$(echo "$i" | jq -r '.installpath')

            FULL_PATH="$MOODLE_DIR/$INSTALL_PATH"

            echo "--- [BUILD] Instalando Plugin: $INSTALL_PATH"

            CLONE_ARGS="--depth 1"
            [ ! -z "$GIT_BRANCH" ] && CLONE_ARGS="$CLONE_ARGS --branch $GIT_BRANCH"

            # Remove diretório se existir (ex: plugins padrão que queremos substituir)
            rm -rf "$FULL_PATH"

            # shellcheck disable=SC2086
            git clone $CLONE_ARGS "$GIT_URL" "$FULL_PATH"

            # Remove git history para economizar espaço na imagem
            rm -rf "$FULL_PATH/.git"
        done
    else
        echo "AVISO: plugins.json existe mas não é um JSON válido ou está vazio."
    fi
else
    echo "--- [BUILD] Nenhum plugins.json encontrado."
fi

# Remove git history do core para economizar espaço (opcional, mas recomendado para produção)
rm -rf "$MOODLE_DIR/.git"

echo "--- [BUILD] Concluído."