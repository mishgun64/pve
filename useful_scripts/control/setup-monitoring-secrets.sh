#!/usr/bin/env bash
# ============================================================================
# setup-monitoring-secrets.sh — заполнить секреты мониторинга в
# ansible/roles/monitoring/server/files/secrets.enc.yml (sops/age).
#
# Запускать там, где есть приватный ключ jenkins@control (обычно control_node):
#   sudo SOPS_AGE_SSH_PRIVATE_KEY_FILE=/root/.ssh/id_ed25519 \
#        ./useful_scripts/control/setup-monitoring-secrets.sh
#
# Значения секретов НЕ выводятся на экран и НЕ передаются аргументами
# командной строки (только интерактивный ввод или файлы).
#
# Что заполняет:
#   monitoring_alertmanager_telegram_bot_token  — @BotFather (бот @pve_mg_monitoring_bot)
#   monitoring_alertmanager_telegram_chat_id    — chat_id получателя/группы
#   monitoring_pve_api_user / token_name / token_value — read-only PVE-токен
#   monitoring_grafana_admin_password           — генерируется, если пусто
#
# Типовой порядок:
#   1) sudo ./useful_scripts/control/setup-pve-monitoring-token.sh
#   2) sudo ./useful_scripts/control/setup-monitoring-secrets.sh \
#          --pve-token-file /root/monitoring-pve-token.secret
#   3) git diff / commit / push
#
# Опции:
#   --file PATH                  путь к secrets.enc.yml (по умолчанию — в репо)
#   --bot-token-file FILE        прочитать bot_token из файла (первая строка)
#   --chat-id ID                 chat_id (не секрет; можно в аргументах)
#   --pve-user NAME              PVE-пользователь (по умолчанию monitoring@pve)
#   --pve-token-name NAME        имя токена (по умолчанию prometheus)
#   --pve-token-file FILE        прочитать секрет PVE-токена из файла
#   --grafana-password-file FILE задать пароль Grafana явно (иначе генерация)
#   --yes                        без интерактивных вопросов (что не задано — не менять)
#   --check                      только показать, что заполнено (rc=1 если не всё)
#   --show-grafana-password      напечатать пароль Grafana и выйти
#   -h, --help                   эта справка
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SECRETS_FILE="$REPO_ROOT/ansible/roles/monitoring/server/files/secrets.enc.yml"
BOT_TOKEN_FILE=""
CHAT_ID=""
PVE_USER=""
PVE_TOKEN_NAME=""
PVE_TOKEN_FILE=""
GRAFANA_PASSWORD_FILE=""
ASSUME_YES=0
CHECK_ONLY=0
SHOW_GRAFANA=0

KEY_BOT="monitoring_alertmanager_telegram_bot_token"
KEY_CHAT="monitoring_alertmanager_telegram_chat_id"
KEY_PVE_USER="monitoring_pve_api_user"
KEY_PVE_NAME="monitoring_pve_token_name"
KEY_PVE_TOKEN="monitoring_pve_token_value"
KEY_GRAFANA="monitoring_grafana_admin_password"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

# ---------------------------------------------------------------- helpers ---
# JSON-строка для `sops set` (значение никогда не попадает в argv/ps).
json_str() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))'
    else
        local s
        s="$(cat)"
        s="${s//\\/\\\\}"
        s="${s//\"/\\\"}"
        printf '"%s"\n' "$s"
    fi
}

sops_get() {
    sops -d --extract "[\"$1\"]" "$SECRETS_FILE" 2>/dev/null | tr -d '\r' || true
}

# sops set: значение передаётся через временный файл (--value-file),
# сам файл удаляется сразу после записи.
sops_set() {
    local key="$1" value="$2" tmp mode
    tmp="$(mktemp /tmp/monitoring-secret.XXXXXX)"
    chmod 600 "$tmp"
    mode="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || echo 644)"
    json_str <<<"$value" > "$tmp"
    if ! sops set --idempotent --value-file "$SECRETS_FILE" "[\"$key\"]" "$tmp"; then
        rm -f "$tmp"
        die "sops set завершился ошибкой для ключа $key"
    fi
    rm -f "$tmp"
    chmod "$mode" "$SECRETS_FILE" 2>/dev/null || true
}

