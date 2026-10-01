$ErrorActionPreference = "Stop"

$services = @(
    @{
        Name = "Media"
        Pipelines = @(
            @{
                Name = "Config"
                Role = "media_vm/config"
                Pipeline = "media_vm/config"
                Target = "media_vm"
            },
            @{
                Name = "Backup"
                Role = "media_vm/backup"
                Pipeline = "media_vm/backup"
                Target = "media_vm"
            },
            @{
                Name = "Restore"
                Role = "media_vm/restore"
                Pipeline = "media_vm/restore"
                Target = "media_vm"
            },
            @{
                Name = "Full"
                Role = $null
                Pipeline = "media_vm/full"
                Target = $null
            }
        )
    },
    @{
        Name = "Nextcloud"
        Pipelines = @(
            @{
                Name = "Config"
                Role = "nextcloud/config"
                Pipeline = "nextcloud/config"
                Target = "nextcloud_vm"
            },
            @{
                Name = "Backup"
                Role = "nextcloud/backup"
                Pipeline = "nextcloud/backup"
                Target = "nextcloud_vm"
            },
            @{
                Name = "Restore"
                Role = "nextcloud/restore"
                Pipeline = "nextcloud/restore"
                Target = "nextcloud_vm"
            },
            @{
                Name = "Full"
                Role = $null
                Pipeline = "nextcloud/full"
                Target = $null
            }
        )
    },
    @{
        Name = "PvPGN"
        Pipelines = @(
            @{
                Name = "Config"
                Role = "pvpgn/config"
                Pipeline = "pvpgn/config"
                Target = "pvpgn_lxc"
            },
            @{
                Name = "Backup"
                Role = "pvpgn/backup"
                Pipeline = "pvpgn/backup"
                Target = "pvpgn_lxc"
            },
            @{
                Name = "Restore"
                Role = "pvpgn/restore"
                Pipeline = "pvpgn/restore"
                Target = "pvpgn_lxc"
            },
            @{
                Name = "Full"
                Role = $null
                Pipeline = "pvpgn/full"
                Target = $null
            }
        )
    },
    @{
        Name = "Traefik"
        Pipelines = @(
            @{
                Name = "Config"
                Role = "traefik/config"
                Pipeline = "traefik/config"
                Target = "traefik_lxc"
            },
            @{
                Name = "Backup"
                Role = "traefik/backup"
                Pipeline = "traefik/backup"
                Target = "traefik_lxc"
            },
            @{
                Name = "Restore"
                Role = "traefik/restore"
                Pipeline = "traefik/restore"
                Target = "traefik_lxc"
            },
            @{
                Name = "Full"
                Role = $null
                Pipeline = "traefik/full"
                Target = $null
            }
        )
    },
    @{
        Name = "Valheim"
        Pipelines = @(
            @{
                Name = "Config"
                Role = "valheim/config"
                Pipeline = "valheim/config"
                Target = "valheim_lxc"
            },
            @{
                Name = "Backup"
                Role = "valheim/backup"
                Pipeline = "valheim/backup"
                Target = "valheim_lxc"
            },
            @{
                Name = "Restore"
                Role = "valheim/restore"
                Pipeline = "valheim/restore"
                Target = "valheim_lxc"
            },
            @{
                Name = "Full"
                Role = $null
                Pipeline = "valheim/full"
                Target = $null
            }
        )
    },
    @{
        Name = "WireGuard"
        Pipelines = @(
            @{
                Name = "Config"
                Role = "wireguard/config"
                Pipeline = "wireguard/config"
                Target = "wg_lxc"
            },
            @{
                Name = "Full"
                Role = $null
                Pipeline = "wireguard/full"
                Target = $null
            }
        )
    },
    @{
        Name = "Cancel"
        Pipelines = $null
    }
)

# -------------------------- Service selection --------------------------

$selectedService = 0

