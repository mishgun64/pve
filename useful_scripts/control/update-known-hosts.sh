#!/usr/bin/env bash
# Обновление ansible/known_hosts — публичных host-ключей управляемых хостов.
#
# Зачем: в контейнерах Woodpecker CI нет ~/.ssh/known_hosts, а host_key_checking
# включён (ansible.cfg). Доверенные ключи берутся из ansible/known_hosts через
# ansible_ssh_common_args в ansible/hosts_prod.
#
# Когда запускать:
#   * добавили хост в ansible/hosts_prod;
#   * пересоздали LXC/VM (сменился host key) — пайплайн упадёт с
#     "Host key verification failed";
#   * хост был выключен и его ключ не попал в файл при прошлом обновлении.
#
# Запуск (с любого хоста, откуда доступны 22/tcp целевых машин):
#   ./useful_scripts/control/update-known-hosts.sh
#   ./useful_scripts/control/update-known-hosts.sh --dry-run
#
# Секретов не содержит: записываются только публичные host-ключи.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INVENTORY="$REPO_ROOT/ansible/hosts_prod"
KNOWN_HOSTS="${KNOWN_HOSTS_FILE:-$REPO_ROOT/ansible/known_hosts}"
KEY_TYPES="${KEY_TYPES:-rsa,ecdsa,ed25519}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-5}"
DRY_RUN=0

[[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]] && DRY_RUN=1

[[ -f "$INVENTORY" ]] || { echo "Нет inventory: $INVENTORY" >&2; exit 1; }
command -v ssh-keyscan >/dev/null || { echo "Нужен ssh-keyscan (openssh-client)" >&2; exit 1; }

mapfile -t HOSTS < <(
    grep -oE 'ansible_host: [0-9A-Za-z.:_-]+' "$INVENTORY" | awk '{print $2}' | sort -u
)
[[ ${#HOSTS[@]} -gt 0 ]] || { echo "В $INVENTORY не найдено ansible_host" >&2; exit 1; }

TMP_KEYS="$(mktemp)"
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_KEYS" "$TMP_OUT"' EXIT

ok=0; kept=0; failed=()

for host in "${HOSTS[@]}"; do
    scanned="$(timeout $((SCAN_TIMEOUT + 5)) ssh-keyscan -T "$SCAN_TIMEOUT" -t "$KEY_TYPES" "$host" 2>/dev/null | grep -v '^#' || true)"

    if [[ -n "$scanned" ]]; then
        printf '%s\n' "$scanned" >> "$TMP_KEYS"
        echo "OK      $host ($(printf '%s\n' "$scanned" | wc -l) ключей)"
        ok=$((ok + 1))
        continue
    fi

    # Хост недоступен: сохраняем ранее запиненные ключи, чтобы не потерять их.
    if [[ -f "$KNOWN_HOSTS" ]] && ssh-keygen -F "$host" -f "$KNOWN_HOSTS" 2>/dev/null | grep -qv '^#'; then
        ssh-keygen -F "$host" -f "$KNOWN_HOSTS" 2>/dev/null | grep -v '^#' >> "$TMP_KEYS"
        echo "KEPT    $host (недоступен, оставлены прежние ключи)"
        kept=$((kept + 1))
    else
        echo "MISSING $host (недоступен, ключей нет)"
        failed+=("$host")
    fi
done

sort -k1,1 -k2,2 -u "$TMP_KEYS" > "$TMP_KEYS.sorted"

{
    cat <<'EOF'
# Публичные host-ключи управляемых хостов. Секретов не содержит.
# Используется через ansible_ssh_common_args в ansible/hosts_prod
# (проверка host key остаётся включённой: ansible.cfg host_key_checking=True).
# Обновление после пересоздания LXC/VM: useful_scripts/control/update-known-hosts.sh
EOF
    cat "$TMP_KEYS.sorted"
} > "$TMP_OUT"

echo
echo "Итог: обновлено $ok, сохранено прежних $kept, без ключей ${#failed[@]}"
if [[ ${#failed[@]} -gt 0 ]]; then
    printf '  нет ключей: %s\n' "${failed[*]}"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: $KNOWN_HOSTS не изменён (новых строк: $(grep -vc '^#' "$TMP_OUT"))"
    exit 0
fi

if [[ -f "$KNOWN_HOSTS" ]] && cmp -s "$TMP_OUT" "$KNOWN_HOSTS"; then
    echo "Изменений нет: $KNOWN_HOSTS"
else
    install -m 0644 "$TMP_OUT" "$KNOWN_HOSTS"
    echo "Записан: $KNOWN_HOSTS"
    echo "Не забудьте закоммитить изменения (CI читает файл из репозитория)."
fi