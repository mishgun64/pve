#!/usr/bin/env bash
# Создание/обновление ansible/vault.sops.yml (sops + age).
#
# Зачем: после п.2 аудита пароли root берутся из vault_* переменных, а пайплайны
# Woodpecker работают в эфемерных контейнерах, где plaintext vault.yml взять неоткуда.
# Механизм:
#   * ansible/group_vars/all/vault.yml      — plaintext, в git НЕ коммитится (.gitignore);
#   * ansible/vault.sops.yml — шифртекст sops, коммитится;
#   * age-получатель = публичный SSH-ключ root control-node (он же секрет ssh_key
#     в Woodpecker), поэтому CI расшифровывает файл тем же ключом, без новых секретов.
#
# Запуск на control-node от root (нужен приватный ключ /root/.ssh/id_ed25519 и sops):
#   ./useful_scripts/control/init-ansible-vault.sh            # из готового vault.yml
#   ./useful_scripts/control/init-ansible-vault.sh --new      # задать пароли заново
#
# Пароли/хеши в вывод не попадают.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GV_DIR="$REPO_ROOT/ansible/group_vars/all"
PLAIN="$GV_DIR/vault.yml"
ENC="$REPO_ROOT/ansible/vault.sops.yml"
EXAMPLE="$GV_DIR/vault.yml.example"
AGE_KEY="${AGE_SSH_PRIVATE_KEY_FILE:-/root/.ssh/id_ed25519}"
MODE="${1:-}"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

[[ -f "$EXAMPLE" ]] || die "нет шаблона $EXAMPLE"
command -v sops >/dev/null || die "нет sops (установите: setup-control.sh или github.com/getsops/sops)"
command -v openssl >/dev/null || die "нет openssl"
[[ -f "$AGE_KEY" ]] || die "нет age-ключа $AGE_KEY (это root SSH-ключ control-node)"
id -u | grep -qx 0 || echo "ВНИМАНИЕ: скрипт не от root; ключ должен быть читаем текущему пользователю." >&2

AGE_RECIPIENT="$(ssh-keygen -y -f "$AGE_KEY" </dev/null)" || die "не удалось получить публичный ключ из $AGE_KEY"
[[ "$AGE_RECIPIENT" == ssh-* ]] || die "из $AGE_KEY не получился SSH-публичный ключ"

if [[ "$MODE" == "--new" ]]; then
    [[ -f "$PLAIN" ]] && cp -a "$PLAIN" "$PLAIN.bak-$(date +%Y%m%d%H%M%S)"
    rm -f "$PLAIN"
fi

if [[ ! -f "$PLAIN" ]]; then
    log "Заполнение $PLAIN (пароли вводятся скрыто)"
    umask 077
    : > "$PLAIN"

    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        host="${key#vault_}"; host="${host%_root_password_hash}"
        while :; do
            read -rsp "Пароль root для ${host}: " pw </dev/tty || die "ввод прерван"
            echo
            [[ -n "$pw" ]] && break
            echo "Пустой пароль недопустим."
        done
        hash="$(printf '%s\n' "$pw" | openssl passwd -6 -stdin)"
        [[ "$hash" == \$6\$* ]] || die "openssl не выдал SHA-512 хеш"
        unset pw
        printf '%s: "%s"\n' "$key" "$hash" >> "$PLAIN"
        unset hash
    done < <(grep -oE '^vault_[a-z0-9_]+' "$EXAMPLE")

    chmod 600 "$PLAIN"
    echo "Записан $PLAIN (plaintext, gitignored)"
else
    log "Использую существующий plaintext $PLAIN"
    chmod 600 "$PLAIN"
fi

log "Шифрование sops (age-получатель: ${AGE_RECIPIENT%% *} ...)"

# Проверка: в файле не осталось заглушек.
if grep -q 'CHANGE_ME' "$PLAIN"; then
    die "в $PLAIN остались CHANGE_ME — заполните значения"
fi

# Временный файл обязан иметь .yml: sops определяет формат по расширению,
# без него он считает входные данные JSON и падает на YAML.
tmp_enc="$(mktemp "${TMPDIR:-/tmp}/vault.sops.XXXXXX.yml")"
trap 'rm -f "$tmp_enc"' EXIT
SOPS_AGE_RECIPIENTS="$AGE_RECIPIENT" \
    sops -e --input-type yaml --output-type yaml "$PLAIN" > "$tmp_enc"
SOPS_AGE_SSH_PRIVATE_KEY_FILE="$AGE_KEY" \
    sops -d --input-type yaml "$tmp_enc" >/dev/null || die "расшифровка тестовым ключом не удалась"

install -m 0644 "$tmp_enc" "$ENC"

log "Готово"
echo "Зашифрованный файл: $ENC"
echo "Plaintext (не коммитить): $PLAIN"
echo
echo "Дальше:"
echo "  git add ansible/vault.sops.yml"
echo "  git commit -m 'ansible: vault_* значения (sops/age)' && git push"
echo
echo "CI расшифровывает vault.sops.yml ключом из секрета ssh_key (шаг Vault в пайплайнах)."