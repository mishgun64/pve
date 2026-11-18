#!/usr/bin/env bash
# ============================================================
# WOODPECKER CI — bash-аналог wp_cli.ps1
#
# Интерактивно (меню на стрелках):
#   ./wp_cli.sh
#
# Неинтерактивно (для скриптов/агентов):
#   ./wp_cli.sh <service> <pipeline> [опции]
#   ./wp_cli.sh media backup
#   ./wp_cli.sh santa_bot firewall --dry-run
#   ./wp_cli.sh list
#
# Опции:
#   --repo <owner/repo>     репозиторий (по умолчанию mishgun64/pve)
#   --branch <branch>       ветка (по умолчанию main)
#   --var KEY=VALUE         дополнительная переменная пайплайна (можно repeat)
#   --dry-run               только показать команду, не запускать
#   --no-install            не устанавливать woodpecker-cli автоматически
#   -y, --yes               не спрашивать подтверждение
#   -h, --help              справка
#
# Бинарник: woodpecker-cli из PATH или путь в $WOODPECKER_CLI.
# Если не установлен — скачивается с GitHub Releases автоматически
# (версия подстраивается под сервер; /usr/local/bin или ~/.local/bin).
# Сервер: всегда https://ci.mishgun.com.
# Токен: $WOODPECKER_TOKEN или файл ~/.config/woodpecker/env (chmod 600,
# строка WOODPECKER_TOKEN=...; путь переопределяется $WOODPECKER_ENV_FILE).
# Сам токен: Web UI → User settings → Token.
# ============================================================

set -euo pipefail

REPO="mishgun64/pve"
BRANCH="main"
SERVER_URL="https://ci.mishgun.com"
CLI="${WOODPECKER_CLI:-woodpecker-cli}"
DRY_RUN=0
ASSUME_YES=0
NO_INSTALL=0
EXTRA_VARS=()

# ============================================================
# ДАННЫЕ: key|Service|Name|PIPELINE|ROLE|TARGET  (пустые ROLE/TARGET = не передавать)
# ============================================================
ROWS=(
    "common|Common|Basic|common/basic|common/basic|docker_hosts"
    "common|Common|Docker|common/docker|common/docker|docker_hosts"
    "pve|PVE|Firewall|pve/firewall|pve/firewall|pve"
    "media|Media|Config|media/config|media_vm/backup;media_vm/config;media_vm/restore|media_vm"
    "media|Media|Backup|media/backup|media_vm/backup|media_vm"
    "media|Media|Restore|media/restore|media_vm/restore|media_vm"
    "media|Media|Firewall|media_vm/firewall|media_vm/firewall|pve"
    "media|Media|Full|media/full||"
    "nextcloud|Nextcloud|Config|nextcloud/config|nextcloud/config|nextcloud_vm"
    "nextcloud|Nextcloud|Backup|nextcloud/backup|nextcloud/backup|nextcloud_vm"
    "nextcloud|Nextcloud|Restore|nextcloud/restore|nextcloud/restore|nextcloud_vm"
    "nextcloud|Nextcloud|Firewall|nextcloud/firewall|nextcloud/firewall|pve"
    "nextcloud|Nextcloud|Full|nextcloud/full||"
    "pvpgn|PvPGN|Config|pvpgn/config|pvpgn/config|pvpgn_lxc"
    "pvpgn|PvPGN|Backup|pvpgn/backup|pvpgn/backup|pvpgn_lxc"
    "pvpgn|PvPGN|Restore|pvpgn/restore|pvpgn/restore|pvpgn_lxc"
    "pvpgn|PvPGN|Firewall|pvpgn/firewall|pvpgn/firewall|pve"
    "pvpgn|PvPGN|Full|pvpgn/full||"
    "traefik|Traefik|Config|traefik/config|traefik/config|traefik_lxc"
    "traefik|Traefik|Backup|traefik/backup|traefik/backup|traefik_lxc"
    "traefik|Traefik|Restore|traefik/restore|traefik/restore|traefik_lxc"
    "traefik|Traefik|Firewall|traefik/firewall|traefik/firewall|pve"
    "traefik|Traefik|Full|traefik/full||"
    "valheim|Valheim|Config|valheim/config|valheim/config|valheim_lxc"
    "valheim|Valheim|Backup|valheim/backup|valheim/backup|valheim_lxc"
    "valheim|Valheim|Restore|valheim/restore|valheim/restore|valheim_lxc"
    "valheim|Valheim|Firewall|valheim/firewall|valheim/firewall|pve"
    "valheim|Valheim|Full|valheim/full||"
    "wireguard|WireGuard|Firewall|wireguard/firewall|wireguard/firewall|pve"
    "santa_bot|Santa Bot|Config|santa_bot/config|santa_bot/config|santa_bot_lxc"
    "santa_bot|Santa Bot|Backup|santa_bot/backup|santa_bot/backup|santa_bot_lxc"
    "santa_bot|Santa Bot|Restore|santa_bot/restore|santa_bot/restore|santa_bot_lxc"
    "santa_bot|Santa Bot|Firewall|santa_bot/firewall|santa_bot/firewall|pve"
    "santa_bot|Santa Bot|Full|santa_bot/full||"
)

