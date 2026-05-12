#!/usr/bin/env bash

set -euo pipefail

BASE_DIR="RUS Sound"

if [[ ! -d "$BASE_DIR" ]]; then
    echo "Папка '$BASE_DIR' не найдена"
    exit 1
fi

echo "Доступные озвучки:"
echo

mapfile -t SOUND_DIRS < <(find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

if [[ ${#SOUND_DIRS[@]} -eq 0 ]]; then
    echo "Папки с озвучками не найдены"
    exit 1
fi

for i in "${!SOUND_DIRS[@]}"; do
    name=$(basename "${SOUND_DIRS[$i]}")
    echo "$((i + 1))) $name"
done

echo
read -rp "Выберите номер озвучки: " CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
    echo "Нужно ввести число"
    exit 1
fi

INDEX=$((CHOICE - 1))

if (( INDEX < 0 || INDEX >= ${#SOUND_DIRS[@]} )); then
    echo "Неверный номер"
    exit 1
fi

SELECTED_DIR="${SOUND_DIRS[$INDEX]}"

echo
echo "Выбрана озвучка: $(basename "$SELECTED_DIR")"

read -rp "Куда положить хардлинки: " RAW_TARGET_DIR
eval "TARGET_DIR=$RAW_TARGET_DIR"

mkdir -p "$TARGET_DIR"

FOUND=0

while IFS= read -r -d '' FILE; do
    FOUND=1

    BASENAME=$(basename "$FILE")

# Ищем сезон и серию
if [[ "$BASENAME" =~ S([0-9]+)[[:space:]_-]*E([0-9]{2}) ]]; then
    SEASON="${BASH_REMATCH[1]}"
    EPISODE="${BASH_REMATCH[2]}"

elif [[ "$BASENAME" =~ S([0-9]+)[[:space:]_-]*-[[:space:]_-]*([0-9]{2}) ]]; then
    SEASON="${BASH_REMATCH[1]}"
    EPISODE="${BASH_REMATCH[2]}"

else
    echo "Не удалось определить серию: $BASENAME"
    continue
fi

    SERIES_PATTERN="S$(printf "%02d" $((10#$SEASON)))E$(printf "%02d" $((10#$EPISODE)))"

    MKV_FILE=$(find "$TARGET_DIR" -maxdepth 1 -type f -name "*${SERIES_PATTERN}*.mkv" | head -n 1)

    if [[ -z "$MKV_FILE" ]]; then
        echo "MKV не найден для $BASENAME"
        continue
    fi

    MKV_BASENAME=$(basename "$MKV_FILE")
    MKV_NAME="${MKV_BASENAME%.mkv}"

    TARGET_FILE="${TARGET_DIR}/${MKV_NAME}.ru.mka"

    ln -f "$FILE" "$TARGET_FILE"

    chown docker:docker "$TARGET_FILE"

    echo "Создан:"
    echo "  $TARGET_FILE"

done < <(find "$SELECTED_DIR" -type f -name '*.mka' -print0)

if [[ $FOUND -eq 0 ]]; then
    echo "Файлы .mka не найдены"
    exit 1
fi

echo
echo "Готово"