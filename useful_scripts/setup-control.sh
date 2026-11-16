#!/usr/bin/env bash
# Первичная настройка control node на x86 (Debian 13 trixie, amd64)
# Запуск: sudo ./setup-control.sh
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

USER_NAME="pi"
TIMEZONE="Europe/Moscow"
WP_DIR="/opt/woodpecker"
PROJECT_NAME="woodpecker"
SOPS_URL="https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64"
RCLONE_REMOTE="gdrive:"
RCLONE_BACKUP_DIR="woodpecker"
RCLONE_CONFIG_FILE="/root/.config/rclone/rclone.conf"
RCLONE_TIMEOUT_ARGS=(--retries 1 --low-level-retries 1 --contimeout 10s)
# Для скачивания бэкапа (и любой передачи крупных файлов) — с ретраями и запасом:
# на медленном канале TLS-хендшейк до Google не укладывается в 10s.
RCLONE_TRANSFER_ARGS=(--retries 3 --low-level-retries 10 --contimeout 30s --timeout 300s)
BACKUP_NAME="woodpecker_backup"
SSH_KEY_FILE="/root/.ssh/id_ed25519"
SSH_PUB_FILE="${SSH_KEY_FILE}.pub"
PI_WEB_PORT=8504
# Пусто = спросить (по умолчанию предлагается LAN-адрес машины).
# Значения: 127.0.0.1 (только локально) или конкретный LAN-IP.
PI_WEB_HOST=""
PI_WEB_NPM_PACKAGE="@jmfederico/pi-web@latest"
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

# ------------------------------- root authorized_keys (ssh root@localhost) ---
log "Публичный ключ root в authorized_keys (вход ssh на самого себя)"

ROOT_AUTH_KEYS="$SSH_DIR/authorized_keys"

install -d -m 0700 -o root -g root "$SSH_DIR"

touch "$ROOT_AUTH_KEYS"
chmod 600 "$ROOT_AUTH_KEYS"
chown root:root "$ROOT_AUTH_KEYS"

# Ключ берём из того же .pub, что уже проверен выше как age-получатель.
ROOT_PUB_KEY="$(cat "$SSH_PUB_FILE")"

if grep -qxF "$ROOT_PUB_KEY" "$ROOT_AUTH_KEYS"; then
    echo "Ключ уже есть в $ROOT_AUTH_KEYS"
else
    printf '%s\n' "$ROOT_PUB_KEY" >> "$ROOT_AUTH_KEYS"
    echo "Ключ добавлен в $ROOT_AUTH_KEYS"
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

# ----------------------------------------------------------------- users ---
log "Пользователь $USER_NAME, sudo и SSH-ключ"

PI_HOME="/home/$USER_NAME"
PI_SSH_DIR="$PI_HOME/.ssh"
PI_AUTH_KEYS="$PI_SSH_DIR/authorized_keys"
SUDOERS_FILE="/etc/sudoers.d/90-$USER_NAME"

# sudo нужен для pi, openssh-server — чтобы sshd вообще был установлен,
# passwd — для chpasswd.
apt-get install -y sudo openssh-server passwd

if id "$USER_NAME" &>/dev/null; then
    echo "Пользователь $USER_NAME уже существует"
    EXISTING_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"

    if [[ "$EXISTING_HOME" != "$PI_HOME" ]]; then
        echo "ВНИМАНИЕ: домашний каталог $USER_NAME — $EXISTING_HOME, а не $PI_HOME" >&2
        PI_HOME="$EXISTING_HOME"
        PI_SSH_DIR="$PI_HOME/.ssh"
        PI_AUTH_KEYS="$PI_SSH_DIR/authorized_keys"
    fi
else
    useradd --create-home --home-dir "$PI_HOME" --shell /bin/bash "$USER_NAME"
    echo "Создан пользователь $USER_NAME ($PI_HOME)"
fi

usermod --shell /bin/bash "$USER_NAME"

# Группа sudo + явный drop-in в sudoers (sudo без пароля: под pi могут
# работать автоматизированные задачи).
usermod --append --groups sudo "$USER_NAME"

printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$USER_NAME" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
chown root:root "$SUDOERS_FILE"

