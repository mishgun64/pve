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
RCLONE_CONFIG_FILE="/root/.config/rclone/rclone.conf"
RCLONE_TIMEOUT_ARGS=(--retries 1 --low-level-retries 1 --contimeout 10s)
# Для самой передачи файла таймауты жёстче не нужны: на медленном/шумном канале
# до Google TLS-хендшейк не укладывается в 10s и бэкап падает. Проверки (lsd/mkdir)
# остаются быстрыми, а передача — с ретраями и запасом по времени.
RCLONE_TRANSFER_ARGS=(--retries 3 --low-level-retries 10 --contimeout 30s --timeout 300s)
BACKUP_NAME="woodpecker_backup"
SSH_KEY_FILE="/root/.ssh/id_ed25519"
SSH_PUB_FILE="${SSH_KEY_FILE}.pub"

REMOTE_FILE="${RCLONE_REMOTE}${RCLONE_BACKUP_DIR}/${BACKUP_NAME}.tar.gz.enc"
LOCAL_KEEP_DIR="/var/backups/woodpecker"
LOCAL_KEEP_FILE="$LOCAL_KEEP_DIR/${BACKUP_NAME}.tar.gz.enc"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    exit 1
}

# ------------------------------------------------------------- preflight ---
# Проверка rclone ДО дорогой работы (docker tar, sops): иначе прогон падал на
# последнем шаге и весь архив терялся.
# Все вызовы rclone идут с явным --config, чтобы не зависеть от HOME.
rclone_preflight() {
    local remotes err_file err lsd_status

    command -v rclone >/dev/null ||
        fail "rclone не установлен"

    command -v docker sops tar >/dev/null ||
        fail "Не установлены docker/sops/tar — без них бэкап невозможен"

    [[ -s "$RCLONE_CONFIG_FILE" ]] ||
        fail "Нет $RCLONE_CONFIG_FILE. Запусти: sudo /root/setup-control.sh (мастер rclone) или создай конфиг вручную: sudo rclone config"

    remotes="$(rclone listremotes --config "$RCLONE_CONFIG_FILE" 2>/dev/null || true)"

    grep -qxF "$RCLONE_REMOTE" <<<"$remotes" ||
        fail "В $RCLONE_CONFIG_FILE нет remote '$RCLONE_REMOTE'. Запусти: sudo /root/setup-control.sh (мастер rclone) — он создаст remote '${RCLONE_REMOTE%:}'"

    err_file="$(mktemp /tmp/rclone-preflight.XXXXXX)"

    log "Проверяю доступ к $RCLONE_REMOTE (lsd)"

    lsd_status=0

    rclone lsd "$RCLONE_REMOTE" \
        --config "$RCLONE_CONFIG_FILE" \
        "${RCLONE_TIMEOUT_ARGS[@]}" >/dev/null 2>"$err_file" || lsd_status=$?

    if [[ "$lsd_status" -ne 0 ]]; then
        err="$(cat "$err_file")"
        rm -f "$err_file"

        # rc=1 — конфиг/токен или ошибка параметров: лечится мастером настройки.
        if [[ "$lsd_status" -eq 1 ]]; then
            fail "Remote $RCLONE_REMOTE недоступен (rc=1): ${err:-нет вывода rclone}. Это конфиг/токен или ошибка параметров. Запусти: sudo /root/setup-control.sh (мастер rclone) или поправь $RCLONE_CONFIG_FILE"
        fi

        fail "Remote $RCLONE_REMOTE недоступен (rc=$lsd_status): ${err:-нет вывода rclone}"
    fi

    log "Проверяю каталог ${RCLONE_REMOTE}${RCLONE_BACKUP_DIR} (mkdir)"

    if ! rclone mkdir "${RCLONE_REMOTE}${RCLONE_BACKUP_DIR}" \
        --config "$RCLONE_CONFIG_FILE" \
        "${RCLONE_TIMEOUT_ARGS[@]}" 2>"$err_file"; then
        err="$(cat "$err_file")"
        rm -f "$err_file"
        fail "Не удалось создать ${RCLONE_REMOTE}${RCLONE_BACKUP_DIR}: ${err:-нет вывода rclone}"
    fi

    rm -f "$err_file"

    log "rclone готов: $REMOTE_FILE"
}

if [[ $EUID -ne 0 ]]; then
    fail "Запусти от root"
fi

