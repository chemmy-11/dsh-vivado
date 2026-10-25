<#
.SYNOPSIS
    Run a Tcl script with Vivado in batch mode: blocking (short scripts) or detached (long builds).

.DESCRIPTION
    Wraps the one start recipe measured to work on Vivado 2023.1 (2026-10-24), and works around a
    Windows PowerShell 5.1 defect measured on 2026-10-25: the Process object returned by
    `Start-Process -PassThru` for a .bat has a NULL ExitCode, so every exit-code judgement built on
    it was silently wrong. Both modes therefore run a generated .cmd wrapper that records
    %ERRORLEVEL% itself (see Write-KitBatchLauncher / Get-KitBatchExitCode in lib/common.ps1).

    Measured failures the wrapper exists to avoid:
      * `& vivado.bat -version` and `cmd /c "<whole quoted command>"`: silent exit 1, zero output.
      * `Start-Process -ArgumentList '/c', <quoted whole command>`: cmd receives a second quoting
        layer and answers "The filename, directory name, or volume label syntax is incorrect."

    Modes:
      * default (wait) - blocks until Vivado exits. Only for short scripts: one implementation
        segment was measured at 34 min, longer than any tool call survives.
      * -Detach        - starts the same wrapper through
        `Invoke-CimMethod -ClassName Win32_Process -MethodName Create`, so the build outlives the
        turn. A detached build cannot return a tool result: progress is read from the status file
        (BUILD_START / SYNTH_OK / IMPL_OK / BUILD_EXIT / BUILD_FAILED) and the `-log` tail.

    Machine-readable output (one KEY=value per line):
        RUN_MODE=<wait|detach>    RUN_RESULT=<OK|FAIL|TIMEOUT|LAUNCHED>
        RUN_EXIT=<code|unknown>   RUN_BANNER=<yes|no>
        RUN_LOG=<path>            RUN_JOURNAL=<path>
        RUN_CONSOLE=<path>        RUN_CONSOLE_BYTES=<n>
        RUN_STATUS=<path>         RUN_WRAPPER=<path>
        RUN_CWD=<path>            RUN_PID=<pid>   RUN_RV=<cim return value>
    Exit codes: 0 = success / launched, 1 = run failed or timeout, 2 = setup error.

.PARAMETER Source
    Tcl script to run in batch mode (mandatory, must exist).

.PARAMETER VivadoBat
    vivado.bat or its bin directory. Default: kit config.yml, then %XILINX_VIVADO%.

.PARAMETER OutDir
    Working directory for the run and default location of log/journal/console/status.
    Default: the directory that holds -Source.

.PARAMETER Log
.PARAMETER Journal
.PARAMETER Console
.PARAMETER StatusFile
    Override the file names. Defaults: <out>\<base>.vivado.log, <base>.vivado.jou,
    <base>.console.log, <out>\build_status.txt.

.PARAMETER Detach
    Start outside this process tree (survives the turn) and return immediately.

.PARAMETER TimeoutSec
    wait mode only: give up waiting after N seconds. 0 = wait until it ends (default).
    On timeout the batch process keeps running; the script does NOT kill a process tree.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\vivado-run.ps1 -Source .\probe.tcl
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\vivado-run.ps1 -Source .\impl.tcl -Detach

.NOTES
    Windows PowerShell 5.1 compatible, ASCII-only source (see lib/common.ps1 header).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$VivadoBat,
    [string]$OutDir,
    [string]$Log,
    [string]$Journal,
    [string]$Console,
    [string]$StatusFile,
    [switch]$Detach,
    [int]$TimeoutSec = 0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$KitRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
function Say { param([string]$Level, [string]$Message) Write-KitLog $Level $Message }

# ---- inputs --------------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    Say FAIL ('tcl source not found: ' + $Source)
    Write-Output 'RUN_RESULT=FAIL'
    exit 2
}
$src = (Resolve-Path -LiteralPath $Source).Path

$bat = Find-KitVivadoBat -Explicit $VivadoBat -KitRoot $KitRoot
if ([string]::IsNullOrWhiteSpace($bat)) {
    Say FAIL 'no vivado.bat found: pass -VivadoBat <path>, set vivado_path in config.yml, or set %XILINX_VIVADO%'
    Write-Output 'RUN_RESULT=FAIL'
    exit 2
}

$base = [System.IO.Path]::GetFileNameWithoutExtension($src)
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Split-Path -Parent $src }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
if ([string]::IsNullOrWhiteSpace($Log)) { $Log = Join-Path $OutDir ($base + '.vivado.log') }
if ([string]::IsNullOrWhiteSpace($Journal)) { $Journal = Join-Path $OutDir ($base + '.vivado.jou') }
if ([string]::IsNullOrWhiteSpace($Console)) { $Console = Join-Path $OutDir ($base + '.console.log') }
if ([string]::IsNullOrWhiteSpace($StatusFile)) { $StatusFile = Join-Path $OutDir 'build_status.txt' }
$wrapper = Join-Path $OutDir ($base + '.run.cmd')

