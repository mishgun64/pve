#!/usr/bin/env bash
# Статические тесты для useful_scripts: без docker, rclone и root.
# Запуск: bash useful_scripts/tests/check.sh
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

BACKUP_SCRIPT="$SCRIPTS_DIR/backup-woodpecker.sh"
SETUP_SCRIPT="$SCRIPTS_DIR/setup-control.sh"
SYNC_PIWEB_SCRIPT="$SCRIPTS_DIR/sync-piweb-config.sh"
RESTORE_PI_SCRIPT="$SCRIPTS_DIR/restore-pi-agent.sh"
BACKUP_PI_SH="$SCRIPTS_DIR/backup-pi-agent.sh"
BACKUP_PI_SCRIPT="$SCRIPTS_DIR/backup-pi-agent.ps1"

FAILED=0

pass() {
    printf 'PASS: %s\n' "$*"
}

fail() {
    printf 'FAIL: %s\n' "$*"
    FAILED=1
}

# Порядок двух фрагментов в файле: 0 — первый раньше второго, 1 — позже,
# 2 — один из фрагментов не найден.
order_ok() {
    local file="$1" first="$2" second="$3"

    awk -v a="$first" -v b="$second" '
        index($0, a) && !la { la = NR }
        index($0, b) && !lb { lb = NR }
        END {
            if (!la || !lb) exit 2
            exit (la < lb) ? 0 : 1
        }
    ' "$file"
}

check_order() {
    local file="$1" first="$2" second="$3" label="$4"
    local rc=0

    order_ok "$file" "$first" "$second" || rc=$?

    case "$rc" in
        0) pass "$label" ;;
        1) fail "$label (фрагмент «$first» идёт позже «$second»)" ;;
        *) fail "$label (не найден фрагмент: «$first» или «$second»)" ;;
    esac
}

# --- 1. синтаксис -----------------------------------------------------------
if bash -n "$SETUP_SCRIPT" 2>/dev/null; then
    pass "bash -n setup-control.sh"
else
    fail "bash -n setup-control.sh"
fi

if bash -n "$BACKUP_SCRIPT" 2>/dev/null; then
    pass "bash -n backup-woodpecker.sh"
else
    fail "bash -n backup-woodpecker.sh"
fi

if bash -n "$RESTORE_PI_SCRIPT" 2>/dev/null; then
    pass "bash -n restore-pi-agent.sh"
else
    fail "bash -n restore-pi-agent.sh"
fi

if bash -n "$BACKUP_PI_SH" 2>/dev/null; then
    pass "bash -n backup-pi-agent.sh"
else
    fail "bash -n backup-pi-agent.sh"
fi

# --- 1a. pi agent backup/restore -------------------------------------------
# получатель по умолчанию — ключ root@control
if grep -qF 'DEFAULT_RECIPIENT="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMy5WqCB0OqW9WuzzHWVegy5oWFH1tRBZALxKOvkr8GB root@control"' "$BACKUP_PI_SH"; then
    pass 'backup-pi-agent.sh: получатель по умолчанию — root@control'
else
    fail 'backup-pi-agent.sh: получатель по умолчанию не root@control'
fi

# источник и каталог загрузки совпадают с restore-pi-agent.sh
grep -q 'pi-agent-backups' "$BACKUP_PI_SH" &&
    grep -q 'RCLONE_CONFIG_FILE="/root/.config/rclone/rclone.conf"' "$BACKUP_PI_SH" &&
    pass 'backup-pi-agent.sh: remote/каталог/конфиг rclone как у restore' ||
    fail 'backup-pi-agent.sh: remote/каталог/конфиг rclone расходятся с restore'

# перезапись одного и того же объекта
for frag in 'rclone copyto' '--ignore-times' 'перезапись' 'sha256'; do
    if grep -q -- "$frag" "$BACKUP_PI_SH"; then
        pass "backup-pi-agent.sh: есть «$frag»"
    else
        fail "backup-pi-agent.sh: нет «$frag»"
    fi
done

# Шифрование идёт из staging-каталога: иначе .sops.yaml рядом со скриптом
# подменит получателя.
check_order "$BACKUP_PI_SH"     'cd "$STAGING"'     'sops encrypt'     'backup-pi-agent.sh: шифрование из staging (не подхватывает .sops.yaml)'