# Битый sudoers ломает sudo целиком — проверяем и откатываемся.
if ! visudo -cf "$SUDOERS_FILE" >/dev/null; then
    rm -f "$SUDOERS_FILE"
    echo "ОШИБКА: $SUDOERS_FILE не прошёл visudo -c, файл удалён" >&2
    exit 1
fi

echo "$USER_NAME добавлен в sudoers: $SUDOERS_FILE"

# sshd должен быть включён, иначе вход по ключам (root/pi) не заработает.
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true

# ----------------------------------------------- pi: authorized_keys ---
log "SSH-ключ для $USER_NAME"

echo "Вставь публичный ключ для $USER_NAME (одной строкой)."
echo "Enter — использовать тот же ключ, что у root:"
echo "  $ROOT_PUB_KEY"
echo ""

read -rp "> " PI_PUB_KEY </dev/tty || PI_PUB_KEY=""
PI_PUB_KEY="${PI_PUB_KEY:-$ROOT_PUB_KEY}"

if [[ -z "$PI_PUB_KEY" ]]; then
    echo "Публичный ключ не введён" >&2
    exit 1
fi

if ! ssh-keygen -l -f /dev/stdin <<<"$PI_PUB_KEY" >/dev/null 2>&1; then
    echo "Похоже, это не публичный SSH ключ." >&2
    exit 1
fi

install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" "$PI_SSH_DIR"

touch "$PI_AUTH_KEYS"
chmod 600 "$PI_AUTH_KEYS"
chown "$USER_NAME:$USER_NAME" "$PI_AUTH_KEYS"

if grep -qxF "$PI_PUB_KEY" "$PI_AUTH_KEYS"; then
    echo "Ключ уже есть в $PI_AUTH_KEYS"
else
    printf '%s\n' "$PI_PUB_KEY" >> "$PI_AUTH_KEYS"
    echo "Ключ добавлен в $PI_AUTH_KEYS"
fi

# ----------------------------------- удаление прочих логинящихся юзеров ---
log "Удаление пользователей, кроме root и $USER_NAME"

# «Может залогиниться» — не системный аккаунт (UID 0 или 1000..60000)
# с реальным шеллом (не nologin/false).
mapfile -t LOGIN_USERS < <(
    getent passwd | awk -F: -v keep="$USER_NAME" '
        $1 == "root" || $1 == keep || $1 == "nobody" { next }
        (($3 >= 1000 && $3 <= 60000) || $3 == 0) && $7 != "" &&
            $7 !~ /(nologin|false|sync|shutdown|halt)$/ { print $1 }
    '
)

if [[ "${#LOGIN_USERS[@]}" -eq 0 ]]; then
    echo "Лишних пользователей с логином нет"
else
    echo "Найдены пользователи, которые могут залогиниться:"
    printf '  - %s\n' "${LOGIN_USERS[@]}"

    # Удаление домашних каталогов необратимо — спрашиваем подтверждение.
    read -rp "Удалить их вместе с домашними каталогами? [y/N]: " REMOVE_USERS </dev/tty ||
        REMOVE_USERS="n"

    if [[ "$REMOVE_USERS" =~ ^[YyДд]$ ]]; then
        for u in "${LOGIN_USERS[@]}"; do
            if pkill -KILL -u "$u" 2>/dev/null; then
                echo "Завершены процессы пользователя $u"
            fi

            if userdel --remove "$u" 2>/dev/null; then
                echo "Удалён пользователь $u (с домашним каталогом)"
            elif userdel "$u" 2>/dev/null; then
                echo "Удалён пользователь $u (домашний каталог не тронут)"
            else
                echo "ВНИМАНИЕ: не удалось удалить $u (возможно, есть активная сессия)" >&2
            fi
        done
    else
        echo "Удаление пользователей пропущено"
    fi
fi

# ----------------------------------------------------- пароли root и pi ---
log "Установка паролей root и $USER_NAME"

set_password() {
    local user="$1" label="$2" pass confirm

    while true; do
        read -rsp "Пароль для $label: " pass </dev/tty || return 1
        echo

        if [[ -z "$pass" ]]; then
            echo "Пароль не может быть пустым."
            continue
        fi

        read -rsp "Повторите пароль для $label: " confirm </dev/tty || return 1
        echo

        if [[ "$pass" != "$confirm" ]]; then
            echo "Пароли не совпадают. Попробуйте ещё раз."
            continue
        fi

        # Пароль передаётся только через stdin chpasswd, не в аргументах.
        printf '%s:%s\n' "$user" "$pass" | chpasswd

        unset pass confirm
        echo "Пароль для $label установлен."
        return 0
    done
}

