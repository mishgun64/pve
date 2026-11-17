#!/usr/bin/env bash
# ============================================================================
# backup-pi-agent.sh — бэкап настроек pi agent на Google Drive.
#
# Собирает /home/pi/.pi/agent, пакует в tar.gz, шифрует sops + age
# (age-получатель — публичный SSH-ключ root@control) и загружает на Drive
# через rclone. Объект всегда один и тот же — он перезаписывается.
#
# Запуск: sudo ./backup-pi-agent.sh
#         sudo ./backup-pi-agent.sh --no-upload --out /tmp/pibk
#         curl -fsSL https://raw.githubusercontent.com/mishgun64/pve/main/useful_scripts/backup-pi-agent.sh | sudo bash
#         cron:  17 4 * * * /root/useful_scripts/backup-pi-agent.sh >/var/log/pi-agent-backup.log 2>&1
#
# Восстановление — restore-pi-agent.sh (лежит рядом), формат совместим.
# ============================================================================
set -euo pipefail

# ------------------------------------------------------------ настройки ---
PI_USER="pi"
SOURCE_DIR=""                       # по умолчанию /home/<PI_USER>/.pi/agent
RCLONE_REMOTE="gdrive:"
RCLONE_BACKUP_DIR="pi-agent-backups"
RCLONE_CONFIG_FILE="/root/.config/rclone/rclone.conf"

# Age-получатель: публичный SSH-ключ root@control. Приватная половина этого
# ключа нужна для расшифровки, публичная — не секрет.
DEFAULT_RECIPIENT="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMy5WqCB0OqW9WuzzHWVegy5oWFH1tRBZALxKOvkr8GB root@control"
RECIPIENT="$DEFAULT_RECIPIENT"

BACKUP_NAME=""                      # по умолчанию pi-agent-config-<host>.tar.gz.sops
OUT_DIR=""                          # каталог для локальной копии (mktemp)
KEEP_DIR="/var/backups/pi-agent"    # страховка, если загрузка не удалась
NO_UPLOAD=0
DRY_RUN=0
WITH_SESSIONS=0
WITH_MISSIONS=1
WITH_DATA=0
REQUIRE_VERIFY=0
SKIP_VERIFY=0

RCLONE_TIMEOUT_ARGS=(--retries 1 --low-level-retries 1 --contimeout 10s)
RCLONE_TRANSFER_ARGS=(--retries 3 --low-level-retries 10 --contimeout 30s --timeout 300s)

# Что попадает в архив: конфиги pi agent верхнего уровня.
INCLUDE_FILES=(
    settings.json settings.jsonc keybindings.json
    mcp.json mcp-auth.json models.json models-store.json auth.json
    AGENTS.md AGENTS.override.md CLAUDE.md SYSTEM.md APPEND_SYSTEM.md
    ssh-remote-config.json ssh-remote-known-hosts.json
    ssh-remote-memories pi-subagents
)
INCLUDE_DIRS=(extensions skills prompts themes)

EXCLUDE_ARGS=(
    --exclude='*.bak' --exclude='*.bak.*' --exclude='*.orig' --exclude='*.rej'
    --exclude='*.html' --exclude='*.log' --exclude='*.tgz'
    --exclude='.git' --exclude='node_modules' --exclude='__pycache__'
    --exclude='.DS_Store' --exclude='Thumbs.db'
)

# ---------------------------------------------------------------- helpers ---
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
============================================================================
backup-pi-agent.sh — бэкап настроек pi agent на Google Drive.

Собирает /home/pi/.pi/agent, пакует в tar.gz, шифрует sops + age
(age-получатель — публичный SSH-ключ root@control) и загружает на Drive
через rclone. Объект всегда один и тот же — он перезаписывается.

Запуск: sudo ./backup-pi-agent.sh
        curl -fsSL https://raw.githubusercontent.com/mishgun64/pve/main/useful_scripts/backup-pi-agent.sh | sudo bash -s -- --dry-run
        cron:  17 4 * * * /root/useful_scripts/backup-pi-agent.sh >/var/log/pi-agent-backup.log 2>&1