# preflight rclone раньше tar/sops
check_order "$BACKUP_PI_SH"     'rclone lsd "$RCLONE_REMOTE"'     'tar -czf "$ARCHIVE"'     'backup-pi-agent.sh: rclone lsd раньше tar/sops'

# restore ищет ключ для расшифровки у пользователя pi, а не у root
if grep -q '/home/\$PI_USER/.ssh/id_ed25519' "$RESTORE_PI_SCRIPT"; then
    pass 'restore-pi-agent.sh: ключ ищется у пользователя pi'
else
    fail 'restore-pi-agent.sh: нет поиска ключа в /home/$PI_USER/.ssh/'
fi

# архив распаковывается в /home/pi/.pi/agent
if grep -q 'TARGET_DIR:=/home/\$PI_USER/.pi/agent' "$RESTORE_PI_SCRIPT"; then
    pass 'restore-pi-agent.sh: каталог по умолчанию /home/<user>/.pi/agent'
else
    fail 'restore-pi-agent.sh: нет каталога по умолчанию /home/<user>/.pi/agent'
fi

# защита от path traversal до распаковки
check_order "$RESTORE_PI_SCRIPT"     "архив содержит '..'"     "tar -xzf \"\$ARCHIVE\" -C \"\$TARGET_DIR\""     'restore-pi-agent.sh: проверка путей раньше распаковки'

for frag in 'SOPS_AGE_SSH_PRIVATE_KEY_FILE' 'rclone copyto' 'sha256'; do
    if grep -q -- "$frag" "$RESTORE_PI_SCRIPT"; then
        pass "restore-pi-agent.sh: есть «$frag»"
    else
        fail "restore-pi-agent.sh: нет «$frag»"
    fi
done

# бэкап шифрует sops-ом и перезаписывает объект на Drive
for frag in 'sops' 'rclone copyto' '--ignore-times' 'overwrite'; do
    if grep -q -- "$frag" "$BACKUP_PI_SCRIPT"; then
        pass "backup-pi-agent.ps1: есть «$frag»"
    else
        fail "backup-pi-agent.ps1: нет «$frag»"
    fi
done

# ключ шифрования запрашивается у пользователя интерактивно
if grep -q 'Read-Host' "$BACKUP_PI_SCRIPT"; then
    pass 'backup-pi-agent.ps1: ключ запрашивается интерактивно (Read-Host)'
else
    fail 'backup-pi-agent.ps1: нет интерактивного запроса ключа'
fi

# --- 2. preflight раньше шифрования ----------------------------------------
check_order "$BACKUP_SCRIPT" \
    'rclone_preflight' \
    'sops -e' \
    'backup-woodpecker.sh: rclone_preflight раньше sops -e'

# --- 3. проверка доступности remote раньше проверки файла ------------------
check_order "$SETUP_SCRIPT" \
    'if ! rclone lsd "$RCLONE_REMOTE"' \
    'grep -qxF "${BACKUP_NAME}' \
    'setup-control.sh: rclone lsd раньше проверки наличия бэкапа'

# --- 4. код возврата 3 (папки нет) отделён от прочих ошибок ----------------
if grep -q 'RCLONE_LSF_STATUS" -ne 0 && .* -ne 3' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: rc=3 обрабатывается отдельно от прочих ошибок'
else
    fail 'setup-control.sh: нет проверки "RCLONE_LSF_STATUS" -ne 0 && ... -ne 3'
fi

# --- 5. паритет констант ---------------------------------------------------
for const in RCLONE_REMOTE RCLONE_BACKUP_DIR RCLONE_CONFIG_FILE \
    RCLONE_TRANSFER_ARGS BACKUP_NAME SSH_KEY_FILE PROJECT_NAME; do

    backup_line="$(grep -m1 "^${const}=" "$BACKUP_SCRIPT")"
    setup_line="$(grep -m1 "^${const}=" "$SETUP_SCRIPT")"

    if [[ -n "$backup_line" && "$backup_line" == "$setup_line" ]]; then
        pass "константа $const одинакова в обоих скриптах"
    else
        fail "константа $const расходится: «${backup_line}» != «${setup_line}»"
    fi
done

