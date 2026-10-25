<#
.SYNOPSIS
    Tcl syntax gate for dsh-vivado: parse every .tcl with the interpreter Vivado itself ships.

.DESCRIPTION
    Vivado 2023.1 ships tclsh85t.exe (Tcl 8.5.14) under bin\unwrapped\win64.o -- the same
    interpreter version the tool uses, so `info complete` here answers the question "would Vivado
    fail to parse this file?" without starting Vivado or touching a project.

    Two measured traps this script handles for you:
      * calling tclsh85t.exe without <vivado>\lib\win64.o on PATH dies with exit -1073741515
        (0xC0000135, missing DLL);
      * without TCL_LIBRARY=<vivado>\tps\tcl\tcl8.5 it cannot find its own init.tcl.
    The old CI answer "tclsh is unavailable, skip" was wrong for exactly these two reasons
    (2026-10-25 note in the issue report).

    Output contract (stdout, one KEY=value or per-file line):
        TCLCHECK_TCLSH=<path>
        TCLCHECK_PATCHLEVEL=<x.y.z>
        TCLCHECK file=<abs path> complete=<1|0> exit=<code>
        TCLCHECK_FILES=<n>
        TCLCHECK_FAILED=<n>
        TCLCHECK_RESULT=<PASS|FAIL>
    Exit codes: 0 = all files parse, 1 = at least one file does not, 2 = setup error.

.PARAMETER Path
    One or more .tcl files or directories (directories are searched recursively for *.tcl).

.PARAMETER VivadoBat
    vivado.bat or its bin directory, used to locate the bundled tclsh. Default: kit config.yml,
    then %XILINX_VIVADO%.

.PARAMETER Tclsh
    Use this interpreter instead of the auto-detected one.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\tcl-check.ps1 .\scripts
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\tcl-check.ps1 .\a.tcl .\b.tcl

.NOTES
    Windows PowerShell 5.1 compatible, ASCII-only source (see lib/common.ps1 header).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string[]]$Path,
    [string]$VivadoBat,
    [string]$Tclsh
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$KitRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
function Say { param([string]$Level, [string]$Message) Write-KitLog $Level $Message }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---- 1. Vivado root ------------------------------------------------------------------------
$vivadoRoot = ''
$bat = Find-KitVivadoBat -Explicit $VivadoBat -KitRoot $KitRoot
if (-not [string]::IsNullOrWhiteSpace($bat)) {
    $vivadoRoot = Split-Path -Parent (Split-Path -Parent $bat)
} elseif (-not [string]::IsNullOrWhiteSpace($env:XILINX_VIVADO)) {
    $vivadoRoot = $env:XILINX_VIVADO
}

# ---- 2. interpreter ------------------------------------------------------------------------
$candidates = New-Object System.Collections.Generic.List[string]
if (-not [string]::IsNullOrWhiteSpace($Tclsh)) { $candidates.Add($Tclsh) }
if (-not [string]::IsNullOrWhiteSpace($vivadoRoot)) {
    $candidates.Add((Join-Path $vivadoRoot 'bin\unwrapped\win64.o\tclsh85t.exe'))
    foreach ($sub in @('bin\unwrapped\win64.o', 'bin\unwrapped\win64', 'bin')) {
        $dir = Join-Path $vivadoRoot $sub
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Filter 'tclsh*.exe' -File -ErrorAction SilentlyContinue |
            ForEach-Object { $candidates.Add($_.FullName) }
    }
}
foreach ($name in @('tclsh', 'tclsh85', 'tclsh86')) {
    $cmd = Get-Command -Name $name -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) { $candidates.Add($cmd.Source) }
}
$tclshPath = ''
foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $tclshPath = (Resolve-Path -LiteralPath $candidate).Path
        break
    }
}
if ([string]::IsNullOrWhiteSpace($tclshPath)) {
    Say FAIL 'no tclsh found: pass -Tclsh <path>, -VivadoBat <path>, or set %XILINX_VIVADO%'
    Write-Output 'TCLCHECK_RESULT=FAIL'
    exit 2
}

