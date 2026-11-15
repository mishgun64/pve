#!/usr/bin/env bash
# Первичная настройка control node на x86 (Debian 13 trixie, amd64)
# Запуск: sudo ./setup-control.sh
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

USER_NAME="mishgun"
WP_DIR="/opt/woodpecker"
PROJECT_NAME="woodpecker"
SOPS_URL="https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64"
RCLONE_REMOTE="gdrive:"
RCLONE_BACKUP_DIR="woodpecker"
RCLONE_CONFIG_FILE="/root/.config/rclone/rclone.conf"
RCLONE_TIMEOUT_ARGS=(--retries 1 --low-level-retries 1 --contimeout 10s)
BACKUP_NAME="woodpecker_backup"
SSH_KEY_FILE="/root/.ssh/id_ed25519"
SSH_PUB_FILE="${SSH_KEY_FILE}.pub"
SERVER_VOL="${PROJECT_NAME}_woodpecker-server-data"
AGENT_VOL="${PROJECT_NAME}_woodpecker-agent-config"
RAW_BASE="https://raw.githubusercontent.com/mishgun64/pve/main/useful_scripts"

log() {
    printf '\n\033[1;32m==> %s\033[0m\n' "$*"
}

if [[ $EUID -ne 0 ]]; then
    echo "Запусти от root" >&2
    exit 1
fi

ARCH="$(dpkg --print-architecture)"

if [[ "$ARCH" != "amd64" ]]; then
    echo "Ожидается amd64, найдено: $ARCH (бинарник sops собран под amd64)" >&2
    exit 1
fi

# Скрипт могут запустить локально (sudo ./setup-control.sh) — кладём его копию
# в /root, чтобы подсказки «sudo /root/setup-control.sh» были правдой.
# При запуске через curl|bash $0 не файл — просто пропускаем.
if [[ -f "$0" ]]; then
    install -m 0755 "$0" /root/setup-control.sh
    echo "Скрипт скопирован: /root/setup-control.sh"
fi

# --------------------------------------------------------------- SSH key ---
log "Настройка SSH ключа (он же age-ключ для sops)"

SSH_DIR="/root/.ssh"
SSH_KEY="$SSH_KEY_FILE"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -f "$SSH_KEY" ]]; then
    echo "SSH ключ уже существует: $SSH_KEY"
    read -rp "Перезаписать его? [y/N]: " OVERWRITE_KEY </dev/tty || OVERWRITE_KEY="n"

    if [[ ! "$OVERWRITE_KEY" =~ ^[Yy]$ ]]; then
        echo "Существующий SSH ключ сохранён."
    else
        echo ""
        echo "Вставь приватный SSH ключ."
        echo "После последней строки нажми Enter, затем Ctrl+D."
        echo ""

        SSH_KEY_CONTENT="$(cat </dev/tty)"

        if [[ -z "$SSH_KEY_CONTENT" ]]; then
            echo "SSH ключ не введён" >&2
            exit 1
        fi

        if ! grep -qE '^-----BEGIN .*PRIVATE KEY-----$' <<< "$SSH_KEY_CONTENT"; then
            echo "Похоже, это не приватный SSH ключ." >&2
            exit 1
        fi

        printf '%s\n' "$SSH_KEY_CONTENT" > "$SSH_KEY"

        chmod 600 "$SSH_KEY"
        chown root:root "$SSH_KEY"

        # Публичный ключ обязан соответствовать новому приватному: старый .pub
        # дал бы age-получателя, которым нельзя расшифровать бэкап.
        ssh-keygen -y -f "$SSH_KEY" </dev/null > "$SSH_PUB_FILE" || {
            echo "Не удалось получить публичный ключ из нового приватного (ключ под паролем?)" >&2
            exit 1
        }

        chmod 644 "$SSH_PUB_FILE"

        echo "SSH ключ сохранён: $SSH_KEY"
        echo "Публичный ключ пересоздан: $SSH_PUB_FILE"
    fi
