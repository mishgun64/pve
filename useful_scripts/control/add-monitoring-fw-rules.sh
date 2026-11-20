#!/usr/bin/env bash
# ============================================================================
# add-monitoring-fw-rules.sh — добавить в PVE-firewall гостей/гипервизора
# разрешение на входящие 9100 (node_exporter) и 8081 (cAdvisor) ТОЛЬКО с
# сервера мониторинга (control_node, 192.168.2.200).
#
# Зачем: Prometheus на control ходит на агентов по LAN, а PVE-firewall
# сервисных LXC/VM по умолчанию эти порты не пропускает. Правила лежат в
# зашифрованных sops-файлах ansible/roles/<svc>/firewall/files/<vmid>.fw.enc
# (п.10.1 MONITORING-PLAN.md).
#
# Запускать НА МАШИНЕ С ПРИВАТНЫМ КЛЮЧОМ jenkins@control (обычно сам control),
# из checkout репозитория. По умолчанию — dry-run (только показать diff).
#
#   sudo ./useful_scripts/control/add-monitoring-fw-rules.sh
#   sudo ./useful_scripts/control/add-monitoring-fw-rules.sh --apply
#   sudo ./useful_scripts/control/add-monitoring-fw-rules.sh --source 192.168.2.200
#
# После --apply: git diff, commit, push. Правки roles/*/firewall/** запускают
# соответствующие .woodpecker/<svc>_firewall.yml; для pve — pve_firewall.yml.
# ============================================================================
set -euo pipefail

MONITORING_SRC="192.168.2.200"
APPLY=0
REPO_ROOT="${REPO_ROOT:-}"

# guest — с cAdvisor (docker-хост), host — без cAdvisor.
FW_FILES=(
    "ansible/roles/media_vm/firewall/files/124.fw.enc:guest"
    "ansible/roles/nextcloud/firewall/files/125.fw.enc:guest"
    "ansible/roles/wireguard/firewall/files/126.fw.enc:guest"
    "ansible/roles/traefik/firewall/files/143.fw.enc:guest"
    "ansible/roles/pvpgn/firewall/files/145.fw.enc:guest"
    "ansible/roles/valheim/firewall/files/146.fw.enc:guest"
    "ansible/roles/santa_bot/firewall/files/148.fw.enc:guest"
    "ansible/roles/pve/firewall/files/cluster.fw.enc:host"
)

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# age-получатель берём из публичных метаданных существующего .enc (не секрет),
# с запасным вариантом — из .sops.yaml рядом. Так шифрование не зависит от
# того, нашёл ли sops конфиг в текущем окружении.
recipient_of() {
    local enc="$1" r=""
    r="$(grep -o '"recipient"[[:space:]]*:[[:space:]]*"[^"]*"' "$enc" 2>/dev/null \
        | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/')"
    if [[ -z "$r" ]]; then
        r="$(grep -Eo 'ssh-(ed25519|rsa)[[:space:]]+[A-Za-z0-9+/=]+[^"]*' "$enc" 2>/dev/null | head -n1)"
    fi
    if [[ -z "$r" && -f "$(dirname "$enc")/.sops.yaml" ]]; then
        r="$(awk '/age1[0-9a-z]+|ssh-(ed25519|rsa)[[:space:]]/ { sub(/^[[:space:]]*-?[[:space:]]*/, ""); print; exit }' \
             "$(dirname "$enc")/.sops.yaml")"
    fi
    printf '%s' "$r"
}

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

while (($#)); do
    case "$1" in
        --apply)  APPLY=1; shift ;;
        --source) MONITORING_SRC=${2:?}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "неизвестная опция: $1 (см. --help)" ;;
    esac
done

command -v sops >/dev/null || fail "sops не установлен"
command -v git  >/dev/null || fail "git не установлен"

[[ -n "$REPO_ROOT" ]] || REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || REPO_ROOT="$(pwd)"
cd "$REPO_ROOT"
[[ -d ansible/roles ]] || fail "не похоже на checkout репозитория pve: $REPO_ROOT"