set_password root root || exit 1
set_password "$USER_NAME" "$USER_NAME" || exit 1

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

# --------------------------------------------------------------- timezone ---
log "Часовой пояс: $TIMEZONE"

CURRENT_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"

if [[ "$CURRENT_TZ" == "$TIMEZONE" ]]; then
    echo "Уже установлен: $TIMEZONE"
elif [[ -e "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    if command -v timedatectl >/dev/null 2>&1 &&
        timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
        echo "Установлен через timedatectl: $TIMEZONE"
    else
        # Fallback для окружений без работающего systemd-dbus
        ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
        printf '%s\n' "$TIMEZONE" > /etc/timezone
        dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
        echo "Установлен вручную (/etc/localtime + /etc/timezone): $TIMEZONE"
    fi
else
    echo "ВНИМАНИЕ: нет /usr/share/zoneinfo/$TIMEZONE — часовой пояс не изменён" >&2
fi

echo "Проверка: $(date '+%Z %z  %Y-%m-%d %H:%M:%S')"

# ------------------------------------------------------------- pi agent ---
log "Установка pi agent (Node.js + pi CLI)"

# pi требует Node.js >= 22.19. Официальный install.sh интерактивен (меню и
# «Start pi now?») и без tty не умеет ставить Node, поэтому ставим детерминированно:
# официальный бинарный дистрибутив с nodejs.org + npm -g.
NODE_VERSION="22"
PI_NPM_PACKAGE="@earendil-works/pi-coding-agent"

node_version_ok() {
    command -v node >/dev/null 2>&1 || return 1

    node -e '
        const [maj, min] = process.versions.node.split(".").map(Number);
        process.exit(maj > 22 || (maj === 22 && min >= 19) ? 0 : 1);
    ' >/dev/null 2>&1
}

install_node_tarball() {
    local tmp arch ver file

    case "$ARCH" in
        amd64) arch="x64" ;;
        arm64) arch="arm64" ;;
        *)
            echo "Нет бинарника Node.js для архитектуры $ARCH — поставь Node.js 22.19+ вручную" >&2
            return 1
            ;;
    esac

    tmp="$(mktemp -d /tmp/node-install.XXXXXX)"
    trap 'rm -rf "$tmp"' RETURN

    echo "Определяю последний Node.js ${NODE_VERSION}.x"

    curl -fsSL "https://nodejs.org/dist/latest-v${NODE_VERSION}.x/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt" || return 1

    file="$(awk -v suffix="-linux-${arch}.tar.xz" '
        index($2, "node-v") == 1 && substr($2, length($2) - length(suffix) + 1) == suffix { print $2; exit }
    ' "$tmp/SHASUMS256.txt")"

    if [[ -z "$file" ]]; then
        echo "Не найден архив Node.js для linux-${arch}" >&2
        return 1
    fi

    ver="${file#node-}"
    ver="${ver%-linux-*}"

    echo "Скачиваю Node.js ${ver}"

    curl -fsSL "https://nodejs.org/dist/latest-v${NODE_VERSION}.x/$file" -o "$tmp/$file" || return 1

    # Проверка контрольной суммы: без неё битый/подменённый архив уйдёт в /usr/local.
    if ! (cd "$tmp" && grep " $file\$" SHASUMS256.txt | sha256sum -c -); then
        echo "Контрольная сумма Node.js не совпала" >&2
        return 1
    fi

    # Распаковка в /usr/local: node/npm/npx окажутся в /usr/local/bin.
    tar -xJf "$tmp/$file" -C /usr/local --strip-components=1 --exclude='*/CHANGELOG.md' \
        --exclude='*/LICENSE' --exclude='*/README.md' || return 1

    hash -r

    echo "Node.js установлен: $(node --version), npm: $(npm --version)"
}

if node_version_ok; then
    echo "Node.js уже подходит: $(node --version)"
