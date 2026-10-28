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

function Find-KitVivadoBat {
    <#
    Locate vivado.bat without launching it. Order: -Explicit (file or its bin directory),
    the kit config (`vivado_bat`, else `<vivado_path>\vivado.bat`), then %XILINX_VIVADO%\bin.
    Returns the full path, or $null when nothing exists (callers print their own fix hint).
    #>
    param(
        [string]$Explicit,
        [string]$KitRoot,
        [string]$ConfigPath
    )
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        if (Test-Path -LiteralPath $Explicit -PathType Leaf) { return (Resolve-Path -LiteralPath $Explicit).Path }
        $asDir = Join-Path $Explicit 'vivado.bat'
        if (Test-Path -LiteralPath $asDir -PathType Leaf) { return (Resolve-Path -LiteralPath $asDir).Path }
        return $null
    }
    if (-not [string]::IsNullOrWhiteSpace($KitRoot)) {
        try {
            $cfgFile = Resolve-KitConfigPath -KitRoot $KitRoot -Config $ConfigPath
            $cfg = Read-KitConfig -Path $cfgFile
            foreach ($key in @('vivado_bat', 'vivado_path')) {
                if (-not $cfg.Contains($key)) { continue }
                $raw = [string]$cfg[$key]
                if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                $candidate = $raw
                if ($key -eq 'vivado_path') { $candidate = Join-Path $raw 'vivado.bat' }
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
            }
        } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:XILINX_VIVADO)) {
        $candidate = Join-Path $env:XILINX_VIVADO 'bin\vivado.bat'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    return $null
}

function New-KitAsciiWorkDir {
    <#
    Return a directory whose FULL path is pure ASCII (Vivado breaks on non-ASCII paths), creating
    it when needed. Candidates: -Preferred, %TEMP%\<Prefix>-<random>, <KitRoot>\.tmp-work.
    #>
    param(
        [string]$Preferred,
        [string]$KitRoot,
        [string]$Prefix = 'dsh-vivado-work'
    )
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Preferred)) { $candidates.Add($Preferred) }
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        $rand = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $candidates.Add((Join-Path $env:TEMP ('{0}-{1}' -f $Prefix, $rand)))
    }
    if (-not [string]::IsNullOrWhiteSpace($KitRoot)) { $candidates.Add((Join-Path $KitRoot '.tmp-work')) }
    foreach ($candidate in $candidates) {
        if (-not (Test-AsciiPath $candidate)) { continue }
        if (-not (Test-Path -LiteralPath $candidate)) {
            New-Item -ItemType Directory -Path $candidate -Force | Out-Null
        }
        return (Resolve-Path -LiteralPath $candidate).Path
    }
    throw 'no ASCII-only work directory available: pass -WorkDir with an ASCII path'
}

function Write-KitBatchLauncher {
    <#
    Write a .cmd wrapper that runs `vivado.bat -mode batch` on one Tcl file, redirects all output
    to <Console>, and records BUILD_START / BUILD_EXIT=<rc> / BUILD_FAILED in <Status>.

    Why a wrapper instead of `Start-Process -PassThru ... -RedirectStandardOutput`:
    measured 2026-10-25 on Windows PowerShell 5.1 -- the Process object returned by Start-Process
    for a .bat has a NULL ExitCode after the run, so every exit-code judgement silently became
    "$null != 0 => failure" or worse, "empty => success". The wrapper makes cmd itself record
    %ERRORLEVEL%, which is the one value that cannot be lost. The wrapper is also the only piece
    the detached (WMI) mode needs, so both modes share one code path.

    The `call` in front of vivado.bat is mandatory: vivado.bat ends with `exit /b %errorlevel%`,
    and a batch file invoked WITHOUT `call` never returns control to its caller -- the wrapper's
    remaining lines (BUILD_EXIT / BUILD_FAILED) were measured to never run, which is exactly how
    the exit code got lost. Do not "simplify" it away.

    Two other cmd parsing details are deliberate and must not be "simplified":
      * `... %KIT_RC% >> "file"` keeps a space before `>>`: after variable expansion a bare
        `0>>`/`2>>` is a handle redirect, not an append.
      * timestamps come from `%TIME%` only: `%DATE%` on a Chinese Windows contains a CJK weekday,
        and cmd writes it in the OEM code page, so the status file would be valid GBK but read
        back as mojibake by any UTF-8 reader (measured).
      * only a single quoted token follows `cmd /c` (see Invoke-KitBatch); the measured failure
        was a whole quoted command line, which cmd re-parses and rejects.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$VivadoBat,
        [Parameter(Mandatory = $true)][string]$Tcl,
        [Parameter(Mandatory = $true)][string]$Log,
        [Parameter(Mandatory = $true)][string]$Journal,
        [Parameter(Mandatory = $true)][string]$Console,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [string]$Mode = 'wait',
        [string]$CleanupTask = ''
    )
    $lines = @(
        '@echo off',
        'setlocal',
        ('set "KIT_STATUS_FILE=' + $Status + '"'),
        ('cd /d "' + $WorkDir + '"'),
        ('echo BUILD_START mode=' + $Mode + ' at %TIME% >> "' + $Status + '"'),
        ('call "' + $VivadoBat + '" -mode batch -source "' + $Tcl + '" -notrace -log "' + $Log + '" -journal "' + $Journal + '" > "' + $Console + '" 2>&1'),
        'set "KIT_RC=%ERRORLEVEL%"',
        ('echo BUILD_EXIT=%KIT_RC% >> "' + $Status + '"'),
        ('if not "%KIT_RC%"=="0" echo BUILD_FAILED rc=%KIT_RC% at %TIME% >> "' + $Status + '"')
    )
    # A detached-via-Task-Scheduler run leaves a one-shot task behind; the wrapper removes it as its
    # very last act (after BUILD_EXIT is already on disk), because nothing else knows when the build
    # ended. schtasks /delete /f on the task that is currently running may end this cmd right after
    # that line -- which is why it is the last one.
    if ($CleanupTask -ne '') {
        $lines += ('schtasks /delete /tn "' + $CleanupTask + '" /f >nul 2>&1')
    }
    $lines += 'exit /b %KIT_RC%'
    $text = ($lines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.ASCIIEncoding))
    return $Path
}

function Get-KitBatchExitCode {
    <#
    Read the last BUILD_EXIT=<rc> line the launcher wrote. Returns an [int], or $null when the
    marker is missing (which means the run never reached the end, not "success").
    #>
    param([Parameter(Mandatory = $true)][string]$Status)
    if (-not (Test-Path -LiteralPath $Status -PathType Leaf)) { return $null }
    $text = [System.IO.File]::ReadAllText($Status)
    $matches = [regex]::Matches($text, 'BUILD_EXIT=(-?\d+)')
    if ($matches.Count -eq 0) { return $null }
    return [int]$matches[$matches.Count - 1].Groups[1].Value
}