while ($true) {
    Clear-Host

    Write-Host "Woodpecker CI"
    Write-Host ""
    Write-Host "Select service:"
    Write-Host ""

    for ($i = 0; $i -lt $services.Count; $i++) {
        if ($i -eq $selectedService) {
            Write-Host "-> $($services[$i].Name)"
        }
        else {
            Write-Host "   $($services[$i].Name)"
        }
    }

    Write-Host ""
    Write-Host "Up/Down = select    Enter = open    Esc = exit"

    $key = [Console]::ReadKey($true)

    switch ($key.Key) {
        "UpArrow" {
            $selectedService--

            if ($selectedService -lt 0) {
                $selectedService = $services.Count - 1
            }
        }

        "DownArrow" {
            $selectedService++

            if ($selectedService -ge $services.Count) {
                $selectedService = 0
            }
        }

        "Enter" {
            break
        }

        "Escape" {
            exit 0
        }
    }

    if ($key.Key -eq "Enter") {
        break
    }
}

$selectedServiceItem = $services[$selectedService]

if ($null -eq $selectedServiceItem.Pipelines) {
    Clear-Host
    Write-Host "Cancelled."
    exit 0
}

# -------------------------- Pipeline selection --------------------------

$selectedPipeline = 0
$pipelines = $selectedServiceItem.Pipelines

while ($true) {
    Clear-Host

    Write-Host "Woodpecker CI"
    Write-Host ""
    Write-Host "Service: $($selectedServiceItem.Name)"
    Write-Host ""
    Write-Host "Select pipeline:"
    Write-Host ""

    for ($i = 0; $i -lt $pipelines.Count; $i++) {
        if ($i -eq $selectedPipeline) {
            Write-Host "-> $($pipelines[$i].Name)"
        }
        else {
            Write-Host "   $($pipelines[$i].Name)"
        }
    }

    Write-Host "   Cancel"
    Write-Host ""
    Write-Host "Up/Down = select    Enter = run    Esc = back"

    $key = [Console]::ReadKey($true)

    switch ($key.Key) {
        "UpArrow" {
            $selectedPipeline--

            if ($selectedPipeline -lt 0) {
                $selectedPipeline = $pipelines.Count - 1
            }
        }

        "DownArrow" {
            $selectedPipeline++

            if ($selectedPipeline -ge $pipelines.Count) {
                $selectedPipeline = 0
            }
        }

        "Enter" {
            break
        }

        "Escape" {
            break
        }
    }

    if ($key.Key -eq "Enter" -or $key.Key -eq "Escape") {
        break
    }
}

if ($key.Key -eq "Escape") {
    exit 0
}

$selectedItem = $pipelines[$selectedPipeline]

# -------------------------- Start pipeline --------------------------

Clear-Host

Write-Host "Woodpecker CI"
Write-Host ""
Write-Host "Starting pipeline:"
Write-Host "  Service:  $($selectedServiceItem.Name)"
Write-Host "  Pipeline: $($selectedItem.Pipeline)"

if ($null -ne $selectedItem.Role) {
    Write-Host "  Role:     $($selectedItem.Role)"
    Write-Host "  Target:   $($selectedItem.Target)"
}

Write-Host ""

if ($null -eq $selectedItem.Role) {
    $args = @(
        "pipeline"
        "create"
        "mishgun64/pve"
        "--branch"
        "main"
        "--var"
        "PIPELINE=$($selectedItem.Pipeline)"
    )
}
else {
    $args = @(
        "pipeline"
        "create"
        "mishgun64/pve"
        "--branch"
        "main"
        "--var"
        "PIPELINE=$($selectedItem.Pipeline)"
        "--var"
        "ROLE=$($selectedItem.Role)"
        "--var"
        "TARGET=$($selectedItem.Target)"
    )
}

& woodpecker-cli @args

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Pipeline creation failed."
    Write-Host "Exit code: $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Pipeline created successfully."