else
    if command -v node >/dev/null 2>&1; then
        echo "Node.js $(node --version) старше 22.19 — ставлю Node.js ${NODE_VERSION}"
    else
        echo "Node.js не найден — ставлю Node.js ${NODE_VERSION}"
    fi

    # xz нужен для tar -xJf
    apt-get install -y xz-utils

    install_node_tarball || {
        echo "ОШИБКА: не удалось установить Node.js" >&2
        exit 1
    }
fi

if command -v pi >/dev/null 2>&1; then
    echo "pi уже установлен: $(command -v pi) ($(pi --version 2>/dev/null || echo '?'))"
    echo "Обновить pi до последней версии? [y/N]: "
    read -rp "> " UPDATE_PI </dev/tty || UPDATE_PI="n"

    if [[ "$UPDATE_PI" =~ ^[YyДд]$ ]]; then
        pi update || echo "ВНИМАНИЕ: pi update завершился с ошибкой" >&2
    fi
else
    # --ignore-scripts: документация pi явно говорит, что lifecycle-скрипты не нужны.
    echo "Устанавливаю $PI_NPM_PACKAGE глобально"
    npm install -g --ignore-scripts "$PI_NPM_PACKAGE" || {
        echo "ОШИБКА: npm install $PI_NPM_PACKAGE завершился с ошибкой" >&2
        exit 1
    }

    hash -r
fi

if ! command -v pi >/dev/null 2>&1; then
    echo "ОШИБКА: pi не найден в PATH после установки ($(npm prefix -g 2>/dev/null)/bin)" >&2
    exit 1
fi

echo "pi: $(command -v pi) ($(pi --version 2>/dev/null || echo '?'))"
echo "node: $(node --version)"

# -------------------------------------------------------- pi web ui ---
log "Установка PI WEB (https://github.com/jmfederico/pi-web)"

# Адрес, на котором слушает PI WEB.
# Встроенной авторизации нет, поэтому 0.0.0.0 не предлагаем: либо loopback
# (доступ только через ssh-туннель), либо конкретный LAN-IP.
PI_WEB_LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null |\
    awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')"

if [[ -z "$PI_WEB_HOST" ]]; then
    echo ""
    echo "На каком адресе слушать PI WEB?"
    echo "  1) LAN-адрес этой машины — доступ с других хостов сети (по умолчанию)"
    echo "  2) 127.0.0.1 — только локально/через ssh-туннель"
    echo ""
    echo "У PI WEB НЕТ авторизации: доступ к порту = shell от $USER_NAME,"
    echo "а у $USER_NAME есть sudo без пароля. Во внешнюю сеть так не выставляй."
    echo ""

    if [[ -n "$PI_WEB_LAN_IP" ]]; then
        echo "LAN-адрес: $PI_WEB_LAN_IP"
    else
        echo "LAN-адрес определить не удалось."
    fi

    read -rp "Выбор [1-2] (Enter = 1): " PI_WEB_HOST_CHOICE </dev/tty ||
        PI_WEB_HOST_CHOICE="1"

    case "$PI_WEB_HOST_CHOICE" in
        2)
            PI_WEB_HOST="127.0.0.1"
            ;;
        ""|1)
            PI_WEB_HOST="${PI_WEB_LAN_IP:-127.0.0.1}"

            if [[ -z "$PI_WEB_LAN_IP" ]]; then
                echo "ВНИМАНИЕ: LAN-адрес не найден, использую 127.0.0.1" >&2
            fi
            ;;
        *)
            # Разрешаем ввести адрес вручную — вдруг нужен другой интерфейс.
            PI_WEB_HOST="$PI_WEB_HOST_CHOICE"
            echo "Использую введённый адрес: $PI_WEB_HOST"
            ;;
    esac
fi

echo ""
echo "PI WEB ставится пакетом @jmfederico/pi-web и работает от пользователя $USER_NAME."
echo "Он ставит ДВА per-user сервиса (pi-web.service + pi-web-sessiond.service) и"
echo "слушает $PI_WEB_HOST:$PI_WEB_PORT."

echo ""

read -rp "Установить PI WEB? [Y/n]: " INSTALL_PI_WEB </dev/tty || INSTALL_PI_WEB="y"