Восстановление — restore-pi-agent.sh (лежит рядом), формат совместим.
============================================================================


Опции:
  --user NAME          пользователь-владелец каталога (по умолчанию pi)
  --src DIR            каталог настроек (по умолчанию /home/<user>/.pi/agent)
  --name FILE          имя объекта на Drive (по умолчанию pi-agent-config-<host>.tar.gz.sops)
  --recipient RCPT     age-получатель: age1..., ssh-ed25519 AAAA... или путь к .pub
  --remote REMOTE      rclone remote (по умолчанию gdrive:)
  --remote-dir DIR     каталог на remote (по умолчанию pi-agent-backups)
  --rclone-config PATH путь к rclone.conf (по умолчанию /root/.config/rclone/rclone.conf)
  --with-sessions      включить sessions/ (история, объёмно)
  --without-missions   не включать missions/
  --with-data          включить data/ (кэши валют)
  --no-upload          только создать зашифрованный архив
  --out DIR            каталог локальной копии (по умолчанию mktemp)
  --require-verify     падать, если локальный ключ не может расшифровать архив
  --skip-verify        не проверять расшифровку после шифрования
  --dry-run            показать план, ничего не делать
  -h, --help           эта справка
EOF
}

while (($#)); do
    case "$1" in
        --user)             PI_USER=${2:?}; shift 2 ;;
        --src)              SOURCE_DIR=${2:?}; shift 2 ;;
        --name)             BACKUP_NAME=${2:?}; shift 2 ;;
        --recipient)        RECIPIENT=${2:?}; shift 2 ;;
        --remote)           RCLONE_REMOTE=${2:?}; shift 2 ;;
        --remote-dir)       RCLONE_BACKUP_DIR=${2:?}; shift 2 ;;
        --rclone-config)    RCLONE_CONFIG_FILE=${2:?}; shift 2 ;;
        --with-sessions)    WITH_SESSIONS=1; shift ;;
        --without-missions) WITH_MISSIONS=0; shift ;;
        --with-data)        WITH_DATA=1; shift ;;
        --no-upload)        NO_UPLOAD=1; shift ;;
        --out)              OUT_DIR=${2:?}; shift 2 ;;
        --require-verify)   REQUIRE_VERIFY=1; shift ;;
        --skip-verify)      SKIP_VERIFY=1; shift ;;
        --dry-run)          DRY_RUN=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  fail "неизвестная опция: $1 (см. --help)" ;;
    esac
done

[[ $DRY_RUN -eq 1 ]] || [[ $EUID -eq 0 ]] || fail "запусти от root: sudo $0 $*"

: "${SOURCE_DIR:=/home/$PI_USER/.pi/agent}"
HOST_SLUG="$(hostname -s 2>/dev/null || hostname)"
HOST_SLUG="${HOST_SLUG//[^A-Za-z0-9._-]/-}"
: "${BACKUP_NAME:=pi-agent-config-$HOST_SLUG.tar.gz.sops}"

REMOTE_DIR="${RCLONE_REMOTE%/}/${RCLONE_BACKUP_DIR}"
REMOTE_FILE="$REMOTE_DIR/$BACKUP_NAME"
REMOTE_SUM="$REMOTE_FILE.sha256"

# -------------------------------------------------------------- recipient ---
resolve_recipient() {
    local value="$RECIPIENT" line

    # путь к публичному ключу тоже принимается
    if [[ -f "$value" ]]; then
        line="$(awk '$1 ~ /^(ssh-ed25519|ssh-rsa)$/ && NF >= 2 {print $1" "$2; exit}' "$value")"
        [[ -n "$line" ]] || fail "в $value нет ssh-ed25519/ssh-rsa публичного ключа"
        value="$line"
    fi

    # отбрасываем комментарий ("user@host") — sops он не нужен
    value="$(awk '{ if (NF >= 2) print $1" "$2; else print $1 }' <<<"$value")"

    if [[ ! "$value" =~ ^(age1[0-9a-z]+|ssh-(ed25519|rsa)[[:space:]]+[^[:space:]]+)$ ]]; then
        fail "некорректный age-получатель: '$value' (ожидается age1..., ssh-ed25519 AAAA..., ssh-rsa AAAA... или путь к .pub)"
    fi

    printf '%s' "$value"
}

