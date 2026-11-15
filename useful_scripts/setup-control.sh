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
BACKUP_NAME="woodpecker_backup"
AGE_KEY_FILE="/root/.config/sops/age/keys.txt"
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

# --------------------------------------------------------------- SSH key ---
log "Настройка SSH ключа"

SSH_DIR="/root/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -f "$SSH_KEY" ]]; then
    echo "SSH ключ уже существует: $SSH_KEY"
    read -rp "Перезаписать его? [y/N]: " OVERWRITE_KEY </dev/tty

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

        echo "SSH ключ сохранён: $SSH_KEY"
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

curl -fsSL -o /tmp/sops "$SOPS_URL"

install -m 0755 /tmp/sops /usr/local/bin/sops

rm -f /tmp/sops

sops --version

# ---------------------------------------------------------------- rclone ---
log "Проверка rclone remote"

echo "Remote для бэкапов: $RCLONE_REMOTE (каталог: $RCLONE_BACKUP_DIR)"
echo "Если remote ещё не настроен — выполни в другом терминале:"
echo ""
echo "    rclone config"
echo ""
echo "и создай remote с именем '${RCLONE_REMOTE%:}' (тип: drive)."
echo ""

rclone listremotes || true

if ! rclone listremotes 2>/dev/null | grep -qxF "$RCLONE_REMOTE"; then
    echo ""
    echo "ВНИМАНИЕ: remote '$RCLONE_REMOTE' не найден в rclone config." >&2
    read -rp "Продолжить без rclone (бэкап на Drive работать не будет)? [y/N]: " RCLONE_SKIP </dev/tty

    if [[ ! "$RCLONE_SKIP" =~ ^[Yy]$ ]]; then
        echo "Настрой rclone config и запусти скрипт снова." >&2
        exit 1
    fi
else
    echo "Remote '$RCLONE_REMOTE' найден."
fi

# --------------------------------------------------------------- age key ---
log "Настройка age-ключа для sops"

AGE_KEY_DIR="$(dirname "$AGE_KEY_FILE")"

mkdir -p "$AGE_KEY_DIR"
chmod 700 "$AGE_KEY_DIR"

if [[ -f "$AGE_KEY_FILE" ]]; then
    echo "age-ключ уже существует: $AGE_KEY_FILE"

    chmod 600 "$AGE_KEY_FILE"
    chown root:root "$AGE_KEY_FILE"
else
    echo "age-ключа нет. Варианты:"
    echo "  (i) вставить существующий приватный age-ключ (нужен для расшифровки бэкапа)"
    echo "  (g) сгенерировать новый age-ключ"
    echo ""

    read -rp "Выбор [i/g]: " AGE_CHOICE </dev/tty

    case "$AGE_CHOICE" in
        i|I)
            echo ""
            echo "Вставь приватный age-ключ (строка AGE-SECRET-KEY-1...)."
            echo "После последней строки нажми Enter, затем Ctrl+D."
            echo ""

            AGE_KEY_CONTENT="$(cat </dev/tty)"

            if ! grep -qE '^AGE-SECRET-KEY-1' <<< "$AGE_KEY_CONTENT"; then
                echo "Не найдена строка AGE-SECRET-KEY-1..., это не приватный age-ключ." >&2
                exit 1
            fi

            printf '%s\n' "$AGE_KEY_CONTENT" > "$AGE_KEY_FILE"

            echo "age-ключ сохранён: $AGE_KEY_FILE"
            ;;
        *)
            age-keygen -o "$AGE_KEY_FILE"

            echo ""
            echo "Сгенерирован новый age-ключ: $AGE_KEY_FILE"
            echo "ВНИМАНИЕ: сохрани приватный ключ в надёжном месте."
            echo "Без него бэкап Woodpecker на Drive не расшифровать."
            ;;
    esac

    chmod 600 "$AGE_KEY_FILE"
    chown root:root "$AGE_KEY_FILE"
fi

echo "Публичный ключ (recipient для шифрования):"
age-keygen -y "$AGE_KEY_FILE"

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

BACKUP_REMOTE_PATH="${RCLONE_REMOTE}${RCLONE_BACKUP_DIR}/${BACKUP_NAME}.tar.gz.enc"

RESTORE_ANSWER="n"

if rclone lsf "$BACKUP_REMOTE_PATH" &>/dev/null; then
    echo "Найден бэкап на Drive: $BACKUP_REMOTE_PATH"
    read -rp "Восстановить Woodpecker из бэкапа? [y/N]: " RESTORE_ANSWER </dev/tty
else
    echo "Бэкап на Drive не найден ($BACKUP_REMOTE_PATH) — будет свежая установка."
fi

if [[ "$RESTORE_ANSWER" =~ ^[Yy]$ ]]; then
    log "Восстановление Woodpecker из бэкапа"

    RESTORE_DIR="$(mktemp -d /tmp/woodpecker-restore.XXXXXX)"
    trap 'rm -rf "$RESTORE_DIR"' EXIT

    rclone copyto \
        "$BACKUP_REMOTE_PATH" \
        "$RESTORE_DIR/${BACKUP_NAME}.tar.gz.enc"

    SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops -d \
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
            sh -c "rm -rf /data/*; tar xzf /restore/$archive -C /data"

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
        WP_CLIENT </dev/tty

    read -rsp \
        "WOODPECKER_GITHUB_SECRET (Client Secret): " \
        WP_SECRET </dev/tty

    echo

    read -rsp \
        "WOODPECKER_AGENT_SECRET (пусто = сгенерировать): " \
        WP_AGENT </dev/tty

    echo

    if [[ -z "$WP_AGENT" ]]; then
        WP_AGENT="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"

        echo "Сгенерирован WOODPECKER_AGENT_SECRET"
        echo "Сохранён в $WP_DIR/.env"
    fi

    if [[ -z "$WP_CLIENT" || -z "$WP_SECRET" ]]; then
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
rclone listremotes || true

echo ""
echo "age public key:"
age-keygen -y "$AGE_KEY_FILE"

echo ""
echo "cron:"
crontab -l

echo ""
echo "Woodpecker:"
cd "$WP_DIR"
docker compose ps
