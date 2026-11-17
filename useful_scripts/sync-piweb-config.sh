#!/usr/bin/env bash
# ============================================================================
# sync-piweb-config.sh — перенос настроек pi agent из /home/pi в /home/piweb.
#
# Pi Web работает от отдельной учётки piweb, которой домашний каталог pi
# недоступен (0700 pi:pi + InaccessiblePaths в юните). Поэтому настройки не
# «видны» сервису, а копируются — и только те, что безопасны для веб-агента.
#
# Переносится: settings.json, models.json, models-store.json, auth.json,
#              mcp.json, mcp-auth.json, AGENTS.md, data/, extensions/, skills/,
#              prompts/, themes/
# НЕ переносится: sessions/ (история с cwd /home/pi и возможными секретами),
#              ssh-remote-memories/, ssh-remote-*.json, pi-subagents/, trust.json,
#              npm/, pi-web-*.json, web-push.json, bin/ (машинозависимо).
# Из settings.json вырезается npm:pi-ssh-remote — у веб-учётки нет SSH.
#
# Запуск: sudo ./sync-piweb-config.sh
#         sudo ./sync-piweb-config.sh --dry-run
#         sudo ./sync-piweb-config.sh --no-backup
#
# Содержимое конфигов не печатается: только имена файлов и размеры.
# ============================================================================
set -euo pipefail

AGENT_USER="pi"
WEB_USER="piweb"
SOURCE_DIR=""
TARGET_DIR=""
DRY_RUN=0
DO_BACKUP=1
RESTART=0
OWN_UNIT="/etc/systemd/system/pi-web.service"

# Файлы верхнего уровня, которые безопасно отдать веб-агенту.
FILES=(
    settings.json settings.jsonc keybindings.json
    models.json models-store.json auth.json
    mcp.json mcp-auth.json
    AGENTS.md AGENTS.override.md CLAUDE.md SYSTEM.md APPEND_SYSTEM.md
)

# Каталоги, которые можно копировать целиком.
DIRS=(
    data
    extensions
    skills
    prompts
    themes
)

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
sync-piweb-config.sh — перенести настройки pi agent из /home/pi в /home/piweb.

Pi Web работает от учётки piweb, а /home/pi для неё закрыт (0700 + systemd
InaccessiblePaths). Настройки поэтому копируются, а не разделяются.

Опции:
  --from DIR          каталог настроек агента (по умолчанию /home/pi/.pi/agent)
  --to DIR            целевой каталог (по умолчанию /home/piweb/.pi/agent)
  --agent-user NAME   владелец источника (по умолчанию pi)
  --web-user NAME     владелец цели (по умолчанию piweb)
  --dry-run           показать план, ничего не менять
  --no-backup         не делать резервную копию целевого каталога
  --restart           перезапустить pi-web.service после переноса
  -h, --help          эта справка

Не переносятся: sessions/, ssh-remote-memories/, ssh-remote-*.json,
pi-subagents/, trust.json, npm/, pi-web-*.json, web-push.json, bin/.
Из settings.json удаляется npm:pi-ssh-remote (веб-агент без SSH).
============================================================================
EOF
}

while (($#)); do
    case "$1" in
        --from)         SOURCE_DIR=${2:?}; shift 2 ;;
        --to)           TARGET_DIR=${2:?}; shift 2 ;;
        --agent-user)   AGENT_USER=${2:?}; shift 2 ;;
        --web-user)     WEB_USER=${2:?}; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --no-backup)    DO_BACKUP=0; shift ;;
        --restart)      RESTART=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              fail "неизвестная опция: $1 (см. --help)" ;;
    esac
done

[[ $DRY_RUN -eq 1 ]] || [[ $EUID -eq 0 ]] ||
    fail "запусти от root: sudo $0 $*"

getent passwd "$WEB_USER" >/dev/null 2>&1 ||
    fail "нет пользователя $WEB_USER (сначала setup-control.sh)"

: "${SOURCE_DIR:=/home/$AGENT_USER/.pi/agent}"
: "${TARGET_DIR:=/home/$WEB_USER/.pi/agent}"

[[ -d "$SOURCE_DIR" ]] || fail "нет каталога источника: $SOURCE_DIR"

