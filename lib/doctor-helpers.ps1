# lib/doctor-helpers.ps1 -- helpers used only by doctor.ps1.
#
# Deliberately self-contained (it does NOT dot-source lib/install-helpers.ps1): doctor is the
# acceptance gate, so it must keep working even while the installer is being reworked, and it
# must be safe to run against ANY profile without side effects.
#
# Constraints (same as lib/common.ps1):
#   * Windows PowerShell 5.1 (powershell.exe). No `??`, no `?.`, no ternaries.
#   * ASCII-only literals: PS 5.1 reads *.ps1 as ANSI, non-ASCII would garble.
#   * No external modules. Read-only: nothing here writes to disk except the OS temp of a
#     child process.
#
# Dot-source AFTER lib/common.ps1:   . "$PSScriptRoot\lib\doctor-helpers.ps1"

# ---------------------------------------------------------------------------
#  native command execution with a hard timeout
# ---------------------------------------------------------------------------

function ConvertTo-DoctorArg {
    <# Quote one argument for the CreateProcess-style command line.
       Only the shapes doctor.ps1 produces are supported (no embedded double quotes). #>
    param([string]$Argument)
    if ($null -eq $Argument) { return '""' }
    if ($Argument.Length -eq 0) { return '""' }
    if ($Argument.IndexOf('"') -ge 0) { return ('"' + ($Argument -replace '"', '\"') + '"') }
    if ($Argument -match '\s') { return ('"' + $Argument + '"') }
    return $Argument
}

function Invoke-DoctorNative {
    <#
    Run a native command (.exe / .cmd / .bat) with a real wall-clock timeout.

    Why not & / Invoke-Expression: a hung Vivado probe would block doctor forever. Here the
    child is started with System.Diagnostics.Process, stdout/stderr are read asynchronously and
    the wait is bounded; on timeout the whole process TREE is killed (taskkill /T) because
    vivado.bat is only a cmd wrapper around loader.bat -> vivado.exe.

    Never throws for a non-zero exit code. Returns:
        Ok        : the process started AND exited (ExitCode is meaningful)
        ExitCode  : $null when the process could not be started or was killed
        StdOut    : decoded as UTF-8 (the kit forces PYTHONUTF8=1 / utf-8 for its children)
        StdErr    : same
        TimedOut  : $true when the timeout fired and the tree was killed
        ElapsedMs : wall clock
        Command   : the command line, for evidence
        Error     : start-up failure text ('' normally)
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [hashtable]$Environment,
        [int]$TimeoutSec = 120,
        [string]$WorkingDirectory
    )
    $result = [pscustomobject]@{
        Ok        = $false
        ExitCode  = $null
        StdOut    = ''
        StdErr    = ''
        TimedOut  = $false
        ElapsedMs = 0
        Command   = ''
        Error     = ''
    }
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        $result.Error = 'empty executable path'
        return $result
    }
    $argList = @()
    $shown = $FilePath
    foreach ($a in $Arguments) {
        $q = ConvertTo-DoctorArg $a
        $argList += $q
        $shown = $shown + ' ' + $q
    }
    $result.Command = $shown

    if ($TimeoutSec -lt 1) { $TimeoutSec = 1 }
    $exe = $FilePath
    $argLine = ($argList -join ' ')
    if ($FilePath -match '\.(bat|cmd)$') {
        # .bat/.cmd must go through cmd.exe; the classic quoted form survives spaces in the path.
        $exe = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $argLine = '/c ""' + $FilePath + '"'
        if ($argList.Count -gt 0) { $argLine = $argLine + ' ' + ($argList -join ' ') }
        $argLine = $argLine + '"'
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $psi.StandardOutputEncoding = $utf8
        $psi.StandardErrorEncoding = $utf8
    } catch { }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    if ($null -ne $Environment) {
        foreach ($k in $Environment.Keys) {
            $psi.EnvironmentVariables[[string]$k] = [string]$Environment[$k]
        }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        $sw.Stop()
        $result.ElapsedMs = $sw.ElapsedMilliseconds
        $result.Error = $_.Exception.Message
        return $result
    }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $exited = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) {
        $result.TimedOut = $true
        try {
            $tk = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            if (Test-Path -LiteralPath $tk) {
                & $tk /T /F /PID $proc.Id 2>&1 | Out-Null
            }
        } catch { }
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
    }
    $sw.Stop()
    $result.ElapsedMs = $sw.ElapsedMilliseconds
    try { $result.StdOut = $outTask.Result } catch { $result.StdOut = '' }
    try { $result.StdErr = $errTask.Result } catch { $result.StdErr = '' }
    if (-not $result.TimedOut) {
        try {
            $result.ExitCode = $proc.ExitCode
            $result.Ok = $true
        } catch {
            $result.Error = 'exit code unavailable'
        }
    }
    try { $proc.Dispose() } catch { }
    return $result
}

function Get-DoctorTextTail {
    <# First $Lines non-empty lines of a text blob (for one-line error details). #>
    param([string]$Text, [int]$Lines = 3)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $all = @($Text -split "\r?\n" | Where-Object { $_.Trim().Length -gt 0 })
    if ($all.Count -eq 0) { return '' }
    $take = $Lines
    if ($all.Count -lt $take) { $take = $all.Count }
    return (($all[0..($take - 1)] | ForEach-Object { $_.Trim() }) -join ' | ')
}

# ---------------------------------------------------------------------------
#  filesystem / JSON helpers (read-only)
# ---------------------------------------------------------------------------

function Get-DoctorWinPath {
    <# Normalise a config value to a Windows path. '' stays ''. #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return ($Path.Trim() -replace '/', '\')
}