# --- 6. нет обхода настройки rclone ----------------------------------------
if grep -q "Продолжить без rclone" "$SETUP_SCRIPT"; then
    fail 'setup-control.sh: остался обход «Продолжить без rclone»'
else
    pass 'setup-control.sh: обхода «Продолжить без rclone» нет'
fi

# --- 7. часовой пояс ----------------------------------------------------
if grep -q '^TIMEZONE="Europe/Moscow"' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: TIMEZONE="Europe/Moscow"'
else
    fail 'setup-control.sh: нет TIMEZONE="Europe/Moscow"'
fi

if grep -q 'timedatectl set-timezone' "$SETUP_SCRIPT" &&
    grep -q '/etc/localtime' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: timedatectl set-timezone + fallback /etc/localtime'
else
    fail 'setup-control.sh: нет timedatectl set-timezone и/или fallback /etc/localtime'
fi

check_order "$SETUP_SCRIPT" \
    'timedatectl set-timezone' \
    'log "Woodpecker CI"' \
    'setup-control.sh: секция timezone раньше woodpecker'

# Часовой пояс должен попадать и в контейнеры Woodpecker, иначе cron-задачи
# сервера срабатывают в UTC (со сдвигом на 3 часа относительно MSK).
if grep -q '^TIMEZONE=${TIMEZONE}$' "$SETUP_SCRIPT" &&
    grep -q 'TZ: ${TIMEZONE}' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: TZ прокидывается в контейнеры Woodpecker'
else
    fail 'setup-control.sh: нет TIMEZONE в .env и/или TZ: ${TIMEZONE} в compose'
fi

if grep -q '^ensure_woodpecker_tz()' "$SETUP_SCRIPT" &&
    grep -q '^ensure_woodpecker_tz$' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: ensure_woodpecker_tz для уже установленной инсталляции'
else
    fail 'setup-control.sh: нет идемпотентной доставки TZ в установленный Woodpecker'
fi

# --- 7b. cron-задачи Woodpecker --------------------------------------------
# Плановые бэкапы запускаются событием cron, а не manual/push.
for cron_pipeline in \
    'media_vm_backup.yml:Media-backup' \
    'nextcloud_backup.yml:Nextcloud-backup' \
    'traefik_backup.yml:Traefik-backup' \
    'valheim_backup.yml:Valheim-backup'; do
    pipeline_file="${cron_pipeline%%:*}"
    cron_name="${cron_pipeline##*:}"

    if grep -q 'event: cron' "$SCRIPTS_DIR/../.woodpecker/$pipeline_file" &&
        grep -q "cron: \"$cron_name\"" "$SCRIPTS_DIR/../.woodpecker/$pipeline_file"; then
        pass ".woodpecker/$pipeline_file: event cron ($cron_name)"
    else
        fail ".woodpecker/$pipeline_file: нет event: cron с именем $cron_name"
    fi
done

# --- 9. пользователи, sudo, пароли -----------------------------------------
# Две учётки: pi (человек, sudo+ключи) и piweb (сервис Pi Web, без привилегий).
if grep -q '^AGENT_USER_NAME="pi"' "$SETUP_SCRIPT" &&
    grep -q '^WEB_USER_NAME="piweb"' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: AGENT_USER_NAME="pi" + WEB_USER_NAME="piweb"'
else
    fail 'setup-control.sh: нет разделения AGENT_USER_NAME/WEB_USER_NAME'
fi

for frag in 'useradd --create-home' 'usermod --append --groups sudo' \
    '/etc/sudoers.d/90-' 'visudo -cf' 'chpasswd'; do

    if grep -qF "$frag" "$SETUP_SCRIPT"; then
        pass "setup-control.sh: есть «$frag»"
    else
        fail "setup-control.sh: нет «$frag»"
    fi
done

if grep -q 'ROOT_AUTH_KEYS="\$SSH_DIR/authorized_keys"' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: публичный ключ root пишется в authorized_keys'
else
    fail 'setup-control.sh: нет добавления ключа root в authorized_keys'
fi

# Пароли не должны попадать в аргументы командной строки.
if grep -qE 'chpasswd .*\$pass|echo .*\$pass' "$SETUP_SCRIPT"; then
    fail 'setup-control.sh: пароль передаётся в аргументах'
else
    pass 'setup-control.sh: пароль передаётся только через stdin chpasswd'
