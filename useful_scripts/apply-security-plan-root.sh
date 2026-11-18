#!/usr/bin/env bash
# Применение root-мер плана аудита SECURITY-AUDIT-PLAN.md на control-ноде
# (pi.mishgun.com, 192.168.2.200). Запускать от root: sudo ./apply-security-plan-root.sh
#
# Что делает (п.1.2, п.3.4, п.4, п.5, п.6.1, п.7.1):
#   1. Pi Web unit: ReadWritePaths — ротация preview-секретов становится возможной
#      (перезапуск pi-web НЕ выполняется автоматически: убьёт активную сессию агента).
#   2. sshd: PermitRootLogin prohibit-password, X11Forwarding no.
#   3. nftables: инкрементальная таблица control_guard — 22 только с админ-адресов,
#      8000 (Woodpecker) только с Traefik LXC. Инкрементально, без flush ruleset
#      (иначе сносятся цепочки DOCKER-*).
#   4. crontab root: одно задание apt update/upgrade c noninteractive, force-confold,
#      логом и проверкой reboot; дубли старого задания удаляются.
#   5. /srv/backups: 0700 root:root, файлы без записи для group/other;
#      существующие santa_bot_*.tar.gz шифруются в *.tar.gz.enc (sops/age).
#   6. Woodpecker compose: WOODPECKER_OPEN=false, SWAGGER=false,
#      USER_REGISTERED_AGENTS=false, порт только на IP control.
#
# Чего НЕ делает (см. SECURITY-AUDIT-PLAN.md, п.9 и п.10):
#   - ротацию ключей/паролей, приватность GitHub-репозитория, DNS-записи,
#   - установку fail2ban/auditd (п.7.2 — отдельным шагом, с настройкой),
#   - полный policy drop на input/forward (нужна ревизия всех сервисов;
#     сейчас ограничиваются конкретные порты — 22/8000/30141).
set -u
umask 077

if [[ $EUID -ne 0 ]]; then
    echo "Запускать от root: sudo $0" >&2
    exit 1
fi

# ---------------------------------------------------------------- настройки ---
# Откуда разрешён SSH (22). 192.168.1.0/24 — админ-сеть, 192.168.2.0/24 — LAN.
# ПОСЛЕ проверки, откуда реально ходит администратор, сузить список!
SSH_SOURCES=("192.168.1.0/24" "192.168.2.0/24")

TRAEFIK_IP="192.168.2.3"          # единственный клиент для 8000 (Woodpecker UI/API)
CONTROL_IP="192.168.2.200"
WP_DIR="/opt/woodpecker"
PI_WEB_UNIT="/etc/systemd/system/pi-web.service"
APT_LOG="/var/log/apt-upgrade.log"
SANTA_BACKUP_DIR="/srv/backups/santa_bot"
# age-recipient для шифрования бэкапов santa_bot: публичный ключ деплоя CI
# (публичная половина ssh_key; приватная только в Woodpecker secrets).
SANTA_AGE_RECIPIENT="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOrAkVqWbPt82Bc0CRPjzGgvpVqmuqkdAQLjZQwxgoVd"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ОШИБКА: $*"; exit 1; }

# ------------------------------------------------------- 1. Pi Web unit (п.1) --
if [[ -f "$PI_WEB_UNIT" ]]; then
    if grep -q 'ReadWritePaths=/home/pi -/opt/pi-web/.next/cache' "$PI_WEB_UNIT"; then
        cp -a "$PI_WEB_UNIT" "${PI_WEB_UNIT}.bak-security-plan"
        sed -i 's|^ReadWritePaths=/home/pi -/opt/pi-web/.next/cache$|ReadWritePaths=/home/pi /opt/pi-web/.next/cache /opt/pi-web/node_modules/@agegr/pi-web/.next|' "$PI_WEB_UNIT"
        systemctl daemon-reload
        log "pi-web.service: ReadWritePaths обновлён (бэкап: ${PI_WEB_UNIT}.bak-security-plan)"
        log "ВНИМАНИЕ: перезапусти pi-web вручную в удобный момент:"
        log "    systemctl restart pi-web   # перезапуск завершит активную сессию агента!"
        log "После перезапуска в логе НЕ должно быть 'could not rotate ... preview-mode secrets':"
        log "    journalctl -u pi-web -n 50 | grep -i rotate"
    else
        log "pi-web.service: ReadWritePaths уже обновлён или отличается — пропускаю"
    fi
else
    log "pi-web.service не найден — пропускаю п.1"
fi

