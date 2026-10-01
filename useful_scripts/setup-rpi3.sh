#!/usr/bin/env bash
# Первичная настройка Debian trixie на Raspberry Pi 3
# Запуск: sudo ./setup-rpi3.sh
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

USER_NAME="mishgun"
SOPS_URL="https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.arm64"
WP_DIR="/opt/woodpecker"

log() {
    printf '\n\033[1;32m==> %s\033[0m\n' "$*"
}

if [[ $EUID -ne 0 ]]; then
    echo "Запусти от root" >&2
    exit 1
fi

ARCH="$(dpkg --print-architecture)"

if [[ "$ARCH" != "arm64" ]]; then
    echo "Ожидается arm64, найдено: $ARCH (бинарник sops собран под arm64)" >&2
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
    curl

# ------------------------------------------------ cleanup_backups.sh ---
log "Установка cleanup_backups.sh"

CLEANUP_URL="https://raw.githubusercontent.com/mishgun64/pve/main/useful_scripts/cleanup_backups.sh"

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

crontab -l

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

# ------------------------------------------------------------ woodpecker ---
log "Установка Woodpecker CI"

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

# ------------------------------------------------------------------- done ---
log "Готово"

echo ""
echo "SSH key:"
ls -l "$SSH_KEY"

echo ""
echo "Woodpecker:"
docker compose ps