fi

check_order "$SETUP_SCRIPT" \
    'useradd --create-home' \
    'mapfile -t LOGIN_USERS' \
    'setup-control.sh: создание pi раньше удаления прочих пользователей'

# --- 10. pi agent и pi-web --------------------------------------------------
if grep -q '@earendil-works/pi-coding-agent' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: ставится pi coding agent'
else
    fail 'setup-control.sh: нет установки pi coding agent'
fi

if grep -q 'sha256sum -c' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: архив Node.js проверяется по sha256'
else
    fail 'setup-control.sh: скачивание Node.js без проверки sha256'
fi

if grep -q '@agegr/pi-web' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: Pi Web ставится из @agegr/pi-web'
else
    fail 'setup-control.sh: нет установки @agegr/pi-web'
fi

if grep -q -- '--allow-scripts=node-pty' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: node-pty разрешён точечно (--allow-scripts)'
else
    fail 'setup-control.sh: нет --allow-scripts=node-pty'
fi

# Отдельный каталог: бинарник pi-web не должен затирать другие реализации.
if grep -q 'PI_WEB_DIR="/opt/pi-web"' "$SETUP_SCRIPT" &&
    grep -q 'PI_WEB_BIN="\$PI_WEB_DIR/node_modules/.bin/pi-web"' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: Pi Web ставится в отдельный каталог /opt/pi-web'
else
    fail 'setup-control.sh: Pi Web не в отдельном каталоге'
fi

# Пароль обязателен при бинде наружу и не должен попадать в unit-файл.
if grep -q 'PI_WEB_PASS_FILE=' "$SETUP_SCRIPT" &&
    grep -q 'EnvironmentFile=' "$SETUP_SCRIPT" &&
    ! grep -qE '^Environment=PI_WEB_PASSWORD=' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: пароль Pi Web хранится в файле, а не в юните'
else
    fail 'setup-control.sh: пароль Pi Web не отделён от unit-файла'
fi

if grep -q 'PI_WEB_PASSWORD" > "\$PI_WEB_PASS_FILE"' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: пароль записывается в файл'
else
    fail 'setup-control.sh: пароль не записывается в файл'
fi

if grep -q 'umask 077' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: umask 077 перед записью пароля'
else
    fail 'setup-control.sh: нет umask 077 для файла пароля'
fi

# Адрес выбирается интерактивно; 0.0.0.0 не используется.
if grep -q 'PI_WEB_HOST=""' "$SETUP_SCRIPT" &&
    grep -q 'LAN-адрес этой машины' "$SETUP_SCRIPT" &&
    ! grep -qE 'PI_WEB_HOST="0\.0\.0\.0"' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: адрес Pi Web выбирается (LAN/loopback), 0.0.0.0 не используется'
else
    fail 'setup-control.sh: нет выбора адреса Pi Web или есть 0.0.0.0'
fi

if grep -q 'ip -4 route get' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: LAN-адрес определяется автоматически'
else
    fail 'setup-control.sh: нет автоопределения LAN-адреса'
fi

# Pi Web читает порт из PORT; PI_WEB_PORT он игнорирует (иначе слушает 30141
# независимо от настроек). Домены за reverse proxy идут в PI_WEB_ALLOWED_HOSTS.
if grep -q '^Environment=PORT=\$PI_WEB_PORT$' "$SETUP_SCRIPT" &&
    ! grep -q '^Environment=PI_WEB_PORT=' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: порт Pi Web передаётся через PORT'
else
    fail 'setup-control.sh: порт Pi Web не через PORT (PI_WEB_PORT игнорируется)'
fi

if grep -q 'PI_WEB_ALLOWED_HOSTS' "$SETUP_SCRIPT" &&
    grep -q 'Untrusted API request' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: домены reverse proxy попадают в PI_WEB_ALLOWED_HOSTS'
else
    fail 'setup-control.sh: нет PI_WEB_ALLOWED_HOSTS для домена за прокси'
fi

# system-level unit, но не от pi, а от низкопривилегированной учётки piweb.
if grep -q '/etc/systemd/system/pi-web.service' "$SETUP_SCRIPT" &&
    grep -q 'systemctl enable pi-web' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: Pi Web запускается systemd-сервисом'
