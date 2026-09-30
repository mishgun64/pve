$ErrorActionPreference = "Stop"

$items = @(
@{
Name = "Backup"
Role = "pvpgn/backup"
Pipeline = "backup"
},
@{
Name = "Config"
Role = "pvpgn/config"
Pipeline = "config"
},
@{
Name = "Restore"
Role = "pvpgn/restore"
Pipeline = "restore"
},
@{
Name = "Cancel"
Role = $null
Pipeline = $null
}
)

$selected = 0

while ($true) {
Clear-Host


Write-Host "Woodpecker CI"
Write-Host ""
Write-Host "Select pipeline:"
Write-Host ""

for ($i = 0; $i -lt $items.Count; $i++) {
    if ($i -eq $selected) {
        Write-Host "-> $($items[$i].Name)"
    }
    else {
        Write-Host "   $($items[$i].Name)"
    }
}

Write-Host ""
Write-Host "Up/Down = select    Enter = run    Esc = exit"

$key = [Console]::ReadKey($true)

switch ($key.Key) {
    "UpArrow" {
        $selected--
        if ($selected -lt 0) {
            $selected = $items.Count - 1
        }
    }

    "DownArrow" {
        $selected++
        if ($selected -ge $items.Count) {
            $selected = 0
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

$selectedItem = $items[$selected]

if ($null -eq $selectedItem.Role) {
Clear-Host
Write-Host "Cancelled."
exit 0
}

Clear-Host

Write-Host "Woodpecker CI"
Write-Host ""
Write-Host "Starting pipeline:"
Write-Host "  Pipeline: $($selectedItem.Pipeline)"
Write-Host "  Role:     $($selectedItem.Role)"
Write-Host "  Target:   pvpgn_lxc"
Write-Host ""

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
"TARGET=pvpgn_lxc"
)

& woodpecker-cli @args

if ($LASTEXITCODE -ne 0) {
Write-Host ""
Write-Host "Pipeline creation failed."
Write-Host "Exit code: $LASTEXITCODE"
exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Pipeline created successfully."
