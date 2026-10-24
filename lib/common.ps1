# lib/common.ps1 -- shared helpers for dsh-vivado installers.
#
# Constraints (deliberate, do not "improve"):
#   * Windows PowerShell 5.1 compatible (powershell.exe). No `??`, no `?.`, no ternaries.
#   * ASCII-only output: this file is read by PS 5.1 as ANSI, so non-ASCII literals would garble.
#     Chinese documentation lives in *.md, never in *.ps1.
#   * No external module dependencies (no powershell-yaml, no Pester).
#
# Dot-source:  . "$PSScriptRoot\lib\common.ps1"

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:KitLogPrefix = 'kit'

function Write-KitLog {
    param(
        [ValidateSet('INFO', 'STEP', 'PASS', 'WARN', 'FAIL')][string]$Level = 'INFO',
        [Parameter(Mandatory = $true)][string]$Message
    )
    $color = 'Gray'
    switch ($Level) {
        'STEP' { $color = 'Cyan' }
        'PASS' { $color = 'Green' }
        'WARN' { $color = 'Yellow' }
        'FAIL' { $color = 'Red' }
        'INFO' { $color = 'Gray' }
    }
    Write-Host ('[{0}] {1}' -f $Level.PadRight(4), $Message) -ForegroundColor $color
}

function Get-KitVersion {
    param([string]$KitRoot)
    $pkg = Join-Path $KitRoot 'package.json'
    if (-not (Test-Path -LiteralPath $pkg)) { return '0.0.0' }
    $json = Get-Content -LiteralPath $pkg -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($json.PSObject.Properties.Name -contains 'version') { return [string]$json.version }
    return '0.0.0'
}

function ConvertTo-SlashPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return ($Path -replace '\\', '/')
}

function Test-AsciiPath {
    <# True when every character of the path is ASCII (< 0x80). #>
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($ch in $Path.ToCharArray()) {
        if ([int][char]$ch -gt 127) { return $false }
    }
    return $true
}

function Get-DshHome {
    <# DSH config root: -Override, else $env:DSH_HOME, else %USERPROFILE%\.dsh #>
    param([string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override }
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) { return $env:DSH_HOME }
    return (Join-Path $env:USERPROFILE '.dsh')
}

function Test-DshProfile {
    param([Parameter(Mandatory = $true)][string]$ProfileDir)
    return (Test-Path -LiteralPath (Join-Path $ProfileDir 'package.json'))
}

function Get-DshProfileDir {
    param(
        [Parameter(Mandatory = $true)][string]$DshHome,
        [Parameter(Mandatory = $true)][string]$Profile
    )
    return (Join-Path (Join-Path $DshHome 'profiles') $Profile)
}

function Find-DshCli {
    <#
    Locate the *installed* DSH CLI launcher (dsh.cmd), which boots the same runtime as the
    Electron host. Never trust a `dsh` on PATH unless it points into this installation: the
    PATH copy can be an older release (proven on 2026-10-24: PATH dsh = 0.1.7-rc.2 while the
    running host is 0.2.1-rc.2).

    Search order: -InstallDir, $env:DSH_INSTALL_DIR, running process path, registry App Paths,
    then a few conventional install roots.
    Returns $null when nothing is found.
    #>
    param([string]$InstallDir)

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($InstallDir)) { $candidates.Add($InstallDir) }
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_INSTALL_DIR)) { $candidates.Add($env:DSH_INSTALL_DIR) }

    # 1) the running host process knows where it lives
    try {
        $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -like 'DeepSeek*' -or $_.ProcessName -like '*Harness*'
        }
        foreach ($p in $procs) {
            if (-not [string]::IsNullOrWhiteSpace($p.Path)) {
                $candidates.Add((Split-Path -Parent $p.Path))
            }
        }
    } catch { }

    # 2) registry App Paths (HKCU first: a per-user install needs no admin)
    foreach ($hive in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\DeepSeek Harness.exe',
                        'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\DeepSeek Harness.exe')) {
        try {
            if (Test-Path $hive) {
                $exe = (Get-ItemProperty -Path $hive -ErrorAction Stop).'(default)'
                if (-not [string]::IsNullOrWhiteSpace($exe) -and (Test-Path -LiteralPath $exe)) {
                    $candidates.Add((Split-Path -Parent $exe))
                }
            }
        } catch { }
    }

    # 3) conventional install roots
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'),
        (Join-Path $env:ProgramFiles 'DeepSeek Harness'),
        (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness'),
        'D:\dsh',
        'C:\dsh'
    )
    foreach ($r in $roots) {
        if (-not [string]::IsNullOrWhiteSpace($r)) { $candidates.Add($r) }
    }

    foreach ($dir in $candidates) {
        $cli = Join-Path $dir 'resources\runtime\cli\bin\dsh.cmd'
        if (Test-Path -LiteralPath $cli) { return $cli }
    }
    return $null
}

