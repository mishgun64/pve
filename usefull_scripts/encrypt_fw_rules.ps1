$files = @(
    "../ansible/roles/pve/config_soft/files/cluster.fw",
    "../ansible/roles/media_vm/config_soft/files/124.fw",
    "../ansible/roles/wireguard/files/126.fw",
    "../ansible/roles/traefik/config/files/143.fw"
    "../ansible/roles/openfire/config/files/144.fw"
)

foreach ($file in $files) {
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