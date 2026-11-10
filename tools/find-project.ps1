# find-project.ps1 -- locate FPGA project artifacts under the configured project_root.
#
# Why: a distributed kit cannot assume any directory layout. A real case (2026-11-10):
# a teammate's agent called parse_xpr with "<repo>/prj/project_13/prj13.xpr" while the
# file actually lives at "<repo>/prj/project_13/vivado/prj13.xpr". Discovery, not
# construction, is the rule: run this script (or glob) to get real paths first.
#
# Reads project_root from the kit config (default: <kit>\config.yml, then
# <kit>\config.example.yml) or takes -ProjectRoot explicitly.
#
# Output is pure ASCII (Vivado/Tcl are GBK-sensitive; keep logs ASCII).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <kit>\tools\find-project.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File <kit>\tools\find-project.ps1 -Pattern '*.xpr'
#   powershell -NoProfile -ExecutionPolicy Bypass -File <kit>\tools\find-project.ps1 -ProjectRoot <project_root> -Json
#
# Exit codes: 0 = at least one artifact found, 1 = none found, 2 = config/root error.

param(
    [string]$Config = '',
    [string]$ProjectRoot = '',
    [string[]]$Pattern = @('*.xpr', '*.bit', '*.ltx', '*.dcp', '*.rpt'),
    [int]$MaxDepth = 8,
    [int]$MaxPerPattern = 50,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Fail([string]$message, [int]$code) {
    if ($Json) {
        @{ ok = $false; error = $message } | ConvertTo-Json -Compress
    } else {
        Write-Output ("[ERROR] " + $message)
    }
    exit $code
}

function Resolve-KitConfigPath([string]$explicit) {
    if ($explicit -ne '') {
        if (Test-Path -LiteralPath $explicit) { return (Resolve-Path -LiteralPath $explicit).Path }
        Fail ("config not found: " + $explicit) 2
    }
    $here = $PSScriptRoot
    $candidates = @(
        (Join-Path $here '..\config.yml'),
        (Join-Path $here '..\config.example.yml')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    Fail ("no config found; pass -Config <kit>\config.yml or -ProjectRoot <dir>") 2
}

function Get-ProjectRootFromConfig([string]$path) {
    $root = ''
    foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8)) {
        if ($line -match '^\s*project_root\s*:\s*(.+?)\s*$') {
            $root = $Matches[1].Trim()
            if ($root.Length -ge 2 -and (($root.StartsWith("'") -and $root.EndsWith("'")) -or ($root.StartsWith('"') -and $root.EndsWith('"')))) {
                $root = $root.Substring(1, $root.Length - 2)
            }
            break
        }
    }
    if ($root -eq '') { Fail ("project_root not found in " + $path) 2 }
    return $root
}

if ($ProjectRoot -eq '') {
    $configPath = Resolve-KitConfigPath $Config
    $ProjectRoot = Get-ProjectRootFromConfig $configPath
} else {
    $configPath = '(explicit -ProjectRoot)'
}

if (-not (Test-Path -LiteralPath $ProjectRoot)) {
    Fail ("project_root does not exist: " + $ProjectRoot) 2
}
$resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

$nonAscii = @($resolvedRoot.ToCharArray() | Where-Object { [int]$_ -gt 127 })
$warning = ''
if ($nonAscii.Count -gt 0) {
    $warning = 'project_root contains non-ASCII characters; Vivado Tcl may fail on these paths'
}

$skipDirs = @('.git', 'node_modules', '.Xil', 'xsim.dir', '__pycache__', '.venv', 'venv', 'site-packages', '.tmp')
$files = @()
try {
    $files = @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -Depth $MaxDepth -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = $_.FullName.Substring($resolvedRoot.Length).TrimStart('\', '/')
            $parts = $rel -split '[\\/]'
            $blocked = $false
            foreach ($part in $parts) {
                if ($skipDirs -contains $part) { $blocked = $true; break }
            }
            -not $blocked
        })
} catch {
    Fail ("scan failed: " + $_.Exception.Message) 2
}

$found = 0
$report = @()
foreach ($pat in $Pattern) {
    $matchesForPattern = @($files | Where-Object { $_.Name -like $pat } | Sort-Object FullName)
    $report += [pscustomobject]@{
        pattern = $pat
        count   = $matchesForPattern.Count
        files   = @($matchesForPattern | Select-Object -First $MaxPerPattern | ForEach-Object {
            [pscustomobject]@{
                path     = $_.FullName
                bytes    = $_.Length
                modified = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            }
        })
    }
    $found += $matchesForPattern.Count
}

if ($Json) {
    [pscustomobject]@{
        ok           = ($found -gt 0)
        project_root = $resolvedRoot
        config       = $configPath
        warning      = $warning
        patterns     = $report
    } | ConvertTo-Json -Depth 6
} else {
    Write-Output ("project_root = " + $resolvedRoot)
    Write-Output ("config       = " + $configPath)
    if ($warning -ne '') { Write-Output ("[WARN] " + $warning) }
    foreach ($entry in $report) {
        Write-Output ("PATTERN " + $entry.pattern + " : " + $entry.count + " file(s)")
        foreach ($file in $entry.files) {
            Write-Output ("  " + $file.path + "  (" + $file.bytes + " B, " + $file.modified + ")")
        }
        if ($entry.count -gt $entry.files.Count) {
            Write-Output ("  ... " + ($entry.count - $entry.files.Count) + " more; narrow the pattern or raise -MaxPerPattern")
        }
    }
    if ($found -eq 0) {
        Write-Output "FIND_PROJECT: none (check project_root / -Pattern)"
        exit 1
    }
    Write-Output ("FIND_PROJECT: ok (" + $found + " artifact(s) over " + $Pattern.Count + " pattern(s))")
}
exit 0
