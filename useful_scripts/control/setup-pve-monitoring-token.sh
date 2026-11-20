#!/usr/bin/env bash
# ============================================================================
# setup-pve-monitoring-token.sh — создать на Proxmox VE read-only пользователя
# и API-токен для pve_exporter (мониторинг LXC/VM).
#
# Что делает (идемпотентно):
#   1. создаёт пользователя monitoring@pve (realm PVE), если его нет;
#   2. выпускает API-токен monitoring@pve!prometheus с privsep=1;
#   3. выдаёт токену роль PVEAuditor на "/" (у токена свои права, у юзера — нет);
#   4. проверяет токен запросом к PVE API;
#   5. пишет секрет токена в файл 0600 (в терминал значение НЕ выводится).
#
# По умолчанию работает по SSH с control_node на PVE (192.168.2.2).
# На самом PVE: добавь --local.
#
#   sudo ./useful_scripts/control/setup-pve-monitoring-token.sh
#   sudo ./useful_scripts/control/setup-pve-monitoring-token.sh --rotate
#   sudo ./useful_scripts/control/setup-pve-monitoring-token.sh --check
#   sudo ./useful_scripts/control/setup-pve-monitoring-token.sh --local
#
# После создания:
#   sudo ./useful_scripts/control/setup-monitoring-secrets.sh \
#        --pve-token-file /root/monitoring-pve-token.secret
#   shred -u /root/monitoring-pve-token.secret
#
# Опции:
#   --pve-host HOST       адрес PVE для ssh (по умолчанию 192.168.2.2)
#   --ssh-user USER       ssh-пользователь (по умолчанию root)
#   --ssh-key FILE        приватный ключ для ssh (по умолчанию — агент/дефолт)
#   --pve-user USER       PVE-пользователь (по умолчанию monitoring@pve)
#   --token-name NAME     имя токена (по умолчанию prometheus)
#   --out FILE            куда записать секрет (по умолчанию /root/monitoring-pve-token.secret)
#   --local               выполнять pveum локально (запуск на PVE)
#   --rotate              перевыпустить токен (старый будет удалён)
#   --check               только проверить наличие юзера/токена (ничего не менять)
#   -h, --help            эта справка
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PVE_HOST="192.168.2.2"
SSH_USER="root"
SSH_KEY=""
PVE_USER="monitoring@pve"
TOKEN_NAME="prometheus"
OUT_FILE="/root/monitoring-pve-token.secret"
LOCAL=0
ROTATE=0
MODE="apply"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

while (($#)); do
    case "$1" in
        --pve-host)   PVE_HOST="${2:?}"; shift 2 ;;
        --ssh-user)   SSH_USER="${2:?}"; shift 2 ;;
        --ssh-key)    SSH_KEY="${2:?}"; shift 2 ;;
        --pve-user)   PVE_USER="${2:?}"; shift 2 ;;
        --token-name) TOKEN_NAME="${2:?}"; shift 2 ;;
        --out)        OUT_FILE="${2:?}"; shift 2 ;;
        --local)      LOCAL=1; shift ;;
        --rotate)     ROTATE=1; shift ;;
        --check)      MODE="check"; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "неизвестная опция: $1 (см. --help)" ;;
    esac
done

# Значения уходят в удалённую команду через аргументы/кавычки — не допускаем
# ничего, кроме безопасного набора символов.
[[ "$PVE_USER" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$ ]] ||
    die "PVE-пользователь должен быть name@realm (например monitoring@pve)"