# ------------------------------------------------------- 2. sshd (п.6.1) ------
SSHD_CONF="/etc/ssh/sshd_config"
if grep -q '^PermitRootLogin yes' "$SSHD_CONF" || grep -q '^X11Forwarding yes' "$SSHD_CONF"; then
    cp -a "$SSHD_CONF" "${SSHD_CONF}.bak-security-plan"
    sed -i 's|^PermitRootLogin yes$|PermitRootLogin prohibit-password|; s|^X11Forwarding yes$|X11Forwarding no|' "$SSHD_CONF"
    if sshd -t 2>&1; then
        systemctl restart ssh || systemctl restart sshd || die "рестарт ssh не удался (конфиг корректен, проверь сервис)"
        log "sshd: PermitRootLogin prohibit-password, X11Forwarding no — применено"
        log "ВНИМАНИЕ: НЕ закрывай текущую SSH-сессию, пока не проверишь вход с паролем root: он должен стать невозможен, вход по ключу — работать."
    else
        cp -a "${SSHD_CONF}.bak-security-plan" "$SSHD_CONF"
        die "sshd -t не прошёл — конфиг откатан, ssh не перезапущен"
    fi
else
    log "sshd: настройки уже применены — пропускаю"
fi

# ------------------------------------------------------- 3. nftables (п.4) ----
# Отдельная таблица с приоритетом -15: не трогает piweb_guard (-10) и DOCKER-*.
# Инкрементально: nft -f только своей таблицы, никакого flush ruleset.
install -d -m 0755 /etc/nftables.d

{
    echo '#!/usr/sbin/nft -f'
    echo '# Сгенерировано apply-security-plan-root.sh (п.4 плана аудита).'
    echo '# 22 — только с админ-адресов; 8000 (Woodpecker) — только с Traefik.'
    echo '# 30141 (Pi Web) уже ограничен таблицей piweb_guard.'
    echo 'table inet control_guard {'
    echo '    set ssh_sources {'
    echo '        type ipv4_addr'
    echo '        flags interval'
    echo '        elements = { '"$(IFS=, ; echo "${SSH_SOURCES[*]}")"' }'
    echo '    }'
    echo ''
    echo '    chain input {'
    echo '        type filter hook input priority -15; policy accept;'
    echo ''
    echo '        iif "lo" accept'
    echo '        ct state established,related accept'
    echo '        ip protocol icmp accept'
    echo '        ip6 nexthdr ipv6-icmp accept'
    echo ''
    echo "        tcp dport 22 ip saddr @ssh_sources accept"
    echo '        tcp dport 22 drop'
    echo ''
    echo "        tcp dport 8000 ip saddr $TRAEFIK_IP accept"
    echo '        tcp dport 8000 drop'
    echo '    }'
    echo '}'
} > /etc/nftables.d/control-guard.nft
chmod 0644 /etc/nftables.d/control-guard.nft

NFT_CHECK="$(mktemp /tmp/nft-check.XXXXXX)"
{ printf 'flush ruleset\n'; cat /etc/nftables.d/control-guard.nft; } > "$NFT_CHECK"
if ! nft -c -f "$NFT_CHECK"; then
    rm -f "$NFT_CHECK"
    die "/etc/nftables.d/control-guard.nft не прошёл nft -c"
fi
rm -f "$NFT_CHECK"

if ! grep -qF 'include "/etc/nftables.d/*.nft"' /etc/nftables.conf 2>/dev/null; then
    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> /etc/nftables.conf
fi

nft delete table inet control_guard 2>/dev/null || true
nft -f /etc/nftables.d/control-guard.nft || die "не удалось загрузить control_guard"
nft list table inet control_guard >/dev/null 2>&1 && log "nftables: control_guard загружен (22: ${SSH_SOURCES[*]}; 8000: $TRAEFIK_IP)"

# ------------------------------------------------------- 4. crontab (п.7.1) ---
APT_JOB='0 6 * * * { DEBIAN_FRONTEND=noninteractive apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q -o Dpkg::Options::="--force-confold" && DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -q && apt-get autoclean -q; newest_kernel=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -1); [ "$(uname -r)" = "$newest_kernel" ] || echo "REBOOT REQUIRED: running $(uname -r), newest installed $newest_kernel"; } >> /var/log/apt-upgrade.log 2>&1'

CURRENT="$(crontab -l 2>/dev/null || true)"
NEW="$(grep -vE 'apt (update|upgrade)|apt-get (update|upgrade)' <<<"$CURRENT" || true)"
if grep -qxF "$APT_JOB" <<<"$NEW"; then
    log "crontab: hardened apt-задание уже стоит"
