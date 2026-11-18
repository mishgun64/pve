<#
.SYNOPSIS
    Backup / restore of the pi agent configuration directory.
    Archive is encrypted with sops + age and uploaded to Google Drive via rclone.

.DESCRIPTION
    Collects a minimal subset of the pi agent directory (~/.pi/agent by default),
    packs it into tar.gz, encrypts the archive with sops using an age recipient
    (age1... or an ssh public key). The recipient / encryption key is requested
    interactively unless -Recipient is supplied.

    Backed up by default (minimal set):
      models.json, models-store.json, settings.json/.jsonc  (settings.json also
      holds the plugin registry: "packages": ["npm:..."]), extensions/

    Never backed up unless explicitly requested:
      sessions/            - only with -WithSessions
      ssh-remote-config.json, ssh-remote-known-hosts.json,
      ssh-remote-memories  - only with -WithSsh
      auth.json, mcp.json, mcp-auth.json (credentials)
                           - only with -WithSecrets
      missions/, data/     - only with -WithMissions / -WithData
      skills/, prompts/, themes/ - only with -WithContent
      AGENTS.md, keybindings.json, pi-subagents - only with -WithConfig

    Upload uses rclone copyto with --ignore-times, so an already existing
    remote object is overwritten. After upload the remote size and SHA256 are
    verified.

.PARAMETER Command
    Backup (default) or Restore.

.PARAMETER Recipient
    age recipient used for encryption: "age1..." or "ssh-ed25519 AAAA..." or a
    path to an ssh public key file. If omitted, you are prompted.

.PARAMETER Identity
    Private key used to verify the archive and to decrypt it on restore.
    May be an ssh private key (SOPS_AGE_SSH_PRIVATE_KEY_FILE) or an age
    identity file (SOPS_AGE_KEY_FILE). Never printed or copied anywhere.

.PARAMETER RequireVerify
    Fail the backup unless a local private key can decrypt the new archive.
    By default a recipient that belongs to another machine only produces a
    warning (the matching private key is simply not present here).

.PARAMETER SkipVerify
    Do not attempt the round-trip decryption check at all.

.PARAMETER WithConfig
    Also include keybindings.json, AGENTS*.md, CLAUDE.md, SYSTEM.md,
    APPEND_SYSTEM.md and pi-subagents.

.PARAMETER WithContent
    Also include skills/, prompts/ and themes/.

.PARAMETER WithSecrets
    Also include auth.json, mcp.json and mcp-auth.json (API keys / tokens).

.PARAMETER WithSsh
    Also include the remote SSH connection state: ssh-remote-config.json,
    ssh-remote-known-hosts.json and ssh-remote-memories/.

.PARAMETER WithSessions
    Also include sessions/ (conversation history).

.PARAMETER WithMissions / WithData
    Also include missions/ or data/ (caches).

.EXAMPLE
    .\backup-pi-agent.ps1
    .\backup-pi-agent.ps1 -WithContent -WithConfig
    .\backup-pi-agent.ps1 -WithSessions -Remote gdrive:pi-agent-backups
    .\backup-pi-agent.ps1 -NoUpload -Out C:\temp\pibackup
    .\backup-pi-agent.ps1 -Command Restore -Yes