# Порядок сервисов как в ps1
SERVICE_ORDER=(common pve media nextcloud pvpgn traefik valheim wireguard santa_bot)

# ============================================================
# ЦВЕТА / UI
# ============================================================
if [[ -t 1 ]]; then
    C_CYAN=$'\e[36m'; C_GREEN=$'\e[32m'; C_RED=$'\e[31m'
    C_GRAY=$'\e[90m'; C_WHITE=$'\e[97m'; C_YELLOW=$'\e[33m'; C_RESET=$'\e[0m'
else
    C_CYAN=""; C_GREEN=""; C_RED=""; C_GRAY=""; C_WHITE=""; C_YELLOW=""; C_RESET=""
fi

die() { echo "${C_RED}ERROR:${C_RESET} $*" >&2; exit 1; }

show_header() {
    clear 2>/dev/null || true
    echo ""
    echo "${C_CYAN}╔══════════════════════════════════════╗${C_RESET}"
    echo "${C_CYAN}║           WOODPECKER CI              ║${C_RESET}"
    echo "${C_CYAN}╚══════════════════════════════════════╝${C_RESET}"
    echo ""
}

usage() {
    sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
}

# ============================================================
# АВТОУСТАНОВКА CLI / АВТООПРЕДЕЛЕНИЕ СЕРВЕРА
# ============================================================
http_get() { # $1=url -> stdout
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 60 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=60 "$1"
    else
        die "нужен curl или wget для автоустановки woodpecker-cli"
    fi
}

HINT_SHOWN=0
show_env_setup_hint() {
    ((HINT_SHOWN)) && return 0
    HINT_SHOWN=1
    echo ""
    echo "${C_WHITE} Выполните в вашем shell после установки:${C_RESET}"
    echo ""
    echo '  export WOODPECKER_SERVER="https://ci.mishgun.com"'
    echo ""
    echo '  read -rsp "Woodpecker token: " WOODPECKER_TOKEN'
    echo '  export WOODPECKER_TOKEN'
    echo '  echo'
    echo ""
    echo "${C_GRAY} (или сохраните в ~/.config/woodpecker/env с chmod 600 — тогда скрипт подхватит сам)${C_RESET}"
}