read_secret() {
    local v=""
    if [[ -r /dev/tty ]]; then
        printf '%s' "$1" >&2
        IFS= read -rs v </dev/tty || true
        printf '\n' >&2
    fi
    printf '%s' "$v"
}

read_value() {
    local v=""
    if [[ -r /dev/tty ]]; then
        printf '%s' "$1" >&2
        IFS= read -r v </dev/tty || true
    fi
    printf '%s' "$v"
}

read_file_line() {
    local f="$1" v=""
    [[ -f "$f" ]] || die "файл не найден: $f"
    IFS= read -r v < "$f" || true
    v="${v%$'\r'}"
    printf '%s' "$v"
}

gen_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' | cut -c1-32
    fi
}

is_set() { [[ -n "${1:-}" && "${1}" != "CHANGE_ME" ]]; }

mask() {
    if ! is_set "${1:-}"; then
        printf 'НЕ ЗАДАН'
    else
        printf 'задан (%s симв.)' "${#1}"
    fi
}

# ----------------------------------------------------------------- options ---
while (($#)); do
    case "$1" in
        --file)                SECRETS_FILE="${2:?}"; shift 2 ;;
        --bot-token-file)      BOT_TOKEN_FILE="${2:?}"; shift 2 ;;
        --chat-id)             CHAT_ID="${2:?}"; shift 2 ;;
        --pve-user)            PVE_USER="${2:?}"; shift 2 ;;
        --pve-token-name)      PVE_TOKEN_NAME="${2:?}"; shift 2 ;;
        --pve-token-file)      PVE_TOKEN_FILE="${2:?}"; shift 2 ;;
        --grafana-password-file) GRAFANA_PASSWORD_FILE="${2:?}"; shift 2 ;;
        --yes)                 ASSUME_YES=1; shift ;;
        --check)               CHECK_ONLY=1; shift ;;
        --show-grafana-password) SHOW_GRAFANA=1; shift ;;
        -h|--help)             usage; exit 0 ;;
        *)                     die "неизвестная опция: $1 (см. --help)" ;;
    esac
done

# ---------------------------------------------------------------- preflight ---
command -v sops >/dev/null || die "sops не установлен"
[[ -f "$SECRETS_FILE" ]] || die "нет файла секретов: $SECRETS_FILE"

# sops не ищет ~/.ssh сам: подставляем ключ по умолчанию, если переменная не задана.
if [[ -z "${SOPS_AGE_SSH_PRIVATE_KEY_FILE:-}" && -f /root/.ssh/id_ed25519 ]]; then
    export SOPS_AGE_SSH_PRIVATE_KEY_FILE=/root/.ssh/id_ed25519
fi

if ! sops -d "$SECRETS_FILE" >/dev/null 2>&1; then
    die "не удалось расшифровать $SECRETS_FILE. Нужен приватный ключ jenkins@control:
     export SOPS_AGE_SSH_PRIVATE_KEY_FILE=/path/to/id_ed25519"
fi

log "файл секретов: $SECRETS_FILE"

if [[ $SHOW_GRAFANA -eq 1 ]]; then
    v="$(sops_get "$KEY_GRAFANA")"
    is_set "$v" || die "пароль Grafana не задан (запусти скрипт без --show-grafana-password)"
    printf '%s\n' "$v"
    exit 0
fi

cur_bot="$(sops_get "$KEY_BOT")"
cur_chat="$(sops_get "$KEY_CHAT")"
cur_pve_user="$(sops_get "$KEY_PVE_USER")"
cur_pve_name="$(sops_get "$KEY_PVE_NAME")"
cur_pve_token="$(sops_get "$KEY_PVE_TOKEN")"
cur_grafana="$(sops_get "$KEY_GRAFANA")"

if [[ $CHECK_ONLY -eq 1 ]]; then
    all_ok=1
    printf 'bot_token:   %s\n' "$(mask "$cur_bot")"
    printf 'chat_id:     %s\n' "$(if is_set "$cur_chat" && [[ "$cur_chat" != "0" ]]; then echo "задан ($cur_chat)"; else echo "НЕ ЗАДАН"; fi)"
    printf 'pve_user:    %s\n' "${cur_pve_user:-НЕ ЗАДАН}"
    printf 'pve_token:   %s\n' "$(mask "$cur_pve_token")"
    printf 'pve_tokname: %s\n' "${cur_pve_name:-НЕ ЗАДАН}"
    printf 'grafana_pw:  %s\n' "$(mask "$cur_grafana")"
    for v in "$cur_bot" "$cur_chat" "$cur_pve_user" "$cur_pve_name" "$cur_pve_token" "$cur_grafana"; do
        is_set "$v" || all_ok=0
    done
    [[ "$cur_chat" != "0" ]] || all_ok=0
    ((all_ok == 1))
    exit $?