function Backup-KitFile {
    <# Copy <Path> to <Path>.bak-<suffix> unless that backup already exists. Returns the backup path. #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Suffix
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $bak = '{0}.bak-{1}' -f $Path, $Suffix
    if (Test-Path -LiteralPath $bak) {
        Write-KitLog WARN ("backup already exists, keeping the first one: {0}" -f $bak)
        return $bak
    }
    Copy-Item -LiteralPath $Path -Destination $bak -Force
    Write-KitLog INFO ("backup: {0}" -f $bak)
    return $bak
}

function ConvertFrom-KitConfigText {
    <#
    Parse the flat `key: value` config dialect used by config.yml.
    Rules: blank lines and `#` comments ignored; first `:` splits key and value; a trailing
    ` #comment` is stripped; surrounding single/double quotes are removed. Unknown keys are kept
    (callers decide which are required). Returns an ordered hashtable.
    #>
    param([Parameter(Mandatory = $true)][string]$Text)
    $cfg = [ordered]@{}
    foreach ($rawLine in ($Text -split "`n")) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0) { continue }
        if ($line.StartsWith('#')) { continue }
        $idx = $line.IndexOf(':')
        if ($idx -lt 1) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        # strip an unquoted trailing comment
        if ($val.Length -gt 0 -and -not ($val.StartsWith('"') -or $val.StartsWith("'"))) {
            $hash = $val.IndexOf(' #')
            if ($hash -ge 0) { $val = $val.Substring(0, $hash).Trim() }
        }
        if ($val.Length -ge 2) {
            if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }
        $cfg[$key] = $val
    }
    return $cfg
}

function Read-KitConfig {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("config file not found: {0}" -f $Path)
    }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($null -eq $text) { $text = '' }
    return (ConvertFrom-KitConfigText -Text $text)
}

function Write-KitConfigFile {
    <# Write an ordered hashtable back in the same commented dialect (installer persists detected values). #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# dsh-vivado -- environment config (flat `key: value`).')
    [void]$sb.AppendLine('# Rewritten by install.ps1 with the values it actually used. Keep every path ASCII.')
    [void]$sb.AppendLine('')
    foreach ($k in $Config.Keys) {
        [void]$sb.AppendLine(('{0}: {1}' -f $k, $Config[$k]))
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), $enc)
}

function Resolve-KitConfigPath {
    <#
    Pick the config file for a kit root: explicit -Config, else <root>\config.yml,
    else <root>\config.example.yml (and report which one was used).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$KitRoot,
        [string]$Config
    )
    if (-not [string]::IsNullOrWhiteSpace($Config)) {
        if (-not (Test-Path -LiteralPath $Config)) { throw ("config not found: {0}" -f $Config) }
        return (Resolve-Path -LiteralPath $Config).Path
    }
    $local = Join-Path $KitRoot 'config.yml'
    if (Test-Path -LiteralPath $local) { return $local }
    $example = Join-Path $KitRoot 'config.example.yml'
    if (Test-Path -LiteralPath $example) { return $example }
    throw ("no config.yml / config.example.yml under {0}" -f $KitRoot)
}

function Format-KitCommand {
    <# Quote one argument for display in a copy-pasteable command line. #>
    param([Parameter(Mandatory = $true)][string]$Argument)
    if ($Argument -match '[\s"]') { return ('"{0}"' -f ($Argument -replace '"', '\"')) }
    return $Argument
}
