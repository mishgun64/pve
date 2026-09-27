#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка root
if [[ $EUID -ne 0 ]]; then
    error "Скрипт нужно запускать от root: sudo $0"
    exit 1
fi

# Проверка наличия LVM утилит
for cmd in lvs vgs pvs lvremove vgremove pvremove vgchange; do
    if ! command -v $cmd &>/dev/null; then
        error "Утилита '$cmd' не найдена. Установи: sudo apt install lvm2"
        exit 1
    fi
done

echo ""
echo "=============================="
echo "     LVM Cleanup Script"
echo "=============================="
echo ""

# Показать что будет удалено
LVS=$(lvs --noheadings -o lv_path 2>/dev/null | tr -d ' ' || true)
VGS=$(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ' || true)
PVS=$(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' ' || true)

if [[ -z "$LVS" && -z "$VGS" && -z "$PVS" ]]; then
    log "LVM томов не найдено. Нечего удалять."
    exit 0
fi

echo -e "${YELLOW}Будет удалено:${NC}"
echo ""

if [[ -n "$LVS" ]]; then
    echo "  Логические тома (LV):"
    for lv in $LVS; do echo "    - $lv"; done
fi

if [[ -n "$VGS" ]]; then
    echo "  Группы томов (VG):"
    for vg in $VGS; do echo "    - $vg"; done
fi

if [[ -n "$PVS" ]]; then
    echo "  Физические тома (PV):"
    for pv in $PVS; do echo "    - $pv"; done
fi

echo ""
warn "ВСЕ ДАННЫЕ БУДУТ УНИЧТОЖЕНЫ БЕЗ ВОЗМОЖНОСТИ ВОССТАНОВЛЕНИЯ!"
echo ""
read -r -p "Введите 'YES' для подтверждения: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
    log "Отменено."
    exit 0
fi

echo ""

# Шаг 1: Отмонтировать все LV
log "Отмонтирование логических томов..."
for lv in $LVS; do
    if mountpoint -q "$lv" 2>/dev/null || grep -q "^$lv " /proc/mounts 2>/dev/null; then
        warn "Отмонтирование $lv"
        umount -f "$lv" 2>/dev/null && log "Отмонтирован: $lv" || warn "Не удалось отмонтировать: $lv (возможно уже отмонтирован)"
    fi
done

# Шаг 2: Деактивировать все VG
log "Деактивация групп томов..."
for vg in $VGS; do
    vgchange -an "$vg" && log "Деактивирована VG: $vg" || warn "Не удалось деактивировать VG: $vg"
done

# Шаг 3: Удалить LV
log "Удаление логических томов..."
for vg in $VGS; do
    if lvs "$vg" &>/dev/null; then
        lvremove -f "$vg" && log "Удалены LV в VG: $vg" || error "Ошибка удаления LV в VG: $vg"
    fi
done

# Шаг 4: Удалить VG
log "Удаление групп томов..."
for vg in $VGS; do
    vgremove -f "$vg" && log "Удалена VG: $vg" || error "Ошибка удаления VG: $vg"
done

# Шаг 5: Удалить PV
log "Удаление физических томов..."
for pv in $PVS; do
    pvremove -f "$pv" && log "Удалён PV: $pv" || error "Ошибка удаления PV: $pv"
done

echo ""
log "Проверка..."
REMAINING_LVS=$(lvs --noheadings 2>/dev/null | tr -d ' ' || true)
REMAINING_VGS=$(vgs --noheadings 2>/dev/null | tr -d ' ' || true)
REMAINING_PVS=$(pvs --noheadings 2>/dev/null | tr -d ' ' || true)

if [[ -z "$REMAINING_LVS" && -z "$REMAINING_VGS" && -z "$REMAINING_PVS" ]]; then
    echo ""
    log "✓ Все LVM структуры успешно удалены."
else
    warn "Остались неудалённые структуры:"
    [[ -n "$REMAINING_LVS" ]] && echo "  LV: $REMAINING_LVS"
    [[ -n "$REMAINING_VGS" ]] && echo "  VG: $REMAINING_VGS"
    [[ -n "$REMAINING_PVS" ]] && echo "  PV: $REMAINING_PVS"
fi

echo ""