#!/usr/bin/env bash
#
# Оставляет только N последних резервных копий для каждого сервиса.
# Работает рекурсивно по /srv/backups и всем подпапкам.
# Группировка идёт по паре (директория, имя_сервиса) — то есть файлы
# в разных подпапках с одинаковым именем сервиса считаются разными группами.
#
# Ожидаемый формат имени файла: <сервис>_ДД_ММ_ГГГГ_ЧЧ_ММ.<расширение>
# Файлы, не подходящие под этот формат (.sops.yaml, *_backup_v2.5...zip и т.п.),
# скрипт игнорирует и не трогает.
#
# По умолчанию — режим "сухого прогона" (ничего не удаляется, только печать).
# Для реального удаления запустите: ./cleanup_backups.sh --apply

set -euo pipefail

BACKUP_ROOT="/srv/backups"
KEEP=3
APPLY=0

if [[ "${1:-}" == "--apply" ]]; then
    APPLY=1
fi

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

# Собираем все подходящие файлы: dir<TAB>service<TAB>sortkey<TAB>filepath
while IFS= read -r -d '' file; do
    base=$(basename -- "$file")
    dir=$(dirname -- "$file")

    if [[ "$base" =~ ^(.+)_([0-9]{2})_([0-9]{2})_([0-9]{4})_([0-9]{2})_([0-9]{2})\. ]]; then
        service="${BASH_REMATCH[1]}"
        dd="${BASH_REMATCH[2]}"
        mm="${BASH_REMATCH[3]}"
        yyyy="${BASH_REMATCH[4]}"
        hh="${BASH_REMATCH[5]}"
        min="${BASH_REMATCH[6]}"
        sortkey="${yyyy}${mm}${dd}${hh}${min}"
        printf '%s\t%s\t%s\t%s\n' "$dir" "$service" "$sortkey" "$file" >> "$tmpfile"
    fi
done < <(find "$BACKUP_ROOT" -type f -print0)

# Сортировка: по директории, по сервису, затем по дате в убывающем порядке (новые первыми)
sort -t $'\t' -k1,1 -k2,2 -k3,3r "$tmpfile" -o "$tmpfile"

prev_key=""
kept=0
total_deleted=0

while IFS=$'\t' read -r dir service sortkey file; do
    key="${dir}/${service}"

    if [[ "$key" != "$prev_key" ]]; then
        prev_key="$key"
        kept=1
        echo "=== ${key} ==="
    else
        kept=$((kept + 1))
    fi

    if (( kept <= KEEP )); then
        echo "  сохранить: $(basename -- "$file")"
    else
        if (( APPLY == 1 )); then
            echo "  УДАЛЕНО:   $(basename -- "$file")"
            rm -f -- "$file"
        else
            echo "  удалить (dry-run): $(basename -- "$file")"
        fi
        total_deleted=$((total_deleted + 1))
    fi
done < "$tmpfile"

echo
if (( APPLY == 1 )); then
    echo "Готово. Удалено файлов: ${total_deleted}"
else
    echo "Сухой прогон завершён. Будет удалено файлов: ${total_deleted}"
    echo "Для реального удаления запустите: $0 --apply"
fi