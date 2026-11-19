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
#   ./useful_scripts/control/init-ansible-vault.sh            # по каждому ключу:
#                                                             # заменить пароль или оставить
#   ./useful_scripts/control/init-ansible-vault.sh --new      # пересоздать всё с нуля
#
# Для каждого ключа из vault.yml.example скрипт спрашивает:
#   * пароль уже задан  -> "Заменить пароль? [y/N]" (по умолчанию — оставить);
#   * пароля нет/CHANGE_ME -> просит ввести новый.
# Ключи, которых нет в шаблоне, сохраняются как есть.
#
# Тип хеша выбирается по имени ключа:
#   * vault_*_root_password_hash        -> SHA-512 crypt (openssl passwd -6);
#   * vault_authelia_*_password_hash    -> argon2id (утилита argon2).
#
# Зависимости: sops, openssl, argon2 (ставится автоматически через apt-get,
# если запущено от root), ssh-ключ root для age.
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

case "$MODE" in
    ''|--new) ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "неизвестный аргумент: $MODE (используйте --new или --help)" ;;
esac

[[ -f "$EXAMPLE" ]] || die "нет шаблона $EXAMPLE"
command -v sops >/dev/null || die "нет sops (установите: setup-control.sh или github.com/getsops/sops)"
command -v openssl >/dev/null || die "нет openssl"
# argon2 нужен для argon2id-хешей Authelia (vault_authelia_*). Ставим сразу,
# чтобы не заставлять вводить остальные пароли до падения на последнем ключе.
ensure_argon2() {
    command -v argon2 >/dev/null && return 0

    if ! id -u | grep -qx 0; then
        die "нет утилиты argon2, а скрипт не от root: sudo apt-get install -y argon2 (или запустите через sudo)"
    fi
    command -v apt-get >/dev/null || die "нет argon2 и нет apt-get: установите argon2 вручную"

    log "Установка argon2 (нужен для argon2id-хеша Authelia)"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y argon2 >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq \
            || die "apt-get update не удался"
        DEBIAN_FRONTEND=noninteractive apt-get install -y argon2 >/dev/null \
            || die "не удалось установить argon2"
    fi
    command -v argon2 >/dev/null || die "argon2 установлен, но не найден в PATH"
}

if grep -qE '^vault_authelia_' "$EXAMPLE"; then
    ensure_argon2
fi
[[ -f "$AGE_KEY" ]] || die "нет age-ключа $AGE_KEY (это root SSH-ключ control-node)"
id -u | grep -qx 0 || echo "ВНИМАНИЕ: скрипт не от root; ключ должен быть читаем текущему пользователю." >&2

AGE_RECIPIENT="$(ssh-keygen -y -f "$AGE_KEY" </dev/null)" || die "не удалось получить публичный ключ из $AGE_KEY"
[[ "$AGE_RECIPIENT" == ssh-* ]] || die "из $AGE_KEY не получился SSH-публичный ключ"

if [[ "$MODE" == "--new" ]]; then
    [[ -f "$PLAIN" ]] && cp -a "$PLAIN" "$PLAIN.bak-$(date +%Y%m%d%H%M%S)"
    rm -f "$PLAIN"
fi

#--------------------------- helpers ----------------------------------------

# Текущее значение ключа из plaintext vault.yml (пусто, если ключа нет).
current_value() {
    [[ -f "$PLAIN" ]] || return 0
    awk -v k="$1" '
        index($0, k ":") == 1 {
            v = substr($0, length(k) + 2)
            sub(/^[ \t]+/, "", v)
            sub(/[ \t]+$/, "", v)
            gsub(/^"|"$/, "", v)
            print v
            exit
        }' "$PLAIN"
}

hash_sha512() {
    local hash
    hash="$(printf '%s\n' "$1" | openssl passwd -6 -stdin)"
    [[ "$hash" == \$6\$* ]] || die "openssl не выдал SHA-512 хеш"
    printf '%s' "$hash"
}