fi

changed=0

# ---------------------------------------------------------------- bot token ---
new_bot=""
if [[ -n "$BOT_TOKEN_FILE" ]]; then
    new_bot="$(read_file_line "$BOT_TOKEN_FILE")"
    [[ -n "$new_bot" ]] || die "файл $BOT_TOKEN_FILE пуст"
elif ((ASSUME_YES == 0)) && [[ -r /dev/tty ]]; then
    printf 'Telegram bot_token (@pve_mg_monitoring_bot): %s\n' "$(mask "$cur_bot")" >&2
    new_bot="$(read_secret '  вставить токен из @BotFather (Enter — оставить как есть): ')"
fi
if [[ -n "$new_bot" ]]; then
    [[ "$new_bot" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]] ||
        log "WARNING: токен не похож на Telegram bot_token (ожидается '<id>:<35 симв.>')"
    if [[ "$new_bot" != "$cur_bot" ]]; then
        sops_set "$KEY_BOT" "$new_bot"
        log "bot_token: обновлён"
        changed=1
    else
        log "bot_token: без изменений"
    fi
fi

# ------------------------------------------------------------------- chat id ---
new_chat="$CHAT_ID"
if [[ -z "$new_chat" ]] && ((ASSUME_YES == 0)) && [[ -r /dev/tty ]]; then
    printf 'Telegram chat_id: %s\n' "$(if is_set "$cur_chat" && [[ "$cur_chat" != "0" ]]; then echo "$cur_chat"; else echo "НЕ ЗАДАН"; fi)" >&2
    new_chat="$(read_value '  chat_id (число; у групп отрицательное; Enter — оставить): ')"
fi
if [[ -n "$new_chat" ]]; then
    [[ "$new_chat" =~ ^-?[0-9]+$ ]] || die "chat_id должен быть числом: '$new_chat'"
    [[ "$new_chat" != "0" ]] || die "chat_id не может быть 0"
    if [[ "$new_chat" != "$cur_chat" ]]; then
        sops_set "$KEY_CHAT" "$new_chat"
        log "chat_id: $new_chat"
        changed=1
    else
        log "chat_id: без изменений"
    fi
fi

# ------------------------------------------------------------------- pve user ---
new_user="$PVE_USER"
if [[ -z "$new_user" ]] && ((ASSUME_YES == 0)) && [[ -r /dev/tty ]]; then
    new_user="$(read_value "PVE-пользователь [${cur_pve_user:-monitoring@pve}]: ")"
    [[ -n "$new_user" ]] || new_user="${cur_pve_user:-monitoring@pve}"
fi
if [[ -n "$new_user" && "$new_user" != "$cur_pve_user" ]]; then
    [[ "$new_user" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$ ]] ||
        die "PVE-пользователь должен быть в формате name@realm (например monitoring@pve)"
    sops_set "$KEY_PVE_USER" "$new_user"
    log "pve_user: $new_user"
    changed=1
fi

new_name="$PVE_TOKEN_NAME"
if [[ -z "$new_name" ]] && ((ASSUME_YES == 0)) && [[ -r /dev/tty ]]; then
    new_name="$(read_value "Имя PVE API-токена [${cur_pve_name:-prometheus}]: ")"
    [[ -n "$new_name" ]] || new_name="${cur_pve_name:-prometheus}"
fi
if [[ -n "$new_name" && "$new_name" != "$cur_pve_name" ]]; then
    [[ "$new_name" =~ ^[A-Za-z0-9._-]+$ ]] ||
        die "имя токена: только буквы/цифры/._-"
    sops_set "$KEY_PVE_NAME" "$new_name"
    log "pve_token_name: $new_name"
    changed=1
fi

