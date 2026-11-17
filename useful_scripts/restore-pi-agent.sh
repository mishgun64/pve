#!/usr/bin/env bash
# ============================================================================
# restore-pi-agent.sh — восстановление конфигурации pi agent из бэкапа.
#
# Скачивает зашифрованный архив (sops + age) с Google Drive через rclone,
# расшифровывает приватным SSH-ключом пользователя и раскладывает файлы в
# /home/pi/.pi/agent (каталог agent-dir pi).
#
# Запуск: sudo ./restore-pi-agent.sh
#         sudo ./restore-pi-agent.sh --name pi-agent-config-pi.tar.gz.sops
#         sudo ./restore-pi-agent.sh --file /root/pi-agent-config.tar.gz.sops
#         curl -fsSL https://raw.githubusercontent.com/mishgun64/pve/main/useful_scripts/restore-pi-agent.sh | sudo bash -s -- --yes
#
# Архив создаётся на Windows скриптом backup-pi-agent.ps1 (лежит рядом):
#   tar.gz -> sops -e (binary, age-получатель = SSH-ключ) -> rclone copyto
# ============================================================================
set -euo pipefail

# ------------------------------------------------------------ настройки ---
PI_USER="pi"
PI_GROUP="pi"
TARGET_DIR=""                       # по умолчанию /home/<PI_USER>/.pi/agent
RCLONE_REMOTE="gdrive:"
RCLONE_BACKUP_DIR="pi-agent-backups"
RCLONE_CONFIG_FILE=""               # по умолчанию /root/.config/rclone/rclone.conf
SSH_KEY_FILE=""                     # по умолчанию ключ пользователя PI_USER
BACKUP_NAME=""                      # имя объекта на Drive (без пути)
LOCAL_FILE=""                       # готовый локальный .sops вместо загрузки
ASSUME_YES=0
NO_BACKUP=0
RESTART_SERVICE=0
KEEP_STAGING=0

RCLONE_TIMEOUT_ARGS=(--retries 1 --low-level-retries 1 --contimeout 10s)
RCLONE_TRANSFER_ARGS=(--retries 3 --low-level-retries 10 --contimeout 30s --timeout 300s)

# Файлы/каталоги верхнего уровня, которые разрешено распаковывать. Всё
# остальное в архиве считается неожиданным и прерывает распаковку.
ALLOWED_TOP=(
    settings.json settings.jsonc keybindings.json
    mcp.json mcp-auth.json models.json models-store.json auth.json
    AGENTS.md AGENTS.override.md CLAUDE.md SYSTEM.md APPEND_SYSTEM.md
    ssh-remote-config.json ssh-remote-known-hosts.json
    ssh-remote-memories pi-subagents
    extensions skills prompts themes missions sessions data
)

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    exit 1
}

# Читает строку с терминала; если tty нет (pipe/cron) — со stdin.
prompt_read() {
    local prompt="$1" var="$2"
    if [[ -r /dev/tty ]] && read -r -p "$prompt" "$var" </dev/tty 2>/dev/null; then
        return 0
    fi
    printf '%s' "$prompt" >&2
    read -r "$var"
}

usage() {
    cat <<'EOF'
============================================================================
restore-pi-agent.sh — восстановление конфигурации pi agent из бэкапа.

Скачивает зашифрованный архив (sops + age) с Google Drive через rclone,
расшифровывает приватным SSH-ключом пользователя и раскладывает файлы в
/home/pi/.pi/agent (каталог agent-dir pi).

Запуск: sudo ./restore-pi-agent.sh
        curl -fsSL https://raw.githubusercontent.com/mishgun64/pve/main/useful_scripts/restore-pi-agent.sh | sudo bash -s -- --yes
        sudo ./restore-pi-agent.sh --file /root/pi-agent-config.tar.gz.sops

Архив создаётся скриптом backup-pi-agent.sh (лежит рядом, Windows-версия —
backup-pi-agent.ps1):
  tar.gz -> sops -e (binary, age-получатель = SSH-ключ) -> rclone copyto
============================================================================


Опции:
  --user NAME          пользователь-владелец (по умолчанию pi)
  --dest DIR           каталог установки (по умолчанию /home/<user>/.pi/agent)
  --name FILE          имя объекта на Drive (иначе выбор из списка)
  --file PATH          локальный .sops-файл, без обращения к Drive
  --remote REMOTE      rclone remote (по умолчанию gdrive:)
  --remote-dir DIR     каталог на remote (по умолчанию pi-agent-backups)
  --rclone-config PATH путь к rclone.conf
  --ssh-key PATH       приватный ключ для расшифровки (ssh или age identity)
  -y, --yes            без подтверждений
  --no-backup          не сохранять текущий agent-dir в *.bak.<дата>
  --restart-service    перезапустить pi-web.service после установки
  --keep-staging       не удалять временный каталог (для отладки)
  -h, --help           эта справка
EOF
}