ensure_cli() {
    # Если не в PATH — проверить стандартные места установки
    if [[ "$CLI" == "woodpecker-cli" ]] && ! command -v "$CLI" >/dev/null 2>&1; then
        local p
        for p in "$HOME/.local/bin/woodpecker-cli" /usr/local/bin/woodpecker-cli; do
            if [[ -x "$p" ]]; then
                CLI="$p"
                export PATH="${p%/*}:$PATH"
                break
            fi
        done
    fi
    command -v "$CLI" >/dev/null 2>&1 && return 0
    ((NO_INSTALL)) && die "$CLI not found (автоустановка отключена: --no-install)"

    local arch ver url tmp bindir
    case "$(uname -m)" in
        x86_64)  arch=amd64 ;;
        aarch64) arch=arm64 ;;
        armv7l)  arch=arm ;;
        riscv64) arch=riscv64 ;;
        *) die "неподдерживаемая архитектура: $(uname -m)" ;;
    esac

    echo "${C_YELLOW} $CLI не найден — устанавливаю...${C_RESET}"

    # Версия: сначала как у сервера, иначе latest с GitHub
    ver=""
    if [[ -n "${WOODPECKER_SERVER:-}" ]]; then
        ver="$(http_get "$WOODPECKER_SERVER/version" 2>/dev/null | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p')" || true
    fi
    if [[ -z "$ver" ]]; then
        ver="$(http_get https://api.github.com/repos/woodpecker-ci/woodpecker/releases/latest 2>/dev/null | sed -n 's/.*"tag_name" *: *"v\([^"]*\)".*/\1/p')" || true
    fi
    [[ -n "$ver" ]] || die "не удалось определить версию woodpecker-cli (сеть/GitHub недоступны?)"

    url="https://github.com/woodpecker-ci/woodpecker/releases/download/v${ver}/woodpecker-cli_linux_${arch}.tar.gz"
    tmp="$(mktemp -d)"
    echo "${C_GRAY} Загрузка: $url${C_RESET}"
    if ! http_get "$url" > "$tmp/cli.tar.gz"; then
        rm -rf "$tmp"
        die "не удалось скачать $url"
    fi
    tar -xzf "$tmp/cli.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "ошибка распаковки архива"; }

    if [[ -w /usr/local/bin ]]; then
        bindir=/usr/local/bin
    else
        bindir="$HOME/.local/bin"
        mkdir -p "$bindir"
    fi
    install -m 0755 "$tmp/woodpecker-cli" "$bindir/woodpecker-cli" || { rm -rf "$tmp"; die "ошибка установки в $bindir"; }
    rm -rf "$tmp"

    CLI="$bindir/woodpecker-cli"
    export PATH="$bindir:$PATH"
    echo "${C_GREEN} Установлен: $CLI ($("$CLI" --version 2>/dev/null || echo "v$ver"))${C_RESET}"
    [[ ":$PATH:" == *":$bindir:"* ]] || echo "${C_GRAY} Добавьте $bindir в PATH${C_RESET}"
    show_env_setup_hint
}

check_env() {
    # Токен/сервер из защищённого файла (если не заданы в окружении)
    local env_file="${WOODPECKER_ENV_FILE:-$HOME/.config/woodpecker/env}"
    if [[ -z "${WOODPECKER_TOKEN:-}" && -r "$env_file" ]]; then
        local perms
        perms="$(stat -c '%a' "$env_file" 2>/dev/null || echo '?')"
        [[ "$perms" == "600" || "$perms" == "400" ]] || \
            echo "${C_YELLOW} WARNING: права на $env_file ($perms) слишком широкие; сделайте chmod 600${C_RESET}" >&2
        set -a; source "$env_file"; set +a
    fi
    export WOODPECKER_SERVER="$SERVER_URL"
    ensure_cli
    if [[ -z "${WOODPECKER_TOKEN:-}" ]]; then
        echo "${C_RED}ERROR:${C_RESET} WOODPECKER_TOKEN не задан. Токен: Web UI → User settings → Token." >&2
        show_env_setup_hint
        exit 1
    fi
}

# ============================================================
# ПОИСК / СПИСКИ
# ============================================================
normalize_service() {
    local s="${1,,}"
    s="${s//-/_}"
    [[ "$s" == "santa" ]] && s="santa_bot"
    echo "$s"
}

service_display() {
    local row
    for row in "${ROWS[@]}"; do
        IFS='|' read -r key name _ <<< "$row"
        if [[ "$key" == "$1" ]]; then echo "$name"; return 0; fi
    done
    return 1
}

# Строки сервиса в глобальный массив MATCHED
rows_for_service() {
    local svc="$1" row key rest
    MATCHED=()
    for row in "${ROWS[@]}"; do
        IFS='|' read -r key rest <<< "$row"
        [[ "$key" == "$svc" ]] && MATCHED+=("$row")
    done
    ((${#MATCHED[@]} > 0))
}

find_row() { # svc pipeline_short_name -> строка в FOUND
    local svc="$1" name="${2,,}" row key svcname pipename rest
    for row in "${ROWS[@]}"; do
        IFS='|' read -r key svcname pipename rest <<< "$row"
        if [[ "$key" == "$svc" && "${pipename,,}" == "$name" ]]; then
            FOUND="$row"; return 0
        fi
    done
    return 1
}

cmd_list() {
    local row key svcname pipename pipeline role target
    printf "%-12s %-9s %-22s %-55s %s\n" "SERVICE" "PIPELINE" "PIPELINE var" "ROLE" "TARGET"
    for row in "${ROWS[@]}"; do
        IFS='|' read -r key svcname pipename pipeline role target <<< "$row"
        printf "%-12s %-9s %-22s %-55s %s\n" "$key" "${pipename,,}" "$pipeline" "${role:--}" "${target:--}"
    done
}

# ============================================================
# ИНТЕРАКТИВНОЕ МЕНЮ (стрелки, Enter, Esc/q; j/k, цифры 1-9)
# ============================================================
MENU_ITEMS=()
MENU_LABELS=()
menu_select() { # $1=title; результат в MENU_RESULT (индекс)
    local title="$1" selected=0 i key rest n=${#MENU_ITEMS[@]}
    while true; do
        show_header
        echo "${C_WHITE}${title}${C_RESET}"
        echo ""
        for ((i = 0; i < n; i++)); do
            if ((i == selected)); then
                echo "  ${C_GREEN}> $((i + 1)). ${MENU_LABELS[i]}${C_RESET}"
            else
                echo "  ${C_GRAY}  $((i + 1)). ${MENU_LABELS[i]}${C_RESET}"
            fi
        done
        echo ""
        echo "  ${C_GRAY}↑/↓ выбор   Enter подтвердить   1-9 быстрый выбор   Esc/q выход${C_RESET}"

        IFS= read -rsn1 key || exit 0
        if [[ "$key" == $'\e' ]]; then
            rest=""
            IFS= read -rsn2 -t 0.01 rest || true
            case "$rest" in
                "[A") selected=$(( selected > 0 ? selected - 1 : selected )) ;;
                "[B") selected=$(( selected < n - 1 ? selected + 1 : selected )) ;;
                "")   exit 0 ;;  # чистый Esc
            esac
        elif [[ "$key" == "j" ]]; then
            selected=$(( selected < n - 1 ? selected + 1 : selected ))
        elif [[ "$key" == "k" ]]; then
            selected=$(( selected > 0 ? selected - 1 : selected ))
        elif [[ "$key" == "q" ]]; then
            exit 0
        elif [[ "$key" =~ [1-9] ]] && ((key <= n)); then
            MENU_RESULT=$((key - 1)); return 0
        elif [[ -z "$key" ]]; then   # Enter
            MENU_RESULT=$selected; return 0
        fi
    done
}

interactive() {
    [[ -t 0 && -t 1 ]] || die "интерактивное меню требует TTY; используйте: $0 <service> <pipeline> (см. --help)"

    local svc row key svcname pipename rest
    trap 'printf "\e[?25h" >&2' EXIT   # вернуть курсор
    printf '\e[?25l' >&2               # скрыть курсор

    # --- выбор сервиса ---
    MENU_ITEMS=(); MENU_LABELS=()
    for svc in "${SERVICE_ORDER[@]}"; do
        MENU_ITEMS+=("$svc")
        MENU_LABELS+=("$(service_display "$svc")")
    done
    menu_select "Select service:"
    svc="${MENU_ITEMS[MENU_RESULT]}"

    # --- выбор пайплайна ---
    rows_for_service "$svc"
    MENU_ITEMS=("${MATCHED[@]}"); MENU_LABELS=()
    for row in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r key svcname pipename rest <<< "$row"
        MENU_LABELS+=("$pipename")
    done
    menu_select "Select pipeline:"
    FOUND="${MENU_ITEMS[MENU_RESULT]}"

    printf '\e[?25h' >&2
    trap - EXIT
}

# ============================================================
# ЗАПУСК ПАЙПЛАНА
# ============================================================
run_pipeline() { # $1 = строка ROWS
    local row="$1" key svcname pipename pipeline role target
    IFS='|' read -r key svcname pipename pipeline role target <<< "$row"

    local args=(pipeline create "$REPO" --branch "$BRANCH" --var "PIPELINE=$pipeline")
    [[ -n "$role" ]]   && args+=(--var "ROLE=$role")
    [[ -n "$target" ]] && args+=(--var "TARGET=$target")
    local v
    for v in ${EXTRA_VARS[@]+"${EXTRA_VARS[@]}"}; do
        args+=(--var "$v")
    done

    show_header
    echo "${C_WHITE} Starting pipeline...${C_RESET}"
    echo ""
    echo "  ${C_GRAY}Service:  ${svcname}${C_RESET}"
    echo "  ${C_GRAY}Pipeline: ${pipeline}${C_RESET}"
    echo "  ${C_GRAY}Role:     ${role:--}${C_RESET}"
    echo "  ${C_GRAY}Target:   ${target:--}${C_RESET}"
    echo "  ${C_GRAY}Repo:     ${REPO} @ ${BRANCH}${C_RESET}"
    echo ""

    if ((DRY_RUN)); then
        echo "${C_YELLOW}[dry-run]${C_RESET} $CLI ${args[*]}"
        return 0
    fi

    check_env

    if ((ASSUME_YES == 0)) && [[ -t 0 ]]; then
        local answer
        read -rp " Create pipeline? [y/N] " answer || exit 0
        [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]] || { echo " Cancelled."; exit 0; }
    fi

    echo "${C_YELLOW} Creating pipeline...${C_RESET}"
    echo ""

    local rc=0
    "$CLI" "${args[@]}" || rc=$?

    if ((rc != 0)); then
        echo ""
        echo "${C_RED}╔══════════════════════════════════════╗${C_RESET}"
        echo "${C_RED}║         PIPELINE CREATION ERROR      ║${C_RESET}"
        echo "${C_RED}╚══════════════════════════════════════╝${C_RESET}"
        echo ""
        echo " ${C_RED}Exit code: $rc${C_RESET}"
        exit "$rc"
    fi

    echo ""
    echo "${C_GREEN}╔══════════════════════════════════════╗${C_RESET}"
    echo "${C_GREEN}║          PIPELINE CREATED            ║${C_RESET}"
    echo "${C_GREEN}╚══════════════════════════════════════╝${C_RESET}"
    echo ""
    echo " ${C_WHITE}Service:  ${svcname}${C_RESET}"
    echo " ${C_WHITE}Pipeline: ${pipeline}${C_RESET}"
    [[ -n "$role" ]]   && echo " ${C_WHITE}Role:     ${role}${C_RESET}"
    [[ -n "$target" ]] && echo " ${C_WHITE}Target:   ${target}${C_RESET}"
    echo ""
}

# ============================================================
# РАЗБОР АРГУМЕНТОВ
# ============================================================
POSITIONAL=()
while (($# > 0)); do
    case "$1" in
        -h|--help)  usage; exit 0 ;;
        --repo)     REPO="${2:?--repo требует значение}"; shift 2 ;;
        --branch)   BRANCH="${2:?--branch требует значение}"; shift 2 ;;
        --var)      EXTRA_VARS+=("${2:?--var требует KEY=VALUE}"); shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --no-install) NO_INSTALL=1; shift ;;
        -y|--yes)   ASSUME_YES=1; shift ;;
        --)         shift; while (($# > 0)); do POSITIONAL+=("$1"); shift; done ;;
        -*)         die "неизвестная опция: $1 (см. --help)" ;;
        *)          POSITIONAL+=("$1"); shift ;;
    esac
done

for v in ${EXTRA_VARS[@]+"${EXTRA_VARS[@]}"}; do
    [[ "$v" == *=* ]] || die "--var ожидает KEY=VALUE, получено: $v"
done

if ((${#POSITIONAL[@]} == 0)); then
    interactive
    run_pipeline "$FOUND"
    exit 0
fi

if [[ "${POSITIONAL[0],,}" == "list" || "${POSITIONAL[0],,}" == "ls" ]]; then
    cmd_list
    exit 0
fi

((${#POSITIONAL[@]} == 2)) || { usage >&2; die "ожидается: <service> <pipeline> либо 'list'"; }

SVC="$(normalize_service "${POSITIONAL[0]}")"
service_display "$SVC" >/dev/null || die "неизвестный сервис: ${POSITIONAL[0]} (см. '$0 list')"
find_row "$SVC" "${POSITIONAL[1]}" || die "у сервиса '$SVC' нет пайплайна '${POSITIONAL[1]}' (см. '$0 list')"

run_pipeline "$FOUND"
