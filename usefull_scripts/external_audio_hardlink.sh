#!/usr/bin/env bash

set -euo pipefail

# ── 1. Выбор папки с озвучкой (источник .mka) ──────────────────────────────

echo "Сканирование папок в текущем каталоге..."
echo

mapfile -t ALL_DIRS < <(
    find . -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
)

if [[ ${#ALL_DIRS[@]} -eq 0 ]]; then
    echo "Папки не найдены в текущем каталоге"
    exit 1
fi

echo "Доступные папки:"
echo

for i in "${!ALL_DIRS[@]}"; do
    echo "$((i + 1))) ${ALL_DIRS[$i]}"
done

echo
read -rp "Выберите папку с озвучкой (номер): " CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
    echo "Нужно ввести число"
    exit 1
fi

INDEX=$((CHOICE - 1))

if (( INDEX < 0 || INDEX >= ${#ALL_DIRS[@]} )); then
    echo "Неверный номер"
    exit 1
fi

SEARCH_ROOT="./${ALL_DIRS[$INDEX]}"

echo
echo "Выбрана папка для поиска озвучек: ${SEARCH_ROOT#./}"
echo

# ── 2. Поиск .mka файлов внутри выбранной папки ────────────────────────────

echo "Поиск папок с .mka файлами в «${SEARCH_ROOT#./}»..."
echo

mapfile -t SOUND_DIRS < <(
    find "$SEARCH_ROOT" -mindepth 1 -type f -name '*.mka' -print0 \
    | xargs -0 -I{} dirname {} \
    | sort -u
)

if [[ ${#SOUND_DIRS[@]} -eq 0 ]]; then
    echo "Папки с .mka файлами не найдены в «${SEARCH_ROOT#./}»"
    exit 1
fi

echo "Доступные озвучки:"
echo

for i in "${!SOUND_DIRS[@]}"; do
    name="${SOUND_DIRS[$i]}"
    name="${name#./}"
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
echo "Выбрана озвучка: ${SELECTED_DIR#./}"

# ── 3. Выбор целевой папки (куда класть хардлинки) ─────────────────────────

read -rp "Куда положить хардлинки: " RAW_TARGET_DIR
eval "TARGET_DIR=$RAW_TARGET_DIR"

mkdir -p "$TARGET_DIR"

# ── 4. Создание хардлинков ──────────────────────────────────────────────────

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

    # Формат: "NN. Title.mka" — просто номер серии в начале имени
    elif [[ "$BASENAME" =~ ^([0-9]+)[[:space:]]*\. ]]; then
        SEASON="1"
        EPISODE="${BASH_REMATCH[1]}"

    # Формат: "Title - NN (tags).mka" — номер серии после " - " перед пробелом/скобкой
    elif [[ "$BASENAME" =~ -[[:space:]]+([0-9]{1,3})[[:space:]]*([\(\[]) ]]; then
        SEASON="1"
        EPISODE="${BASH_REMATCH[1]}"

    else
        echo "Не удалось определить серию: $BASENAME"
        continue
    fi

    SERIES_PATTERN="S$(printf "%02d" $((10#$SEASON)))E$(printf "%02d" $((10#$EPISODE)))"

    MKV_FILE=$(find "$TARGET_DIR" -type f -name "*${SERIES_PATTERN}*.mkv" | head -n 1)

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