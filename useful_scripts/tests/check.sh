#!/usr/bin/env bash
# Статические тесты для useful_scripts: без docker, rclone и root.
# Запуск: bash useful_scripts/tests/check.sh
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

BACKUP_SCRIPT="$SCRIPTS_DIR/backup-woodpecker.sh"
SETUP_SCRIPT="$SCRIPTS_DIR/setup-control.sh"

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
    BACKUP_NAME SSH_KEY_FILE PROJECT_NAME; do

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
