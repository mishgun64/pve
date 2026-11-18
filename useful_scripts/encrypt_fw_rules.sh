#!/usr/bin/env bash
#
# Encrypt firewall rules (*.fw) with sops.
# Plain-text files are expected next to the encrypted *.fw.enc files
# inside the corresponding ansible firewall role.
#
# Usage: ./encrypt_fw_rules.sh

set -uo pipefail

files=(
    "ansible/roles/pve/firewall/files/cluster.fw"
    "ansible/roles/media_vm/firewall/files/124.fw"
    "ansible/roles/wireguard/firewall/files/126.fw"
    "ansible/roles/traefik/firewall/files/143.fw"
    "ansible/roles/pvpgn/firewall/files/145.fw"
    "ansible/roles/nextcloud/firewall/files/125.fw"
    "ansible/roles/valheim/firewall/files/146.fw"
    "ansible/roles/santa_bot/firewall/files/148.fw"
)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0

if ! command -v sops >/dev/null 2>&1; then
    echo "ERROR: sops not found in PATH" >&2
    exit 1
fi

for relative_file in "${files[@]}"; do
    file="${repo_root}/${relative_file}"

    if [[ ! -f "$file" ]]; then
        echo "WARNING: file not found: $file" >&2
        continue
    fi

    enc_file="${file}.enc"
    echo "Encrypting: $file -> $enc_file"

    if ! sops -e --output "$enc_file" "$file"; then
        echo "ERROR: sops failed for $file" >&2
        failed=1
    fi
done

if (( failed )); then
    echo "Done with errors" >&2
    exit 1
fi

echo "Done"