else
    fail 'setup-control.sh: нет systemd-юнита для Pi Web'
fi

# Следы предыдущего варианта (jmfederico/pi-web) не должны остаться.
if grep -q 'jmfederico\|pi_web_as_user\|enable-linger\|pi-web-sessiond' "$SETUP_SCRIPT"; then
    fail 'setup-control.sh: остались следы jmfederico/pi-web'
else
    pass 'setup-control.sh: нет следов jmfederico/pi-web'
fi

# --- 11. разделение пользователей pi/piweb ---------------------------------
# Юнит Pi Web должен работать от сервисной учётки и нести блок хардненинга.
for frag in '^User=$WEB_USER_NAME$' '^Group=$WEB_USER_NAME$' \
    'Environment=PI_CODING_AGENT_DIR=$WEB_HOME/.pi/agent' \
    'NoNewPrivileges=yes' 'ProtectSystem=strict' 'InaccessiblePaths=-$AGENT_HOME' \
    'ReadWritePaths=$WEB_HOME $PIWEB_WORK_DIR' 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6' \
    'SystemCallFilter=@system-service' 'CapabilityBoundingSet=' 'UMask=0077'; do

    if grep -q -- "$frag" "$SETUP_SCRIPT"; then
        pass "setup-control.sh: в юните/скрипте есть «$frag»"
    else
        fail "setup-control.sh: нет «$frag»"
    fi
done

# Обязательно отсутствующие директивы: ProtectHome скрыл бы /home/piweb,
# MemoryDenyWriteExecute ломает JIT V8.
if grep -qE '^ProtectHome=|^MemoryDenyWriteExecute=' "$SETUP_SCRIPT"; then
    fail 'setup-control.sh: ProtectHome/MemoryDenyWriteExecute сломают Pi Web'
else
    pass 'setup-control.sh: нет ProtectHome и MemoryDenyWriteExecute'
fi

# Код сервиса принадлежит root: низкодоверенный процесс не правит свой же код.
if grep -q 'chown -R root:root "\$PI_WEB_DIR"' "$SETUP_SCRIPT" &&
    grep -q 'chmod -R go-w "\$PI_WEB_DIR"' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: /opt/pi-web принадлежит root и не writable'
else
    fail 'setup-control.sh: /opt/pi-web не защищён от записи сервисом'
fi

# npm install выполняется от root, а не от веб-учётки.
if grep -qE 'sudo -u "\$(WEB|AGENT)_USER_NAME".*npm install' "$SETUP_SCRIPT"; then
    fail 'setup-control.sh: npm install выполняется от пользователя'
else
    pass 'setup-control.sh: npm install выполняется от root'
fi

# sudo без пароля у pi остался бы риском: ключ человека = root.
if grep -qE "NOPASSWD: ALL" "$SETUP_SCRIPT"; then
    fail 'setup-control.sh: остался NOPASSWD: ALL в sudoers'
else
    pass 'setup-control.sh: sudoers без NOPASSWD: ALL'
fi

if grep -q "printf '%s ALL=(ALL:ALL) ALL" "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: pi получает sudo с паролем'
else
    fail 'setup-control.sh: нет правила sudo с паролем для pi'
fi

# Веб-учётка не должна попадать в привилегированные группы.
if grep -q 'usermod --append --groups sudo "\$WEB_USER_NAME"' "$SETUP_SCRIPT"; then
    fail 'setup-control.sh: WEB_USER_NAME добавлен в sudo'
else
    pass 'setup-control.sh: WEB_USER_NAME не добавляется в sudo'
fi

if grep -q 'nologin "\$WEB_USER_NAME"\|--shell /usr/sbin/nologin "\$WEB_USER_NAME"' "$SETUP_SCRIPT" &&
    grep -q 'passwd -l "\$WEB_USER_NAME"' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: piweb с nologin и заблокированным паролем'
else
    fail 'setup-control.sh: piweb без nologin/passwd -l'
fi

if grep -q 'install -d -m 0750 -o "\$WEB_USER_NAME" -g "\$WEB_USER_NAME" "\$PIWEB_WORK_DIR"' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: рабочий каталог /srv/work/piweb создаётся 0750'
else
    fail 'setup-control.sh: нет каталога /srv/work/piweb'
fi

