#!/usr/bin/env bash
set -euo pipefail

URL="https://enterprise.proxmox.com/iso/"
ANSWER_URL="https://raw.githubusercontent.com/mishgun64/pve/refs/heads/main/answer.toml"
STATE_FILE="pve-last-version"

WORKDIR="$(pwd)"
MOUNT_DIR="$WORKDIR/mnt"
EXTRACTED_DIR="$WORKDIR/extracted"
RESULT_DIR="/srv/pve-iso"
ANSWER_FILE="$WORKDIR/answer.toml"

mkdir -p "$MOUNT_DIR" "$RESULT_DIR"

# --- определить последнюю версию ---
latest_version=$(
  curl -fsSL "$URL" |
    grep -oE 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' |
    sed -E 's/proxmox-ve_([0-9]+\.[0-9]+-[0-9]+)\.iso/\1/' |
    sort -V |
    tail -n1
)

if [[ -z "$latest_version" ]]; then
  echo "Не удалось определить последнюю версию"
  exit 1
fi

saved_version=""
if [[ -s "$STATE_FILE" ]]; then
  saved_version=$(cat "$STATE_FILE")
fi

version_gt() {
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]] && [[ "$1" != "$2" ]]
}

if [[ -n "$saved_version" ]] && ! version_gt "$latest_version" "$saved_version"; then
  echo "Обновление не требуется ($saved_version)"
  exit 0
fi

# --- скачать answer.toml ---
curl -fsSL "$ANSWER_URL" | sops -d /dev/stdin > "$ANSWER_FILE"
cat "$ANSWER_FILE"
# --- скачать ISO как source.iso ---
curl -fSL -o "$WORKDIR/source.iso" "${URL}/proxmox-ve_${latest_version}.iso"
echo "$latest_version" > "$STATE_FILE"

# --- подготовка ISO (fetch-from iso, локальный answer.toml) ---
proxmox-auto-install-assistant prepare-iso "$WORKDIR/source.iso" \
  --fetch-from iso \
  --answer-file "$ANSWER_FILE"

# --- удалить временные файлы ---
rm -f "$WORKDIR/source.iso" "$ANSWER_FILE"

AUTO_ISO="$WORKDIR/source-auto-from-iso.iso"

# --- монтирование подготовленного ISO ---
sudo mount -o loop "$AUTO_ISO" "$MOUNT_DIR"

cp "$MOUNT_DIR/boot/linux26" "$WORKDIR/linux26"
cp "$MOUNT_DIR/boot/initrd.img" "$WORKDIR/initrd.img"

sudo umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

# --- распаковка initrd (zstd + cpio) ---
rm -rf "$EXTRACTED_DIR"
mkdir -p "$EXTRACTED_DIR"

zstd -d -f "$WORKDIR/initrd.img" -o "$WORKDIR/initrd.img.cpio"
rm -f "$WORKDIR/initrd.img"

cd "$EXTRACTED_DIR"
cpio -idv < "$WORKDIR/initrd.img.cpio"
rm -f "$WORKDIR/initrd.img.cpio"

# --- перенос ISO внутрь initrd ---
mv "$AUTO_ISO" "$EXTRACTED_DIR/proxmox.iso"

# --- упаковка initrd обратно ---
find . | cpio --quiet -o -H newc > "$WORKDIR/custom.initrd.img.cpio"
zstd -19 -f "$WORKDIR/custom.initrd.img.cpio" -o "$WORKDIR/custom-initrd.img"

# --- очистка ---
cd "$WORKDIR"
rm -f "$WORKDIR/custom.initrd.img.cpio"
rm -rf "$EXTRACTED_DIR"
rm -f "./auto-installer-mode.toml"

# --- перенос результата ---
mv "$WORKDIR/linux26" "$RESULT_DIR/linux26"
mv "$WORKDIR/custom-initrd.img" "$RESULT_DIR/custom-initrd.img"

echo "Готово:"
echo "- $RESULT_DIR/linux26"
echo "- $RESULT_DIR/custom-initrd.img"