#>
[CmdletBinding()]
param(
    [ValidateSet('Backup', 'Restore')]
    [string] $Command = 'Backup',

    [string] $Name,
    [string] $Remote = $(if ($env:RCLONE_REMOTE) { $env:RCLONE_REMOTE } else { 'gdrive:pi-agent-backups' }),
    [string] $Dir,
    [string] $Recipient = $env:SOPS_AGE_RECIPIENT,
    [string] $Identity,
    [string] $Out,
    [string] $Source,          # restore: remote path or local .sops file
    [switch] $WithSessions,
    [switch] $WithMissions,
    [switch] $NoMissions,      # deprecated no-op: missions are opt-in now
    [switch] $WithData,
    [switch] $WithConfig,
    [switch] $WithContent,
    [switch] $WithSecrets,
    [switch] $WithSsh,
    [switch] $NoUpload,
    [switch] $DryRun,
    [switch] $SkipVerify,
    [switch] $RequireVerify,
    [switch] $Yes
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# paths / tools
# ---------------------------------------------------------------------------
if (-not $Dir) {
    if ($env:PI_CODING_AGENT_DIR) { $Dir = $env:PI_CODING_AGENT_DIR }
    elseif ($env:PI_AGENT_DIR)    { $Dir = $env:PI_AGENT_DIR }
    else                          { $Dir = Join-Path $HOME '.pi/agent' }
}
$Dir = [IO.Path]::GetFullPath($Dir)

$hostSlug = ($env:COMPUTERNAME, 'pi-host' | Where-Object { $_ } | Select-Object -First 1)
$hostSlug = ($hostSlug -replace '[^A-Za-z0-9._-]', '-')
if (-not $Name) {
    if ($env:BACKUP_NAME) { $Name = $env:BACKUP_NAME }
    else { $Name = "pi-agent-config-$hostSlug.tar.gz.sops" }
}

function Write-Log([string] $Message) {
    Write-Host "[backup-pi-agent] $Message" -ForegroundColor DarkCyan
}
function Write-Warn([string] $Message) {
    Write-Host "[backup-pi-agent] WARNING: $Message" -ForegroundColor Yellow
}
function Stop-Script([string] $Message) {
    throw [System.Exception]::new("[backup-pi-agent] ERROR: $Message")
}

function Get-Tool([string] $Name) {
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $cmd) { Stop-Script "required tool '$Name' not found in PATH" }
    return $cmd.Source
}