# Перенос настроек живёт в отдельном скрипте: setup-control.sh его вызывает.
if grep -q 'sync-piweb-config.sh' "$SETUP_SCRIPT" &&
    grep -q -- '--from "$AGENT_HOME/.pi/agent"' "$SETUP_SCRIPT" &&
    grep -q -- '--to "$WEB_HOME/.pi/agent"' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: перенос настроек делегирован sync-piweb-config.sh'
else
    fail 'setup-control.sh: нет вызова sync-piweb-config.sh'
fi

if bash -n "$SYNC_PIWEB_SCRIPT" 2>/dev/null; then
    pass 'bash -n sync-piweb-config.sh'
else
    fail 'bash -n sync-piweb-config.sh'
fi

# Список переносимого ограничен конфигами: ни sessions, ни SSH-заметок.
if grep -q '^FILES=(' "$SYNC_PIWEB_SCRIPT" &&
    grep -q 'settings.json settings.jsonc keybindings.json' "$SYNC_PIWEB_SCRIPT"; then
    pass 'sync-piweb-config.sh: список файлов агента ограничен конфигами'
else
    fail 'sync-piweb-config.sh: нет ограниченного списка файлов'
fi

if grep -qE '^FILES=\(|^DIRS=\(' "$SYNC_PIWEB_SCRIPT" &&
    ! sed -n '/^FILES=(/,/^)/p;/^DIRS=(/,/^)/p' "$SYNC_PIWEB_SCRIPT" |
        grep -qE 'sessions|ssh-remote|pi-subagents|trust\.json|npm'; then
    pass 'sync-piweb-config.sh: sessions/ssh-remote/trust.json не переносятся'
else
    fail 'sync-piweb-config.sh: в списке переноса есть sessions/ssh-remote/trust.json'
fi

if grep -q 'pi-ssh-remote' "$SYNC_PIWEB_SCRIPT" &&
    grep -q 'удалено из packages' "$SYNC_PIWEB_SCRIPT"; then
    pass 'sync-piweb-config.sh: из settings.json вырезается pi-ssh-remote'
else
    fail 'sync-piweb-config.sh: pi-ssh-remote не вырезается из settings.json'
fi

# Симлинки в копию не попадают: они указывали бы в /home/pi.
if grep -q 'find "$dst" -type l -delete' "$SYNC_PIWEB_SCRIPT"; then
    pass 'sync-piweb-config.sh: симлинки удаляются из копии'
else
    fail 'sync-piweb-config.sh: симлинки не вычищаются из копии'
fi

# Цель не должна оказаться внутри домашнего каталога человека.
if grep -q 'цель не должна быть внутри' "$SYNC_PIWEB_SCRIPT"; then
    pass 'sync-piweb-config.sh: запрещена цель внутри /home/pi'
else
    fail 'sync-piweb-config.sh: нет проверки цели внутри /home/pi'
fi

# Файлы с правами 0600 и владельцем piweb.
if grep -q 'install -m 0600 -o "$WEB_USER" -g "$WEB_USER"' "$SYNC_PIWEB_SCRIPT"; then
    pass 'sync-piweb-config.sh: файлы ставятся 0600 piweb:piweb'
else
    fail 'sync-piweb-config.sh: файлы переносятся без владельца/прав'
fi

# Совместимость: setup-control.sh больше не правит settings.json сам.
if grep -q 'PIWEB_SETTINGS=' "$SETUP_SCRIPT"; then
    fail 'setup-control.sh: дублирует правку settings.json'
else
    pass 'setup-control.sh: правка settings.json не дублируется'
fi

# nftables: порт Pi Web только для доверенных источников.
if grep -q 'PIWEB_ALLOWED_SRC' "$SETUP_SCRIPT" &&
    grep -q 'nft -c -f' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: порт Pi Web ограничен через nftables'
else
    fail 'setup-control.sh: нет ограничения порта Pi Web через nftables'
fi

# Регрессия: restart nftables выполняет `flush ruleset` из /etc/nftables.conf
# и сносит цепочки DOCKER, которые dockerd создал при старте. Демон после этого
# не может публиковать порты: "iptables: No chain/target/match by that name".
if grep -vE '^\s*#' "$SETUP_SCRIPT" | grep -qE 'systemctl (restart|reload) nftables'; then
    fail 'setup-control.sh: restart nftables сносит цепочки Docker (flush ruleset)'
