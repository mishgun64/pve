$files = @(
    "../ansible/roles/pve/config_soft/files/cluster.fw",
    "../ansible/roles/media_vm/config_soft/files/124.fw",
    "../ansible/roles/wireguard/files/126.fw",
    "../ansible/roles/traefik/config/files/143.fw"
)

foreach ($file in $files) {

    if (!(Test-Path $file)) {
        Write-Warning "File not found: $file"
        continue
    }

    $encFile = "$file.enc"

    Write-Host "Encrypting: $file -> $encFile"

    $output = sops -e $file
    if ($LASTEXITCODE -ne 0) {
        Write-Error "sops failed for $file"
        continue
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($encFile, $output, $utf8NoBom)
}

Write-Host "Done"