function Test-DoctorFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (Test-Path -LiteralPath $Path -PathType Leaf)
}

function Test-DoctorDir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (Test-Path -LiteralPath $Path -PathType Container)
}

function Read-DoctorTextFile {
    <# Raw file text ('' when unreadable/absent). Never throws. #>
    param([string]$Path, [int]$MaxBytes = 0)
    if (-not (Test-DoctorFile $Path)) { return '' }
    try {
        if ($MaxBytes -gt 0) {
            $fs = [System.IO.File]::OpenRead($Path)
            try {
                $buf = New-Object byte[] $MaxBytes
                $n = $fs.Read($buf, 0, $MaxBytes)
                return [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
            } finally { $fs.Dispose() }
        }
        $txt = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($null -eq $txt) { return '' }
        return [string]$txt
    } catch {
        return ''
    }
}

function Read-DoctorJsonFile {
    <# Parse a JSON file; returns $null when absent or malformed. Never throws. #>
    param([string]$Path)
    $raw = Read-DoctorTextFile $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try {
        return (ConvertFrom-Json -InputObject $raw)
    } catch {
        return $null
    }
}

function Get-DoctorJsonValue {
    <# StrictMode-safe property read for ConvertFrom-Json objects / dictionaries. #>
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    foreach ($p in $Object.PSObject.Properties) {
        if ($p.Name -eq $Name) { return $p.Value }
    }
    return $null
}

# ---------------------------------------------------------------------------
#  DSH runtime / mcp-client version
# ---------------------------------------------------------------------------

function Get-DoctorRuntimeVersionInfo {
    <#
    Version string of the DSH runtime that loads the profile, plus where it came from.

      1. <dsh.cmd> --version  -> "0.2.1-rc.2" (exact, keeps the prerelease suffix; ~0.35 s)
      2. <install>\DeepSeek Harness.exe VersionInfo.ProductVersion -> "0.2.1.0" (drops -rc.2,
         so it is NOT a valid compatibility.json value - only a hint)

    Source values: 'dsh.cmd --version' / 'exe ProductVersion' / ''
    #>
    param([string]$DshCli, [string]$InstallRoot)
    $info = @{ Version = ''; Source = '' }
    if (-not [string]::IsNullOrWhiteSpace($DshCli)) {
        if (Test-DoctorFile $DshCli) {
            $r = Invoke-DoctorNative -FilePath $DshCli -Arguments @('--version') -TimeoutSec 30
            if ($r.Ok -and $r.ExitCode -eq 0) {
                $lines = @($r.StdOut -split "\r?\n" | Where-Object { $_.Trim().Length -gt 0 })
                if ($lines.Count -gt 0) {
                    $cand = [string]$lines[$lines.Count - 1].Trim()
                    if ($cand -match '^\d+\.\d+\.\d+') {
                        $info.Version = $cand
                        $info.Source = 'dsh.cmd --version'
                        return $info
                    }
                }
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        $exe = Join-Path $InstallRoot 'DeepSeek Harness.exe'
        if (Test-DoctorFile $exe) {
            try {
                $pv = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
                if (-not [string]::IsNullOrWhiteSpace($pv)) {
                    $info.Version = ([string]$pv).Trim()
                    $info.Source = 'exe ProductVersion'
                    return $info
                }
            } catch { }
        }
    }
    return $info
}

function Get-DoctorRuntimeVersion {
    <# Version string only (see Get-DoctorRuntimeVersionInfo for the source). '' when unknown. #>
    param([string]$DshCli, [string]$InstallRoot)
    $info = Get-DoctorRuntimeVersionInfo -DshCli $DshCli -InstallRoot $InstallRoot
    return [string]$info.Version
}

function Get-DoctorMcpClientVersion {
    <# Version the profile actually resolves for @deepseek-ai/dsh-mcp-client, or ''. #>
    param([string]$ProfileDir)
    if ([string]::IsNullOrWhiteSpace($ProfileDir)) { return '' }
    $pkg = Join-Path $ProfileDir 'node_modules\@deepseek-ai\dsh-mcp-client\package.json'
    $json = Read-DoctorJsonFile $pkg
    if ($null -eq $json) { return '' }
    $v = Get-DoctorJsonValue $json 'version'
    if ($null -eq $v) { return '' }
    return ([string]$v).Trim()
}

# ---------------------------------------------------------------------------
#  small formatting helpers
# ---------------------------------------------------------------------------

function Get-DoctorAsciiSuggestion {
    <#
    Suggest an ASCII scratch directory on the same drive as the offending path:
      1. <drive>:/FPGA/.tmp   (this machine's convention)
      2. <drive>:/.kit-tmp
    Prefers a candidate that already exists and passes Test-AsciiPath.
    #>
    param([string]$OffendingPath)
    $drive = ''
    if (-not [string]::IsNullOrWhiteSpace($OffendingPath)) {
        $m = [regex]::Match($OffendingPath, '^([A-Za-z]):')
        if ($m.Success) { $drive = $m.Groups[1].Value.ToUpper() + ':' }
    }
    if ($drive -eq '') { return 'D:/FPGA/.tmp' }
    $candidates = @(($drive + '/FPGA/.tmp'), ($drive + ':/.kit-tmp'), $env:USERPROFILE)
    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $win = Get-DoctorWinPath $c
        if ((Test-DoctorDir $win) -and (Test-AsciiPath $c)) { return (ConvertTo-SlashPath $win) }
    }
    return $candidates[0]
}

function Format-DoctorSeconds {
    param([long]$Milliseconds)
    return ('{0:0.0} s' -f ($Milliseconds / 1000.0))
}