else
    pass 'setup-control.sh: nftables не перезапускается (цепочки Docker целы)'
fi

if grep -q 'nft -f /etc/nftables.d/piweb.nft' "$SETUP_SCRIPT" &&
    grep -q 'nft delete table inet piweb_guard' "$SETUP_SCRIPT"; then
    pass 'setup-control.sh: правило Pi Web применяется инкрементально (nft -f)'
else
    fail 'setup-control.sh: правило Pi Web не применяется инкрементально'
fi

# Проверки границ после запуска.
for frag in 'sudo -u "$WEB_USER_NAME" ls "$AGENT_HOME"' \
    'sudo -u "$WEB_USER_NAME" test -w "$PI_WEB_DIR"' \
    'sudo -u "$WEB_USER_NAME" sudo -n true' 'systemd-analyze security'; do

    if grep -q -- "$frag" "$SETUP_SCRIPT"; then
        pass "setup-control.sh: проверка «$frag»"
    else
        fail "setup-control.sh: нет проверки «$frag»"
    fi
done

# pi agent ставится раньше Pi Web.
check_order "$SETUP_SCRIPT" \
    'npm install -g --ignore-scripts' \
    'PI_WEB_PKG@latest' \
    'setup-control.sh: pi agent ставится раньше Pi Web'

# --- 8. загрузка с ретраями, а не с жёсткими таймаутами ---------------------
if grep -q 'rclone copyto' "$BACKUP_SCRIPT" &&
    awk '/rclone copyto/{f=1} f && /RCLONE_TRANSFER_ARGS/{found=1; exit} END{exit !found}' "$BACKUP_SCRIPT"; then
    pass 'backup-woodpecker.sh: загрузка использует RCLONE_TRANSFER_ARGS'
else
    fail 'backup-woodpecker.sh: rclone copyto без RCLONE_TRANSFER_ARGS (будет TLS timeout)'
fi

# --- 8. stub-прогон backup-скрипта -----------------------------------------
# rclone всегда падает => preflight обязан остановить скрипт ДО docker и sops.
run_stub_backup_test() {
    local tmp stub patched rc
    local docker_marker sops_marker

    tmp="$(mktemp -d)"
    stub="$tmp/bin"
    patched="$tmp/backup-patched.sh"
    docker_marker="$tmp/docker.marker"
    sops_marker="$tmp/sops.marker"

    mkdir -p "$stub"

    cat > "$stub/rclone" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB

    cat > "$stub/docker" <<STUB
#!/usr/bin/env bash
touch "$docker_marker"
exit 0
STUB

    cat > "$stub/sops" <<STUB
#!/usr/bin/env bash
touch "$sops_marker"
exit 0
STUB

    chmod 0755 "$stub/rclone" "$stub/docker" "$stub/sops"

    # root-проверка выключается, конфиг rclone указывает на пустой файл.
    sed -e 's|^if \[\[ \$EUID -ne 0 \]\]; then$|if false; then|' \
        -e "s|^RCLONE_CONFIG_FILE=.*|RCLONE_CONFIG_FILE=\"$tmp/empty-rclone.conf\"|" \
        "$BACKUP_SCRIPT" > "$patched"

    : > "$tmp/empty-rclone.conf"

    rc=0
    PATH="$stub:$PATH" bash "$patched" >"$tmp/out.log" 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        pass "stub-прогон backup-woodpecker.sh: rc=$rc (ожидался != 0)"
    else
        fail 'stub-прогон backup-woodpecker.sh: скрипт завершился с rc=0'
    fi

    if [[ -e "$docker_marker" ]]; then
        fail 'stub-прогон: docker вызван до preflight'
    else
        pass 'stub-прогон: docker не вызывался до preflight'
    fi

    if [[ -e "$sops_marker" ]]; then
        fail 'stub-прогон: sops вызван до preflight'
    else
        pass 'stub-прогон: sops не вызывался до preflight'
    fi

    rm -rf "$tmp"
}

run_stub_backup_test

# --- итог -------------------------------------------------------------------
echo ""

if [[ "$FAILED" -ne 0 ]]; then
    echo "ЕСТЬ ОШИБКИ"
    exit 1
fi

echo "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