while (($#)); do
    case "$1" in
        --user)             PI_USER=${2:?}; shift 2 ;;
        --dest)             TARGET_DIR=${2:?}; shift 2 ;;
        --name)             BACKUP_NAME=${2:?}; shift 2 ;;
        --file)             LOCAL_FILE=${2:?}; shift 2 ;;
        --remote)           RCLONE_REMOTE=${2:?}; shift 2 ;;
        --remote-dir)       RCLONE_BACKUP_DIR=${2:?}; shift 2 ;;
        --rclone-config)    RCLONE_CONFIG_FILE=${2:?}; shift 2 ;;
        --ssh-key)          SSH_KEY_FILE=${2:?}; shift 2 ;;
        -y|--yes)           ASSUME_YES=1; shift ;;
        --no-backup)        NO_BACKUP=1; shift ;;
        --restart-service)  RESTART_SERVICE=1; shift ;;
        --keep-staging)     KEEP_STAGING=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  fail "неизвестная опция: $1 (см. --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || fail "запусти от root: sudo $0 $*"

: "${TARGET_DIR:=/home/$PI_USER/.pi/agent}"
: "${RCLONE_CONFIG_FILE:=/root/.config/rclone/rclone.conf}"
PI_GROUP="$(id -gn "$PI_USER" 2>/dev/null)" ||
    fail "нет пользователя $PI_USER (создай его: sudo ./setup-control.sh)"

# ------------------------------------------------------------- preflight ---
command -v sops >/dev/null || fail "sops не установлен (apt install sops / see github.com/getsops/sops)"
command -v tar  >/dev/null || fail "tar не установлен"
command -v ssh-keygen >/dev/null || fail "ssh-keygen не установлен (apt install openssh-client)"

STAGING="$(mktemp -d /tmp/pi-agent-restore.XXXXXX)"
chmod 700 "$STAGING"

cleanup() {
    if [[ $KEEP_STAGING -eq 1 ]]; then
        log "staging сохранён: $STAGING"
    else
        rm -rf "$STAGING"
    fi
}
trap cleanup EXIT

log "staging: $STAGING"

# --------------------------------------------------------------- SSH key ---
# Ключ ищем в типовых местах: сначала у пользователя pi, затем у root.
if [[ -z "$SSH_KEY_FILE" ]]; then
    for cand in "/home/$PI_USER/.ssh/id_ed25519" "/home/$PI_USER/.ssh/id_rsa" \
                "/root/.ssh/id_ed25519" "/root/.ssh/id_rsa"; do
        if [[ -f "$cand" ]]; then SSH_KEY_FILE="$cand"; break; fi
    done
fi

[[ -n "$SSH_KEY_FILE" && -f "$SSH_KEY_FILE" ]] ||
    fail "не найден приватный SSH-ключ (укажи --ssh-key PATH). Ключ должен быть парным к тому, чей публичный ключ использовался при шифровании"

SSH_KEY_FILE="$(readlink -f "$SSH_KEY_FILE")"

# sops различает ssh-ключи и age identity-файлы (AGE-SECRET-KEY-...).
if head -n1 -- "$SSH_KEY_FILE" | grep -q 'AGE-SECRET-KEY'; then
    SOPS_KEY_VAR="SOPS_AGE_KEY_FILE"
    PUB_RECIPIENT="(age identity)"
else
    SOPS_KEY_VAR="SOPS_AGE_SSH_PRIVATE_KEY_FILE"
    PUB_RECIPIENT="$(ssh-keygen -y -P '' -f "$SSH_KEY_FILE" 2>/dev/null |
                     awk 'NR==1 {print $1" "$2}')" || true
    [[ -n "$PUB_RECIPIENT" ]] ||
        fail "не удалось получить публичный ключ из $SSH_KEY_FILE (ключ под паролем? sops не сможет расшифровать без tty — используй ключ без пароля)"
fi

log "ключ расшифровки: $SSH_KEY_FILE"
log "получатель:       ${PUB_RECIPIENT:0:60}"

# ---------------------------------------------------------------- источник ---
ENC_FILE=""