# ------------------------------------------------------------- pve token value ---
new_pve_token=""
if [[ -n "$PVE_TOKEN_FILE" ]]; then
    new_pve_token="$(read_file_line "$PVE_TOKEN_FILE")"
    [[ -n "$new_pve_token" ]] || die "файл $PVE_TOKEN_FILE пуст"
elif ((ASSUME_YES == 0)) && [[ -r /dev/tty ]]; then
    printf 'PVE API-токен (secret): %s\n' "$(mask "$cur_pve_token")" >&2
    new_pve_token="$(read_secret '  вставить secret токена (Enter — оставить как есть): ')"
fi
if [[ -n "$new_pve_token" ]]; then
    [[ "$new_pve_token" =~ ^[A-Za-z0-9-]{16,}$ ]] ||
        log "WARNING: секрет PVE-токена обычно UUID (8-4-4-4-12)"
    if [[ "$new_pve_token" != "$cur_pve_token" ]]; then
        sops_set "$KEY_PVE_TOKEN" "$new_pve_token"
        log "pve_token_value: обновлён"
        changed=1
    else
        log "pve_token_value: без изменений"
    fi
fi

# --------------------------------------------------------------- grafana pw ---
new_grafana=""
if [[ -n "$GRAFANA_PASSWORD_FILE" ]]; then
    new_grafana="$(read_file_line "$GRAFANA_PASSWORD_FILE")"
    [[ ${#new_grafana} -ge 16 ]] || die "пароль Grafana короче 16 символов"
elif ! is_set "$cur_grafana"; then
    new_grafana="$(gen_password)"
fi
if [[ -n "$new_grafana" && "$new_grafana" != "$cur_grafana" ]]; then
    sops_set "$KEY_GRAFANA" "$new_grafana"
    log "grafana admin password: обновлён (посмотреть: $0 --show-grafana-password)"
    changed=1
fi

# Если пользователь/имя токена не заполнены — подставить значения по умолчанию
# из defaults роли (не перезаписывая уже заданные).
if ! is_set "$(sops_get "$KEY_PVE_USER")"; then
    sops_set "$KEY_PVE_USER" "monitoring@pve"
    changed=1
fi
if ! is_set "$(sops_get "$KEY_PVE_NAME")"; then
    sops_set "$KEY_PVE_NAME" "prometheus"
    changed=1
fi

# ---------------------------------------------------------------- verify ---
final_bot="$(sops_get "$KEY_BOT")"
final_chat="$(sops_get "$KEY_CHAT")"
final_user="$(sops_get "$KEY_PVE_USER")"
final_name="$(sops_get "$KEY_PVE_NAME")"
final_pve_token="$(sops_get "$KEY_PVE_TOKEN")"
final_grafana="$(sops_get "$KEY_GRAFANA")"

echo >&2
printf '  bot_token:   %s\n' "$(mask "$final_bot")" >&2
printf '  chat_id:     %s\n' "$(if is_set "$final_chat" && [[ "$final_chat" != "0" ]]; then echo "$final_chat"; else echo "НЕ ЗАДАН"; fi)" >&2
printf '  pve_user:    %s\n' "${final_user:-НЕ ЗАДАН}" >&2
printf '  pve_token:   %s\n' "$(mask "$final_pve_token")" >&2
printf '  grafana_pw:  %s\n' "$(mask "$final_grafana")" >&2
echo >&2

missing=0
is_set "$final_bot" || { log "не задан bot_token"; missing=1; }
{ is_set "$final_chat" && [[ "$final_chat" != "0" ]]; } || { log "не задан chat_id"; missing=1; }
is_set "$final_pve_token" || { log "не задан pve_token_value (см. setup-pve-monitoring-token.sh)"; missing=1; }
is_set "$final_grafana" || { log "не задан grafana admin password"; missing=1; }

if ((missing == 1)); then
    die "секреты заполнены не полностью; monitoring/server упадёт на проверке"
fi

log "готово$( ((changed == 1)) && echo ', файл обновлён')"
log "дальше: git diff -- $SECRETS_FILE && git add ... && git commit && git push"
if [[ -n "$PVE_TOKEN_FILE" ]]; then
    log "файл с PVE-токеном можно удалить: shred -u '$PVE_TOKEN_FILE'"
fi
log "пароль Grafana: $0 --show-grafana-password"