# ---------------------------------------------------------------- preflight ---
command -v sops >/dev/null || fail "sops не установлен"
command -v tar  >/dev/null || fail "tar не установлен"

[[ -d "$SOURCE_DIR" ]] || fail "нет каталога настроек: $SOURCE_DIR"

if [[ $NO_UPLOAD -eq 0 ]]; then
    command -v rclone >/dev/null || fail "rclone не установлен"

    # В dry-run не трогаем сеть и не требуем настроенный конфиг.
    if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] пропускаю проверки rclone ($RCLONE_REMOTE, $RCLONE_CONFIG_FILE)"
    else
        [[ -s "$RCLONE_CONFIG_FILE" ]] ||
            fail "нет $RCLONE_CONFIG_FILE (настрой rclone: sudo /root/setup-control.sh или sudo rclone config)"

        # Именованный remote ("gdrive:") должен быть в конфиге; on-the-fly
        # бэкенды (":local:", ":s3:") проверять не нужно.
        if [[ "$RCLONE_REMOTE" =~ ^[A-Za-z0-9_.-]+: ]]; then
            remotes="$(rclone listremotes --config "$RCLONE_CONFIG_FILE" 2>/dev/null || true)"
            grep -qxF "$RCLONE_REMOTE" <<<"$remotes" ||
                fail "в $RCLONE_CONFIG_FILE нет remote '$RCLONE_REMOTE' (sudo /root/setup-control.sh)"
        fi

        # Проверяем доступ ДО tar/sops: иначе прогон падает на последнем шаге.
        log "проверяю доступ к $RCLONE_REMOTE (lsd)"
        if ! rclone lsd "$RCLONE_REMOTE" --config "$RCLONE_CONFIG_FILE" \
                "${RCLONE_TIMEOUT_ARGS[@]}" >/dev/null 2>&1; then
            fail "remote $RCLONE_REMOTE недоступен (конфиг/токен). Запусти: sudo /root/setup-control.sh"
        fi

        if [[ $DRY_RUN -eq 0 ]] && ! rclone mkdir "$REMOTE_DIR" --config "$RCLONE_CONFIG_FILE" \
                "${RCLONE_TIMEOUT_ARGS[@]}" 2>/dev/null; then
            fail "не удалось создать каталог $REMOTE_DIR"
        fi

        log "rclone готов: $REMOTE_FILE"
    fi
fi

RECIPIENT_RESOLVED="$(resolve_recipient)"
log "получатель (age): $RECIPIENT_RESOLVED"

# ------------------------------------------------------------------ staging ---
STAGING="$(mktemp -d /tmp/pi-agent-backup.XXXXXX)"
chmod 700 "$STAGING"

if [[ -n "$OUT_DIR" ]]; then
    [[ $DRY_RUN -eq 1 ]] || install -d -m 0700 "$OUT_DIR"
fi

KEEP_FILES=()