else
    echo "Вставь приватный SSH ключ."
    echo "После последней строки нажми Enter, затем Ctrl+D."
    echo ""

    SSH_KEY_CONTENT="$(cat </dev/tty)"

    if [[ -z "$SSH_KEY_CONTENT" ]]; then
        echo "SSH ключ не введён" >&2
        exit 1
    fi

    if ! grep -qE '^-----BEGIN .*PRIVATE KEY-----$' <<< "$SSH_KEY_CONTENT"; then
        echo "Похоже, это не приватный SSH ключ." >&2
        exit 1
    fi

    printf '%s\n' "$SSH_KEY_CONTENT" > "$SSH_KEY"

    chmod 600 "$SSH_KEY"
    chown root:root "$SSH_KEY"

    echo "SSH ключ сохранён: $SSH_KEY"
fi

# Публичный ключ нужен sops как age-получатель
if [[ -s "$SSH_PUB_FILE" ]]; then
    chmod 644 "$SSH_PUB_FILE"
else
    ssh-keygen -y -f "$SSH_KEY" </dev/null > "$SSH_PUB_FILE" || {
        echo "Не удалось получить публичный ключ из $SSH_KEY (ключ под паролем? расшифровка без tty невозможна)" >&2
        exit 1
    }

    chmod 644 "$SSH_PUB_FILE"
fi

AGE_RECIPIENT="$(awk 'NR==1 {print $1" "$2}' "$SSH_PUB_FILE")"

if [[ "$AGE_RECIPIENT" != ssh-* ]]; then
    echo "Не удалось получить SSH-публичный ключ из $SSH_KEY" >&2
    exit 1
fi

echo "SSH файлы:"
ls -l "$SSH_KEY" "$SSH_PUB_FILE"
echo ""
echo "age-получатель (SSH-ключ root):"
echo "  $AGE_RECIPIENT"

# ---------------------------------------------------------------- .bashrc ---
add_aliases() {
    local rc="$1" owner="${2:-}"

    touch "$rc"

    grep -qxF "alias v='nvim'" "$rc" ||
        echo "alias v='nvim'" >> "$rc"

    grep -qxF "alias ll='ls -lh'" "$rc" ||
        echo "alias ll='ls -lh'" >> "$rc"

    [[ -n "$owner" ]] && chown "$owner:$owner" "$rc"

    return 0
}

log "Алиасы в .bashrc"

add_aliases /root/.bashrc

if id "$USER_NAME" &>/dev/null; then
    USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
    add_aliases "$USER_HOME/.bashrc" "$USER_NAME"
else
    echo "Пользователь $USER_NAME не найден, пропускаю его .bashrc" >&2
fi

# ------------------------------------------------------------------- apt ---
log "apt update && upgrade"

apt-get update
apt-get upgrade -y

log "Установка пакетов"

# curl нужен для скачивания sops и ключа Docker
apt-get install -y \
    neovim \
    cron \
    zip \
    unzip \
    htop \
    ca-certificates \
    curl \
    rclone \
    age \
    openssh-client \
    lm-sensors

# ------------------------------------------------ cleanup_backups.sh ---
log "Установка cleanup_backups.sh"

CLEANUP_URL="$RAW_BASE/cleanup_backups.sh"

curl -fsSL "$CLEANUP_URL" -o /root/cleanup_backups.sh

chmod 0755 /root/cleanup_backups.sh
chown root:root /root/cleanup_backups.sh

echo "Установлен:"
ls -l /root/cleanup_backups.sh

# ------------------------------------------------------------------ sops ---
log "Установка sops"

# Качаем во временный файл (mktemp), чтобы не оставить недокачанный бинарник
# на месте рабочего sops.
SOPS_TMP="$(mktemp /tmp/sops.XXXXXX)"

curl -fsSL -o "$SOPS_TMP" "$SOPS_URL"

install -m 0755 "$SOPS_TMP" /usr/local/bin/sops

rm -f "$SOPS_TMP"

sops --version

# ---------------------------------------------------------------- rclone ---
log "Настройка rclone (Google Drive)"

echo "Конфиг rclone: $RCLONE_CONFIG_FILE"
echo "Remote для бэкапов: $RCLONE_REMOTE (каталог: $RCLONE_BACKUP_DIR)"
echo ""

install -d -m 0700 /root/.config/rclone

RCLONE_PI_CONF="/home/pi/.config/rclone/rclone.conf"
RCLONE_SA_FILE="/root/.config/rclone/sa.json"