function ConvertTo-Arg {
    param([string] $Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    # double every backslash that precedes a quote or the end of the argument
    $sb = New-Object System.Text.StringBuilder
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append('\' * ($slashes * 2 + 1)).Append('"')
            $slashes = 0
            continue
        }
        if ($slashes) { [void]$sb.Append('\' * $slashes); $slashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($slashes) { [void]$sb.Append('\' * ($slashes * 2)) }
    return '"' + $sb.ToString() + '"'
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string] $File,
        [string[]] $Arguments = @(),
        [hashtable] $Environment = @{},
        [switch] $AllowFailure
    )
    # Use System.Diagnostics.Process: in Windows PowerShell 5.1 a native
    # command writing to stderr while $ErrorActionPreference='Stop' aborts the
    # script, and we need a reliable exit code.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    # ProcessStartInfo.ArgumentList is .NET Core only; Windows PowerShell 5.1
    # runs on .NET Framework, so build a quoted command line there.
    if ($psi.PSObject.Properties['ArgumentList'] -and $psi.ArgumentList) {
        foreach ($a in $Arguments) { $psi.ArgumentList.Add([string]$a) }
    }
    else {
        $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-Arg ([string]$_) }) -join ' ')
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($k in $Environment.Keys) {
        $psi.EnvironmentVariables[$k] = [string]$Environment[$k]
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $code = $proc.ExitCode
    $proc.Dispose()

    $lines = @()
    if ($stdout) { $lines += ($stdout -split "
?
") | Where-Object { $_ -ne '' } }
    $text = (@($stdout, $stderr) | Where-Object { $_ }) -join "`n"
    $text = $text.Trim()

    if ($code -ne 0 -and -not $AllowFailure) {
        Stop-Script "'$([IO.Path]::GetFileName($File)) $($Arguments -join ' ')' failed (exit $code)`n$text"
    }
    return [pscustomobject]@{
        ExitCode = $code
        Output   = $lines
        Text     = $text
        Stdout   = $stdout
        Stderr   = $stderr
    }
}

# ---------------------------------------------------------------------------
# encryption key (requested from the user)
# ---------------------------------------------------------------------------
$script:RecipientCache = Join-Path ([IO.Path]::GetTempPath()) 'pi-agent-backup-recipient.txt'

function Resolve-Recipient {
    param([string] $Value)

    $Value = if ($Value) { $Value.Trim() } else { '' }

    # a path to a public key file is also accepted
    if ($Value -and -not $Value.StartsWith('age1') -and (Test-Path -LiteralPath $Value -PathType Leaf)) {
        $line = Get-Content -LiteralPath $Value -TotalCount 20 |
                Where-Object { $_ -match '^(ssh-ed25519|ssh-rsa)\s+\S+' } |
                Select-Object -First 1
        if (-not $line) { Stop-Script "no ssh-ed25519/ssh-rsa public key found in $Value" }
        $Value = (($line.Trim() -split '\s+')[0..1] -join ' ')
    }

    if ($Value -and $Value -notmatch '^(age1[a-z0-9]+|ssh-(ed25519|rsa)\s+\S+)') {
        Stop-Script "not a valid age recipient: '$Value' (expected age1..., ssh-ed25519 AAAA..., ssh-rsa AAAA... or a .pub file path)"
    }
    return $Value
}

function Request-Recipient {
    param([string] $Value)

    $cached = $null
    if (Test-Path -LiteralPath $script:RecipientCache) {
        $cached = (Get-Content -LiteralPath $script:RecipientCache -TotalCount 1)
        if ($cached) { $cached = $cached.Trim() }
    }

    $resolved = Resolve-Recipient -Value $Value
    if ($resolved) { return $resolved }

    Write-Host ''
    Write-Host 'Encryption key (age recipient) required.' -ForegroundColor Cyan
    Write-Host '  Paste an age recipient ("age1..."), an ssh public key line' -ForegroundColor Gray
    Write-Host '  ("ssh-ed25519 AAAA... user@host") or a path to a .pub file.' -ForegroundColor Gray
    if ($cached) { Write-Host "  Press Enter to reuse: $cached" -ForegroundColor Gray }
    Write-Host ''

    for ($i = 0; $i -lt 3; $i++) {
        $answer = Read-Host -Prompt 'Encryption key'
        if (-not $answer -and $cached) { $answer = $cached }
        if (-not $answer) { continue }
        try {
            $resolved = Resolve-Recipient -Value $answer
            if (-not $resolved) { continue }
        }
        catch {
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
            continue
        }
        # remember the public recipient for convenience (it is not a secret)
        try {
            Set-Content -LiteralPath $script:RecipientCache -Value $resolved -Encoding ASCII -NoNewline
        } catch { }
        return $resolved
    }
    Stop-Script 'no encryption key provided'
}

function Resolve-Identity {
    param([string] $Value, [switch] $Required)

    $candidates = @()
    if ($Value)            { $candidates += $Value }
    if ($env:SOPS_AGE_KEY_FILE) { $candidates += $env:SOPS_AGE_KEY_FILE }
    if ($env:SOPS_AGE_SSH_PRIVATE_KEY_FILE) { $candidates += $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE }
    $candidates += @(
        (Join-Path $HOME '.ssh/id_ed25519_pi'),
        (Join-Path $HOME '.ssh/id_ed25519'),
        (Join-Path $HOME '.config/sops/age/keys.txt'),
        (Join-Path $env:APPDATA 'sops/age/keys.txt')
    )

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            return [pscustomobject]@{ Path = (Get-Item -LiteralPath $c).FullName; EnvName = $null }
        }
    }

    if (-not $Required) { return $null }

    Write-Host ''
    Write-Host 'Private key needed for decryption.' -ForegroundColor Cyan
    Write-Host '  Provide a path to an ssh private key (id_ed25519) or an age identity file.' -ForegroundColor Gray
    for ($i = 0; $i -lt 3; $i++) {
        $answer = Read-Host -Prompt 'Private key path'
        if (-not $answer) { continue }
        if (-not (Test-Path -LiteralPath $answer -PathType Leaf)) {
            Write-Host '  file not found' -ForegroundColor Yellow
            continue
        }
        $full = (Get-Item -LiteralPath $answer).FullName
        $envName = 'SOPS_AGE_SSH_PRIVATE_KEY_FILE'
        $first = Get-Content -LiteralPath $full -TotalCount 1
        if ($first -match 'AGE-SECRET-KEY') { $envName = 'SOPS_AGE_KEY_FILE' }
        return [pscustomobject]@{ Path = $full; EnvName = $envName }
    }
    Stop-Script 'no private key provided'
}

# ---------------------------------------------------------------------------
# backup
# ---------------------------------------------------------------------------
$script:ToolSops  = $null
$script:ToolRclone = $null
$script:ToolTar   = $null
$script:TarExtra  = @()