else
    { [[ -n "$NEW" ]] && printf '%s\n' "$NEW"; printf '%s\n' "#Ansible: Update, upgrade and reboot"; printf '%s\n' "$APT_JOB"; } | crontab -
    log "crontab: apt-задание заменено на hardened (лог: $APT_LOG), дубли удалены"
fi

# ------------------------------------------------------- 5. /srv/backups (п.5) -
if [[ -d /srv/backups ]]; then
    chmod 700 /srv/backups
    find /srv/backups -xdev -type f -perm /022 -exec chmod go-w {} \;
    log "/srv/backups: 0700, с файлов снята запись group/other"
fi

if [[ -d "$SANTA_BACKUP_DIR" ]] && command -v sops >/dev/null; then
    shopt -s nullglob
    for f in "$SANTA_BACKUP_DIR"/santa_bot_*.tar.gz; do
        [[ -e "${f}.enc" ]] && continue
        if sops --age "$SANTA_AGE_RECIPIENT" --input-type binary --output-type binary -e "$f" > "${f}.enc"; then
            chmod 600 "$f" "${f}.enc"
            log "бэкапы: $f зашифрован -> ${f}.enc (оригинал оставлен с chmod 600 — после проверки расшифровки удали его)"
        else
            rm -f "${f}.enc"
            log "бэкапы: НЕ удалось зашифровать $f — см. вывод sops"
        fi
    done
    shopt -u nullglob
fi

# ------------------------------------------------------- 6. Woodpecker (п.3) ---
if [[ -f "$WP_DIR/docker-compose.yml" ]]; then
    cp -a "$WP_DIR/docker-compose.yml" "$WP_DIR/docker-compose.yml.bak-security-plan"

    # Явные override: старые значения .env перекрываются напрямую
    # (WOODPECKER_OPEN=true при WOODPECKER_ADMIN=mishgun64 = открытая регистрация)
    sed -i 's|^      WOODPECKER_OPEN: .*|      WOODPECKER_OPEN: "false"|' "$WP_DIR/docker-compose.yml"
    if ! grep -q 'WOODPECKER_ENABLE_SWAGGER' "$WP_DIR/docker-compose.yml"; then
        sed -i '/WOODPECKER_OPEN: /a\      WOODPECKER_ENABLE_SWAGGER: "false"\n      WOODPECKER_USER_REGISTERED_AGENTS: "false"' "$WP_DIR/docker-compose.yml"
    fi

    # Порт: только на IP control (наружу ходит Traefik через LAN; дополнительно
    # закрыт nftables control_guard: 8000 только с $TRAEFIK_IP)
    sed -i 's|^      - "8000:8000"$|      - "'"$CONTROL_IP"':8000:8000"|' "$WP_DIR/docker-compose.yml"

    log "Woodpecker compose обновлён (бэкап: $WP_DIR/docker-compose.yml.bak-security-plan)"
    log "TODO (п.3.2): убрать монтирование /var/run/docker.sock у агента — нужен dind или отдельная VM/LXC; сейчас сокет оставлен, иначе CI встанет."
    if command -v docker >/dev/null; then
        ( cd "$WP_DIR" && docker compose up -d ) && log "Woodpecker перезапущен с новыми настройками"
    fi
else
    log "$WP_DIR/docker-compose.yml не найден — пропускаю п.6"
fi

# ---------------------------------------------------------------- итог --------
log ""
log "Готово. Осталось вручную (см. SECURITY-AUDIT-PLAN.md п.9):"
log "  - systemctl restart pi-web (после правки unit, удобный момент)"
log "  - ротация ключей/паролей: провайдеры API, Pi Web, pi@control, root@control, PVE, Prosody, Traefik admin"
log "  - ansible/group_vars/all/vault.yml из vault.yml.example + ansible-vault encrypt"
log "  - GitHub: репозиторий приватным / чистка истории (git filter-repo) + force-push"
log "  - DNS: убрать xmpp/upload/prosody.mishgun.com; LXC prosody (144) заархивировать и вывести"
log "  - deploy Traefik-конфига (CI: traefik/config) — закроет обход авторизации на периметре"
log "  - fail2ban/auditd (п.7.2), git push с новым конфигом, затем проверить"
log "    curl -H 'x-prerender-revalidate: ...' https://pi.mishgun.com/api/sessions -> 401"
log ""
log "Проверка признаков эксплуатации (п.1.5) — выполни после deploy Traefik:"
log "  journalctl -u pi-web --since 2026-11-17 | grep -E 'api/terminal|api/sessions|api/models-config|x-prerender-revalidate'"
log "  grep x-prerender-revalidate /home/docker/traefik/logs/access.log  # на traefik LXC"