# Валидация шага: remote есть в конфиге И отвечает на lsd (токен/сеть в порядке).
# Без рабочего rclone бэкап на Drive невозможен, поэтому обхода «продолжить без
# rclone» здесь нет.
# Причина неудачи кладётся в RCLONE_LAST_ERR — её печатает каждая неудачная попытка.
RCLONE_LAST_ERR=""

rclone_remote_ok() {
    local remotes err_file

    RCLONE_LAST_ERR=""

    if [[ ! -s "$RCLONE_CONFIG_FILE" ]]; then
        RCLONE_LAST_ERR="нет файла конфига $RCLONE_CONFIG_FILE"
        return 1
    fi

    remotes="$(rclone listremotes --config "$RCLONE_CONFIG_FILE" 2>/dev/null || true)"

    if ! grep -qxF "$RCLONE_REMOTE" <<<"$remotes"; then
        RCLONE_LAST_ERR="в $RCLONE_CONFIG_FILE нет remote '$RCLONE_REMOTE'"
        return 1
    fi

    err_file="$(mktemp /tmp/rclone-lsd.XXXXXX)"

    if ! rclone lsd "$RCLONE_REMOTE" \
        --config "$RCLONE_CONFIG_FILE" \
        "${RCLONE_TIMEOUT_ARGS[@]}" >/dev/null 2>"$err_file"; then
        RCLONE_LAST_ERR="$(cat "$err_file")"
        rm -f "$err_file"
        return 1
    fi

    rm -f "$err_file"

    return 0
}

# Страховка перед любой перезаписью конфига: рядом остаётся .bak для отката.
rclone_backup_config() {
    [[ -f "$RCLONE_CONFIG_FILE" ]] || return 0

    cp -a "$RCLONE_CONFIG_FILE" "${RCLONE_CONFIG_FILE}.bak" || {
        echo "Не удалось сохранить копию $RCLONE_CONFIG_FILE в ${RCLONE_CONFIG_FILE}.bak" >&2
        return 1
    }

    echo "Сохранена копия конфига: ${RCLONE_CONFIG_FILE}.bak"

    return 0
}

# Пишет секцию remote в конфиг: чужие секции сохраняются, одноимённая заменяется.
# Секрет в командную строку rclone не передаётся — только в файл 0600.
rclone_write_section() {
    local name="$1" body="$2" tmp

    # Сначала страховка (.bak), только потом temp с секретом: если cp упадёт,
    # temp с client_secret даже не будет создан.
    rclone_backup_config || return 1

    tmp="$(mktemp /root/.config/rclone/.rclone.conf.XXXXXX)"

    # В temp лежит client_secret: удаляем его при любом возврате из функции,
    # а на путях ошибок — явным rm (trap не срабатывает на exit).
    trap 'rm -f "$tmp"' RETURN

    chmod 0600 "$tmp"

    if [[ -s "$RCLONE_CONFIG_FILE" ]]; then
        # Нормализуем строки до сравнения: CRLF и хвостовые пробелы («[gdrive] »)
        # не должны создавать дубль секции.
        awk -v sect="[${name}]" '
            {
                line = $0
                gsub(/\r/, "", line)
                sub(/[ \t]+$/, "", line)
                if (line ~ /^\[/) { skip = (line == sect) }
                if (!skip) print line
            }
        ' "$RCLONE_CONFIG_FILE" > "$tmp" || {
            rm -f "$tmp"
            return 1
        }
    fi

    {
        printf '[%s]\n' "$name"
        printf '%s\n' "$body"
        # Токен не сочиняем: его получит rclone config reconnect.
        printf 'token = \n'
    } >> "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    install -m 0600 -o root -g root "$tmp" "$RCLONE_CONFIG_FILE" || {
        rm -f "$tmp"
        return 1
    }

    rm -f "$tmp"
}

