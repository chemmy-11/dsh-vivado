<#
.SYNOPSIS
    Reliable "can this machine start Vivado" probe for dsh-vivado.

.DESCRIPTION
    `vivado.bat -version` is NOT a probe. Measured 2026-10-24 on Vivado 2023.1: that switch goes
    through rdiArgs.bat -> prodversion.exe -> `exit /b 1`, and when stdout is redirected/piped it
    prints nothing at all. "exit 1 + zero output" is therefore indistinguishable from success to
    anyone who only checks is_error.

    The only reliable probe is a real batch run whose Tcl prints a marker. This script writes
    `puts "TCL_OK [info patchlevel]"`, runs vivado.bat -mode batch on it through a generated .cmd
    wrapper (so cmd records %ERRORLEVEL%, see Write-KitBatchLauncher), and prints one KEY=value
    line per fact. The recipe lives here instead of in the persona so a session never has to
    retype it (the quoting traps are documented in docs/troubleshooting.md).

    Output contract (stdout, one KEY=value per line):
        PROBE_BAT=<path>              PROBE_EXIT=<code|unknown>
        PROBE_STDOUT_BYTES=<n>        PROBE_BANNER=<yes|no>
        PROBE_TCL_OK=<yes|no>         PROBE_TCL=<patchlevel or empty>
        PROBE_VIVADO_VERSION=<x.y>    PROBE_TIER=<2023.1|2025.2plus|unknown>
        PROBE_LOG=<path>              PROBE_STATUS=<path>
        PROBE_WORKDIR=<path>          PROBE_RESULT=<OK|FAIL|TIMEOUT>
    Exit codes: 0 = OK, 1 = FAIL/TIMEOUT, 2 = setup error (no vivado.bat, non-ASCII work dir).

.PARAMETER VivadoBat
    vivado.bat, or its bin directory. Default: kit config.yml `vivado_bat`/`vivado_path`,
    then %XILINX_VIVADO%\bin\vivado.bat.

.PARAMETER WorkDir
    ASCII-only scratch directory. Default: a fresh %TEMP%\dsh-vivado-probe-<random>.

.PARAMETER TimeoutSec
    Hard timeout for the batch run (default 600). A warm batch start takes ~20-40 s.

.PARAMETER KeepFiles
    Keep the scratch directory (tcl/log/journal/console/status) as evidence.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\vivado-probe.ps1

.NOTES
    Windows PowerShell 5.1 compatible, ASCII-only source (see lib/common.ps1 header).
#>
[CmdletBinding()]
param(
    [string]$VivadoBat,
    [string]$WorkDir,
    [int]$TimeoutSec = 600,
    [switch]$KeepFiles
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$KitRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
function Say { param([string]$Level, [string]$Message) Write-KitLog $Level $Message }

$bat = Find-KitVivadoBat -Explicit $VivadoBat -KitRoot $KitRoot
if ([string]::IsNullOrWhiteSpace($bat)) {
    Say FAIL 'no vivado.bat found: pass -VivadoBat <path>, set vivado_path in config.yml, or set %XILINX_VIVADO%'
    Write-Output 'PROBE_RESULT=FAIL'
    exit 2
}

$createdWorkDir = $false
if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    $WorkDir = New-KitAsciiWorkDir -KitRoot $null -Prefix 'dsh-vivado-probe'
    $createdWorkDir = $true
} else {
    if (-not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    }
    $WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
}
if (-not (Test-AsciiPath $WorkDir)) {
    Say FAIL ('work dir is not ASCII (Vivado cannot use it): ' + $WorkDir)
    Write-Output 'PROBE_RESULT=FAIL'
    exit 2
}

$tcl = Join-Path $WorkDir 'probe.tcl'
$log = Join-Path $WorkDir 'probe.log'
$jou = Join-Path $WorkDir 'probe.jou'
$con = Join-Path $WorkDir 'probe.console.log'
$errFile = $con + '.err'
$status = Join-Path $WorkDir 'probe.status.txt'
$wrapper = Join-Path $WorkDir 'probe.run.cmd'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tcl, 'puts "TCL_OK [info patchlevel]"' + "`n", $utf8NoBom)