[[ "$TOKEN_NAME" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "имя токена: только буквы/цифры/._-"
[[ "$PVE_HOST" =~ ^[A-Za-z0-9.:-]+$ ]] || die "некорректный --pve-host"
[[ "$SSH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "некорректный --ssh-user"

[[ ${EUID} -eq 0 ]] ||
    die "запускай через sudo: нужен root-доступ к ssh-ключу и запись $OUT_FILE"

if [[ $LOCAL -eq 1 ]]; then
    command -v pveum >/dev/null || die "--local: pveum не найден (это не PVE?)"
else
    command -v ssh >/dev/null || die "ssh не найден"
    [[ -z "$SSH_KEY" || -f "$SSH_KEY" ]] || die "нет файла ключа: $SSH_KEY"
fi

# Проверяем запись ДО создания токена: иначе секрет можно потерять.
if [[ "$MODE" != "check" ]]; then
    OUT_DIR="$(dirname "$OUT_FILE")"
    [[ -d "$OUT_DIR" ]] || die "нет каталога для --out: $OUT_DIR"
    [[ -w "$OUT_DIR" ]] || die "нет прав на запись в $OUT_DIR (запусти через sudo)"
    [[ ! -e "$OUT_FILE" ]] || log "WARNING: $OUT_FILE уже существует и будет перезаписан"
fi

# ---------------------------------------------------------------- remote part ---
# Скрипт выполняется на PVE. На stdout печатает ТОЛЬКО строку TOKEN=<secret>
# (её перехватывает и пишет в файл локальная часть, не показывая на экране).
REMOTE_SCRIPT="$(cat <<'REMOTE_EOF'
set -euo pipefail

user="$1"; tokname="$2"; rotate="$3"; mode="$4"
err() { printf '%s\n' "$*" >&2; }

command -v pveum >/dev/null 2>&1 || { err "ERROR: pveum не найден (это не PVE?)"; exit 1; }

user_exists=0
token_exists=0

if users_out="$(pveum user list --output-format json 2>/dev/null)"; then
    grep -q "\"userid\"[[:space:]]*:[[:space:]]*\"${user}\"" <<<"$users_out" && user_exists=1 || true
else
    users_text="$(pveum user list 2>/dev/null || true)"
    grep -qw -- "$user" <<<"$users_text" && user_exists=1 || true
fi

if [ "$user_exists" = 1 ]; then
    if tokens_out="$(pveum user token list "$user" --output-format json 2>/dev/null)"; then
        grep -q "\"tokenid\"[[:space:]]*:[[:space:]]*\"${tokname}\"" <<<"$tokens_out" && token_exists=1 || true
    else
        tokens_text="$(pveum user token list "$user" 2>/dev/null || true)"
        grep -qw -- "$tokname" <<<"$tokens_text" && token_exists=1 || true
    fi
fi

if [ "$mode" = "check" ]; then
    if [ "$user_exists" = 1 ]; then err "user: $user существует"; else err "user: $user НЕ существует"; fi
    if [ "$token_exists" = 1 ]; then err "token: $user!$tokname существует"; else err "token: $user!$tokname НЕ существует"; fi
    if [ "$user_exists" = 1 ] && [ "$token_exists" = 1 ]; then exit 0; else exit 4; fi
fi

if [ "$user_exists" = 0 ]; then
    pveum user add "$user" --comment "Prometheus monitoring (read-only)" >&2
    err "user: создан $user"
else
    err "user: уже существует $user"
fi

if [ "$token_exists" = 1 ] && [ "$rotate" != "1" ]; then
    err "token: уже существует $user!$tokname (секрет PVE не показывает; для нового — --rotate)"
    exit 3
fi

if [ "$token_exists" = 1 ]; then
    pveum user token remove "$user" "$tokname" >&2
    err "token: старый токен удалён (--rotate)"
fi

if ! add_out="$(pveum user token add "$user" "$tokname" --privsep 1)"; then
    err "ERROR: не удалось создать токен (pveum user token add)"
    exit 1
fi

value="$(printf '%s' "$add_out" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n1 || true)"
if [ -z "$value" ]; then
    err "ERROR: не удалось разобрать секрет токена из вывода pveum"
    err "Токен мог быть создан — удали его: pveum user token remove $user $tokname"
    exit 1
fi
err "token: создан $user!$tokname (privsep=1)"

acl_ok=1
if ! pveum acl modify / --tokens "$user!$tokname" --roles PVEAuditor >&2; then
    acl_ok=0
fi
if [ "$acl_ok" = 1 ]; then
    err "acl: PVEAuditor на / для $user!$tokname"
else
    err "ERROR: не удалось выдать PVEAuditor токену $user!$tokname"
fi

# Проверка токена локально на PVE (заголовок передаётся файлом, не argv).
hdr="$(mktemp)"
chmod 600 "$hdr"
printf 'Authorization: PVEAPIToken=%s!%s=%s\n' "$user" "$tokname" "$value" > "$hdr"
code="$(curl -sS -k -o /dev/null -w '%{http_code}' -H @"$hdr" \
    https://127.0.0.1:8006/api2/json/version 2>/dev/null || echo 000)"
rm -f "$hdr"
if [ "$code" = "200" ]; then
    err "api: 200 OK (токен работает)"
else
    err "WARNING: проверка API вернула '$code' (токен всё равно сохранён)"
fi

printf 'TOKEN=%s\n' "$value"
[ "$acl_ok" = 1 ] || exit 5
REMOTE_EOF
)"

# ---------------------------------------------------------------- run ---
if [[ $LOCAL -eq 1 ]]; then
    log "режим: локально на PVE ($MODE)"
    set +e
    out="$(bash -s -- "$PVE_USER" "$TOKEN_NAME" "$ROTATE" "$MODE" <<<"$REMOTE_SCRIPT")"
    rc=$?
    set -e
else
    SSH_ARGS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes)
    [[ -f "$REPO_ROOT/ansible/known_hosts" ]] &&
        SSH_ARGS+=(-o "UserKnownHostsFile=$REPO_ROOT/ansible/known_hosts")
    [[ -n "$SSH_KEY" ]] && SSH_ARGS+=(-i "$SSH_KEY")
    log "режим: ssh ${SSH_USER}@${PVE_HOST} ($MODE)"
    set +e
    out="$(ssh "${SSH_ARGS[@]}" "${SSH_USER}@${PVE_HOST}" \
        "bash -s -- '$PVE_USER' '$TOKEN_NAME' '$ROTATE' '$MODE'" <<<"$REMOTE_SCRIPT")"
    rc=$?
    set -e
fi

token="$(printf '%s\n' "$out" | sed -n 's/^TOKEN=//p' | tail -n 1)"
token="${token%$'\r'}"

if [[ "$MODE" == "check" ]]; then
    if [[ $rc -eq 0 ]]; then
        log "всё на месте: $PVE_USER + токен $TOKEN_NAME"
    else
        log "не готово (rc=$rc): см. сообщения выше"
    fi
    exit "$rc"
fi

# Токен мог быть создан даже при ненулевом rc (например, не удался ACL) —
# сохраняем секрет в любом случае, чтобы не потерять его.
if [[ -n "$token" ]]; then
    umask 077
    printf '%s\n' "$token" > "$OUT_FILE"
    chmod 600 "$OUT_FILE"
    log "секрет токена записан: $OUT_FILE (0600, в выводе не показывается)"
    log "дальше: sudo $SCRIPT_DIR/setup-monitoring-secrets.sh --pve-token-file '$OUT_FILE'"
    log "после заполнения секретов: shred -u '$OUT_FILE'"
else
    case "$rc" in
        3) log "токен $PVE_USER!$TOKEN_NAME уже существует, его секрет PVE не показывает."
           log "если секрет неизвестен — повтори с --rotate (старый токен будет удалён)." ;;
        *) log "секрет токена не получен (rc=$rc), см. сообщения выше" ;;
    esac
fi

if [[ $rc -ne 0 ]]; then
    exit "$rc"
fi