# Authelia проверяет argon2id; параметры совпадают с authentication_backend
# в roles/traefik/config/files/authelia/configuration.yml (m=65536,t=3,p=4).
hash_argon2id() {
    local salt hash
    command -v argon2 >/dev/null || die \
        "нет утилиты argon2: нужна для argon2id-хеша Authelia (apt-get install -y argon2)"
    salt="$(openssl rand -hex 16)"
    hash="$(printf '%s' "$1" | argon2 "$salt" -id -t 3 -m 16 -p 4 -l 32 -e 2>/dev/null)" \
        || die "argon2 не смог посчитать хеш"
    [[ "$hash" == \$argon2id\$v=19\$m=65536,t=3,p=4\$* ]] \
        || die "неожиданный формат argon2id-хеша (ожидался m=65536,t=3,p=4)"
    printf '%s' "$hash"
}

# Тип хеша — по имени ключа.
make_hash() {
    case "$1" in
        *authelia*) hash_argon2id "$2" ;;
        *)          hash_sha512 "$2" ;;
    esac
}

# Неинтерактивный запуск (нет /dev/tty) — сразу ошибка, иначе read повиснет.
[[ -r /dev/tty ]] || die "нужен интерактивный терминал (/dev/tty недоступен)"

#--------------------------- fill vault -------------------------------------

log "Заполнение $PLAIN (пароли вводятся скрыто)"

umask 077
tmp="$(mktemp "${TMPDIR:-/tmp}/vault.XXXXXX.yml")"
trap 'rm -f "$tmp"' EXIT

updated=0
kept=0

while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    current="$(current_value "$key")"

    if [[ -n "$current" && "$current" != "CHANGE_ME" ]]; then
        printf '\n\033[1m%s\033[0m — пароль уже задан.\n' "$key"
        answer=""
        read -r -p "  Заменить пароль? [y/N]: " answer </dev/tty || die "ввод прерван"
        case "${answer,,}" in
            y|yes|д|да) ;;
            *)
                printf '%s: "%s"\n' "$key" "$current" >> "$tmp"
                kept=$((kept + 1))
                continue
                ;;
        esac
    fi

    while :; do
        read -rsp "  Новый пароль для ${key}: " pw </dev/tty || die "ввод прерван"
        echo
        if [[ -n "$pw" ]]; then break; fi
        echo "  Пустой пароль недопустим."
    done

    printf '%s: "%s"\n' "$key" "$(make_hash "$key" "$pw")" >> "$tmp"
    unset pw
    updated=$((updated + 1))
done < <(grep -oE '^vault_[a-z0-9_]+' "$EXAMPLE")

# Ключи вне шаблона не теряем — переносим со старыми значениями.
if [[ -f "$PLAIN" ]]; then
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        if grep -qE "^${key}\$" <(grep -oE '^vault_[a-z0-9_]+' "$EXAMPLE"); then
            continue
        fi
        printf '%s: "%s"\n' "$key" "$(current_value "$key")" >> "$tmp"
    done < <(sed -nE 's/^(vault_[a-z0-9_]+):.*/\1/p' "$PLAIN")
fi

install -m 600 "$tmp" "$PLAIN"
echo
echo "Обновлено паролей: ${updated}, оставлено без изменений: ${kept}."
echo "Записан $PLAIN (plaintext, gitignored)"

#--------------------------- encrypt ----------------------------------------

log "Шифрование sops (age-получатель: ${AGE_RECIPIENT%% *} ...)"

# Проверка: в файле не осталось заглушек.
if grep -q 'CHANGE_ME' "$PLAIN"; then
    die "в $PLAIN остались CHANGE_ME — заполните значения"
fi

# Временный файл обязан иметь .yml: sops определяет формат по расширению,
# без него он считает входные данные JSON и падает на YAML.
tmp_enc="$(mktemp "${TMPDIR:-/tmp}/vault.sops.XXXXXX.yml")"
trap 'rm -f "$tmp" "$tmp_enc"' EXIT
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