Say STEP ('probing Vivado: ' + $bat)
Say INFO ('work dir: ' + $WorkDir)

[void](Write-KitBatchLauncher -Path $wrapper -VivadoBat $bat -Tcl $tcl -Log $log -Journal $jou `
        -Console $con -Status $status -WorkDir $WorkDir -Mode 'probe')

$comspec = $env:ComSpec
if ([string]::IsNullOrWhiteSpace($comspec)) { $comspec = 'cmd.exe' }
$proc = Start-Process -FilePath $comspec -ArgumentList ('/c "' + $wrapper + '"') `
    -WorkingDirectory $WorkDir -NoNewWindow -PassThru -RedirectStandardError $errFile

$timedOut = $false
if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    $timedOut = $true
    try { $proc.Kill() } catch { }
    try { [void]$proc.WaitForExit(5000) } catch { }
}

function Read-IfExists {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try { return [System.IO.File]::ReadAllText($Path) } catch { return '' }
    }
    return ''
}
$consoleText = Read-IfExists -Path $con
$errText = Read-IfExists -Path $errFile
$logText = Read-IfExists -Path $log
$allText = ($consoleText + "`n" + $errText + "`n" + $logText)
$conBytes = 0
if (Test-Path -LiteralPath $con) { $conBytes = (Get-Item -LiteralPath $con).Length }

$exitCode = Get-KitBatchExitCode -Status $status
$exitText = 'unknown'
if ($null -ne $exitCode) { $exitText = [string]$exitCode }

$banner = 'no'
$version = ''
$m = [regex]::Match($allText, '(?m)Vivado v(\d{4}\.\d)')
if ($m.Success) { $banner = 'yes'; $version = $m.Groups[1].Value }

$tclOk = 'no'
$patchlevel = ''
$m2 = [regex]::Match($allText, 'TCL_OK\s+([0-9][0-9.]*)')
if ($m2.Success) { $tclOk = 'yes'; $patchlevel = $m2.Groups[1].Value }

$tier = 'unknown'
if (-not [string]::IsNullOrWhiteSpace($version)) {
    $tier = '2023.1'
    try {
        if ([version]$version -ge [version]'2025.2') { $tier = '2025.2plus' }
    } catch { }
}

$result = 'FAIL'
if ($timedOut) {
    $result = 'TIMEOUT'
} elseif ($exitCode -eq 0 -and ($tclOk -eq 'yes' -or $banner -eq 'yes')) {
    $result = 'OK'
}

Write-Output ('PROBE_BAT=' + $bat)
Write-Output ('PROBE_EXIT=' + $exitText)
Write-Output ('PROBE_STDOUT_BYTES=' + $conBytes)
Write-Output ('PROBE_BANNER=' + $banner)
Write-Output ('PROBE_TCL_OK=' + $tclOk)
Write-Output ('PROBE_TCL=' + $patchlevel)
Write-Output ('PROBE_VIVADO_VERSION=' + $version)
Write-Output ('PROBE_TIER=' + $tier)
Write-Output ('PROBE_LOG=' + $log)
Write-Output ('PROBE_STATUS=' + $status)
Write-Output ('PROBE_WORKDIR=' + $WorkDir)
Write-Output ('PROBE_RESULT=' + $result)

if ($result -ne 'OK') {
    Say WARN ('stdout bytes={0}, exit={1}, banner={2}, TCL_OK={3}' -f $conBytes, $exitText, $banner, $tclOk)
    if (-not [string]::IsNullOrWhiteSpace($consoleText)) {
        $tail = ($consoleText -split "`n" | Select-Object -Last 15) -join "`n"
        Say WARN ('console tail:' + "`n" + $tail)
    }
    if (-not [string]::IsNullOrWhiteSpace($errText)) {
        Say WARN ('stderr:' + "`n" + $errText)
    }
    Say INFO 'judge by the outputs above; `exit!=0 with 0 bytes` is a launch failure, not a pass'
} else {
    Say PASS ('Vivado {0} starts; Tcl {1} (tier {2})' -f $version, $patchlevel, $tier)
}

if ($createdWorkDir -and -not $KeepFiles) {
    try { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

if ($result -eq 'OK') { exit 0 }
exit 1