# Vivado's Tcl layer decodes paths as GBK on this tier: a non-ASCII path fails deep inside the
# flow, so refuse up front instead of producing a confusing "file not found" ten minutes in.
$bad = @()
foreach ($candidate in @($src, $bat, $OutDir, $Log, $Journal, $Console, $StatusFile, $wrapper)) {
    if (-not (Test-AsciiPath $candidate)) { $bad += $candidate }
}
if ($bad.Count -gt 0) {
    Say FAIL ('refusing to start: non-ASCII path(s) would break Vivado Tcl: ' + ($bad -join ', '))
    Write-Output 'RUN_RESULT=FAIL'
    exit 2
}

$mode = 'wait'
if ($Detach) { $mode = 'detach' }
[void](Write-KitBatchLauncher -Path $wrapper -VivadoBat $bat -Tcl $src -Log $Log -Journal $Journal `
        -Console $Console -Status $StatusFile -WorkDir $OutDir -Mode $mode)

# ---- detached mode -------------------------------------------------------------------------
if ($Detach) {
    # Quote only the wrapper path: the measured trap is handing cmd a whole quoted command string.
    $commandLine = 'cmd.exe /c "' + $wrapper + '"'
    $rv = -1
    $childPid = 0
    try {
        $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine }
        $rv = [int]$res.ReturnValue
        $childPid = [int]$res.ProcessId
    } catch {
        Say FAIL ('Win32_Process.Create failed: ' + $_.Exception.Message)
        Write-Output 'RUN_RESULT=FAIL'
        exit 1
    }

    Write-Output 'RUN_MODE=detach'
    Write-Output ('RUN_RV=' + $rv)
    Write-Output ('RUN_PID=' + $childPid)
    Write-Output ('RUN_WRAPPER=' + $wrapper)
    Write-Output ('RUN_CWD=' + $OutDir)
    Write-Output ('RUN_LOG=' + $Log)
    Write-Output ('RUN_JOURNAL=' + $Journal)
    Write-Output ('RUN_CONSOLE=' + $Console)
    Write-Output ('RUN_STATUS=' + $StatusFile)
    if ($rv -eq 0) {
        Write-Output 'RUN_RESULT=LAUNCHED'
        Say PASS ('detached build launched (PID {0}); poll the status file, not this tool' -f $childPid)
        exit 0
    }
    Write-Output 'RUN_RESULT=FAIL'
    Say FAIL ('Win32_Process.Create returned ' + $rv)
    exit 1
}

# ---- wait mode -----------------------------------------------------------------------------
$comspec = $env:ComSpec
if ([string]::IsNullOrWhiteSpace($comspec)) { $comspec = 'cmd.exe' }
Say STEP ('running Vivado batch: ' + $src)
$proc = Start-Process -FilePath $comspec -ArgumentList ('/c "' + $wrapper + '"') `
    -WorkingDirectory $OutDir -NoNewWindow -PassThru

$timedOut = $false
if ($TimeoutSec -gt 0) {
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) { $timedOut = $true }
} else {
    $proc.WaitForExit()
}

$consoleText = ''
if (Test-Path -LiteralPath $Console -PathType Leaf) {
    try { $consoleText = [System.IO.File]::ReadAllText($Console) } catch { $consoleText = '' }
}
$conBytes = 0
if (Test-Path -LiteralPath $Console) { $conBytes = (Get-Item -LiteralPath $Console).Length }
$banner = 'no'
if ($consoleText -match '(?m)Vivado v\d' -or $consoleText -match 'TCL_OK' -or $consoleText -match 'KIT_BATCH_OK') {
    $banner = 'yes'
}

$exitCode = Get-KitBatchExitCode -Status $StatusFile
$exitText = 'unknown'
if ($null -ne $exitCode) { $exitText = [string]$exitCode }

$result = 'OK'
if ($timedOut) { $result = 'TIMEOUT' } elseif ($exitCode -ne 0) { $result = 'FAIL' }

Write-Output 'RUN_MODE=wait'
Write-Output ('RUN_EXIT=' + $exitText)
Write-Output ('RUN_RESULT=' + $result)
Write-Output ('RUN_BANNER=' + $banner)
Write-Output ('RUN_CONSOLE_BYTES=' + $conBytes)
Write-Output ('RUN_CWD=' + $OutDir)
Write-Output ('RUN_LOG=' + $Log)
Write-Output ('RUN_JOURNAL=' + $Journal)
Write-Output ('RUN_CONSOLE=' + $Console)
Write-Output ('RUN_STATUS=' + $StatusFile)
Write-Output ('RUN_WRAPPER=' + $wrapper)

if ($result -ne 'OK') {
    if (-not [string]::IsNullOrWhiteSpace($consoleText)) {
        foreach ($line in @($consoleText -split "`n" | Select-Object -Last 20)) {
            Write-Output ('RUN_TAIL|' + $line.TrimEnd())
        }
    }
    if ($result -eq 'TIMEOUT') {
        Say FAIL ('still running after {0}s; the batch process was NOT killed. Find it with tasklist and kill that PID only' -f $TimeoutSec)
    } else {
        Say FAIL ('Vivado batch failed (exit {0}); console: {1}' -f $exitText, $Console)
    }
    exit 1
}
Say PASS ('Vivado batch OK (exit 0); log: ' + $Log)
Say INFO 'use -Detach for builds longer than ~15 min: one implementation segment measured 34 min'
exit 0
