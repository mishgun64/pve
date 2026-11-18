param(
    [string]$Server = $env:WOODPECKER_SERVER,
    [string]$Token  = $env:WOODPECKER_TOKEN
)

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
        Name = "Common"
        Pipelines = @(
            @{
                Name = "Basic"
                Role = "common/basic"
                Pipeline = "common/basic"
                Target = "docker_hosts"
                Message = "Common Basic"
            },
            @{
                Name = "Docker"
                Role = "common/docker"
                Pipeline = "common/docker"
                Target = "docker_hosts"
                Message = "Common Docker"
            }
        )
    },

    @{
        Name = "PVE"
        Pipelines = @(
            @{
                Name = "Firewall"
                Role = "pve/firewall"
                Pipeline = "pve/firewall"
                Target = "pve"
                Message = "PVE Firewall"
            }
        )
    },

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
                Name = "Firewall"
                Role = "media_vm/firewall"
                Pipeline = "media_vm/firewall"
                Target = "pve"
                Message = "Media Firewall"
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
                Name = "Firewall"
                Role = "nextcloud/firewall"
                Pipeline = "nextcloud/firewall"
                Target = "pve"
                Message = "Nextcloud Firewall"
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
                Name = "Firewall"
                Role = "pvpgn/firewall"
                Pipeline = "pvpgn/firewall"
                Target = "pve"
                Message = "PvPGN Firewall"
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
                Name = "Firewall"
                Role = "traefik/firewall"
                Pipeline = "traefik/firewall"
                Target = "pve"
                Message = "Traefik Firewall"
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
                Name = "Firewall"
                Role = "valheim/firewall"
                Pipeline = "valheim/firewall"
                Target = "pve"
                Message = "Valheim Firewall"
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
                Name = "Firewall"
                Role = "wireguard/firewall"
                Pipeline = "wireguard/firewall"
                Target = "pve"
                Message = "WireGuard Firewall"
            }
        )
    },

    @{
        Name = "Santa Bot"
        Pipelines = @(
            @{
                Name = "Config"
                Role = "santa_bot/config"
                Pipeline = "santa_bot/config"
                Target = "santa_bot_lxc"
                Message = "Santa Bot Config"
            },
            @{
                Name = "Backup"
                Role = "santa_bot/backup"
                Pipeline = "santa_bot/backup"
                Target = "santa_bot_lxc"
                Message = "Santa Bot Backup"
            },
            @{
                Name = "Restore"
                Role = "santa_bot/restore"
                Pipeline = "santa_bot/restore"
                Target = "santa_bot_lxc"
                Message = "Santa Bot Restore"
            },
            @{
                Name = "Firewall"
                Role = "santa_bot/firewall"
                Pipeline = "santa_bot/firewall"
                Target = "pve"
                Message = "Santa Bot Firewall"
            },
            @{
                Name = "Full"
                Role = $null
                Pipeline = "santa_bot/full"
                Target = $null
                Message = "Santa Bot Full"
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
# WOODPECKER API CONFIG
# ============================================================

if ([string]::IsNullOrWhiteSpace($Server)) {
    Write-Host ""
    Write-Host "Woodpecker server is not set." -ForegroundColor Yellow
    Write-Host "Enter URL, e.g. http://192.168.2.200:8000" -ForegroundColor Gray
    $Server = Read-Host "Server"
}

if ([string]::IsNullOrWhiteSpace($Server)) {
    Write-Host ""
    Write-Host "ERROR: server URL is required." -ForegroundColor Red
    Write-Host "Set it with: `$env:WOODPECKER_SERVER = 'http://192.168.2.200:8000'" -ForegroundColor Gray
    Write-Host "Or pass:    .\wp_cli.ps1 -Server http://192.168.2.200:8000" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-Host ""
    Write-Host "Woodpecker API token is not set." -ForegroundColor Yellow
    Write-Host "Create a personal access token in Woodpecker UI (User settings -> API)." -ForegroundColor Gray
    $secureToken = Read-Host "Token" -AsSecureString
    $Token = [System.Net.NetworkCredential]::new("", $secureToken).Password
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-Host ""
    Write-Host "ERROR: API token is required." -ForegroundColor Red
    Write-Host "Set it with: `$env:WOODPECKER_TOKEN = '<token>'" -ForegroundColor Gray
    Write-Host "Or pass:    .\wp_cli.ps1 -Token '<token>'" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

$Server = $Server.TrimEnd('/')
$Headers = @{ Authorization = "Bearer $Token" }

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
# BUILD PIPELINE VARIABLES
# ============================================================

$Variables = @{
    PIPELINE = $selectedPipeline.Pipeline
}

if (-not [string]::IsNullOrWhiteSpace($selectedPipeline.Role)) {
    $Variables["ROLE"] = $selectedPipeline.Role
}

if (-not [string]::IsNullOrWhiteSpace($selectedPipeline.Target)) {
    $Variables["TARGET"] = $selectedPipeline.Target
}

# ============================================================
# DEBUG
# ============================================================

Write-Host " PIPELINE = [$($selectedPipeline.Pipeline)]" -ForegroundColor DarkGray
Write-Host " ROLE     = [$($selectedPipeline.Role)]" -ForegroundColor DarkGray
Write-Host " TARGET   = [$($selectedPipeline.Target)]" -ForegroundColor DarkGray
Write-Host ""

# ============================================================
# CREATE PIPELINE VIA WOODPECKER API
# ============================================================

try {
    $repoInfo = Invoke-RestMethod `
        -Method Get `
        -Uri "$Server/api/repos/lookup/$Repo" `
        -Headers $Headers `
        -ErrorAction Stop

    $body = @{
        branch    = $Branch
        variables = $Variables
    } | ConvertTo-Json -Depth 5

    $pipeline = Invoke-RestMethod `
        -Method Post `
        -Uri "$Server/api/repos/$($repoInfo.id)/pipelines" `
        -Headers $Headers `
        -ContentType "application/json" `
        -Body $body `
        -ErrorAction Stop
}
catch {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║         PIPELINE CREATION ERROR      ║" -ForegroundColor Red
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Host " $($_.Exception.Message)" -ForegroundColor Red

    if ($_.ErrorDetails.Message) {
        Write-Host ""
        Write-Host " $($_.ErrorDetails.Message)" -ForegroundColor DarkGray
    }

    Write-Host ""
    exit 1
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
Write-Host " Number:   $($pipeline.number)" -ForegroundColor White

if (-not [string]::IsNullOrWhiteSpace($selectedPipeline.Role)) {
    Write-Host " Role:     $($selectedPipeline.Role)" -ForegroundColor White
}

if (-not [string]::IsNullOrWhiteSpace($selectedPipeline.Target)) {
    Write-Host " Target:   $($selectedPipeline.Target)" -ForegroundColor White
}

Write-Host ""