[[ "$MONITORING_SRC" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "источник должен быть IPv4-адресом: $MONITORING_SRC"

log "sops: $(sops --version 2>/dev/null | head -n1)"
log "репозиторий: $REPO_ROOT"
log "источник правил: $MONITORING_SRC"
log "режим: $([[ $APPLY -eq 1 ]] && echo APPLY || echo 'dry-run')"

# Проверка доступа к ключу: если sops не может расшифровать первый файл —
# дальнейшие шаги бессмысленны (ключ jenkins@control должен быть локально).
first_enc=""
for item in "${FW_FILES[@]}"; do
    f="${item%%:*}"; [[ -f "$f" ]] && { first_enc="$f"; break; }
done
[[ -n "$first_enc" ]] || fail "не найден ни один .fw.enc (запусти из корня репозитория)"

if ! sops -d "$first_enc" >/dev/null 2>&1; then
    fail "sops не может расшифровать $first_enc: нет приватного ключа jenkins@control (или SOPS_AGE_SSH_PRIVATE_KEY_FILE)"
fi

if [[ $APPLY -eq 1 ]]; then
    dirty="$(git status --porcelain -- "${FW_FILES[@]%%:*}" 2>/dev/null || true)"
    [[ -z "$dirty" ]] || fail "в firewall-файлах есть незакоммиченные изменения — сначала разберись с git status"
fi

inserted=0
skipped=0
failed=0
changed_files=()

for item in "${FW_FILES[@]}"; do
    enc="${item%%:*}"
    kind="${item##*:}"

    if [[ ! -f "$enc" ]]; then
        log "SKIP $enc: файла нет"
        skipped=$((skipped + 1))
        continue
    fi

    dir="$(dirname "$enc")"
    base="$(basename "$enc" .enc)"          # 124.fw
    tmp="$(mktemp /tmp/fw-dec.XXXXXX)"
    patched="$(mktemp /tmp/fw-new.XXXXXX)"
    trap 'rm -f "$tmp" "$patched"' EXIT

    if ! sops -d "$enc" > "$tmp" 2>/dev/null; then
        log "FAIL $enc: не расшифровывается (ключ?)"
        failed=$((failed + 1))
        rm -f "$tmp" "$patched"
        continue
    fi

    need9100=0
    need8081=0
    grep -Eq -- '-dport[[:space:]]+9100' "$tmp" || need9100=1
    if [[ "$kind" == "guest" ]]; then
        grep -Eq -- '-dport[[:space:]]+8081' "$tmp" || need8081=1
    fi

    if [[ $need9100 -eq 0 && $need8081 -eq 0 ]]; then
        log "OK   $enc: правила 9100/8081 уже есть"
        skipped=$((skipped + 1))
        rm -f "$tmp" "$patched"
        continue
    fi

    block="# monitoring (control_node $MONITORING_SRC): node_exporter/cAdvisor"
    if [[ $need9100 -eq 1 ]]; then
        block="$block"$'\n'"IN ACCEPT -source $MONITORING_SRC -p tcp -dport 9100"
    fi
    if [[ $need8081 -eq 1 ]]; then
        block="$block"$'\n'"IN ACCEPT -source $MONITORING_SRC -p tcp -dport 8081"
    fi

    # Вставляем сразу после заголовка [RULES]: PVE применяет правила сверху
    # вниз, а accept должен стоять раньше возможных drop.
    awk -v block="$block" '
        { print }
        /^\[RULES\][[:space:]]*$/ && !done { print block; done = 1 }
        END {
            if (!done) {
                print ""
                print "[RULES]"
                print block
            }
        }
    ' "$tmp" > "$patched"

    if ! diff -q "$tmp" "$patched" >/dev/null; then
        log "DIFF $enc"
        diff -u --label "$enc (old)" --label "$enc (new)" "$tmp" "$patched" || true
    fi

    if [[ $APPLY -eq 1 ]]; then
        recipient="$(recipient_of "$enc")"
        if [[ -z "$recipient" ]]; then
            log "FAIL $enc: не удалось определить age-получателя (нет метаданных в .enc и .sops.yaml)"
            failed=$((failed + 1))
            rm -f "$tmp" "$patched"
            continue
        fi

        # Шифруем во временном каталоге и с явным --age: не зависим от поиска
        # .sops.yaml (частая причина "sops не смог зашифровать" на другом хосте).
        stage="$(mktemp -d /tmp/fw-enc.XXXXXX)"
        chmod 700 "$stage"
        cp "$patched" "$stage/plain.fw"
        abs_tmp="$(cd "$dir" && pwd)/$base.enc.tmp"
        err=""
        if ! err="$( cd "$stage" && sops -e --age "$recipient" \
                --input-type binary --output-type binary \
                --output "$abs_tmp" plain.fw 2>&1 )"; then
            log "FAIL $enc: sops encrypt: ${err:-без вывода}"
            log "  подсказка: нужен sops >= 3.8 с поддержкой ssh-age; на control — /usr/local/bin/sops --version"
            failed=$((failed + 1))
            rm -rf "$stage" "$abs_tmp" "$tmp" "$patched"
            continue
        fi
        # Контроль round-trip: расшифрованный новый файл должен совпасть.
        if err="$(sops -d "$abs_tmp" 2>&1 >/dev/null)"; then
            :
        else
            log "FAIL $enc: новый архив не расшифровывается: ${err:-без вывода}"
            failed=$((failed + 1))
            rm -rf "$stage" "$abs_tmp" "$tmp" "$patched"
            continue
        fi
        if ! sops -d "$abs_tmp" 2>/dev/null | diff -q - "$patched" >/dev/null; then
            log "FAIL $enc: round-trip sops не совпал, файл не изменён"
            failed=$((failed + 1))
            rm -rf "$stage" "$abs_tmp" "$tmp" "$patched"
            continue
        fi
        mv "$abs_tmp" "$enc"
        rm -rf "$stage"
        log "UPDATE $enc"
        changed_files+=("$enc")
        inserted=$((inserted + 1))
    else
        inserted=$((inserted + 1))
    fi

    rm -f "$tmp" "$patched"
done

echo
log "итого: обновлено/к обновлению=$inserted, без изменений=$skipped, ошибок=$failed"

if [[ $APPLY -eq 0 && $inserted -gt 0 ]]; then
    echo
    log "dry-run: ничего не записано. Повторить с --apply, затем git diff/commit/push."
fi

if [[ $APPLY -eq 1 && ${#changed_files[@]} -gt 0 ]]; then
    echo
    log "перешифрованы:"
    printf '  %s\n' "${changed_files[@]}"
    log "дальше: git diff -- ${changed_files[*]} && git add ... && git commit && git push"
fi

((failed == 0)) || exit 1