rclone_preflight

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
    RECIPIENT="$(ssh-keygen -y -f "$SSH_KEY_FILE" </dev/null | awk 'NR==1 {print $1" "$2}')" ||
        fail "Не удалось получить публичный ключ из $SSH_KEY_FILE (ключ под паролем? расшифровка без tty невозможна)"

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

# Список volume снимаем один раз и с проверкой rc: ошибка docker НЕ должна
# выглядеть как «volume отсутствует» — иначе архив без данных перезапишет
# единственный бэкап на Drive.
VOLUME_NAMES=""

load_volume_names() {
    local err_file status err names

    err_file="$(mktemp /tmp/docker-volume-ls.XXXXXX)"
    status=0

    names="$(docker volume ls --format '{{.Name}}' 2>"$err_file")" || status=$?

    err="$(cat "$err_file")"
    rm -f "$err_file"

    [[ "$status" -eq 0 ]] ||
        fail "docker недоступен (docker volume ls, rc=$status): ${err:-нет вывода docker}"

    VOLUME_NAMES="$names"
}

backup_volume() {
    local vol="$1" archive="$2"

    grep -qxF "$vol" <<<"$VOLUME_NAMES" ||
        fail "volume $vol отсутствует. Бэкап без данных не делаю: проверь, что Woodpecker запущен (docker compose up -d в $WP_DIR)"

    log "Архивирую volume $vol -> $archive"

    docker run --rm \
        -v "$vol:/data:ro" \
        -v "$STAGING:/backup" \
        alpine \
        tar czf "/backup/$archive" -C /data .

    ARCHIVE_FILES+=("$archive")
}

load_volume_names

backup_volume "$SERVER_VOL" "woodpecker-server-data.tar.gz"
backup_volume "$AGENT_VOL" "woodpecker-agent-config.tar.gz"

# ------------------------------------------------------------------- архив ---
log "Собираю общий архив $BACKUP_NAME.tar.gz"

tar czf "$STAGING/$BACKUP_NAME.tar.gz" -C "$STAGING" "${ARCHIVE_FILES[@]}"

# --------------------------------------------------------------- шифрование ---
# Шифруем из staging-каталога: случайный .sops.yaml в текущем каталоге
# (например useful_scripts/.sops.yaml) не должен подменить получателя.
log "Шифрую sops + age (SSH-ключ root)"

(
    cd "$STAGING"

    SOPS_AGE_RECIPIENTS="$RECIPIENT" sops -e \
        --input-type binary \
        --output-type binary \
        "$BACKUP_NAME.tar.gz" \
        > "$BACKUP_NAME.tar.gz.enc"
) || fail "sops -e завершился с ошибкой (staging: $STAGING)"

# ------------------------------------------------------------ страховка ---
# Локальная копия шифрованного архива: если загрузка не удалась, прогон
# (вместе со staging) уже не потерять. Удаляется после успешной загрузки.
install -d -m 0700 "$LOCAL_KEEP_DIR"

# install сразу с 0600 — без окна, когда файл лежит с 0644
install -m 0600 "$STAGING/$BACKUP_NAME.tar.gz.enc" "$LOCAL_KEEP_FILE"

log "Локальная копия: $LOCAL_KEEP_FILE"

# ------------------------------------------------------------------ загрузка ---
log "Загружаю на Drive (перезапись): $REMOTE_FILE"

UPLOAD_ERR_FILE="$(mktemp /tmp/rclone-upload.XXXXXX)"

if ! rclone copyto "$STAGING/$BACKUP_NAME.tar.gz.enc" "$REMOTE_FILE" \
    --config "$RCLONE_CONFIG_FILE" \
    "${RCLONE_TRANSFER_ARGS[@]}" 2>"$UPLOAD_ERR_FILE"; then
    UPLOAD_ERR="$(cat "$UPLOAD_ERR_FILE")"
    rm -f "$UPLOAD_ERR_FILE"
    fail "Загрузка не удалась: ${UPLOAD_ERR:-нет вывода rclone}. Шифрованный архив сохранён: $LOCAL_KEEP_FILE"
fi

rm -f "$UPLOAD_ERR_FILE" "$LOCAL_KEEP_FILE"

SIZE="$(stat -c %s "$STAGING/$BACKUP_NAME.tar.gz.enc")"

log "Готово: $REMOTE_FILE ($SIZE байт)"