# Мастер OAuth: client_id + client_secret (без эха), затем rclone печатает ссылку
# и ждёт код подтверждения (headless: на «Use auto config?» отвечаем n).
rclone_setup_oauth() {
    local name client_id client_secret scope root_folder_id body

    read -rp "Имя remote [${RCLONE_REMOTE%:}]: " name </dev/tty
    [[ -n "$name" ]] || name="${RCLONE_REMOTE%:}"

    echo ""
    echo "client_id можно не вводить — тогда используется встроенный client_id rclone"
    echo "(у него общие лимиты Google). Свой client_id делается на console.cloud.google.com"
    echo "(OAuth client type: Desktop app)."

    read -rp "client_id (Enter — встроенный клиент rclone): " client_id </dev/tty

    client_secret=""

    # Секрет спрашиваем только если введён свой client_id.
    if [[ -n "$client_id" ]]; then
        read -rsp "client_secret (ввод не отображается): " client_secret </dev/tty
        echo

        if [[ -z "$client_secret" ]]; then
            echo "client_id введён, а client_secret пуст — так нельзя." >&2
            return 1
        fi
    fi

    read -rp "scope [drive]: " scope </dev/tty
    [[ -n "$scope" ]] || scope="drive"

    read -rp "root_folder_id (Enter — не задавать): " root_folder_id </dev/tty

    body="type = drive
scope = ${scope}
config_is_local = false"

    # Пустой client_id = встроенный клиент rclone: client_id/client_secret не пишем.
    if [[ -n "$client_id" ]]; then
        body="${body}
client_id = ${client_id}
client_secret = ${client_secret}"
    fi

    if [[ -n "$root_folder_id" ]]; then
        body="${body}
root_folder_id = ${root_folder_id}"
    fi

    if ! rclone_write_section "$name" "$body"; then
        unset client_secret body
        echo "Не удалось записать $RCLONE_CONFIG_FILE" >&2
        return 1
    fi

    unset client_secret body

    if [[ "${name}:" != "$RCLONE_REMOTE" ]]; then
        echo "ВНИМАНИЕ: бэкап-скрипты используют remote '$RCLONE_REMOTE'; с именем '${name}:' проверка не пройдёт." >&2
    fi

    echo ""
    echo "Сейчас rclone напечатает ссылку. На вопрос 'Use auto config?' ответь n."
    echo "Открой ссылку в браузере и вставь код подтверждения в этот терминал."
    echo ""

    if ! rclone config reconnect "${name}:" --config "$RCLONE_CONFIG_FILE" </dev/tty >/dev/tty; then
        echo "rclone config reconnect завершился с ошибкой." >&2
        return 1
    fi

    return 0
}

# Service account: JSON копируется в /root/.config/rclone/sa.json, OAuth не нужен.
rclone_setup_service_account() {
    local name json_path body

    read -rp "Имя remote [${RCLONE_REMOTE%:}]: " name </dev/tty
    [[ -n "$name" ]] || name="${RCLONE_REMOTE%:}"

    read -rp "Путь к JSON сервис-аккаунта: " json_path </dev/tty

    if [[ ! -f "$json_path" ]]; then
        echo "Файл не найден: $json_path" >&2
        return 1
    fi

    install -m 0600 -o root -g root "$json_path" "$RCLONE_SA_FILE"

    body="type = drive
service_account_file = ${RCLONE_SA_FILE}
scope = drive
config_is_local = false"

    if ! rclone_write_section "$name" "$body"; then
        echo "Не удалось записать $RCLONE_CONFIG_FILE" >&2
        return 1
    fi

    if [[ "${name}:" != "$RCLONE_REMOTE" ]]; then
        echo "ВНИМАНИЕ: бэкап-скрипты используют remote '$RCLONE_REMOTE'; с именем '${name}:' проверка не пройдёт." >&2
    fi

    echo ""
    echo "Скопирован ключ: $RCLONE_SA_FILE (0600 root:root)"
    echo "ВНИМАНИЕ: папку (или диск) на Google Drive нужно расшарить на email"
    echo "сервис-аккаунта (поле client_email в JSON; сам файл не печатаем)."
    echo ""

    return 0
}

