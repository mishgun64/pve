$files = @(
    "ansible/roles/pve/firewall/files/cluster.fw",
    "ansible/roles/media_vm/firewall/files/124.fw",
    "ansible/roles/wireguard/firewall/files/126.fw",
    "ansible/roles/traefik/firewall/files/143.fw",
    "ansible/roles/pvpgn/firewall/files/145.fw",
    "ansible/roles/nextcloud/firewall/files/125.fw",
    "ansible/roles/valheim/firewall/files/146.fw",
    "ansible/roles/santa_bot/firewall/files/148.fw"
)

$repoRoot = Split-Path -Parent $PSScriptRoot

foreach ($relativeFile in $files) {
    $file = Join-Path $repoRoot $relativeFile

    if (!(Test-Path $file)) {
        Write-Warning "File not found: $file"
        continue
    }

    $encFile = "$file.enc"
    Write-Host "Encrypting: $file -> $encFile"
    & sops -e --output $encFile $file

    if ($LASTEXITCODE -ne 0) {
        Write-Error "sops failed for $file"
    }
}

Write-Host "Done"