download_from_remote() {
    local dir remote_file

    command -v rclone >/dev/null || fail "rclone не установлен"

    [[ -s "$RCLONE_CONFIG_FILE" ]] ||
        fail "нет $RCLONE_CONFIG_FILE (настрой rclone: sudo /root/setup-control.sh или rclone config)"

    dir="${RCLONE_REMOTE%/}/${RCLONE_BACKUP_DIR}"

    log "проверяю доступ к $dir"
    rclone lsf "$dir" --max-depth 1 \
        --config "$RCLONE_CONFIG_FILE" \
        "${RCLONE_TIMEOUT_ARGS[@]}" >"$STAGING/list.txt" ||
        fail "не удалось прочитать $dir (проверь remote '$RCLONE_REMOTE' и конфиг $RCLONE_CONFIG_FILE)"

    if [[ -z "$BACKUP_NAME" ]]; then
        mapfile -t candidates < <(grep -E '\.sops$' "$STAGING/list.txt" | sort)
        ((${#candidates[@]})) ||
            fail "в $dir нет файлов *.sops (бэкап ещё не создавался?)"

        if ((${#candidates[@]} == 1)); then
            BACKUP_NAME="${candidates[0]}"
        else
            printf 'Доступные бэкапы в %s:\n' "$dir" >&2
            local i
            for i in "${!candidates[@]}"; do
                printf '  %2d) %s\n' "$((i + 1))" "${candidates[$i]}" >&2
            done
            local answer
            prompt_read "Выбери номер [1-${#candidates[@]}]: " answer
            [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#candidates[@]})) ||
                fail "некорректный выбор: $answer"
            BACKUP_NAME="${candidates[$((answer - 1))]}"
        fi
    fi

    remote_file="$dir/$BACKUP_NAME"
    ENC_FILE="$STAGING/$BACKUP_NAME"

    log "скачиваю $remote_file"
    rclone copyto "$remote_file" "$ENC_FILE" \
        --config "$RCLONE_CONFIG_FILE" \
        "${RCLONE_TRANSFER_ARGS[@]}" ||
        fail "не удалось скачать $remote_file"

    # Контрольная сумма — если рядом лежит .sha256
    if rclone copyto "$remote_file.sha256" "$ENC_FILE.sha256" \
        --config "$RCLONE_CONFIG_FILE" "${RCLONE_TIMEOUT_ARGS[@]}" 2>/dev/null; then
        local want got
        want="$(awk 'NR==1 {print $1}' "$ENC_FILE.sha256")"
        got="$(sha256sum "$ENC_FILE" | awk '{print $1}')"
        [[ "$want" == "$got" ]] ||
            fail "sha256 не совпал (ожидался $want, получен $got) — файл на Drive повреждён"
        log "sha256 совпал: $got"
    else
        log "рядом нет .sha256 — пропускаю сверку контрольной суммы"
    fi
}

if [[ -n "$LOCAL_FILE" ]]; then
    [[ -f "$LOCAL_FILE" ]] || fail "нет файла $LOCAL_FILE"
    ENC_FILE="$(readlink -f "$LOCAL_FILE")"
    BACKUP_NAME="$(basename "$ENC_FILE")"
    log "использую локальный файл: $ENC_FILE"
else
    download_from_remote
fi

# ---------------------------------------------------------------- расшифровка ---
ARCHIVE="$STAGING/pi-agent-config.tar.gz"

log "расшифровываю sops"
if ! env "$SOPS_KEY_VAR=$SSH_KEY_FILE" \
        sops decrypt --input-type binary --output-type binary \
        --output "$ARCHIVE" "$ENC_FILE" 2>"$STAGING/sops.err"; then
    err="$(tail -n 20 "$STAGING/sops.err")"
    rm -f "$STAGING/sops.err"
    fail "sops не смог расшифровать архив. Проверь, что приватный ключ парный к ключу шифрования.
${err}"
fi
rm -f "$STAGING/sops.err"

SIZE="$(stat -c %s "$ARCHIVE")"
log "расшифровано: $SIZE байт"

# ---------------------------------------------------------- проверка архива ---
tar -tzf "$ARCHIVE" >"$STAGING/entries.txt" ||
    fail "архив повреждён: tar не смог прочитать список файлов"

ENTRIES="$(wc -l <"$STAGING/entries.txt")"
log "файлов в архиве: $ENTRIES"

while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    # абсолютные пути и выход из каталога распаковки запрещены
    [[ "$entry" == /* ]] && fail "архив содержит абсолютный путь: $entry"
    [[ "$entry" =~ (^|/)\.\.(/|$) ]] && fail "архив содержит '..': $entry"

    top="${entry%%/*}"
    found=0
    for allowed in "${ALLOWED_TOP[@]}"; do
        if [[ "$top" == "$allowed" ]]; then found=1; break; fi
    done
    ((found)) || fail "неожиданный элемент в архиве: $entry (ожидались только конфиги pi agent)"
done <"$STAGING/entries.txt"

grep -qE '(^|/)(settings|models|auth|mcp)\.json$' "$STAGING/entries.txt" ||
    fail "в архиве нет ни settings.json, ни models.json/auth.json/mcp.json — похоже, это не бэкап pi agent"

# ------------------------------------------------------- сохранение старого ---
# Сначала подтверждаем, потом копируем: отказ не должен оставлять мусор.
if [[ $ASSUME_YES -eq 0 ]]; then
    printf '\nБудет установлено в %s (владелец %s:%s)\n' "$TARGET_DIR" "$PI_USER" "$PI_GROUP" >&2
    if [[ -e "$TARGET_DIR" && $NO_BACKUP -eq 0 ]]; then
        printf 'Текущий каталог будет сохранён как %s.bak.<дата>\n' "$TARGET_DIR" >&2
    fi
    answer=""
    prompt_read 'Продолжить? [y/N] ' answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || fail 'прервано пользователем'
fi

BACKUP_PATH=""
if [[ -e "$TARGET_DIR" ]]; then
    if [[ $NO_BACKUP -eq 0 ]]; then
        BACKUP_PATH="${TARGET_DIR}.bak.$(date '+%Y%m%d-%H%M%S')"
        log "сохраняю текущий каталог: $BACKUP_PATH"
        cp -a "$TARGET_DIR" "$BACKUP_PATH" ||
            fail "не удалось сохранить $TARGET_DIR в $BACKUP_PATH (используй --no-backup, чтобы пропустить)"
    else
        log 'текущий каталог не сохраняю (--no-backup)'
    fi
fi

# Полный replace, а не merge: старые файлы, которых нет в бэкапе, не должны
# оставаться рядом с новыми. Копия уже сделана выше (BACKUP_PATH).
if [[ -n "$BACKUP_PATH" ]]; then
    rm -rf "$TARGET_DIR" || fail "не удалось очистить $TARGET_DIR"
elif [[ -d "$TARGET_DIR" ]]; then
    log "файлы будут перезаписаны, лишние останутся на месте (--no-backup)"
fi

install -d -m 0755 -o "$PI_USER" -g "$PI_GROUP" "$TARGET_DIR" ||
    fail "не удалось создать $TARGET_DIR"

# Копируем содержимое архива в целевой каталог
tar -xzf "$ARCHIVE" -C "$TARGET_DIR" --no-same-owner --no-same-permissions ||
    fail "не удалось распаковать архив в $TARGET_DIR"

# Права: каталоги 0755, обычные файлы 0644, секреты 0600
find "$TARGET_DIR" -type d -exec chmod 0755 {} +
find "$TARGET_DIR" -type f -exec chmod 0644 {} +
for secret in auth.json mcp-auth.json models-store.json ssh-remote-config.json; do
    if [[ -f "$TARGET_DIR/$secret" ]]; then
        chmod 0600 "$TARGET_DIR/$secret"
    fi
done
chown -R "$PI_USER:$PI_GROUP" "$TARGET_DIR" ||
    fail "не удалось выставить владельца $PI_USER:$PI_GROUP"

log "установлено в $TARGET_DIR"
log "верхний уровень:"
ls -1 "$TARGET_DIR" | sed 's/^/    /'

# ------------------------------------------------------------- сервис ---
if [[ $RESTART_SERVICE -eq 1 ]]; then
    if systemctl list-unit-files pi-web.service >/dev/null 2>&1 &&
       systemctl cat pi-web.service >/dev/null 2>&1; then
        log "перезапускаю pi-web.service"
        systemctl restart pi-web.service
        systemctl is-active --quiet pi-web.service &&
            log "pi-web.service активен" ||
            fail "pi-web.service не поднялся (journalctl -u pi-web -n 50)"
    else
        log "юнит pi-web.service не найден — перезапуск пропущен"
    fi
else
    log "перезапуск pi-web.service не запрошен (--restart-service)"
fi

log "готово: $BACKUP_NAME -> $TARGET_DIR"
if [[ -n "$BACKUP_PATH" ]]; then
    log "откат при необходимости: rm -rf '$TARGET_DIR' && mv '$BACKUP_PATH' '$TARGET_DIR'"
fi