cleanup() {
    if ((${#KEEP_FILES[@]})); then
        log "сохранено: ${KEEP_FILES[*]}"
    fi
    rm -rf "$STAGING"
}
trap cleanup EXIT

log "staging: $STAGING"
log "источник: $SOURCE_DIR"

# ------------------------------------------------------------------- состав ---
members=()
for m in "${INCLUDE_FILES[@]}"; do
    [[ -e "$SOURCE_DIR/$m" ]] && members+=("$m")
done
for m in "${INCLUDE_DIRS[@]}"; do
    [[ -d "$SOURCE_DIR/$m" ]] && members+=("$m")
done
[[ $WITH_MISSIONS -eq 1 && -d "$SOURCE_DIR/missions" ]] && members+=("missions")
[[ $WITH_SESSIONS -eq 1 && -d "$SOURCE_DIR/sessions" ]] && members+=("sessions")
[[ $WITH_DATA     -eq 1 && -d "$SOURCE_DIR/data"     ]] && members+=("data")

((${#members[@]})) || fail "нечего архивировать в $SOURCE_DIR"

log "состав: ${members[*]}"

# -------------------------------------------------------------------- архив ---
ARCHIVE="$STAGING/pi-agent-config.tar.gz"
ENC="$STAGING/$BACKUP_NAME"

log "создаю архив"
if [[ $DRY_RUN -eq 0 ]]; then
    tar -czf "$ARCHIVE" "${EXCLUDE_ARGS[@]}" -C "$SOURCE_DIR" "${members[@]}" ||
        fail "tar завершился с ошибкой"

    archive_size="$(stat -c %s "$ARCHIVE")"
    entries="$(tar -tzf "$ARCHIVE" | wc -l)"
    log "архив: $archive_size байт, файлов: $entries"

    grep -qE '(^|/)(settings|models|auth|mcp)\.json$' <(tar -tzf "$ARCHIVE") ||
        fail "в архиве нет settings.json/models.json/auth.json/mcp.json — это не похоже на настройки pi agent"
fi

# -------------------------------------------------------------- шифрование ---
# Шифруем из staging: случайный .sops.yaml в текущем каталоге не должен
# подменить получателя.
log "шифрую sops + age"
if [[ $DRY_RUN -eq 0 ]]; then
    (
        cd "$STAGING"
        SOPS_AGE_RECIPIENTS="$RECIPIENT_RESOLVED" sops encrypt \
            --input-type binary --output-type binary \
            --output "$BACKUP_NAME" "pi-agent-config.tar.gz"
    ) || fail "sops encrypt завершился с ошибкой"
fi

# ------------------------------------------------- проверка расшифровки ---
# Получатель может принадлежать другой машине — тогда локального приватного
# ключа просто нет (warning). Битый архив при совпадающем ключе — ошибка.
find_identity() {
    local cand
    for cand in /root/.ssh/id_ed25519 /root/.ssh/id_rsa /root/.ssh/id_ecdsa; do
        [[ -f "$cand" ]] && { printf '%s' "$cand"; return 0; }
    done
    return 1
}

if [[ $DRY_RUN -eq 0 && $SKIP_VERIFY -eq 0 ]]; then
    identity="$(find_identity || true)"

    if [[ -z "$identity" ]]; then
        log "WARNING: нет приватного ключа (/root/.ssh/id_ed25519), проверку расшифровки пропускаю"
    else
        pub="$(ssh-keygen -y -P '' -f "$identity" 2>/dev/null | awk '{print $1" "$2}' || true)"
        if [[ -z "$pub" ]]; then
            log "WARNING: ключ $identity под паролем, проверку расшифровки пропускаю"
        elif [[ "$pub" != "$RECIPIENT_RESOLVED" ]]; then
            if [[ $REQUIRE_VERIFY -eq 1 ]]; then
                fail "локальный ключ $identity не соответствует получателю. Убери --require-verify или шифруй на свой ключ"
            fi
            log "WARNING: получатель не совпадает с локальным ключом ($identity)."
            log "WARNING: храни приватную половину ключа root@control — без неё бэкап не восстановить"
        else
            log "проверяю расшифровку ключом $identity"
            if SOPS_AGE_SSH_PRIVATE_KEY_FILE="$identity" sops decrypt \
                    --input-type binary --output-type binary \
                    --output "$STAGING/verify.tar.gz" "$ENC" >/dev/null 2>&1 &&
               cmp -s "$ARCHIVE" "$STAGING/verify.tar.gz"; then
                rm -f "$STAGING/verify.tar.gz"
                log "round-trip OK"
            else
                rm -f "$STAGING/verify.tar.gz"
                fail "архив не расшифровывается совпадающим ключом — загрузка отменена"
            fi
        fi
    fi
fi

if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] rclone copyto --ignore-times \"$ENC\" \"$REMOTE_FILE\""
    log "dry-run завершён"
    exit 0
fi

enc_size="$(stat -c %s "$ENC")"
hash="$(sha256sum "$ENC" | awk '{print $1}')"
printf '%s  %s\n' "$hash" "$BACKUP_NAME" > "$ENC.sha256"

log "зашифровано: $enc_size байт"
log "sha256: $hash"

# ------------------------------------------------------------ локальная копия ---
install -d -m 0700 "$KEEP_DIR"
install -m 0600 "$ENC" "$KEEP_DIR/$BACKUP_NAME"
install -m 0600 "$ENC.sha256" "$KEEP_DIR/$BACKUP_NAME.sha256"
KEEP_FILES+=("$KEEP_DIR/$BACKUP_NAME")
log "локальная копия: $KEEP_DIR/$BACKUP_NAME"

if [[ -n "$OUT_DIR" ]]; then
    install -m 0600 "$ENC" "$OUT_DIR/$BACKUP_NAME"
    install -m 0600 "$ENC.sha256" "$OUT_DIR/$BACKUP_NAME.sha256"
    KEEP_FILES+=("$OUT_DIR/$BACKUP_NAME")
fi

if [[ $NO_UPLOAD -eq 1 ]]; then
    log "загрузка отключена (--no-upload)"
    exit 0
fi

# ---------------------------------------------------------------- загрузка ---
existed=no
rclone lsjson --stat "$REMOTE_FILE" --config "$RCLONE_CONFIG_FILE" \
    "${RCLONE_TIMEOUT_ARGS[@]}" >/dev/null 2>&1 && existed=yes

log "загружаю (перезапись: $existed) -> $REMOTE_FILE"

err_file="$(mktemp /tmp/rclone-upload.XXXXXX)"
if ! rclone copyto --ignore-times "$ENC" "$REMOTE_FILE" \
        --config "$RCLONE_CONFIG_FILE" \
        "${RCLONE_TRANSFER_ARGS[@]}" 2>"$err_file"; then
    err="$(cat "$err_file")"
    rm -f "$err_file"
    fail "загрузка не удалась: ${err:-нет вывода rclone}. Шифрованный архив сохранён: $KEEP_DIR/$BACKUP_NAME"
fi
rm -f "$err_file"

if ! rclone copyto --ignore-times "$ENC.sha256" "$REMOTE_SUM" \
        --config "$RCLONE_CONFIG_FILE" \
        "${RCLONE_TRANSFER_ARGS[@]}" 2>/dev/null; then
    log "WARNING: не удалось загрузить $BACKUP_NAME.sha256 (сам архив загружен)"
fi

# ---------------------------------------------------------------- контроль ---
remote_json="$(rclone lsjson --stat "$REMOTE_FILE" --config "$RCLONE_CONFIG_FILE" \
    "${RCLONE_TIMEOUT_ARGS[@]}" 2>/dev/null || true)"
remote_size="$(grep -o '"Size":[[:space:]]*[0-9]\+' <<<"$remote_json" | grep -o '[0-9]\+$' || true)"

[[ -n "$remote_size" ]] ||
    fail "не удалось проверить загруженный объект ($REMOTE_FILE), локальная копия: $KEEP_DIR/$BACKUP_NAME"

[[ "$remote_size" == "$enc_size" ]] ||
    fail "размер на Drive ($remote_size) не совпал с локальным ($enc_size), локальная копия: $KEEP_DIR/$BACKUP_NAME"

log "загрузка подтверждена: $remote_size байт, sha256 $hash"
log "готово: $REMOTE_FILE"