# Меню способа настройки: варианта «продолжить без rclone» тут нет.
rclone_choose_method() {
    local choice path

    echo ""
    echo "Как настроить доступ к Google Drive?"
    echo "  1) Импортировать готовый rclone.conf из $RCLONE_PI_CONF"
    echo "  2) Импортировать готовый rclone.conf по указанному пути"
    echo "  3) Интерактивный мастер OAuth (client_id + client_secret)"
    echo "  4) Service account JSON (без браузера)"
    echo "  0) Прервать установку"
    echo ""

    read -rp "Выбор [0-4]: " choice </dev/tty

    case "$choice" in
        0)
            echo "Прервано оператором." >&2
            exit 1
            ;;
        1)
            if [[ ! -f "$RCLONE_PI_CONF" ]]; then
                echo "Нет файла $RCLONE_PI_CONF" >&2
                return 1
            fi

            rclone_backup_config || return 1

            install -m 0600 -o root -g root "$RCLONE_PI_CONF" "$RCLONE_CONFIG_FILE"
            echo "Скопирован: $RCLONE_CONFIG_FILE"
            ;;
        2)
            read -rp "Путь к rclone.conf: " path </dev/tty

            if [[ ! -f "$path" ]]; then
                echo "Файл не найден: $path" >&2
                return 1
            fi

            rclone_backup_config || return 1

            install -m 0600 -o root -g root "$path" "$RCLONE_CONFIG_FILE"
            echo "Скопирован: $RCLONE_CONFIG_FILE"
            ;;
        3)
            rclone_setup_oauth
            ;;
        4)
            rclone_setup_service_account
            ;;
        *)
            echo "Не понял выбор: '$choice' (нужно 0-4)" >&2
            return 1
            ;;
    esac
}

RCLONE_ATTEMPTS=0

while ! rclone_remote_ok; do
    RCLONE_ATTEMPTS=$((RCLONE_ATTEMPTS + 1))

    if [[ "$RCLONE_ATTEMPTS" -gt 5 ]]; then
        echo "" >&2
        echo "ERROR: remote '$RCLONE_REMOTE' не заработал после 5 попыток." >&2
        echo "Последняя ошибка rclone: ${RCLONE_LAST_ERR:-нет вывода rclone}" >&2
        echo "Без рабочего rclone бэкап на Drive работать не будет — установка прервана." >&2
        exit 1
    fi

    echo ""
    echo "Remote '$RCLONE_REMOTE' не настроен или не отвечает (попытка $RCLONE_ATTEMPTS из 5)."
    echo "Причина: ${RCLONE_LAST_ERR:-нет вывода rclone}"

    rclone_choose_method || true
done

echo "Remote '$RCLONE_REMOTE' доступен."

# --------------------------------------------------- age = root SSH key ---
log "age для sops: используется SSH-ключ root"

if [[ ! -f "$SSH_KEY_FILE" ]]; then
    echo "Нет SSH-ключа $SSH_KEY_FILE (он же age-ключ)." >&2
    exit 1
fi

chmod 600 "$SSH_KEY_FILE"
chown root:root "$SSH_KEY_FILE"

echo "Приватный ключ (для расшифровки бэкапа): $SSH_KEY_FILE"
echo "Публичный ключ (age-получатель для шифрования): $SSH_PUB_FILE"
echo "  $AGE_RECIPIENT"
echo ""
echo "sops использует:"
echo "  шифрование:  SOPS_AGE_RECIPIENTS='<ssh-ed25519 ...>'"
echo "  расшифровка: SOPS_AGE_SSH_PRIVATE_KEY_FILE=$SSH_KEY_FILE"

# ---------------------------------------------------------------- docker ---
log "Установка Docker"

install -m 0755 -d /etc/apt/keyrings

curl -fsSL \
    https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc

chmod a+r /etc/apt/keyrings/docker.asc

tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update

apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

systemctl enable --now docker

# -------------------------------------------------------------- вентиляторы ---
log "Настройка вентиляторов (setup-fans-control.sh)"

FANS_URL="$RAW_BASE/setup-fans-control.sh"
FANS_TMP="$(mktemp /tmp/setup-fans-control.XXXXXX.sh)"

if curl -fsSL "$FANS_URL" -o "$FANS_TMP"; then
    if bash "$FANS_TMP"; then
        echo "Вентиляторы настроены."
    else
        echo "ВНИМАНИЕ: setup-fans-control.sh завершился с ошибкой, продолжаю установку." >&2
    fi
else
    echo "ВНИМАНИЕ: не удалось скачать $FANS_URL, продолжаю установку." >&2
fi

rm -f "$FANS_TMP"

# ------------------------------------------------------------ woodpecker ---
log "Woodpecker CI"

