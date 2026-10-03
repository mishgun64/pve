
$ErrorActionPreference = "Stop"

# ============================================================
# WOODPECKER CI CONFIG
# ============================================================

$Repo = "mishgun64/pve"
$Branch = "main"

# ============================================================
# SERVICES
# ============================================================

$services = @(
    @{
        Name = "Media"
        Pipelines = @(
            @{
                Name = "Config"
                Role = "media_vm/backup;media_vm/config;media_vm/restore"
                Pipeline = "media/config"
                Target = "media_vm"
                Message = "Media Config"
            },
            @{
                Name = "Backup"
                Role = "media_vm/backup"
                Pipeline = "media/backup"
                Target = "media_vm"
                Message = "Media Backup"
            },
            @{
                Name = "Restore"
                Role = "media_vm/restore"
                Pipeline = "media/restore"
                Target = "media_vm"
                Message = "Media Restore"
            },
            @{
                Name = "Full"
                Role = $null
                Pipeline = "media/full"
                Target = $null
                Message = "Media Full"
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
                Message = "Nextcloud Config"
            },
            @{
                Name = "Backup"
                Role = "nextcloud/backup"
                Pipeline = "nextcloud/backup"
                Target = "nextcloud_vm"
                Message = "Nextcloud Backup"
            },
            @{
                Name = "Restore"
                Role = "nextcloud/restore"
                Pipeline = "nextcloud/restore"
                Target = "nextcloud_vm"
                Message = "Nextcloud Restore"
            },
            @{
                Name = "Full"
                Role = $null
                Pipeline = "nextcloud/full"
                Target = $null
                Message = "Nextcloud Full"
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
                Message = "PvPGN Config"
            },
            @{
                Name = "Backup"
                Role = "pvpgn/backup"
                Pipeline = "pvpgn/backup"
                Target = "pvpgn_lxc"
                Message = "PvPGN Backup"
            },
            @{
                Name = "Restore"
                Role = "pvpgn/restore"
                Pipeline = "pvpgn/restore"
                Target = "pvpgn_lxc"
                Message = "PvPGN Restore"
            },
            @{
                Name = "Full"
                Role = $null
                Pipeline = "pvpgn/full"
                Target = $null
                Message = "PvPGN Full"
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
                Message = "Traefik Config"
            },
            @{
                Name = "Backup"
                Role = "traefik/backup"
                Pipeline = "traefik/backup"
                Target = "traefik_lxc"
                Message = "Traefik Backup"
            },
            @{
                Name = "Restore"
                Role = "traefik/restore"
                Pipeline = "traefik/restore"
                Target = "traefik_lxc"
                Message = "Traefik Restore"
            },
            @{
                Name = "Full"
                Role = $null
                Pipeline = "traefik/full"
                Target = $null
                Message = "Traefik Full"
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
                Message = "Valheim Config"
            },
            @{
                Name = "Backup"
                Role = "valheim/backup"
                Pipeline = "valheim/backup"
                Target = "valheim_lxc"
                Message = "Valheim Backup"
            },
            @{
                Name = "Restore"
                Role = "valheim/restore"
                Pipeline = "valheim/restore"
                Target = "valheim_lxc"
                Message = "Valheim Restore"
            },
            @{
                Name = "Full"
                Role = $null
                Pipeline = "valheim/full"
                Target = $null
                Message = "Valheim Full"
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
                Message = "WireGuard Config"
            },
            @{
                Name = "Full"
                Role = $null
                Pipeline = "wireguard/full"
                Target = $null
                Message = "WireGuard Full"
            }
        )
    }
)

# ============================================================
# FUNCTIONS
# ============================================================