# GNU tar (e.g. shipped with Git for Windows) treats "C:\..." as a remote
# host, so prefer the bundled bsdtar and fall back to --force-local.
function Resolve-Tar {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:SystemRoot) {
        $candidates.Add((Join-Path $env:SystemRoot 'System32\tar.exe'))
    }
    $candidates.Add((Get-Command 'tar' -CommandType Application -ErrorAction SilentlyContinue |
                     Select-Object -First 1).Source)

    foreach ($cand in $candidates) {
        if (-not $cand -or -not (Test-Path -LiteralPath $cand)) { continue }
        $ver = (& $cand --version 2>&1 | Out-String)
        if ($ver -match 'GNU tar') {
            return [pscustomobject]@{ Path = $cand; Extra = @('--force-local') }
        }
        return [pscustomobject]@{ Path = $cand; Extra = @() }
    }
    Stop-Script "required tool 'tar' not found"
}

# Public key that belongs to a local private key, as "ssh-<type> <base64>".
function Get-PublicKeyFromIdentity {
    param([string] $Path)
    if (-not (Get-Command 'ssh-keygen' -ErrorAction SilentlyContinue)) { return $null }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command 'ssh-keygen' -CommandType Application | Select-Object -First 1).Source
    $psi.Arguments = '-y -P "" -f "' + $Path + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $out = $proc.StandardOutput.ReadToEnd()
        [void]$proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { return $null }
    }
    catch { return $null }
    finally { $proc.Dispose() }
    $line = ($out -split "`r?`n" | Where-Object { $_ -match '^(ssh-ed25519|ssh-rsa)\s+\S+' } | Select-Object -First 1)
    if (-not $line) { return $null }
    return (($line.Trim() -split '\s+')[0..1] -join ' ')
}

# True when the failure is "this identity is not a recipient of the file"
# rather than "the file is damaged".
function Test-RecipientMismatch {
    param([string] $ErrorText)
    if (-not $ErrorText) { return $false }
    return ($ErrorText -match 'identity did not match any of the recipients' -or
            $ErrorText -match 'no identity matched any of the recipients' -or
            $ErrorText -match 'identity did not match any recipient')
}

# Returns: ok | mismatch | broken | nokey
function Test-ArchiveReadable {
    param([string] $Recipient, [string] $Archive, [string] $Encrypted)

    $identity = Resolve-Identity -Value $Identity
    if (-not $identity) { return 'nokey' }

    $isAgeKey = $false
    try { $isAgeKey = ((Get-Content -LiteralPath $identity.Path -TotalCount 1) -match 'AGE-SECRET-KEY') } catch { }
    $envName = if ($isAgeKey) { 'SOPS_AGE_KEY_FILE' } else { 'SOPS_AGE_SSH_PRIVATE_KEY_FILE' }

    # make sure this key can decrypt at all before treating any failure as fatal
    $recipientKey = if ($Recipient -match '^(ssh-(?:ed25519|rsa)\s+\S+)') { $Matches[1] }
                    elseif ($Recipient.Trim() -match '^(ssh-(?:ed25519|rsa|dss))\s+(\S+)') { "$($Matches[1]) $($Matches[2])" }
                    elseif ($Recipient -match '^age1') { $Recipient }
                    else { $null }
    if ($recipientKey -and -not $isAgeKey) {
        $pub = Get-PublicKeyFromIdentity -Path $identity.Path
        if ($pub -and $pub -ne $recipientKey) { return 'mismatch' }
    }

    Write-Log "verifying round-trip decryption with $($identity.Path)"
    $verify = Join-Path $Out '.verify.tar.gz'
    Remove-Item -LiteralPath $verify -Force -ErrorAction SilentlyContinue
    $res = Invoke-Tool -File $script:ToolSops -Environment @{ $envName = $identity.Path } -AllowFailure -Arguments @(
        'decrypt', '--input-type', 'binary', '--output-type', 'binary', '--output', $verify, $Encrypted
    )
    if ($res.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $verify)) {
        Remove-Item -LiteralPath $verify -Force -ErrorAction SilentlyContinue
        if (Test-RecipientMismatch -ErrorText $res.Text) { return 'mismatch' }
        return 'broken'
    }
    $same = (Get-FileHash -LiteralPath $verify -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash
    Remove-Item -LiteralPath $verify -Force -ErrorAction SilentlyContinue
    if ($same) { return 'ok' }
    return 'broken'
}