if [[ "$INSTALL_PI_WEB" =~ ^[NnНн]$ ]]; then
    echo "Установка PI WEB пропущена"
else
    # node-pty (терминалы) на Linux собирается из исходников: нужен компилятор
    # и python3, иначе сессионный демон поднимется без терминала.
    apt-get install -y build-essential python3

    echo "Устанавливаю @jmfederico/pi-web глобально (npm prefix: $(npm prefix -g))"

    # --allow-scripts=node-pty: точечно разрешает install-скрипт только node-pty
    # (нужен для нативной сборки). На npm < 12 флага нет, но и запрета нет —
    # там скрипты выполняются по умолчанию.
    if ! npm install -g --allow-scripts=node-pty "$PI_WEB_NPM_PACKAGE"; then
        echo "ОШИБКА: npm install $PI_WEB_NPM_PACKAGE завершился с ошибкой" >&2
        exit 1
    fi

    hash -r

    if ! command -v pi-web >/dev/null 2>&1; then
        echo "ОШИБКА: pi-web не найден в PATH после установки" >&2
        exit 1
    fi

    echo "pi-web: $(command -v pi-web) ($(pi-web --version 2>/dev/null || echo '?'))"

    # pi-web install пишет per-user unit'ы и дёргает systemctl --user: нужен
    # живой user-контекст systemd (XDG_RUNTIME_DIR + DBUS_SESSION_BUS_ADDRESS).
    # Сервисы переживают логаут/перезагрузку только с linger.
    PI_WEB_USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
    PI_WEB_UID="$(id -u "$USER_NAME")"
    NPM_GLOBAL_BIN="$(npm prefix -g)/bin"

    # Сервисы запускаются через login shell (-lc), а -lc не читает .bashrc,
    # поэтому PATH пишем в ~/.profile.
    PI_WEB_PROFILE="$PI_WEB_USER_HOME/.profile"
    PI_WEB_PATH_LINE="export PATH=\"$NPM_GLOBAL_BIN:\$PATH\""

    touch "$PI_WEB_PROFILE"

    if ! grep -qxF "$PI_WEB_PATH_LINE" "$PI_WEB_PROFILE"; then
        printf '%s\n' "$PI_WEB_PATH_LINE" >> "$PI_WEB_PROFILE"
        echo "PATH (pi, pi-web) добавлен в $PI_WEB_PROFILE"
    fi

    chown "$USER_NAME:$USER_NAME" "$PI_WEB_PROFILE"

    if command -v loginctl >/dev/null 2>&1; then
        loginctl enable-linger "$USER_NAME" 2>/dev/null &&
            echo "Включён linger для $USER_NAME (сервисы не зависят от ssh-сессии)"

        # linger поднимает user@UID.service и создаёт /run/user/UID не мгновенно.
        for _ in $(seq 1 20); do
            [[ -d "/run/user/$PI_WEB_UID" ]] && break
            sleep 1
        done
    fi

    # PI WEB переиспользует SDK уже установленного pi и требует, чтобы `pi` был
    # именно npm-пакетом (бинарная сборка без SDK не поддерживается). Наш
    # `npm install -g @earendil-works/pi-coding-agent` этому соответствует;
    # путь фиксируем явно, чтобы сервисы не зависели от PATH login shell.
    PI_SDK_DIR="$(npm root -g)/@earendil-works/pi-coding-agent"

    if [[ ! -f "$PI_SDK_DIR/package.json" ]]; then
        echo "ВНИМАНИЕ: не найден SDK pi в $PI_SDK_DIR" >&2
        echo "          PI WEB может не найти pi: проверь 'pi-web doctor'." >&2
        PI_SDK_DIR=""
    fi

    # Запуск команды от pi в его user-контексте systemd.
    pi_web_as_user() {
        local sdk_env=()

        # Путь к SDK pi передаём только если он реально найден.
        [[ -n "$PI_SDK_DIR" ]] && sdk_env=("PI_WEB_PI_PACKAGE_DIR=$PI_SDK_DIR")

        sudo -u "$USER_NAME" -H \
            env HOME="$PI_WEB_USER_HOME" \
            XDG_RUNTIME_DIR="/run/user/$PI_WEB_UID" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$PI_WEB_UID/bus" \
            PATH="$NPM_GLOBAL_BIN:/usr/local/bin:/usr/bin:/bin" \
            "${sdk_env[@]}" \
            bash -lc "$*"
    }

    echo ""
    echo "Запускаю 'pi-web install' от $USER_NAME ($PI_WEB_HOST:$PI_WEB_PORT)"
    echo ""

    if ! pi_web_as_user "pi-web install --host $PI_WEB_HOST --port $PI_WEB_PORT"; then
        echo "ВНИМАНИЕ: 'pi-web install' не смог поставить user-сервисы" >&2
        echo "          (обычно нет systemd user-сессии у $USER_NAME)." >&2
        echo "          Сам пакет @jmfederico/pi-web уже установлен." >&2
        echo "" >&2
        echo "  Диагностика от имени $USER_NAME:" >&2
        echo "    sudo -u $USER_NAME -i pi-web doctor" >&2
        echo "    sudo -u $USER_NAME -i pi-web install --host $PI_WEB_HOST --port $PI_WEB_PORT" >&2
        echo "" >&2

        PI_WEB_SERVICES_OK=0
    else
        PI_WEB_SERVICES_OK=1
    fi

    if [[ "$PI_WEB_SERVICES_OK" -eq 1 ]]; then
        echo ""
        echo "Сервисы:"
        pi_web_as_user "systemctl --user is-enabled pi-web.service pi-web-sessiond.service" ||
            true

        # doctor сверяет окружение сервисов с login shell. Не валим установку,
        # но показываем проблемы: без терминала сессии будут урезаны.
        if ! pi_web_as_user "pi-web doctor"; then
            echo "ВНИМАНИЕ: 'pi-web doctor' сообщил о проблемах (см. вывод выше)." >&2
        fi

        echo ""
        echo "PI WEB: http://$PI_WEB_HOST:$PI_WEB_PORT"

        if [[ "$PI_WEB_HOST" == "127.0.0.1" ]]; then
            echo "  слушает только loopback — с других хостов:"
            echo "    ssh -N -L $PI_WEB_PORT:127.0.0.1:$PI_WEB_PORT $USER_NAME@<этот-хост>"
        else
            echo "  слушает $PI_WEB_HOST — доступен из этой сети БЕЗ авторизации."
            echo "  Доступ к порту = shell от $USER_NAME (sudo без пароля)."
        fi

        echo "  статус: sudo -u $USER_NAME -i pi-web status"
        echo "  логи:   sudo -u $USER_NAME -i pi-web logs"
        echo "  сменить адрес: редактировать ~/.config/pi-web/config.json (host)"
    fi