function Show-Header {
    Clear-Host

    Write-Host ""
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║           WOODPECKER CI              ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Select-MenuItem {
    param (
        [Parameter(Mandatory = $true)]
        [array]$Items,

        [Parameter(Mandatory = $true)]
        [string]$Title,

        [string]$DisplayProperty = "Name"
    )

    $selected = 0

    while ($true) {
        Show-Header

        Write-Host "$Title" -ForegroundColor White
        Write-Host ""

        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ($i -eq $selected) {
                Write-Host "  > $($Items[$i].$DisplayProperty)" -ForegroundColor Green
            }
            else {
                Write-Host "    $($Items[$i].$DisplayProperty)" -ForegroundColor Gray
            }
        }

        Write-Host ""
        Write-Host "  ↑ ↓  выбор    Enter  подтвердить    Esc  выход" -ForegroundColor DarkGray

        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            "UpArrow" {
                if ($selected -gt 0) {
                    $selected--
                }
            }

            "DownArrow" {
                if ($selected -lt ($Items.Count - 1)) {
                    $selected++
                }
            }

            "Enter" {
                return $Items[$selected]
            }

            "Escape" {
                exit 0
            }
        }
    }
}

# ============================================================
# CHECK WOODPECKER CLI
# ============================================================

try {
    $null = Get-Command woodpecker-cli -ErrorAction Stop
}
catch {
    Write-Host ""
    Write-Host "ERROR: woodpecker-cli not found." -ForegroundColor Red
    Write-Host ""
    exit 1
}

# ============================================================
# SELECT SERVICE
# ============================================================

$selectedService = Select-MenuItem `
    -Items $services `
    -Title "Select service:"

# ============================================================
# SELECT PIPELINE
# ============================================================

$selectedPipeline = Select-MenuItem `
    -Items $selectedService.Pipelines `
    -Title "Select pipeline:"

# ============================================================
# DISPLAY SELECTION
# ============================================================

Show-Header

Write-Host " Starting pipeline..." -ForegroundColor White
Write-Host ""
Write-Host "  Service:  $($selectedService.Name)" -ForegroundColor Gray
Write-Host "  Pipeline: $($selectedPipeline.Pipeline)" -ForegroundColor Gray
Write-Host "  Role:     $($selectedPipeline.Role)" -ForegroundColor Gray
Write-Host "  Target:   $($selectedPipeline.Target)" -ForegroundColor Gray
Write-Host ""

Write-Host " Creating pipeline..." -ForegroundColor Yellow
Write-Host ""

# ============================================================
# BUILD WOODPECKER CLI ARGUMENTS
# ============================================================

$args = @(
    "pipeline"
    "create"
    $Repo
    "--branch"
    $Branch
    "--var"
    "PIPELINE=$($selectedPipeline.Pipeline)"
)

if (-not [string]::IsNullOrWhiteSpace($selectedPipeline.Role)) {
    $args += "--var"
    $args += "ROLE=$($selectedPipeline.Role)"
}

if (-not [string]::IsNullOrWhiteSpace($selectedPipeline.Target)) {
    $args += "--var"
    $args += "TARGET=$($selectedPipeline.Target)"
}

# ============================================================
# DEBUG
# ============================================================

Write-Host " PIPELINE = [$($selectedPipeline.Pipeline)]" -ForegroundColor DarkGray
Write-Host " ROLE     = [$($selectedPipeline.Role)]" -ForegroundColor DarkGray
Write-Host " TARGET   = [$($selectedPipeline.Target)]" -ForegroundColor DarkGray
Write-Host ""

# ============================================================
# CREATE PIPELINE
# ============================================================

& woodpecker-cli @args

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║         PIPELINE CREATION ERROR      ║" -ForegroundColor Red
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Host " Exit code: $LASTEXITCODE" -ForegroundColor Red
    exit $LASTEXITCODE
}

# ============================================================
# SUCCESS
# ============================================================

Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║          PIPELINE CREATED            ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

Write-Host " Service:  $($selectedService.Name)" -ForegroundColor White
Write-Host " Pipeline: $($selectedPipeline.Pipeline)" -ForegroundColor White

if (-not [string]::IsNullOrWhiteSpace($selectedPipeline.Role)) {
    Write-Host " Role:     $($selectedPipeline.Role)" -ForegroundColor White
}

if (-not [string]::IsNullOrWhiteSpace($selectedPipeline.Target)) {
    Write-Host " Target:   $($selectedPipeline.Target)" -ForegroundColor White
}

Write-Host ""