function Initialize-Tools {
    param([switch] $NoRclone)

    if (-not $script:ToolSops)   { $script:ToolSops   = Get-Tool 'sops' }
    if (-not $script:ToolTar) {
        $tarTool = Resolve-Tar
        $script:ToolTar = $tarTool.Path
        $script:TarExtra = $tarTool.Extra
    }
    if (-not $NoUpload -and -not $NoRclone -and -not $script:ToolRclone) {
        $script:ToolRclone = Get-Tool 'rclone'
    }
    # NOTE: assign to $script:Out - a plain assignment inside a function would
    # create a function-local variable and leave the caller's $Out empty.
    if (-not $Out) {
        $script:Out = Join-Path ([IO.Path]::GetTempPath()) ("pi-agent-backup-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    }
    if (-not (Test-Path -LiteralPath $script:Out)) {
        New-Item -ItemType Directory -Path $script:Out -Force | Out-Null
    }
    $script:Out = (Get-Item -LiteralPath $script:Out).FullName
}

# --- minimal set (always backed up): models + plugins ----------------------
# settings.json is part of the minimal set because it holds the installed
# package list ("packages": ["npm:..."]), i.e. the plugin registry.
$MinimalFiles = @('models.json', 'models-store.json', 'settings.json', 'settings.jsonc')
$MinimalDirs  = @('extensions')

# --- opt-in groups ---------------------------------------------------------
$ConfigFiles   = @(
    'keybindings.json',
    'AGENTS.md', 'AGENTS.override.md', 'CLAUDE.md', 'SYSTEM.md', 'APPEND_SYSTEM.md',
    'pi-subagents'
)
$ContentDirs   = @('skills', 'prompts', 'themes')
# credentials / API keys - only with -WithSecrets
$SecretFiles   = @('auth.json', 'mcp.json', 'mcp-auth.json')
# remote connection state - only with -WithSsh, never by default
$SshFiles      = @('ssh-remote-config.json', 'ssh-remote-known-hosts.json', 'ssh-remote-memories')

$ExcludeArgs = @(
    '--exclude=*.bak', '--exclude=*.bak.*', '--exclude=*.orig', '--exclude=*.rej',
    '--exclude=*.html', '--exclude=*.log', '--exclude=*.tgz',
    '--exclude=.git', '--exclude=node_modules', '--exclude=__pycache__',
    '--exclude=.DS_Store', '--exclude=Thumbs.db'
)

function Add-Members {
    param(
        [System.Collections.Generic.List[string]] $Members,
        [string[]] $Files,
        [string[]] $Dirs
    )
    foreach ($m in $Files) {
        if (Test-Path -LiteralPath (Join-Path $Dir $m)) { $Members.Add($m) }
    }
    foreach ($m in $Dirs) {
        if (Test-Path -LiteralPath (Join-Path $Dir $m) -PathType Container) { $Members.Add($m) }
    }
}

function Get-Members {
    $members = New-Object System.Collections.Generic.List[string]

    # minimal set: models + plugins
    Add-Members -Members $members -Files $MinimalFiles -Dirs $MinimalDirs

    if ($WithConfig)  { Add-Members -Members $members -Files $ConfigFiles }
    if ($WithContent) { Add-Members -Members $members -Dirs  $ContentDirs }
    if ($WithSecrets) { Add-Members -Members $members -Files $SecretFiles }
    if ($WithSsh)     { Add-Members -Members $members -Files $SshFiles }
    if ($WithMissions -and (Test-Path -LiteralPath (Join-Path $Dir 'missions') -PathType Container)) {
        $members.Add('missions')
    }
    if ($WithSessions -and (Test-Path -LiteralPath (Join-Path $Dir 'sessions') -PathType Container)) {
        $members.Add('sessions')
    }
    if ($WithData -and (Test-Path -LiteralPath (Join-Path $Dir 'data') -PathType Container)) {
        $members.Add('data')
    }

    # hard guard: never pick up sessions / ssh state / credentials implicitly
    $Forbidden = @()
    if (-not $WithSessions) { $Forbidden += 'sessions' }
    if (-not $WithMissions) { $Forbidden += 'missions' }
    if (-not $WithData)     { $Forbidden += 'data' }
    if (-not $WithSsh)      { $Forbidden += $SshFiles }
    if (-not $WithSecrets)  { $Forbidden += $SecretFiles }
    if (-not $WithConfig)   { $Forbidden += $ConfigFiles }
    foreach ($m in @($members)) {
        if ($Forbidden -contains $m) { [void]$members.Remove($m) }
    }

    if ($members.Count -eq 0) { Stop-Script "nothing to back up in $Dir" }
    return $members.ToArray()
}

function Invoke-Backup {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        Stop-Script "agent dir not found: $Dir"
    }
    Initialize-Tools

    $recipient = Request-Recipient -Value $Recipient
    Write-Log "agent dir : $Dir"
    Write-Log ("recipient : " + $recipient.Substring(0, [Math]::Min(40, $recipient.Length)) + '...')

    $members = Get-Members
    Write-Log ("members   : " + ($members -join ' '))
    if ($WithSsh)     { Write-Warn 'including remote SSH connection state (-WithSsh)' }
    if ($WithSecrets) { Write-Warn 'including credentials / API keys (-WithSecrets): auth.json, mcp.json, mcp-auth.json' }
    if ($WithSessions) { Write-Warn 'including conversation history (-WithSessions)' }

    $archive = Join-Path $Out 'pi-agent-config.tar.gz'
    $enc     = Join-Path $Out $Name
    Remove-Item -LiteralPath $archive, $enc -Force -ErrorAction SilentlyContinue

    Write-Log 'creating archive'
    if (-not $DryRun) {
        $tarArgs = @('-czf', $archive) + $script:TarExtra + $ExcludeArgs + @('-C', $Dir) + $members
        Invoke-Tool -File $script:ToolTar -Arguments $tarArgs | Out-Null
        $archiveSize = (Get-Item -LiteralPath $archive).Length
        $entries = (Invoke-Tool -File $script:ToolTar -Arguments (@('-tzf') + $script:TarExtra + @($archive))).Output.Count
        Write-Log "plain archive: $archiveSize bytes ($entries entries)"
    }

    Write-Log 'encrypting with sops (age)'
    if (-not $DryRun) {
        Invoke-Tool -File $script:ToolSops -Arguments @(
            'encrypt', '--input-type', 'binary', '--output-type', 'binary',
            '--age', $recipient, '--output', $enc, $archive
        ) | Out-Null
    }

    # --- verification round-trip -----------------------------------------
    # The recipient may well belong to another machine, so "no matching private
    # key here" is not an error. But if a local private key DOES match the
    # recipient and still cannot read the archive, the backup is broken.
    if (-not $DryRun -and -not $SkipVerify) {
        $verdict = Test-ArchiveReadable -Recipient $recipient -Archive $archive -Encrypted $enc
        if ($verdict -eq 'mismatch') {
            if ($RequireVerify) {
                Stop-Script ("round-trip verification failed: none of the local private keys match the recipient. " +
                             "Pass -Identity <private key> for the matching key, or drop -RequireVerify.")
            }
            Write-Warn ("the recipient does not match any local private key " +
                        "($($recipient.Substring(0, [Math]::Min(40, $recipient.Length)))...). " +
                        'Make sure you keep the matching private key - without it the backup cannot be restored.')
        }
        elseif ($verdict -eq 'ok') {
            Write-Log 'round-trip OK'
        }
        elseif ($verdict -eq 'broken') {
            Stop-Script 'round-trip decryption failed with a matching key - the archive would not be restorable; refusing to upload'
        }
        else {
            Write-Warn 'no local private key found, skipping round-trip check (use -Identity to enable it)'
        }
    }

    $encSize = 0
    $hash = ''
    if (-not $DryRun) {
        $encSize = (Get-Item -LiteralPath $enc).Length
        $hash = (Get-FileHash -LiteralPath $enc -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Log "encrypted : $enc ($encSize bytes)"
        Write-Log "sha256    : $hash"
        $sumPath = "$enc.sha256"
        # sha256sum-compatible sidecar
        Set-Content -LiteralPath $sumPath -Value "$hash  $Name" -Encoding ASCII
    }

    if ($NoUpload) {
        Write-Log "upload disabled (-NoUpload); archive kept at: $enc"
        return
    }

    $remoteDir = $Remote.TrimEnd('/')
    $target = "$remoteDir/$Name"
    Write-Log "checking rclone destination: $remoteDir"
    if (-not $DryRun) {
        Invoke-Tool -File $script:ToolRclone -AllowFailure -Arguments @('mkdir', $remoteDir) | Out-Null
        $list = Invoke-Tool -File $script:ToolRclone -AllowFailure -Arguments @('lsf', $remoteDir, '--max-depth', '1')
        if ($list.ExitCode -ne 0) {
            Stop-Script "rclone destination unreachable: $remoteDir (check 'rclone config'; list remotes with 'rclone listremotes')"
        }
    }

    $existed = $false
    if (-not $DryRun) {
        $stat = Invoke-Tool -File $script:ToolRclone -AllowFailure -Arguments @('lsjson', '--stat', $target)
        $existed = ($stat.ExitCode -eq 0)
    }
    Write-Log "uploading (overwrite=$($existed.ToString().ToLower())) -> $target"

    if ($DryRun) {
        Write-Log ('[dry-run] rclone copyto --ignore-times "{0}" "{1}"' -f $enc, $target)
    }
    else {
        Invoke-Tool -File $script:ToolRclone -Arguments @(
            'copyto', '--ignore-times', '--stats-one-line', '--stats=15s', $enc, $target
        ) | Out-Null
        Invoke-Tool -File $script:ToolRclone -Arguments @(
            'copyto', '--ignore-times', "$enc.sha256", "$target.sha256"
        ) | Out-Null

        $remoteStat = Invoke-Tool -File $script:ToolRclone -Arguments @('lsjson', '--stat', $target)
        $remoteObj = ($remoteStat.Stdout | ConvertFrom-Json)
        if (-not $remoteObj -or -not $remoteObj.Size) {
            Stop-Script 'upload verification failed: cannot stat the remote object'
        }
        if ([int64]$remoteObj.Size -ne [int64]$encSize) {
            Stop-Script "size mismatch after upload (local=$encSize remote=$($remoteObj.Size))"
        }
        Write-Log "upload verified: $($remoteObj.Size) bytes, sha256 $hash"
    }
    Write-Log ("done (archive " + (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ') + ")")
}

# ---------------------------------------------------------------------------
# restore
# ---------------------------------------------------------------------------
function Invoke-Restore {
    $src = $Source
    if (-not $src) { $src = $Remote.TrimEnd('/') + '/' + $Name }
    $local = Test-Path -LiteralPath $src -PathType Leaf
    Initialize-Tools -NoRclone:$local

    $enc = $src
    if (-not $local) {
        $script:ToolRclone = Get-Tool 'rclone'
        $enc = Join-Path $Out $Name
        Write-Log "downloading $src"
        Invoke-Tool -File $script:ToolRclone -Arguments @('copyto', '--ignore-times', '--progress', $src, $enc) | Out-Null
    }

    $identity = Resolve-Identity -Value $Identity -Required
    $tarFile = Join-Path $Out 'pi-agent-restore.tar.gz'
    Remove-Item -LiteralPath $tarFile -Force -ErrorAction SilentlyContinue

    Write-Log "decrypting with $($identity.Path)"
    $envName = if ($identity.EnvName) { $identity.EnvName }
               elseif ((Get-Content -LiteralPath $identity.Path -TotalCount 1) -match 'AGE-SECRET-KEY') { 'SOPS_AGE_KEY_FILE' }
               else { 'SOPS_AGE_SSH_PRIVATE_KEY_FILE' }
    Invoke-Tool -File $script:ToolSops -Environment @{ $envName = $identity.Path } -Arguments @(
        'decrypt', '--input-type', 'binary', '--output-type', 'binary', '--output', $tarFile, $enc
    ) | Out-Null

    $listing = (Invoke-Tool -File $script:ToolTar -Arguments (@('-tzf') + $script:TarExtra + @($tarFile))).Output
    Write-Log ("archive contains $($listing.Count) entries, first 40:")
    $listing | Select-Object -First 40 | ForEach-Object { Write-Host "    $_" }

    if ($DryRun) {
        Write-Log "[dry-run] would extract into $Dir"
        return
    }
    if (-not $Yes) {
        $answer = Read-Host "Extract into $Dir ? [y/N]"
        if ($answer -notmatch '^(y|yes)$') { Stop-Script 'aborted by user' }
    }
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    Invoke-Tool -File $script:ToolTar -Arguments (@('-xzf') + $script:TarExtra + @($tarFile, '-C', $Dir)) | Out-Null
    Write-Log "restored into $Dir"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
try {
    switch ($Command) {
        'Backup'  { Invoke-Backup }
        'Restore' { Invoke-Restore }
    }
    exit 0
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