# Повторный запуск скрипта не должен перезаписывать рабочие .env и volume:
# если .env уже есть, только поднимаем сервисы.
if [[ -f "$WP_DIR/.env" ]]; then
    echo "Woodpecker уже установлен ($WP_DIR/.env есть) — пропускаю восстановление/переустановку."
    echo "Конфиги и volume не трогаю, только поднимаю сервисы."

    cd "$WP_DIR"
    docker compose up -d
else
    BACKUP_REMOTE_PATH="${RCLONE_REMOTE}${RCLONE_BACKUP_DIR}/${BACKUP_NAME}.tar.gz.enc"

    # Недоступный или неавторизованный remote НЕ должен трактоваться как «бэкапа нет»:
    # сначала проверяем доступность remote, и только потом наличие файла.
    log "Проверка бэкапа на Drive: $BACKUP_REMOTE_PATH"

    RCLONE_ERR_FILE="$(mktemp /tmp/rclone-check.XXXXXX)"

    if ! rclone lsd "$RCLONE_REMOTE" \
        --config "$RCLONE_CONFIG_FILE" \
        "${RCLONE_TIMEOUT_ARGS[@]}" >/dev/null 2>"$RCLONE_ERR_FILE"; then
        RCLONE_ERR="$(cat "$RCLONE_ERR_FILE")"
        rm -f "$RCLONE_ERR_FILE"
        echo "ERROR: remote $RCLONE_REMOTE недоступен: ${RCLONE_ERR:-нет вывода rclone}" >&2
        echo "Ни восстановление, ни свежая установка не запущены — сначала починить доступ к Drive." >&2
        exit 1
    fi

    # Наличие файла проверяем через lsf по каталогу и точное сравнение имени:
    # это не зависит от кода возврата 3 («not found») в rclone size, который
    # менялся между версиями.
    # Код 3 = «каталог не найден», т.е. бэкапа ещё не было — это не ошибка доступа.
    # Любой другой ненулевой код — реальная проблема, её не глушим.
    RCLONE_LSF_STATUS=0

    RCLONE_LIST="$(rclone lsf --files-only \
        --config "$RCLONE_CONFIG_FILE" \
        "${RCLONE_TIMEOUT_ARGS[@]}" \
        "${RCLONE_REMOTE}${RCLONE_BACKUP_DIR}/" 2>"$RCLONE_ERR_FILE")" || RCLONE_LSF_STATUS=$?

    if [[ "$RCLONE_LSF_STATUS" -ne 0 && "$RCLONE_LSF_STATUS" -ne 3 ]]; then
        RCLONE_ERR="$(cat "$RCLONE_ERR_FILE")"
        rm -f "$RCLONE_ERR_FILE"
        echo "ERROR: не удалось прочитать ${RCLONE_REMOTE}${RCLONE_BACKUP_DIR}/: ${RCLONE_ERR:-нет вывода rclone}" >&2
        exit 1
    fi

    rm -f "$RCLONE_ERR_FILE"

    RESTORE_ANSWER="n"

    if grep -qxF "${BACKUP_NAME}.tar.gz.enc" <<<"$RCLONE_LIST"; then
        echo "Найден бэкап на Drive: $BACKUP_REMOTE_PATH"
        read -rp "Восстановить Woodpecker из бэкапа? [y/N]: " RESTORE_ANSWER </dev/tty ||
            RESTORE_ANSWER="n"
    else
        # rc=3: папки/файла на Drive нет. Это штатный «свежий» случай, но если
        # бэкап ожидался — лучше остановиться, чем затереть установку пустой.
        if [[ "$RCLONE_LSF_STATUS" -eq 3 ]]; then
            echo "ВНИМАНИЕ: на Drive нет ${RCLONE_REMOTE}${RCLONE_BACKUP_DIR}/ (rc=3)."
            echo "Если бэкап ожидался — остановись (Ctrl-C) и проверь, что папка"
            echo "расшарена на аккаунт remote и что remote верный."
        fi

        echo "Бэкап на Drive не найден ($BACKUP_REMOTE_PATH) — будет свежая установка."
    fi

    if [[ "$RESTORE_ANSWER" =~ ^[Yy]$ ]]; then
        log "Восстановление Woodpecker из бэкапа"

        RESTORE_DIR="$(mktemp -d /tmp/woodpecker-restore.XXXXXX)"
        trap 'rm -rf "$RESTORE_DIR"' EXIT

        rclone copyto \
            "$BACKUP_REMOTE_PATH" \
            "$RESTORE_DIR/${BACKUP_NAME}.tar.gz.enc" \
            --config "$RCLONE_CONFIG_FILE" \
            "${RCLONE_TIMEOUT_ARGS[@]}"

        SOPS_AGE_SSH_PRIVATE_KEY_FILE="$SSH_KEY_FILE" sops -d \
            --input-type binary \
            --output-type binary \
            "$RESTORE_DIR/${BACKUP_NAME}.tar.gz.enc" \
            > "$RESTORE_DIR/${BACKUP_NAME}.tar.gz"

        mkdir -p "$RESTORE_DIR/unpacked"

        tar xzf "$RESTORE_DIR/${BACKUP_NAME}.tar.gz" -C "$RESTORE_DIR/unpacked"

        if [[ ! -f "$RESTORE_DIR/unpacked/docker-compose.yml" ]]; then
            echo "В бэкапе нет docker-compose.yml" >&2
            exit 1
        fi

        if [[ ! -f "$RESTORE_DIR/unpacked/.env" ]]; then
            echo "В бэкапе нет .env" >&2
            exit 1
        fi

        mkdir -p "$WP_DIR"

        install -m 0644 \
            "$RESTORE_DIR/unpacked/docker-compose.yml" \
            "$WP_DIR/docker-compose.yml"

        install -m 0600 \
            "$RESTORE_DIR/unpacked/.env" \
            "$WP_DIR/.env"

        echo "Разложены $WP_DIR/docker-compose.yml и $WP_DIR/.env"

        docker volume create "$SERVER_VOL" >/dev/null || true
        docker volume create "$AGENT_VOL" >/dev/null || true

        restore_volume() {
            local vol="$1" archive="$2"

            if [[ ! -f "$RESTORE_DIR/unpacked/$archive" ]]; then
                echo "В бэкапе нет $archive — пропускаю $vol" >&2
                return 0
            fi

            docker run --rm \
                -v "$vol:/data" \
                -v "$RESTORE_DIR/unpacked:/restore:ro" \
                alpine \
                sh -c "find /data -mindepth 1 -delete; tar xzf /restore/$archive -C /data"

            echo "Залито в volume $vol из $archive"
        }

        restore_volume "$SERVER_VOL" "woodpecker-server-data.tar.gz"
        restore_volume "$AGENT_VOL" "woodpecker-agent-config.tar.gz"

        cd "$WP_DIR"

        docker compose up -d
    else
        log "Свежая установка Woodpecker CI"

        mkdir -p "$WP_DIR"

        echo "Введи данные GitHub OAuth App и секрет агента."

        read -rp \
            "WOODPECKER_GITHUB_CLIENT (Client ID): " \
            WP_CLIENT </dev/tty || WP_CLIENT=""

        read -rsp \
            "WOODPECKER_GITHUB_SECRET (Client Secret): " \
            WP_SECRET </dev/tty || WP_SECRET=""

        echo

        read -rsp \
            "WOODPECKER_AGENT_SECRET (пусто = сгенерировать): " \
            WP_AGENT </dev/tty || WP_AGENT=""

        echo

        # Ctrl-D в любом из prompt'ов не должен молча убивать установку —
        # работаем с пустыми значениями через ${VAR:-}.
        if [[ -z "${WP_AGENT:-}" ]]; then
            WP_AGENT="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"

            echo "Сгенерирован WOODPECKER_AGENT_SECRET"
            echo "Сохранён в $WP_DIR/.env"
        fi

        if [[ -z "${WP_CLIENT:-}" || -z "${WP_SECRET:-}" ]]; then
            echo "Client ID и Client Secret не могут быть пустыми" >&2
            exit 1
        fi

        umask 077

        cat > "$WP_DIR/.env" <<EOF