# ---- 3. runtime env the bundled interpreter needs ------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($vivadoRoot)) {
    $libDir = Join-Path $vivadoRoot 'lib\win64.o'
    if (Test-Path -LiteralPath $libDir) { $env:PATH = $libDir + ';' + $env:PATH }
    $tclLib = Join-Path $vivadoRoot 'tps\tcl\tcl8.5'
    if (-not (Test-Path -LiteralPath $tclLib)) {
        $parent = Join-Path $vivadoRoot 'tps\tcl'
        if (Test-Path -LiteralPath $parent) {
            Get-ChildItem -LiteralPath $parent -Directory -Filter 'tcl*' -ErrorAction SilentlyContinue |
                Sort-Object Name | Select-Object -First 1 | ForEach-Object { $tclLib = $_.FullName }
        }
    }
    if (Test-Path -LiteralPath $tclLib) { $env:TCL_LIBRARY = $tclLib }
}

# ---- 4. files ------------------------------------------------------------------------------
$files = New-Object System.Collections.Generic.List[string]
foreach ($item in $Path) {
    if (Test-Path -LiteralPath $item -PathType Container) {
        Get-ChildItem -LiteralPath $item -Recurse -Filter '*.tcl' -File -ErrorAction SilentlyContinue |
            ForEach-Object { $files.Add($_.FullName) }
    } elseif (Test-Path -LiteralPath $item -PathType Leaf) {
        $files.Add((Resolve-Path -LiteralPath $item).Path)
    } else {
        Say WARN ('not found, skipped: ' + $item)
    }
}
if ($files.Count -eq 0) {
    Say FAIL 'no .tcl files matched'
    Write-Output 'TCLCHECK_RESULT=FAIL'
    exit 2
}

# ---- 5. runner script (path goes through the environment: PS 5.1 mangles spaced arguments) --
$workDir = New-KitAsciiWorkDir -KitRoot $null -Prefix 'dsh-vivado-tclcheck'
$runner = Join-Path $workDir 'tclcheck_runner.tcl'
$runnerText = @(
    'puts "TCLCHECK_PATCHLEVEL [info patchlevel]"',
    'set f $::env(KIT_TCL_FILE)',
    'if {[catch {set fh [open $f r]} err]} { puts "TCLCHECK_READ_ERROR $err"; exit 2 }',
    'fconfigure $fh -encoding utf-8',
    'set data [read $fh]',
    'close $fh',
    'if {[info complete $data]} { puts "TCLCHECK_COMPLETE 1"; exit 0 }',
    'puts "TCLCHECK_COMPLETE 0"',
    'exit 1'
) -join "`n"
[System.IO.File]::WriteAllText($runner, $runnerText + "`n", $utf8NoBom)

$patchlevel = ''
$failed = 0
foreach ($file in $files) {
    $env:KIT_TCL_FILE = $file
    $output = & $tclshPath $runner 2>&1
    $code = $LASTEXITCODE
    $complete = '0'
    $sawError = $false
    foreach ($line in @($output)) {
        $text = [string]$line
        if ($text -match '^TCLCHECK_PATCHLEVEL (.+)$') { $patchlevel = $Matches[1].Trim() }
        elseif ($text -match '^TCLCHECK_COMPLETE (\d)') { $complete = $Matches[1] }
        elseif ($text -match 'TCLCHECK_READ_ERROR') { $sawError = $true }
    }
    if ($code -ne 0 -or $complete -ne '1' -or $sawError) { $failed = $failed + 1 }
    Write-Output ('TCLCHECK file={0} complete={1} exit={2}' -f $file, $complete, $code)
    if ($code -ne 0 -or $complete -ne '1') {
        foreach ($line in @($output)) { Write-Output ('TCLCHECK_TAIL|' + ([string]$line).TrimEnd()) }
    }
}

try { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Write-Output ('TCLCHECK_TCLSH=' + $tclshPath)
Write-Output ('TCLCHECK_PATCHLEVEL=' + $patchlevel)
Write-Output ('TCLCHECK_FILES=' + $files.Count)
Write-Output ('TCLCHECK_FAILED=' + $failed)
if ($failed -eq 0) {
    Write-Output 'TCLCHECK_RESULT=PASS'
    Say PASS ('{0} .tcl file(s) parse with Tcl {1}' -f $files.Count, $patchlevel)
    exit 0
}
Write-Output 'TCLCHECK_RESULT=FAIL'
Say FAIL ('{0} of {1} .tcl file(s) do not parse (see TCLCHECK_TAIL lines)' -f $failed, $files.Count)
exit 1