fi

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
            "${RCLONE_TRANSFER_ARGS[@]}"

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
echo "Пользователи и SSH:"
id "$USER_NAME"
pwstatus -S root || true
pwstatus -S "$USER_NAME" || true
echo "root authorized_keys: $ROOT_AUTH_KEYS"
echo "$USER_NAME authorized_keys: $PI_AUTH_KEYS"
sudo -n -l -U "$USER_NAME" 2>/dev/null || true

echo ""
echo "pi:"
command -v pi && pi --version 2>/dev/null || true
echo "node: $(node --version 2>/dev/null || echo 'нет')"

if command -v pi-web >/dev/null 2>&1; then
    # Фактический адрес берём из конфига: pi-web читает host при старте.
    PI_WEB_EFFECTIVE_HOST="$(sudo -u "$USER_NAME" -H \
        python3 -c 'import json,os,sys
p=os.path.expanduser("~/.config/pi-web/config.json")
try: print(json.load(open(p)).get("host", ""))
except Exception: sys.exit(0)' 2>/dev/null || true)"

    echo ""
    echo "PI WEB:"
    echo "  $(command -v pi-web) ($(pi-web --version 2>/dev/null || echo '?'))"
    echo "  http://${PI_WEB_EFFECTIVE_HOST:-$PI_WEB_HOST}:$PI_WEB_PORT"
    echo "  статус: sudo -u $USER_NAME -i pi-web status"
    echo "  логи:   sudo -u $USER_NAME -i pi-web logs"
fi
echo ""
echo "cron:"
crontab -l

echo ""
echo "Woodpecker:"
cd "$WP_DIR"
docker compose ps