if [[ "$(cd "$SOURCE_DIR" && pwd -P)" == "$(cd "$TARGET_DIR" 2>/dev/null && pwd -P)" ]]; then
    fail "источник и цель совпадают: $SOURCE_DIR"
fi

# Целевой каталог не должен лежать внутри /home/<agent-user>: это означало бы,
# что веб-агенту снова нужен доступ к домашнему каталогу человека.
AGENT_HOME_RESOLVED="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
if [[ -n "$AGENT_HOME_RESOLVED" && "$TARGET_DIR" == "$AGENT_HOME_RESOLVED"/* ]]; then
    fail "цель не должна быть внутри $AGENT_HOME_RESOLVED (разделение учёток)"
fi

log "источник: $SOURCE_DIR"
log "цель:     $TARGET_DIR (владелец $WEB_USER)"

if [[ $DRY_RUN -eq 1 ]]; then
    log "режим --dry-run: изменения не вносятся"
fi

# ------------------------------------------------------------------ backup ---
if [[ $DO_BACKUP -eq 1 && $DRY_RUN -eq 0 && -d "$TARGET_DIR" ]] &&
    [[ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]]; then
    STAMP="$(date '+%Y%m%d-%H%M%S')"
    BACKUP_FILE="/var/backups/piweb-agent-config-$STAMP.tar.gz"

    # Только создать при отсутствии: chmod существующего /var/backups не наше дело.
    [[ -d /var/backups ]] || install -d -m 0700 /var/backups

    if tar -C "$(dirname "$TARGET_DIR")" -czf "$BACKUP_FILE" \
        "$(basename "$TARGET_DIR")" 2>/dev/null; then
        chmod 0600 "$BACKUP_FILE"
        log "резервная копия цели: $BACKUP_FILE"
    else
        rm -f "$BACKUP_FILE"
        fail "не удалось создать резервную копию $TARGET_DIR"
    fi
fi

# ------------------------------------------------------------- target dirs ---
if [[ $DRY_RUN -eq 0 ]]; then
    install -d -m 0700 -o "$WEB_USER" -g "$WEB_USER" "$(dirname "$TARGET_DIR")"
    install -d -m 0700 -o "$WEB_USER" -g "$WEB_USER" "$TARGET_DIR"
fi

# ------------------------------------------------------------------- files ---
COPIED=0
SKIPPED=0

for name in "${FILES[@]}"; do
    src="$SOURCE_DIR/$name"

    [[ -f "$src" ]] || continue

    dst="$TARGET_DIR/$name"
    size="$(stat -c %s "$src")"

    if [[ $DRY_RUN -eq 1 ]]; then
        log "  перенёс бы: $name ($size байт)"
        COPIED=$((COPIED + 1))
        continue
    fi

    if install -m 0600 -o "$WEB_USER" -g "$WEB_USER" "$src" "$dst"; then
        log "  перенесён: $name ($size байт)"
        COPIED=$((COPIED + 1))
    else
        log "  ВНИМАНИЕ: не удалось перенести $name"
        SKIPPED=$((SKIPPED + 1))
    fi
done

# -------------------------------------------------------------------- dirs ---
for name in "${DIRS[@]}"; do
    src="$SOURCE_DIR/$name"

    [[ -d "$src" ]] || continue

    # Каталоги настроек могут содержать скрипты и симлинки на пути из /home/pi.
    # Симлинки не копируем: для piweb они всё равно недоступны, а ссылка на
    # чужой домашний каталог — лишняя дверь.
    if [[ -n "$(find "$src" -type l -print -quit 2>/dev/null)" ]]; then
        log "  ВНИМАНИЕ: в $name есть симлинки — они будут удалены из копии"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log "  перенёс бы каталог: $name/"
        continue
    fi

    dst="$TARGET_DIR/$name"

    if [[ -d "$dst" ]]; then
        # Существующий каталог не затираем целиком: досыпаем недостающее.
        if cp -a --no-clobber "$src/." "$dst/" 2>/dev/null; then
            log "  дополнен каталог: $name/ (существующее не перезаписано)"
        else
            log "  ВНИМАНИЕ: каталог $name/ скопирован частично"
        fi
    elif cp -a "$src" "$dst" 2>/dev/null; then
        log "  перенесён каталог: $name/"
    else
        log "  ВНИМАНИЕ: не удалось перенести каталог $name/"
        SKIPPED=$((SKIPPED + 1))
    fi

    chown -R "$WEB_USER:$WEB_USER" "$dst" 2>/dev/null || true
    chmod -R go-rwx "$dst" 2>/dev/null || true

    # Убираем симлинки (в том числе на /home/<agent-user>): find -follow не нужен,
    # -type l видит только сами ссылки.
    if [[ -n "$(find "$dst" -type l -print -quit 2>/dev/null)" ]]; then
        find "$dst" -type l -delete 2>/dev/null || true
        log "  симлинки в $name/ удалены из копии"
    fi
done

# --------------------------------------------------------- settings.json ---
SETTINGS="$TARGET_DIR/settings.json"

if [[ -f "$SETTINGS" && $DRY_RUN -eq 0 ]]; then
    if command -v node >/dev/null 2>&1; then
        # set -e не должен ронять скрипт на кодах 2/3 — они информативные.
        rc=0
        node - "$SETTINGS" <<'NODE' || rc=$?
const fs = require("fs");
const file = process.argv[2];

const drop = (entry) => {
    const src = typeof entry === "string" ? entry : entry && entry.source;
    return typeof src === "string" && /pi-ssh-remote/.test(src);
};

let cfg;
try {
    cfg = JSON.parse(fs.readFileSync(file, "utf8"));
} catch {
    process.exit(1);
}

if (!Array.isArray(cfg.packages)) process.exit(2);

const kept = cfg.packages.filter((entry) => !drop(entry));
const removed = cfg.packages.length - kept.length;

if (removed === 0) process.exit(3);

cfg.packages = kept;
fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n", { mode: 0o600 });
fs.chmodSync(file, 0o600);
console.log(`удалено из packages: ${removed} (pi-ssh-remote)`);
NODE

        case "$rc" in
            0) : ;;
            1) log "  ВНИМАНИЕ: settings.json не разобран как JSON — оставлен как есть" ;;
            2) log "  settings.json: нет списка packages" ;;
            3) log "  settings.json: pi-ssh-remote отсутствует" ;;
            *) log "  ВНИМАНИЕ: правка settings.json завершилась с rc=$rc" ;;
        esac
    else
        log "  ВНИМАНИЕ: node не найден — вырежи pi-ssh-remote из settings.json вручную"
    fi

    chown "$WEB_USER:$WEB_USER" "$SETTINGS" 2>/dev/null || true
    chmod 0600 "$SETTINGS" 2>/dev/null || true
fi

# ------------------------------------------------------------- ssh remote ---
if [[ -f "$TARGET_DIR/settings.json" ]] &&
    grep -q 'pi-ssh-remote' "$TARGET_DIR/settings.json" 2>/dev/null; then
    log "ВНИМАНИЕ: в settings.json веб-агента остался pi-ssh-remote — убери вручную"
fi

for name in ssh-remote-config.json ssh-remote-known-hosts.json; do
    if [[ -f "$TARGET_DIR/$name" ]]; then
        log "ВНИМАНИЕ: в $TARGET_DIR есть $name — веб-агент не должен ходить по SSH"
    fi
done

# ------------------------------------------------------------------ итог ---
log "готово: перенесено $COPIED, проблем $SKIPPED"

cat <<EOF

Не перенесено намеренно:
  sessions/              история переписок и cwd из /home/$AGENT_USER
  ssh-remote-memories/   заметки и эндпоинты SSH
  pi-subagents/          требует SSH-профилей
  trust.json             решения привязаны к путям /home/$AGENT_USER
  npm/                   переустанавливается при первом запуске
  bin/, pi-web-*.json    машинозависимое состояние

Ключи провайдеров и токены MCP скопированы от $AGENT_USER — по плану стоит
завести отдельные (с лимитом расходов), чтобы ротация была дешёвой.

Проверить и применить:
  sudo diff -r /home/$AGENT_USER/.pi/agent $TARGET_DIR 2>/dev/null | head
  sudo systemctl restart pi-web
EOF

if [[ $RESTART -eq 1 && $DRY_RUN -eq 0 ]]; then
    log "перезапускаю pi-web.service"
    systemctl restart pi-web.service
    systemctl is-active --quiet pi-web.service &&
        log "pi-web.service активен" ||
        fail "pi-web.service не поднялся (journalctl -u pi-web -n 50)"
fi
