#!/usr/bin/env bash
# Ежедневный бэкап Woodpecker CI на Google Drive (перезапись одного файла).
# Шифрование sops + age, ключ root хранится на этом же хосте.
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
AGE_KEY_FILE="/root/.config/sops/age/keys.txt"

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

# --------------------------------------------------------------- age key ---
if [[ ! -f "$AGE_KEY_FILE" ]]; then
    log "age-ключа нет, генерирую новый: $AGE_KEY_FILE"

    mkdir -p "$(dirname "$AGE_KEY_FILE")"
    chmod 700 "$(dirname "$AGE_KEY_FILE")"

    age-keygen -o "$AGE_KEY_FILE"

    chmod 600 "$AGE_KEY_FILE"
    chown root:root "$AGE_KEY_FILE"

    PUB_KEY="$(age-keygen -y "$AGE_KEY_FILE")"

    log "Сгенерирован age-ключ, публичный: $PUB_KEY"
    log "ВНИМАНИЕ: сохрани приватный ключ $AGE_KEY_FILE в надёжном месте."
    log "Без него бэкап на Drive не расшифровать."
else
    chmod 600 "$AGE_KEY_FILE"
    chown root:root "$AGE_KEY_FILE"

    PUB_KEY="$(age-keygen -y "$AGE_KEY_FILE")"

    log "Использую age-ключ $AGE_KEY_FILE (публичный: $PUB_KEY)"
fi

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
log "Шифрую sops + age"

SOPS_AGE_RECIPIENTS="$PUB_KEY" sops -e \
    --input-type binary \
    --output-type binary \
    "$STAGING/$BACKUP_NAME.tar.gz" \
    > "$STAGING/$BACKUP_NAME.tar.gz.enc"

# ------------------------------------------------------------------ загрузка ---
log "Загружаю на Drive (перезапись): $REMOTE_FILE"

rclone copyto "$STAGING/$BACKUP_NAME.tar.gz.enc" "$REMOTE_FILE"

SIZE="$(stat -c %s "$STAGING/$BACKUP_NAME.tar.gz.enc")"

log "Готово: $REMOTE_FILE ($SIZE байт)"
