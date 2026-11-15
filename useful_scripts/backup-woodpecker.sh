#!/usr/bin/env bash
# Ежедневный бэкап Woodpecker CI на Google Drive (перезапись одного файла).
# Шифрование sops + age, в качестве age-ключа используется SSH-ключ root
# (/root/.ssh/id_ed25519).
# Запуск: sudo /root/backup-woodpecker.sh (cron: 0 3 * * *)
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

WP_DIR="/opt/woodpecker"
PROJECT_NAME="woodpecker"
SERVER_VOL="${PROJECT_NAME}_woodpecker-server-data"
AGENT_VOL="${PROJECT_NAME}_woodpecker-agent-config"
RCLONE_REMOTE="gdrive:"
RCLONE_BACKUP_DIR="woodpecker"
BACKUP_NAME="woodpecker_backup"
SSH_KEY_FILE="/root/.ssh/id_ed25519"
SSH_PUB_FILE="${SSH_KEY_FILE}.pub"

REMOTE_FILE="${RCLONE_REMOTE}${RCLONE_BACKUP_DIR}/${BACKUP_NAME}.tar.gz.enc"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    exit 1
}

if [[ $EUID -ne 0 ]]; then
    fail "Запусти от root"
fi

STAGING="$(mktemp -d /tmp/woodpecker-backup.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

log "Старт бэкапа Woodpecker (staging: $STAGING)"

# ------------------------------------------------------- age (SSH) key ---
# sops принимает SSH-публичный ключ ed25519 как age-получателя,
# а приватный SSH-ключ root используется для расшифровки.
[[ -f "$SSH_KEY_FILE" ]] ||
    fail "Нет SSH-ключа $SSH_KEY_FILE (он же age-ключ для sops)"

chmod 600 "$SSH_KEY_FILE"
chown root:root "$SSH_KEY_FILE"

# Публичный ключ: берём готовый .pub либо выводим из приватного
if [[ -s "$SSH_PUB_FILE" ]]; then
    RECIPIENT="$(awk 'NR==1 {print $1" "$2}' "$SSH_PUB_FILE")"
else
    RECIPIENT="$(ssh-keygen -y -f "$SSH_KEY_FILE" | awk 'NR==1 {print $1" "$2}')"

    printf '%s\n' "$RECIPIENT" > "$SSH_PUB_FILE"
    chmod 644 "$SSH_PUB_FILE"
fi

[[ "$RECIPIENT" == ssh-* ]] ||
    fail "Не удалось получить SSH-публичный ключ из $SSH_KEY_FILE"

log "Использую age-получателя (SSH-ключ root): $RECIPIENT"

# ------------------------------------------------------------- конфигурация ---
[[ -f "$WP_DIR/docker-compose.yml" ]] || fail "Нет $WP_DIR/docker-compose.yml"
[[ -f "$WP_DIR/.env" ]] || fail "Нет $WP_DIR/.env"

install -m 0600 "$WP_DIR/docker-compose.yml" "$STAGING/docker-compose.yml"
install -m 0600 "$WP_DIR/.env" "$STAGING/.env"

log "Скопированы docker-compose.yml и .env"

# ------------------------------------------------------------------ volumes ---
ARCHIVE_FILES=(docker-compose.yml .env)

have_volume() {
    docker volume ls --format '{{.Name}}' | grep -qxF "$1"
}

backup_volume() {
    local vol="$1" archive="$2"

    if ! have_volume "$vol"; then
        log "ВНИМАНИЕ: volume $vol отсутствует, пропускаю"
        return 0
    fi

    log "Архивирую volume $vol -> $archive"

    docker run --rm \
        -v "$vol:/data:ro" \
        -v "$STAGING:/backup" \
        alpine \
        tar czf "/backup/$archive" -C /data .

    ARCHIVE_FILES+=("$archive")
}

backup_volume "$SERVER_VOL" "woodpecker-server-data.tar.gz"
backup_volume "$AGENT_VOL" "woodpecker-agent-config.tar.gz"

# ------------------------------------------------------------------- архив ---
log "Собираю общий архив $BACKUP_NAME.tar.gz"

tar czf "$STAGING/$BACKUP_NAME.tar.gz" -C "$STAGING" "${ARCHIVE_FILES[@]}"

# --------------------------------------------------------------- шифрование ---
log "Шифрую sops + age (SSH-ключ root)"

SOPS_AGE_RECIPIENTS="$RECIPIENT" sops -e \
    --input-type binary \
    --output-type binary \
    "$STAGING/$BACKUP_NAME.tar.gz" \
    > "$STAGING/$BACKUP_NAME.tar.gz.enc"

# ------------------------------------------------------------------ загрузка ---
log "Загружаю на Drive (перезапись): $REMOTE_FILE"

rclone copyto "$STAGING/$BACKUP_NAME.tar.gz.enc" "$REMOTE_FILE"

SIZE="$(stat -c %s "$STAGING/$BACKUP_NAME.tar.gz.enc")"

log "Готово: $REMOTE_FILE ($SIZE байт)"