WOODPECKER_HOST=https://ci.mishgun.com

WOODPECKER_GITHUB=true
WOODPECKER_GITHUB_CLIENT=${WP_CLIENT}
WOODPECKER_GITHUB_SECRET=${WP_SECRET}

WOODPECKER_AGENT_SECRET=${WP_AGENT}

WOODPECKER_OPEN=true
WOODPECKER_ADMIN=mishgun64
EOF

        chmod 600 "$WP_DIR/.env"

        umask 022

        # heredoc в кавычках — ${...} остаются для docker compose

        cat > "$WP_DIR/docker-compose.yml" <<'EOF'
services:
  woodpecker-server:
    image: woodpeckerci/woodpecker-server:v3
    restart: unless-stopped

    ports:
      - "8000:8000"

    volumes:
      - woodpecker-server-data:/var/lib/woodpecker

    environment:
      WOODPECKER_HOST: ${WOODPECKER_HOST}

      WOODPECKER_GITHUB: ${WOODPECKER_GITHUB}
      WOODPECKER_GITHUB_CLIENT: ${WOODPECKER_GITHUB_CLIENT}
      WOODPECKER_GITHUB_SECRET: ${WOODPECKER_GITHUB_SECRET}

      WOODPECKER_AGENT_SECRET: ${WOODPECKER_AGENT_SECRET}

      WOODPECKER_OPEN: ${WOODPECKER_OPEN}
      WOODPECKER_ADMIN: ${WOODPECKER_ADMIN}

  woodpecker-agent:
    image: woodpeckerci/woodpecker-agent:v3
    restart: unless-stopped

    command: agent

    depends_on:
      - woodpecker-server

    volumes:
      - woodpecker-agent-config:/etc/woodpecker
      - /var/run/docker.sock:/var/run/docker.sock

    environment:
      WOODPECKER_SERVER: woodpecker-server:9000
      WOODPECKER_AGENT_SECRET: ${WOODPECKER_AGENT_SECRET}

volumes:
  woodpecker-server-data:
  woodpecker-agent-config:
EOF

        cd "$WP_DIR"

        docker compose up -d
    fi
fi

# ---------------------------------------------------- backup-woodpecker.sh ---
log "Установка backup-woodpecker.sh"

BACKUP_URL="$RAW_BASE/backup-woodpecker.sh"

curl -fsSL "$BACKUP_URL" -o /root/backup-woodpecker.sh

chmod 0755 /root/backup-woodpecker.sh
chown root:root /root/backup-woodpecker.sh

echo "Установлен:"
ls -l /root/backup-woodpecker.sh

# ------------------------------------------------------------------ cron ---
log "Настройка cron (root)"

systemctl enable --now cron

add_cron() {
    # $1 — комментарий
    # $2 — строка расписания

    local comment="$1"
    local line="$2"
    local current

    current="$(crontab -l 2>/dev/null || true)"

    if grep -qxF "$line" <<<"$current"; then
        return 0
    fi

    {
        [[ -n "$current" ]] && printf '%s\n' "$current"
        [[ -n "$comment" ]] && printf '%s\n' "$comment"
        printf '%s\n' "$line"
    } | crontab -
}

add_cron "#Ansible: Update, upgrade and reboot" \
    "0 6 * * * apt update && apt upgrade -y"

add_cron "#Ansible: Update ISO files daily" \
    "0 5 * * * /usr/bin/ansible-playbook /root/control_node_update_iso.yml >> /var/log/control_node_update_iso.log 2>&1"

add_cron "" \
    "0 8 * * * /root/cleanup_backups.sh --apply >> /var/log/cleanup_backups.log 2>&1"

add_cron "#Ежедневный бэкап Woodpecker на Google Drive (перезапись)" \
    "0 3 * * * /root/backup-woodpecker.sh >> /var/log/backup-woodpecker.log 2>&1"

crontab -l

# ------------------------------------------------------------------- done ---
log "Готово"

echo ""
echo "SSH key:"
ls -l "$SSH_KEY"

echo ""
echo "sops:"
sops --version

echo ""
echo "rclone remotes:"
rclone listremotes --config "$RCLONE_CONFIG_FILE" || true

echo ""
echo "age recipient (SSH-ключ root):"
echo "  $AGE_RECIPIENT"

echo ""
echo "cron:"
crontab -l

echo ""
echo "Woodpecker:"
cd "$WP_DIR"
docker compose ps
