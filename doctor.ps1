<#
.SYNOPSIS
    Health check for a dsh-vivado installation (13 checks, PASS / WARN / FAIL).

.DESCRIPTION
    doctor answers one question: will the Vivado preset of this kit actually work on THIS
    machine, and if not, what is the single thing the user must change? It is read-only:
    it starts processes (Vivado, python) but never writes to the profile, to Vivado or to
    the MCP site, and it never needs admin rights.

    Output (human):
        [PASS] <id> <title> - <detail>
        [WARN] ... / [FAIL] ...          (+ one "fix:" line, indented, for WARN and FAIL)
        summary: 11 PASS, 2 WARN, 0 FAIL (13 checks) in 6.2 s

    Exit code: 0 when there is no FAIL, 1 when any check FAILed (WARN never changes it), so CI
    can gate on it.

    Checks (1-10 are KIT-SPEC section 7 in its order; 11-13 are kit additions).
    See docs/doctor-checks.md for the thresholds and the exact commands:
       1 vivado-install    <vivado_path>\vivado.bat exists
       2 vivado-version    config vivado_version is proven against the install
       3 python            <python> runs, >= 3.10, UTF-8 mode usable, PYTHONUTF8=1 in the patch
       4 part              the configured device belongs to an installed part family
       5 ascii-paths       cwd / TEMP / TMP / project_root / vivado_mcp_cwd / temp_dir are ASCII
       6 mcp-import        `import vivado_mcp` works and resolves INSIDE vivado_mcp_site
       7 mcp-tools         mcp_ctl.py list reports 32 tools
       8 license           a license source is statically visible (never FAILs)
       9 bundle-installed  profile package.json has the bundle link + dsh.profile.bundles
      10 bundle-rendered   staging cordis.patch.yml is rendered and points at a real skills dir
      11 mcp-patches       the four local vivado-mcp patches are present (content probes)
      12 compatibility     the mcp-client version exemption exists when it is needed
      13 skills            staging skills/ carries the 8 expected skills with matching names

    Deliberately WARN instead of FAIL (documented in docs/doctor-checks.md):
       * "kit not installed in this profile at all" (nothing to check yet; run install.ps1);
         a *partial*/broken install is a FAIL.
       * check 11 (patches missing only loses the default-full behaviour; Vivado still works).
       * check 8 (licenses may legitimately live in a file server / env we cannot see).
       * checks skipped by -Quick, and "cannot verify statically" cases.

.PARAMETER Config
    Config file. Default: <kit>\config.yml, else <kit>\config.example.yml.

.PARAMETER Profile
    DSH profile to inspect. Default: desktop.

.PARAMETER DshHome
    DSH config root. Default: $env:DSH_HOME, else %USERPROFILE%\.dsh.

.PARAMETER InstallDir
    DSH installation root (the directory that contains "DeepSeek Harness.exe"). Default:
    discovered by lib\common.ps1 Find-DshCli.

.PARAMETER Json
    Machine-readable output: a one-line (compressed) JSON array of {id,title,status,detail,fix}.
    Nothing else is written to stdout in this mode (diagnostics go to stderr). One line on
    purpose: PS 5.1 pipes child-process output line by line, so exactly one line keeps
    `doctor.ps1 -Json | ConvertFrom-Json` usable.

.PARAMETER Quick
    Skip the three slow external probes (vivado.bat -version, the python import, mcp_ctl.py
    list). Must finish in well under 10 s; the skipped checks report WARN "skipped by -Quick".

.PARAMETER NonInteractive
    Accepted for symmetry with install.ps1 (and so copy-pasted command lines keep working).
    doctor never prompts, so this switch changes nothing.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File doctor.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File doctor.ps1 -DshHome D:\probe-home -Profile probe -Json

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File doctor.ps1 -Quick

.NOTES
    Windows PowerShell 5.1 only. ASCII-only source (PS 5.1 reads *.ps1 as ANSI); the Chinese
    explanation lives in docs/doctor-checks.md.
#>
[CmdletBinding()]
param(
    [string]$Config,
    [string]$Profile = 'desktop',
    [string]$DshHome,
    [string]$InstallDir,
    [switch]$Json,
    [switch]$Quick,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$script:KitRoot = $PSScriptRoot
$script:JsonMode = [bool]$Json
$script:QuickMode = [bool]$Quick
$script:Started = Get-Date

. (Join-Path $script:KitRoot 'lib\common.ps1')
. (Join-Path $script:KitRoot 'lib\doctor-helpers.ps1')

$script:BundleName = 'dsh-vivado'
$script:StageLeaf = 'dsh-vivado'
$script:ExpectedTools = 32
$script:ExpectedSkills = @(
    'amd-doc-search',
    'hw-ila-debug',
    'hw-vio-debug',
    'vivado-revision-control',
    'vivado-rtl-elaboration-analysis',
    'vivado-rtl-lint',
    'vivado-simulate-rtl',
    'vivado-workflow-discipline'
)
$script:Results = New-Object System.Collections.Generic.List[object]
$script:State = @{}
$script:Conf = @{}

# ---------------------------------------------------------------------------
#  output helpers (JSON mode must keep stdout clean)
# ---------------------------------------------------------------------------

function Say {
    param([string]$Level, [string]$Message)
    if ($script:JsonMode) { return }
    Write-KitLog $Level $Message
}

function SayRaw {
    param([string]$Message)
    if ($script:JsonMode) { return }
    Write-Host $Message
}

function Note {
    <# Extra evidence line, only for WARN/FAIL rows. #>
    param([string]$Message)
    if ($script:JsonMode) {
        [Console]::Error.WriteLine($Message)
        return
    }
    Write-Host ('       ' + $Message) -ForegroundColor DarkGray
}

function New-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'WARN', 'FAIL')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Detail,
        [string]$Fix = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($Fix)) { $Fix = $Fix.Trim() }
    return [pscustomobject]@{
        id     = $Id
        title  = $Title
        status = $Status
        detail = $Detail
        fix    = $Fix
    }
}

function Add-Result {
    param($Result)
    $script:Results.Add($Result)
    if ($script:JsonMode) { return }
    $color = 'Gray'
    if ($Result.status -eq 'PASS') { $color = 'Green' }
    elseif ($Result.status -eq 'WARN') { $color = 'Yellow' }
    elseif ($Result.status -eq 'FAIL') { $color = 'Red' }
    $line = '[{0}] {1} {2} - {3}' -f $Result.status, $Result.id, $Result.title, $Result.detail
    Write-Host $line -ForegroundColor $color
    if (-not [string]::IsNullOrWhiteSpace($Result.fix)) {
        Write-Host ('       fix: ' + $Result.fix) -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------------------
#  config / context helpers
# ---------------------------------------------------------------------------

function Get-Conf {
    <# Config value ('' when the key is absent or empty). #>
    param([string]$Key)
    if ($script:Conf.ContainsKey($Key)) { return [string]$script:Conf[$Key] }
    return ''
}

function Get-VivadoBin { return (Get-DoctorWinPath (Get-Conf 'vivado_path')).TrimEnd('\') }

function Get-VivadoInstall {
    $bin = Get-VivadoBin
    if ($bin -eq '') { return '' }
    $parent = Split-Path -Parent $bin
    if ($null -eq $parent) { return '' }
    return $parent
}

function Get-PythonPath { return (Get-DoctorWinPath (Get-Conf 'python')) }

function Get-McpSite { return (Get-DoctorWinPath (Get-Conf 'vivado_mcp_site')).TrimEnd('\') }

function Get-SkillsFromPatch {
    <# Read the customSkillDirs path out of a rendered patch / template. Returns ''. #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $lines = @($Text -split "\r?\n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*customSkillDirs\s*:') {
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j].Trim().Length -eq 0) { $j++ }
            if ($j -lt $lines.Count) {
                $v = $lines[$j].Trim()
                $v = $v -replace '^-\s*', ''
                $v = $v.Trim("'").Trim('"')
                return $v.Trim()
            }
        }
    }
    return ''
}

# ---------------------------------------------------------------------------
#  probe helpers (cached so a check never runs the same slow command twice)
# ---------------------------------------------------------------------------

function Get-PythonProbe {
    <#
    Version probe for the configured interpreter, run once and cached:
        Path / Exists / Version / VersionOk / StartOk / Detail
    #>
    if ($script:State.ContainsKey('Python')) { return $script:State['Python'] }
    $probe = @{
        Path = (Get-PythonPath)
        Exists = $false
        StartOk = $false
        Version = ''
        VersionOk = $false
        Detail = ''
    }
    if ($probe.Path -ne '' -and (Test-DoctorFile $probe.Path)) {
        $probe.Exists = $true
        $r = Invoke-DoctorNative -FilePath $probe.Path `
            -Arguments @('-c', 'import sys;print("%d.%d.%d" % sys.version_info[:3])') -TimeoutSec 30
        if ($r.Ok -and $r.ExitCode -eq 0) {
            $m = [regex]::Match($r.StdOut, '(\d+)\.(\d+)\.(\d+)')
            if ($m.Success) {
                $probe.StartOk = $true
                $probe.Version = $m.Value
                $v = New-Object System.Version $m.Value
                if ($v -ge (New-Object System.Version '3.10.0')) { $probe.VersionOk = $true }
            }
        } else {
            if ($r.TimedOut) { $probe.Detail = 'timed out after 30 s' }
            else { $probe.Detail = ('rc={0} {1}' -f $r.ExitCode, (Get-DoctorTextTail -Text ($r.StdErr + "`n" + $r.StdOut) -Lines 2)) }
        }
    }
    $script:State['Python'] = $probe
    return $probe
}

function Get-RuntimeVersionCached {
    <# @{ Version; Source } for the DSH runtime, probed once.
       Source 'dsh.cmd --version' is the only value that is valid in compatibility.json
       (the exe ProductVersion 0.2.1.0 drops the -rc.2 suffix). #>
    if (-not $script:State.ContainsKey('RuntimeVersion')) {
        $root = ''
        if (-not [string]::IsNullOrWhiteSpace($script:State['DshCli'])) {
            $root = $script:State['InstallRoot']
        }
        $script:State['RuntimeVersion'] = (Get-DoctorRuntimeVersionInfo -DshCli $script:State['DshCli'] -InstallRoot $root)
    }
    return $script:State['RuntimeVersion']
}

# ---------------------------------------------------------------------------
#  check 1 -- vivado-install
# ---------------------------------------------------------------------------

function Test-CheckVivadoInstall {
    $bin = Get-VivadoBin
    if ($bin -eq '') {
        return New-Result 'vivado-install' 'Vivado install' 'FAIL' `
            'config has no vivado_path' `
            'set `vivado_path` to the directory that contains vivado.bat (e.g. D:/Xilinx/Vivado/2025.2/bin) and re-run install.ps1'
    }
    $bat = Join-Path $bin 'vivado.bat'
    if (-not (Test-DoctorFile $bat)) {
        $extra = ''
        if (-not (Test-DoctorDir $bin)) { $extra = ' (that directory does not exist either)' }
        return New-Result 'vivado-install' 'Vivado install' 'FAIL' `
            ('vivado.bat not found at ' + (ConvertTo-SlashPath $bat) + $extra) `
            'set `vivado_path` to the directory that contains vivado.bat (e.g. D:/Xilinx/Vivado/2025.2/bin) and re-run install.ps1'
    }
    $size = 0
    try { $size = (Get-Item -LiteralPath $bat).Length } catch { $size = 0 }
    return New-Result 'vivado-install' 'Vivado install' 'PASS' `
        ('found ' + (ConvertTo-SlashPath $bat) + ' (' + $size + ' bytes)') ''
}

# ---------------------------------------------------------------------------
#  check 2 -- vivado-version
# ---------------------------------------------------------------------------

function Get-VivadoVersionProof {
    <#
    Static version proofs, in priority order (Lead ruling 2026-10-24):
      1a  <install>\data\parts\installed_devices.txt -> 'BuildNumber'  (primary on this machine)
      1b  <install>\data\version.txt
      1c  <install>\version.txt                     (== <vivado_path>\..\version.txt)
      1d  <install>\.xinstall\Vivado\xinst_version
    Returns Version/Source/Level. Level 0 means "nothing static proved it".
    #>
    param([string]$Install)
    $proof = @{ Version = ''; Source = ''; Level = 0 }
    if ($Install -eq '') { return $proof }
    $candidates = @(
        @{ Path = (Join-Path $Install 'data\parts\installed_devices.txt'); Label = 'data/parts/installed_devices.txt (BuildNumber)'; Priority = 10 },
        @{ Path = (Join-Path $Install 'data\version.txt'); Label = 'data/version.txt'; Priority = 11 },
        @{ Path = (Join-Path $Install 'version.txt'); Label = 'version.txt'; Priority = 12 },
        @{ Path = (Join-Path $Install '.xinstall\Vivado\xinst_version'); Label = '.xinstall/Vivado/xinst_version'; Priority = 13 }
    )
    $best = $null
    $bestPriority = 0
    foreach ($c in $candidates) {
        if (-not (Test-DoctorFile $c.Path)) { continue }
        $txt = Read-DoctorTextFile $c.Path
        if ($txt.Length -eq 0) { continue }
        $ver = ''
        $m = [regex]::Match($txt, 'BuildNumber''?\s*=>\s*''(\d{4}\.\d)')
        if ($m.Success) {
            $ver = $m.Groups[1].Value
        } else {
            $m = [regex]::Match($txt, 'v?(\d{4}\.\d)')
            if ($m.Success) { $ver = $m.Groups[1].Value }
        }
        if ($ver -eq '') { continue }
        if ($null -eq $best -or $c.Priority -lt $bestPriority) {
            $best = @{ Version = $ver; Source = $c.Label; Level = 1 }
            $bestPriority = $c.Priority
        }
    }
    if ($null -ne $best) { return $best }
    return $proof
}

function Test-CheckVivadoVersion {
    $want = (Get-Conf 'vivado_version').Trim()
    if ($want -eq '') {
        return New-Result 'vivado-version' 'Vivado version' 'FAIL' 'config has no vivado_version' `
            'set `vivado_version` (e.g. 2023.1) in config.yml and re-run install.ps1 - it selects the persona tier'
    }
    $install = Get-VivadoInstall
    $dirname = ''
    if ($install -ne '') { $dirname = Split-Path -Leaf $install }
    if ($install -eq '') {
        return New-Result 'vivado-version' 'Vivado version' 'FAIL' `
            'config has no usable vivado_path, so the install root is unknown' `
            'set `vivado_path` to the directory that contains vivado.bat and re-run install.ps1'
    }

    $proof = Get-VivadoVersionProof $install
    if ($proof.Version -ne '') {
        if ($proof.Version -eq $want) {
            return New-Result 'vivado-version' 'Vivado version' 'PASS' `
                ('config vivado_version=' + $want + ', proved by level 1 (static file): ' + $proof.Source) ''
        }
        return New-Result 'vivado-version' 'Vivado version' 'FAIL' `
            ('config says ' + $want + ' but level 1 (' + $proof.Source + ') says ' + $proof.Version + ' - two comparable values disagree') `
            ('set `vivado_version: ' + $proof.Version + '` in config.yml and re-run install.ps1 (the persona tier depends on it)')
    }

    if ($script:QuickMode) {
        if ($dirname -match '^\d{4}\.\d$') {
            return New-Result 'vivado-version' 'Vivado version' 'WARN' `
                ('unverified (' + $want + '): only the install directory name "' + $dirname + '" matches (level 3); -Quick skipped the level 2 probe') `
                're-run doctor.ps1 without -Quick to prove the version'
        }
        return New-Result 'vivado-version' 'Vivado version' 'WARN' `
            ('unverified (' + $want + '): no static version file under ' + (ConvertTo-SlashPath $install) + '; -Quick skipped the level 2 probe') `
            're-run doctor.ps1 without -Quick to prove the version'
    }

    # level 2: the slow probe. 2023.1's loader.bat forwards -version to
    # `prodversion.exe vivado.exe -longversion`, which on this machine exits rc=1 with NO output,
    # so an empty result is a known-broken probe, not evidence of a broken install.
    $bin = Get-VivadoBin
    $bat = Join-Path $bin 'vivado.bat'
    $r = Invoke-DoctorNative -FilePath $bat -Arguments @('-version') -TimeoutSec 120
    if ($r.TimedOut) {
        return New-Result 'vivado-version' 'Vivado version' 'WARN' `
            ('unverified (' + $want + '): level 2 probe (vivado.bat -version) did not finish within 120 s and was killed') `
            're-run doctor.ps1 -Quick to skip the probe, or check the Vivado install by hand (vivado.bat -version)'
    }
    $m = [regex]::Match(($r.StdOut + "`n" + $r.StdErr), 'v?(\d{4}\.\d)')
    if ($m.Success) {
        $probed = $m.Groups[1].Value
        if ($probed -eq $want) {
            return New-Result 'vivado-version' 'Vivado version' 'PASS' `
                ('config vivado_version=' + $want + ', proved by level 2 (vivado.bat -version, rc=' + $r.ExitCode + ')') ''
        }
        return New-Result 'vivado-version' 'Vivado version' 'FAIL' `
            ('config says ' + $want + ' but level 2 (vivado.bat -version) says ' + $probed + ' - two comparable values disagree') `
            ('set `vivado_version: ' + $probed + '` in config.yml and re-run install.ps1')
    }
    if ($dirname -match '^\d{4}\.\d$') {
        return New-Result 'vivado-version' 'Vivado version' 'WARN' `
            ('unverified (' + $want + '): only the install directory name "' + $dirname + '" matches (level 3); level 2 probe printed no version string (rc=' + $r.ExitCode + ', known-broken on 2023.1 - loader.bat calls prodversion.exe -longversion)') `
            'verify on the machine that Vivado runs (vivado.bat -version), then keep `vivado_version` as is'
    }
    return New-Result 'vivado-version' 'Vivado version' 'WARN' `
        ('unverified (' + $want + '): no static version file under ' + (ConvertTo-SlashPath $install) + ' and the level 2 probe printed nothing (rc=' + $r.ExitCode + ')') `
        'verify on the machine that Vivado runs (vivado.bat -version), then set `vivado_version` to that value'
}

# ---------------------------------------------------------------------------
#  check 3 -- python
# ---------------------------------------------------------------------------

function Test-CheckPython {
    $probe = Get-PythonProbe
    if ($probe.Path -eq '') {
        return New-Result 'python' 'Python + UTF-8' 'FAIL' 'config has no python' `
            'point `python` at a 3.10+ interpreter (e.g. the vivado-mcp venv: D:/vivado-mcp/venv/Scripts/python.exe) and re-run install.ps1'
    }
    if (-not $probe.Exists) {
        return New-Result 'python' 'Python + UTF-8' 'FAIL' `
            ('python not found: ' + (ConvertTo-SlashPath $probe.Path)) `
            'point `python` at a 3.10+ interpreter (e.g. the vivado-mcp venv: D:/vivado-mcp/venv/Scripts/python.exe)'
    }
    if (-not $probe.StartOk) {
        return New-Result 'python' 'Python + UTF-8' 'FAIL' `
            ('python could not report its version: ' + $probe.Detail) `
            'point `python` at a 3.10+ interpreter; a venv whose base interpreter was moved fails exactly like this'
    }
    if (-not $probe.VersionOk) {
        return New-Result 'python' 'Python + UTF-8' 'FAIL' `
            ('python ' + $probe.Version + ' is older than 3.10') `
            'point `python` at a 3.10+ interpreter (e.g. the vivado-mcp venv: D:/vivado-mcp/venv/Scripts/python.exe)'
    }

    # UTF-8 mode: PYTHONUTF8=1 must make the interpreter emit UTF-8 for a CJK literal.
    $u = Invoke-DoctorNative -FilePath $probe.Path `
        -Arguments @('-c', "print('\u4e2d')") `
        -Environment @{ 'PYTHONUTF8' = '1' } -TimeoutSec 30
    $cjk = [string][char]0x4E2D
    $utf8Ok = ($u.Ok -and $u.ExitCode -eq 0 -and $u.StdOut.IndexOf($cjk) -ge 0)
    if ($u.TimedOut) { $utf8Ok = $false }

    # PYTHONUTF8=1 must also be exported by the kit itself for the MCP process.
    $patchPath = Join-Path $script:State['StageDir'] 'cordis.patch.yml'
    $tmplPath = Join-Path $script:KitRoot 'templates\preset.patch.yml.tmpl'
    $patchText = ''
    $patchWhere = ''
    if (Test-DoctorFile $patchPath) {
        $patchText = Read-DoctorTextFile $patchPath
        $patchWhere = 'rendered patch'
    } elseif (Test-DoctorFile $tmplPath) {
        $patchText = Read-DoctorTextFile $tmplPath
        $patchWhere = 'template (not rendered yet)'
    }
    $envDeclared = ''
    if ($patchText.Length -gt 0 -and $patchText -match "PYTHONUTF8:\s*'?1'?") { $envDeclared = $patchWhere }

    if (-not $utf8Ok) {
        $why = 'python could not print a CJK literal with PYTHONUTF8=1'
        if ($u.TimedOut) { $why = 'the PYTHONUTF8=1 probe timed out after 30 s' }
        return New-Result 'python' 'Python + UTF-8' 'FAIL' `
            ('python ' + $probe.Version + ' runs, but ' + $why) `
            'keep PYTHONUTF8=1 in the mcp-vivado env block; if the console cannot encode UTF-8, run install.ps1 from cmd.exe instead of a legacy console'
    }
    if ($envDeclared -eq '') {
        return New-Result 'python' 'Python + UTF-8' 'WARN' `
            ('python ' + $probe.Version + ' + UTF-8 probe OK, but no PYTHONUTF8=1 found in the kit patch (no patch/template under the kit root)') `
            're-run install.ps1 so the mcp-vivado env block exports PYTHONUTF8=1 for the MCP process'
    }
    return New-Result 'python' 'Python + UTF-8' 'PASS' `
        ('python ' + $probe.Version + ' (>=3.10), CJK literal emitted as UTF-8, PYTHONUTF8=1 in the ' + $envDeclared) ''
}

# ---------------------------------------------------------------------------
#  check 4 -- part
# ---------------------------------------------------------------------------

function Get-PartsTree {
    <# The directory whose children are the device-family directories, or ''.
       Layouts accepted: <install>\data\parts\xilinx\<family>  and  <install>\data\parts\<family>. #>
    param([string]$Install)
    $tree = @{ Root = ''; Scheme = '' }
    if ($Install -eq '') { return $tree }
    $parts = Join-Path $Install 'data\parts'
    if (-not (Test-DoctorDir $parts)) { return $tree }
    $xilinx = Join-Path $parts 'xilinx'
    if (Test-DoctorDir $xilinx) {
        $tree.Root = $xilinx
        $tree.Scheme = 'data/parts/xilinx/<family>'
        return $tree
    }
    $tree.Root = $parts
    $tree.Scheme = 'data/parts/<family>'
    return $tree
}

function Get-DeviceFamiliesFromIndex {
    <# Families (from installed_devices.txt DeviceListMapping) whose device list contains $Device. #>
    param([string]$Install, [string]$Device)
    $out = New-Object System.Collections.Generic.List[string]
    if ($Install -eq '') { return $out }
    $file = Join-Path $Install 'data\parts\installed_devices.txt'
    if (-not (Test-DoctorFile $file)) { return $out }
    $txt = Read-DoctorTextFile $file
    if ($txt.Length -eq 0) { return $out }
    $needle = "'" + $Device + "'"
    $headers = [regex]::Matches($txt, "'([a-z][a-z0-9+_]{2,})'\s*=>\s*\[")
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $start = $headers[$i].Index
        if ($i + 1 -lt $headers.Count) { $end = $headers[$i + 1].Index } else { $end = $txt.Length }
        $block = $txt.Substring($start, $end - $start)
        if ($block.IndexOf($needle) -ge 0) { $out.Add($headers[$i].Groups[1].Value) }
    }
    return $out
}

function Get-DeviceFamilyToken {
    <# xcku060 -> xcku, xc7a35t -> xc7a, xczu9eg -> xczu, xc7k325t -> xc7k, xcvp1802 -> xcvp. #>
    param([string]$Device)
    $m = [regex]::Match($Device, '^xc([0-9]?)([a-z]+)')
    if (-not $m.Success) { return '' }
    return ('xc' + $m.Groups[1].Value + $m.Groups[2].Value)
}

function Get-FamilyDirsForToken {
    <# Candidate family directory names for a device token (ordered; '' tokens return @()). #>
    param([string]$Token)
    if ($Token -eq '') { return @() }
    $map = @{
        'xc7a' = @('artix7')
        'xc7k' = @('kintex7')
        'xc7v' = @('virtex7')
        'xc7z' = @('zynq')
        'xc7s' = @('spartan7')
        'xc6s' = @('spartan6')
        'xc5v' = @('virtex5')
        'xc4v' = @('virtex4')
        'xcku' = @('kintexu', 'kintexuplus')
        'xcvu' = @('virtexu', 'virtexuplus', 'virtexuplus58g')
        'xcau' = @('artixuplus')
        'xczu' = @('zynquplus')
        'xcvc' = @('versal')
        'xcvm' = @('versal')
        'xcvp' = @('versal')
        'xcve' = @('versal')
        'xcva' = @('versal')
        'xcvh' = @('versal')
    }
    if ($map.ContainsKey($Token)) { return $map[$Token] }
    return @()
}

function Test-CheckPart {
    $part = (Get-Conf 'part').Trim()
    if ($part -eq '') {
        return New-Result 'part' 'device part' 'FAIL' 'config has no part' `
            'set `part` to a device installed in this Vivado (e.g. xcku060-ffva1156-2-i) and re-run install.ps1'
    }
    $device = ($part -split '-')[0].ToLower()
    $install = Get-VivadoInstall
    $tree = Get-PartsTree $install
    if ($tree.Root -eq '') {
        return New-Result 'part' 'device part' 'WARN' `
            ('cannot verify statically: no parts tree under ' + (ConvertTo-SlashPath (Join-Path $install 'data\parts')) + ' (is Vivado installed without device data?)') `
            'check `part` by hand (Vivado: get_parts) - doctor only verifies the part data on disk'
    }
    $familyDirs = @()
    try {
        $familyDirs = @(Get-ChildItem -LiteralPath $tree.Root -Directory | ForEach-Object { $_.Name } | Sort-Object)
    } catch { $familyDirs = @() }
    $familyList = 'none'
    if ($familyDirs.Count -gt 0) {
        $take = $familyDirs
        if ($take.Count -gt 12) { $take = $take[0..11] }
        $familyList = ($take -join ', ')
        if ($familyDirs.Count -gt 12) { $familyList = $familyList + ', ...' }
    }
    $fix = 'set `part` to a device installed in this Vivado (families found: ' + $familyList + '; device names are listed in data/parts/installed_devices.txt) and re-run install.ps1'

    $families = @(Get-DeviceFamiliesFromIndex -Install $install -Device $device)
    foreach ($f in $families) {
        if (Test-DoctorDir (Join-Path $tree.Root $f)) {
            return New-Result 'part' 'device part' 'PASS' `
                ('part ' + $part + ' -> device ' + $device + ' -> family ' + $f + ' (' + $tree.Scheme + ', listed in installed_devices.txt)') ''
        }
    }

    # fall back to the name convention (xcku060 -> xcku -> kintexu) when the index is absent
    $token = Get-DeviceFamilyToken $device
    $candidates = @(Get-FamilyDirsForToken $token)
    foreach ($c in $candidates) {
        if (Test-DoctorDir (Join-Path $tree.Root $c)) {
            return New-Result 'part' 'device part' 'PASS' `
                ('part ' + $part + ' -> device ' + $device + ' -> family ' + $c + ' (' + $tree.Scheme + ', resolved by name convention)') ''
        }
    }

    if ($families.Count -gt 0) {
        return New-Result 'part' 'device part' 'FAIL' `
            ('device ' + $device + ' is listed under family [' + ($families -join ', ') + '] in installed_devices.txt, but no such directory exists under ' + $tree.Scheme) `
            $fix
    }
    return New-Result 'part' 'device part' 'FAIL' `
        ('device ' + $device + ' is not part of this Vivado install (no match in installed_devices.txt, no family dir for token "' + $token + '")') `
        $fix
}

# ---------------------------------------------------------------------------
#  check 5 -- ascii-paths
# ---------------------------------------------------------------------------

function Test-CheckAsciiPaths {
    <#
    cwd/TEMP/TMP/project_root/vivado_mcp_cwd/temp_dir must be pure ASCII.

    Severity split on purpose:
      * cwd        -> WARN. The current shell directory is where doctor happens to be started, not
                      a kit setting; the kit itself is fine. (Verified: running doctor from the
                      Chinese-named vault would otherwise turn the whole check red for nothing.)
      * TEMP/TMP   -> FAIL. They are inherited by Vivado and by the MCP process; a GBK-decoded
                      Chinese TEMP breaks Tcl scratch files and python's temp I/O.
      * config keys-> FAIL. They are what install.ps1 renders into the MCP env / project root.
    #>
    $cwd = ''
    try { $cwd = (Get-Location).Path } catch { $cwd = '' }
    $items = @(
        @{ Key = 'cwd'; Value = $cwd; Config = $false; Severity = 'WARN' },
        @{ Key = 'TEMP'; Value = $env:TEMP; Config = $false; Severity = 'FAIL' },
        @{ Key = 'TMP'; Value = $env:TMP; Config = $false; Severity = 'FAIL' },
        @{ Key = 'project_root'; Value = (Get-Conf 'project_root'); Config = $true; Severity = 'FAIL' },
        @{ Key = 'vivado_mcp_cwd'; Value = (Get-Conf 'vivado_mcp_cwd'); Config = $true; Severity = 'FAIL' },
        @{ Key = 'temp_dir'; Value = (Get-Conf 'temp_dir'); Config = $true; Severity = 'FAIL' }
    )
    $badFail = New-Object System.Collections.Generic.List[object]
    $badWarn = New-Object System.Collections.Generic.List[object]
    $empty = New-Object System.Collections.Generic.List[string]
    foreach ($it in $items) {
        $val = [string]$it.Value
        if ([string]::IsNullOrWhiteSpace($val)) {
            if ($it.Config) { $empty.Add($it.Key) }
            continue
        }
        if (-not (Test-AsciiPath $val)) {
            if ($it.Severity -eq 'FAIL') { $badFail.Add($it) } else { $badWarn.Add($it) }
        }
    }
    # PS 5.1 quirk: adding two @(List[object]) arrays throws "Argument types do not
    # match" - copy element-wise into one list instead.
    $allBad = New-Object System.Collections.Generic.List[object]
    foreach ($x in $badFail) { $allBad.Add($x) }
    foreach ($x in $badWarn) { $allBad.Add($x) }
    if ($allBad.Count -gt 0) {
        $first = $allBad[0]
        $suggestion = Get-DoctorAsciiSuggestion ([string]$first.Value)
        $detail = 'non-ASCII path in ' + $first.Key + '=' + [string]$first.Value
        if ($allBad.Count -gt 1) {
            $rest = @()
            for ($i = 1; $i -lt $allBad.Count; $i++) { $rest += ($allBad[$i].Key + '=' + [string]$allBad[$i].Value) }
            $detail = $detail + ' (also: ' + ($rest -join '; ') + ')'
        }
        $detail = $detail + ' - Vivado Tcl decodes paths as GBK and breaks on non-ASCII'
        if ($badFail.Count -gt 0) {
            return New-Result 'ascii-paths' 'ASCII paths' 'FAIL' $detail `
                ('point `' + $first.Key + '` at a pure-ASCII directory on the same drive (e.g. ' + $suggestion + ') and re-run install.ps1; for TEMP/TMP set $env:TEMP/$env:TMP before running Vivado')
        }
        return New-Result 'ascii-paths' 'ASCII paths' 'WARN' ($detail + ' (only the current shell directory, not a kit setting)') `
            ('cd to an ASCII directory (e.g. ' + $suggestion + ') before running install.ps1 or Vivado work; the kit config itself is fine')
    }
    if ($empty.Count -gt 0) {
        return New-Result 'ascii-paths' 'ASCII paths' 'WARN' `
            ('no non-ASCII path, but empty config keys: ' + ($empty -join ', ')) `
            'fill these keys in config.yml (they become the MCP cwd/TEMP and the project root) and re-run install.ps1'
    }
    return New-Result 'ascii-paths' 'ASCII paths' 'PASS' `
        'cwd, TEMP, TMP, project_root, vivado_mcp_cwd, temp_dir are pure ASCII' ''
}

# ---------------------------------------------------------------------------
#  check 6 -- mcp-import
# ---------------------------------------------------------------------------

function Test-CheckMcpImport {
    $site = Get-McpSite
    if ($site -eq '') {
        return New-Result 'mcp-import' 'vivado_mcp import' 'FAIL' 'config has no vivado_mcp_site' `
            'set `vivado_mcp_site` to the directory that contains the `vivado_mcp` package (the `site` dir of the vivado-mcp install, e.g. D:/vivado-mcp/site)'
    }
    if (-not (Test-DoctorDir $site)) {
        return New-Result 'mcp-import' 'vivado_mcp import' 'FAIL' `
            ('vivado_mcp_site does not exist: ' + (ConvertTo-SlashPath $site)) `
            'set `vivado_mcp_site` to the directory that contains the `vivado_mcp` package (it is the `site` dir of the vivado-mcp install)'
    }
    $probe = Get-PythonProbe
    if (-not $probe.StartOk) {
        return New-Result 'mcp-import' 'vivado_mcp import' 'FAIL' `
            'cannot run the configured python, so the import cannot be checked (see check 3)' `
            'fix `python` first (see the python check), then re-run doctor.ps1'
    }
    if ($script:QuickMode) {
        return New-Result 'mcp-import' 'vivado_mcp import' 'WARN' `
            ('skipped by -Quick (would run: python -c "import vivado_mcp" with PYTHONPATH=' + (ConvertTo-SlashPath $site) + ')') `
            're-run doctor.ps1 without -Quick for the import probe'
    }
    $code = "import vivado_mcp;print(getattr(vivado_mcp,'__version__',''));print(vivado_mcp.__file__)"
    $r = Invoke-DoctorNative -FilePath $probe.Path -Arguments @('-c', $code) `
        -Environment @{ 'PYTHONPATH' = $site } -TimeoutSec 60
    if ($r.TimedOut) {
        return New-Result 'mcp-import' 'vivado_mcp import' 'FAIL' `
            'import vivado_mcp did not finish within 60 s and was killed' `
            'set `vivado_mcp_site` to the directory that contains the `vivado_mcp` package and re-run install.ps1'
    }
    if (-not $r.Ok -or $r.ExitCode -ne 0) {
        $tail = Get-DoctorTextTail -Text ($r.StdErr + "`n" + $r.StdOut) -Lines 2
        return New-Result 'mcp-import' 'vivado_mcp import' 'FAIL' `
            ('import vivado_mcp failed (rc=' + $r.ExitCode + '): ' + $tail) `
            'set `vivado_mcp_site` to the directory that contains the `vivado_mcp` package (it is the `site` dir of the vivado-mcp install)'
    }
    $lines = @($r.StdOut -split "\r?\n" | Where-Object { $_.Trim().Length -gt 0 })
    $version = ''
    $modulePath = ''
    if ($lines.Count -ge 1) { $version = $lines[0].Trim() }
    if ($lines.Count -ge 2) { $modulePath = $lines[$lines.Count - 1].Trim() }
    if ($modulePath -eq '') {
        return New-Result 'mcp-import' 'vivado_mcp import' 'FAIL' `
            'import vivado_mcp succeeded but did not report __file__' `
            'point `vivado_mcp_site` at the real site directory and re-run install.ps1'
    }
    $normModule = (Get-DoctorWinPath $modulePath).ToLower()
    $normSite = $site.ToLower().TrimEnd('\')
    if (-not $normModule.StartsWith($normSite + '\')) {
        return New-Result 'mcp-import' 'vivado_mcp import' 'FAIL' `
            ('vivado_mcp resolved OUTSIDE vivado_mcp_site: ' + $modulePath + ' (site: ' + (ConvertTo-SlashPath $site) + ')') `
            'set `vivado_mcp_site` to the directory that contains the `vivado_mcp` package - a stale copy on sys.path wins otherwise'
    }
    $verText = 'no __version__'
    if ($version -ne '') { $verText = 'version ' + $version }
    return New-Result 'mcp-import' 'vivado_mcp import' 'PASS' `
        ('import vivado_mcp ok: ' + $verText + ' from ' + $modulePath) ''
}

# ---------------------------------------------------------------------------
#  check 7 -- mcp-tools
# ---------------------------------------------------------------------------

function Test-CheckMcpTools {
    $site = Get-McpSite
    if ($script:QuickMode) {
        return New-Result 'mcp-tools' 'MCP tool count' 'WARN' `
            'skipped by -Quick (would run: python <vivado-mcp>\mcp_ctl.py list)' `
            're-run doctor.ps1 without -Quick to count the MCP tools'
    }
    if ($site -eq '' -or -not (Test-DoctorDir $site)) {
        return New-Result 'mcp-tools' 'MCP tool count' 'FAIL' `
            'cannot run mcp_ctl.py: vivado_mcp_site is not a directory (see check 6)' `
            'fix `vivado_mcp_site` / `python`, or reinstall vivado-mcp'
    }
    $parent = Split-Path -Parent $site
    if ([string]::IsNullOrWhiteSpace($parent)) { $parent = '' }
    $ctl = Join-Path $parent 'mcp_ctl.py'
    if (-not (Test-DoctorFile $ctl)) {
        return New-Result 'mcp-tools' 'MCP tool count' 'FAIL' `
            ('mcp_ctl.py not found at ' + (ConvertTo-SlashPath $ctl) + ' (it must be one level above vivado_mcp_site)') `
            'set `vivado_mcp_site` to <vivado-mcp>\site so that <vivado-mcp>\mcp_ctl.py is found, or reinstall vivado-mcp'
    }
    $probe = Get-PythonProbe
    if (-not $probe.StartOk) {
        return New-Result 'mcp-tools' 'MCP tool count' 'FAIL' `
            'cannot run the configured python (see check 3)' `
            'fix `python` first, then re-run doctor.ps1'
    }
    $r = Invoke-DoctorNative -FilePath $probe.Path -Arguments @($ctl, 'list') `
        -WorkingDirectory $parent -TimeoutSec 120
    if ($r.TimedOut) {
        return New-Result 'mcp-tools' 'MCP tool count' 'FAIL' `
            'mcp_ctl.py list did not finish within 120 s and was killed' `
            'fix `python` / `vivado_mcp_site` (an import that hangs usually means a broken site), or reinstall vivado-mcp'
    }
    if (-not $r.Ok -or $r.ExitCode -ne 0) {
        $tail = Get-DoctorTextTail -Text ($r.StdErr + "`n" + $r.StdOut) -Lines 2
        return New-Result 'mcp-tools' 'MCP tool count' 'FAIL' `
            ('mcp_ctl.py list failed (rc=' + $r.ExitCode + '): ' + $tail) `
            'fix `python` / `vivado_mcp_site`, or reinstall vivado-mcp'
    }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($r.StdOut -split "\r?\n")) {
        $t = $line.Trim()
        if ($t.Length -eq 0) { continue }
        $name = ($t -split '\s+')[0].Trim()
        if ($name -match '^[a-z][a-z0-9_]*$' -and -not $names.Contains($name)) { $names.Add($name) }
    }
    $count = $names.Count
    $expected = $script:ExpectedTools
    if ($count -eq $expected) {
        return New-Result 'mcp-tools' 'MCP tool count' 'PASS' `
            ($count.ToString() + ' tools listed by mcp_ctl.py list (all become mcp__vivado__*)') ''
    }
    if ($count -gt 0) {
        return New-Result 'mcp-tools' 'MCP tool count' 'WARN' `
            ($count.ToString() + ' tools listed, expected ' + $expected.ToString() + ': this is a different vivado-mcp version (tool names still become mcp__vivado__*)') `
            'reinstall the vivado-mcp version the kit was verified with (32 tools), or accept the difference - doctor only counts them'
    }
    return New-Result 'mcp-tools' 'MCP tool count' 'FAIL' `
        ('mcp_ctl.py list exited 0 but printed no tool names: ' + (Get-DoctorTextTail -Text $r.StdOut -Lines 2)) `
        'fix `python` / `vivado_mcp_site`, or reinstall vivado-mcp'
}

# ---------------------------------------------------------------------------
#  check 8 -- license  (static, never FAIL)
# ---------------------------------------------------------------------------

function Test-CheckLicense {
    $vars = @('XILINXD_LICENSE_FILE', 'LM_LICENSE_FILE')
    $evidence = New-Object System.Collections.Generic.List[string]
    $bad = New-Object System.Collections.Generic.List[string]
    $found = $false
    foreach ($v in $vars) {
        $val = [System.Environment]::GetEnvironmentVariable($v, 'Process')
        $scope = 'process'
        if ([string]::IsNullOrWhiteSpace($val)) {
            $val = [System.Environment]::GetEnvironmentVariable($v, 'User')
            $scope = 'user'
        }
        if ([string]::IsNullOrWhiteSpace($val)) { continue }
        $entries = @($val -split ';')
        foreach ($e in $entries) {
            $t = $e.Trim()
            if ($t.Length -eq 0) { continue }
            if ($t -match '^\d{4,5}@') {
                $evidence.Add(($v + ' (' + $scope + ') -> ' + $t + ' [license server, not probed]'))
                $found = $true
                continue
            }
            $w = Get-DoctorWinPath $t
            if ((Test-DoctorFile $w) -or (Test-DoctorDir $w)) {
                $evidence.Add(($v + ' (' + $scope + ') -> ' + $t + ' [exists]'))
                $found = $true
            } else {
                $bad.Add(($v + ' -> ' + $t + ' [missing]'))
            }
        }
    }
    if (-not $found) {
        $xilinx = Join-Path $env:USERPROFILE '.Xilinx'
        if (Test-DoctorDir $xilinx) {
            $lic = @()
            try {
                $lic = @(Get-ChildItem -LiteralPath $xilinx -Filter '*.lic' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 3)
            } catch { $lic = @() }
            if ($lic.Count -gt 0) {
                $names = @()
                foreach ($l in $lic) { $names += $l.FullName }
                $evidence.Add(('*.lic under ' + (ConvertTo-SlashPath $xilinx) + ': ' + ($names -join '; ')))
                $found = $true
            }
        }
    }
    if ($found) {
        return New-Result 'license' 'Vivado license' 'PASS' ('license source visible: ' + ($evidence -join '; ')) ''
    }
    $detail = 'no XILINXD_LICENSE_FILE / LM_LICENSE_FILE and no *.lic under %USERPROFILE%\.Xilinx'
    if ($bad.Count -gt 0) { $detail = $detail + ' (stale values: ' + ($bad -join '; ') + ')' }
    return New-Result 'license' 'Vivado license' 'WARN' ($detail + ' - a license may still live elsewhere (server, dongle, evaluation mode)') `
        'set $env:XILINXD_LICENSE_FILE (this session) or the user environment variable to your .lic file / 2100@server, e.g. D:/Xilinx/license.lic; doctor never installs licenses'
}

# ---------------------------------------------------------------------------
#  check 9 -- bundle-installed
# ---------------------------------------------------------------------------

function Get-ProfileState {
    <# Read the profile package.json once: dependency, bundle list, staging state. #>
    if ($script:State.ContainsKey('ProfileState')) { return $script:State['ProfileState'] }
    $st = @{
        PkgPath = (Join-Path $script:State['ProfileDir'] 'package.json')
        PkgOk = $false
        HasDep = $false
        DepSpec = ''
        DepPath = ''
        DepPathExists = $false
        InBundles = $false
        BundleCount = 0
        StageExists = $false
    }
    $st.StageExists = (Test-DoctorDir $script:State['StageDir'])
    $pkg = Read-DoctorJsonFile $st.PkgPath
    if ($null -ne $pkg) {
        $st.PkgOk = $true
        $deps = Get-DoctorJsonValue $pkg 'dependencies'
        if ($null -ne $deps) {
            $dep = Get-DoctorJsonValue $deps $script:BundleName
            if ($null -ne $dep) {
                $st.DepSpec = ([string]$dep).Trim()
                if ($st.DepSpec.Length -gt 0) {
                    $st.HasDep = $true
                    $target = $st.DepSpec
                    if ($target.StartsWith('link:')) { $target = $target.Substring(5) }
                    if ($target.StartsWith('file:')) { $target = $target.Substring(5) }
                    $target = Get-DoctorWinPath $target
                    if ($target -ne '' -and -not [System.IO.Path]::IsPathRooted($target)) {
                        $target = Join-Path $script:State['ProfileDir'] $target
                    }
                    $st.DepPath = $target
                    $st.DepPathExists = (Test-DoctorDir $target)
                }
            }
        }
        $dsh = Get-DoctorJsonValue $pkg 'dsh'
        if ($null -ne $dsh) {
            $prof = Get-DoctorJsonValue $dsh 'profile'
            if ($null -ne $prof) {
                $bundles = Get-DoctorJsonValue $prof 'bundles'
                if ($null -ne $bundles) {
                    $arr = @($bundles)
                    $st.BundleCount = $arr.Count
                    foreach ($b in $arr) {
                        if (([string]$b).Trim() -eq $script:BundleName) { $st.InBundles = $true }
                    }
                }
            }
        }
    }
    $script:State['ProfileState'] = $st
    return $st
}

function Test-CheckBundleInstalled {
    $st = Get-ProfileState
    $fix = ('run install.ps1 -Profile ' + $script:State['ProfileName'])
    if (-not $st.PkgOk) {
        if ($st.StageExists) {
            return New-Result 'bundle-installed' 'bundle installed' 'FAIL' `
                ('staging exists (' + (ConvertTo-SlashPath $script:State['StageDir']) + ') but the profile has no readable package.json at ' + (ConvertTo-SlashPath $st.PkgPath)) `
                $fix
        }
        return New-Result 'bundle-installed' 'bundle installed' 'WARN' `
            ('profile "' + $script:State['ProfileName'] + '" does not exist yet at ' + (ConvertTo-SlashPath $script:State['ProfileDir']) + ' - the kit is not installed here, nothing to verify') `
            $fix
    }
    if ($st.HasDep -and $st.InBundles) {
        if (-not $st.DepPathExists) {
            return New-Result 'bundle-installed' 'bundle installed' 'FAIL' `
                ('dependency ' + $script:BundleName + ' points at ' + $st.DepSpec + ' but that directory does not exist') `
                $fix
        }
        return New-Result 'bundle-installed' 'bundle installed' 'PASS' `
            ('dependency ' + $script:BundleName + ' -> ' + (ConvertTo-SlashPath $st.DepPath) + ' (exists); listed in dsh.profile.bundles (' + $st.BundleCount + ' bundles)') ''
    }
    if ($st.HasDep -and -not $st.InBundles) {
        return New-Result 'bundle-installed' 'bundle installed' 'FAIL' `
            ('dependency is present but "' + $script:BundleName + '" is missing from dsh.profile.bundles - DSH will not load the bundle') `
            $fix
    }
    if (-not $st.HasDep -and $st.InBundles) {
        return New-Result 'bundle-installed' 'bundle installed' 'FAIL' `
            ('dsh.profile.bundles lists "' + $script:BundleName + '" but package.json has no matching dependency - the link is broken') `
            $fix
    }
    if ($st.StageExists) {
        return New-Result 'bundle-installed' 'bundle installed' 'FAIL' `
            ('staging exists (' + (ConvertTo-SlashPath $script:State['StageDir']) + ') but the profile is not wired to it (no dependency, not in dsh.profile.bundles)') `
            $fix
    }
    return New-Result 'bundle-installed' 'bundle installed' 'WARN' `
        ('the kit is not installed in profile "' + $script:State['ProfileName'] + '" (no dependency, no bundle entry, no staging directory) - nothing to verify') `
        $fix
}

# ---------------------------------------------------------------------------
#  check 10 -- bundle-rendered
# ---------------------------------------------------------------------------

function Test-CheckBundleRendered {
    $stage = $script:State['StageDir']
    $st = Get-ProfileState
    if (-not (Test-DoctorDir $stage)) {
        return New-Result 'bundle-rendered' 'bundle patch rendered' 'WARN' `
            ('staging directory not present (' + (ConvertTo-SlashPath $stage) + ') - nothing has been rendered yet') `
            ('run install.ps1 -Profile ' + $script:State['ProfileName'] + ' (it renders cordis.patch.yml into the staging directory)')
    }
    $fix = ('re-run install.ps1 -Profile ' + $script:State['ProfileName'] + ' (it re-renders cordis.patch.yml)')
    $patch = Join-Path $stage 'cordis.patch.yml'
    if (-not (Test-DoctorFile $patch)) {
        return New-Result 'bundle-rendered' 'bundle patch rendered' 'FAIL' `
            ('staging has no cordis.patch.yml (' + (ConvertTo-SlashPath $patch) + ')') `
            $fix
    }
    $text = Read-DoctorTextFile $patch
    if ([string]::IsNullOrWhiteSpace($text)) {
        return New-Result 'bundle-rendered' 'bundle patch rendered' 'FAIL' `
            ('cordis.patch.yml in staging is empty (' + (ConvertTo-SlashPath $patch) + ')') `
            $fix
    }
    $leftovers = @()
    foreach ($m in [regex]::Matches($text, '\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}')) {
        $name = $m.Groups[1].Value
        if ($name -eq 'model') { continue }
        if ($leftovers -notcontains $name) { $leftovers += $name }
    }
    if ($leftovers.Count -gt 0) {
        return New-Result 'bundle-rendered' 'bundle patch rendered' 'FAIL' `
            ('leftover placeholders in the rendered patch: {{' + ($leftovers -join '}}, {{') + '}}') `
            $fix
    }
    $skillDir = Get-SkillsFromPatch $text
    if ($skillDir -eq '') {
        return New-Result 'bundle-rendered' 'bundle patch rendered' 'FAIL' `
            'rendered patch has no customSkillDirs entry (the bundled skills would not be mounted)' `
            $fix
    }
    $skillWin = Get-DoctorWinPath $skillDir
    if (-not (Test-DoctorDir $skillWin)) {
        return New-Result 'bundle-rendered' 'bundle patch rendered' 'FAIL' `
            ('customSkillDirs points at a directory that does not exist: ' + $skillDir) `
            $fix
    }
    $insert = 'no top-level - insert: row list'
    if ($text -match '(?m)^- insert:') { $insert = 'top-level - insert: present' }
    $mcpRow = 'no mcp-vivado row'
    if ($text -match 'mcp-vivado') { $mcpRow = 'mcp-vivado row present' }
    return New-Result 'bundle-rendered' 'bundle patch rendered' 'PASS' `
        ('no leftover placeholders except {{model}}, customSkillDirs -> ' + $skillDir + ' (exists), ' + $insert + ', ' + $mcpRow) ''
}

# ---------------------------------------------------------------------------
#  check 11 -- mcp-patches
# ---------------------------------------------------------------------------

function Test-CheckMcpPatches {
    $site = Get-McpSite
    if ($site -eq '' -or -not (Test-DoctorDir $site)) {
        return New-Result 'mcp-patches' 'vivado-mcp patches' 'WARN' `
            'cannot check the local patches: vivado_mcp_site is not a directory (see check 6)' `
            'fix `vivado_mcp_site` first, then re-run doctor.ps1'
    }
    $shipDir = Join-Path $script:KitRoot 'patches\vivado-mcp'
    $shipped = 0
    try {
        if (Test-DoctorDir $shipDir) { $shipped = @(Get-ChildItem -LiteralPath $shipDir -Filter '*.patch' -File).Count }
    } catch { $shipped = 0 }

    # Probes are CONTENT based on purpose: a re-applied patch keeps no mtime evidence, and a
    # .bak file would otherwise make an unpatched tree look patched.
    $probes = @(
        @{
            Label = 'tcl_tools max_lines/save_full_to (patch 0001)'
            File  = (Join-Path $site 'vivado_mcp\tools\tcl_tools.py')
            Any   = @('max_lines: int = 0', 'save_full_to')
        },
        @{
            Label = 'safe_tcl placeholder hint (patch 0001)'
            File  = (Join-Path $site 'vivado_mcp\tools\tcl_tools.py')
            Any   = @('_QUOTE_TRAP_HINT', 'close-quote')
        },
        @{
            Label = 'xdc_lint server-side aggregate (patch 0002)'
            File  = (Join-Path $site 'vivado_mcp\analysis\xdc_linter.py')
            Any   = @('_rule_breakdown', 'max_items: int = 0')
        },
        @{
            Label = 'xdc_lint tool default full (patch 0003)'
            File  = (Join-Path $site 'vivado_mcp\tools\diagnostic_tools.py')
            Any   = @('max_items: int = 0')
        },
        @{
            Label = 'get_cdc_report default full (patch 0004)'
            File  = (Join-Path $site 'vivado_mcp\tools\cdc_tools.py')
            Any   = @('max_details: int = 0')
        }
    )
    $present = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($p in $probes) {
        $hit = $false
        if (Test-DoctorFile $p.File) {
            foreach ($pat in $p.Any) {
                try {
                    if (Select-String -LiteralPath $p.File -Pattern $pat -SimpleMatch -Quiet) { $hit = $true; break }
                } catch { }
            }
        }
        if ($hit) { $present.Add($p.Label) } else { $missing.Add($p.Label) }
    }
    if ($missing.Count -eq 0) {
        $detail = ('all ' + $probes.Count.ToString() + ' content markers present (probed by content, not by file mtime)')
        return New-Result 'mcp-patches' 'vivado-mcp patches' 'PASS' $detail ''
    }
    $found = 'none'
    if ($present.Count -gt 0) { $found = ($present -join '; ') }
    $detail = ('missing: ' + ($missing -join '; ') + ' (present: ' + $found + ')')
    return New-Result 'mcp-patches' 'vivado-mcp patches' 'WARN' $detail `
        ('re-apply the ' + $shipped.ToString() + ' patch files in patches/vivado-mcp/ (Vivado still runs, but xdc_lint/get_cdc_report/run_tcl lose default-full or lossless output)')
}

# ---------------------------------------------------------------------------
#  check 12 -- compatibility
# ---------------------------------------------------------------------------

function Test-CheckCompatibility {
    $profileDir = $script:State['ProfileDir']
    $mcpVersion = Get-DoctorMcpClientVersion $profileDir
    if ($mcpVersion -eq '') {
        return New-Result 'compatibility' 'mcp-client compatibility' 'WARN' `
            ('the profile does not resolve @deepseek-ai/dsh-mcp-client (' + (ConvertTo-SlashPath (Join-Path $profileDir 'node_modules\@deepseek-ai\dsh-mcp-client')) + ')') `
            ('run install.ps1 -Profile ' + $script:State['ProfileName'] + ' after the profile has its node_modules (the kit cannot invent it)')
    }
    $runtimeInfo = Get-RuntimeVersionCached
    $runtime = [string]$runtimeInfo.Version
    $runtimeSource = [string]$runtimeInfo.Source
    if ($runtime -eq '') {
        return New-Result 'compatibility' 'mcp-client compatibility' 'WARN' `
            ('cannot read the DSH runtime version (dsh.cmd --version failed and the exe VersionInfo is unavailable); mcp-client is ' + $mcpVersion) `
            'pass -InstallDir <DSH install root> so doctor can run dsh.cmd --version, then re-run'
    }
    if ($runtimeSource -ne 'dsh.cmd --version') {
        return New-Result 'compatibility' 'mcp-client compatibility' 'WARN' `
            ('runtime version was only read from ' + $runtimeSource + ' (' + $runtime + '), which drops the prerelease suffix - cannot judge the exemption; mcp-client is ' + $mcpVersion) `
            'pass -InstallDir <DSH install root> so doctor can run dsh.cmd --version (the value compatibility.json must carry)'
    }
    $detailTail = ' (runtime ' + $runtime + ' read from dsh.cmd --version)'
    if ($mcpVersion -eq $runtime) {
        return New-Result 'compatibility' 'mcp-client compatibility' 'PASS' `
            ('mcp-client ' + $mcpVersion + ' equals the runtime version - no exemption needed' + $detailTail) ''
    }
    $key = '@deepseek-ai/dsh-mcp-client@' + $mcpVersion
    $compatPath = Join-Path $profileDir 'compatibility.json'
    $compat = Read-DoctorJsonFile $compatPath
    $fix = ('re-run install.ps1 -Profile ' + $script:State['ProfileName'] + ' (it merges the exemption) or add "' + $key + '": ["' + $runtime + '"] to ' + (ConvertTo-SlashPath $compatPath))
    if ($null -eq $compat) {
        return New-Result 'compatibility' 'mcp-client compatibility' 'WARN' `
            ('compatibility.json is missing or unreadable (' + (ConvertTo-SlashPath $compatPath) + '); DSH would silently drop the mcp-vivado row' + $detailTail) `
            $fix
    }
    $val = Get-DoctorJsonValue $compat $key
    if ($null -eq $val) {
        return New-Result 'compatibility' 'mcp-client compatibility' 'WARN' `
            ('compatibility.json has no key "' + $key + '"; DSH would silently drop the mcp-vivado row' + $detailTail) `
            $fix
    }
    $listed = @($val | ForEach-Object { [string]$_ })
    $hasRuntime = $false
    foreach ($l in $listed) { if ($l.Trim() -eq $runtime) { $hasRuntime = $true } }
    if ($hasRuntime) {
        return New-Result 'compatibility' 'mcp-client compatibility' 'PASS' `
            ('exemption "' + $key + '" -> [' + ($listed -join ', ') + ']' + $detailTail) ''
    }
    return New-Result 'compatibility' 'mcp-client compatibility' 'WARN' `
        ('exemption "' + $key + '" lists [' + ($listed -join ', ') + '] instead of the runtime version ' + $runtime + '; the mcp row may still be dropped' + $detailTail) `
        $fix
}

# ---------------------------------------------------------------------------
#  check 13 -- skills
# ---------------------------------------------------------------------------

function Test-CheckSkills {
    $stage = $script:State['StageDir']
    if (-not (Test-DoctorDir $stage)) {
        return New-Result 'skills' 'bundled skills' 'WARN' `
            ('staging directory not present (' + (ConvertTo-SlashPath $stage) + ') - the skills are copied by install.ps1') `
            ('run install.ps1 -Profile ' + $script:State['ProfileName'] + ' (it copies skills\ into the staging directory)')
    }
    $fix = ('reinstall the kit with install.ps1 -Profile ' + $script:State['ProfileName'] + ' (skills\ is copied by install.ps1)')
    $root = Join-Path $stage 'skills'
    if (-not (Test-DoctorDir $root)) {
        return New-Result 'skills' 'bundled skills' 'FAIL' `
            ('staging has no skills directory (' + (ConvertTo-SlashPath $root) + ')') `
            $fix
    }
    $missing = New-Object System.Collections.Generic.List[string]
    $mismatch = New-Object System.Collections.Generic.List[string]
    foreach ($name in $script:ExpectedSkills) {
        $dir = Join-Path $root $name
        $md = Join-Path $dir 'SKILL.md'
        if (-not (Test-DoctorDir $dir)) { $missing.Add($name); continue }
        if (-not (Test-DoctorFile $md)) { $missing.Add($name + ' (no SKILL.md)'); continue }
        $head = Read-DoctorTextFile $md
        $declared = ''
        $m = [regex]::Match($head, '(?m)^name:\s*(\S+)\s*$')
        if ($m.Success) { $declared = $m.Groups[1].Value.Trim() }
        if ($declared -ne $name) {
            if ($declared -eq '') { $mismatch.Add($name + ' (SKILL.md has no "name:" line)') }
            else { $mismatch.Add($name + ' (SKILL.md says name: ' + $declared + ')') }
        }
    }
    if ($missing.Count -gt 0 -or $mismatch.Count -gt 0) {
        $bits = @()
        if ($missing.Count -gt 0) { $bits += ('missing: ' + ($missing -join '; ')) }
        if ($mismatch.Count -gt 0) { $bits += ('name mismatch: ' + ($mismatch -join '; ')) }
        return New-Result 'skills' 'bundled skills' 'FAIL' `
            ($script:ExpectedSkills.Count.ToString() + ' expected skills: ' + ($bits -join ' / ')) `
            $fix
    }
    return New-Result 'skills' 'bundled skills' 'PASS' `
        ($script:ExpectedSkills.Count.ToString() + '/' + $script:ExpectedSkills.Count.ToString() + ' skills present in ' + (ConvertTo-SlashPath $root) + ', every SKILL.md name: matches its directory') ''
}

# ---------------------------------------------------------------------------
#  main
# ---------------------------------------------------------------------------

$script:State['DshCli'] = Find-DshCli -InstallDir $InstallDir
$script:State['InstallRoot'] = ''
if (-not [string]::IsNullOrWhiteSpace($script:State['DshCli'])) {
    $root = $script:State['DshCli']
    for ($i = 0; $i -lt 5; $i++) {
        $parent = Split-Path -Parent $root
        if ([string]::IsNullOrWhiteSpace($parent)) { break }
        $root = $parent
    }
    $script:State['InstallRoot'] = $root
}
$script:State['ProfileName'] = $Profile
$script:State['DshHomePath'] = Get-DshHome -Override $DshHome
$script:State['ProfileDir'] = Get-DshProfileDir -DshHome $script:State['DshHomePath'] -Profile $Profile
$script:State['StageDir'] = Join-Path (Join-Path $script:State['DshHomePath'] 'bundles') $script:StageLeaf

$configPath = ''
$configProblem = ''
try {
    $configPath = Resolve-KitConfigPath -KitRoot $script:KitRoot -Config $Config
} catch {
    $configProblem = $_.Exception.Message
}
if ($configProblem -ne '') {
    $row = New-Result 'config' 'kit config' 'FAIL' ('cannot read the kit config: ' + $configProblem) `
        'pass -Config <path to config.yml> (or run install.ps1 once, which writes <kit>\config.yml)'
    Add-Result $row
}
if ($configPath -ne '') {
    try {
        $cfg = Read-KitConfig -Path $configPath
        foreach ($k in $cfg.Keys) { $script:Conf[$k] = [string]$cfg[$k] }
    } catch {
        $row = New-Result 'config' 'kit config' 'FAIL' ('cannot parse the kit config: ' + $_.Exception.Message) `
            'fix config.yml (flat `key: value` lines) and re-run doctor.ps1'
        Add-Result $row
    }
}

if (-not $script:JsonMode) {
    $kitVersion = '0.0.0'
    try { $kitVersion = Get-KitVersion -KitRoot $script:KitRoot } catch { $kitVersion = '0.0.0' }
    $modeText = 'full'
    if ($script:QuickMode) { $modeText = 'quick (slow probes skipped)' }
    Write-Host ''
    Write-Host ('dsh-vivado doctor ' + $kitVersion) -ForegroundColor Cyan
    $cfgLabel = '(none - no config file could be read, see the config row above)'
    if ($configPath -ne '') {
        $cfgLabel = ConvertTo-SlashPath $configPath
        if ((Split-Path -Leaf $configPath) -eq 'config.example.yml') {
            $cfgLabel = $cfgLabel + '  [example file: run install.ps1 to write config.yml]'
        }
    }
    Write-Host ('  config   : ' + $cfgLabel)
    Write-Host ('  dsh home : ' + (ConvertTo-SlashPath $script:State['DshHomePath']) + '   profile: ' + $Profile)
    Write-Host ('  staging  : ' + (ConvertTo-SlashPath $script:State['StageDir']))
    $cliText = 'not found (use -InstallDir <DSH install root>)'
    if (-not [string]::IsNullOrWhiteSpace($script:State['DshCli'])) {
        $cliText = ConvertTo-SlashPath $script:State['DshCli']
    }
    Write-Host ('  dsh cli  : ' + $cliText)
    Write-Host ('  mode     : ' + $modeText)
    Write-Host ''
}

$checkList = @(
    @{ Id = 'vivado-install'; Function = 'Test-CheckVivadoInstall'; Soft = $false },
    @{ Id = 'vivado-version'; Function = 'Test-CheckVivadoVersion'; Soft = $false },
    @{ Id = 'python'; Function = 'Test-CheckPython'; Soft = $false },
    @{ Id = 'part'; Function = 'Test-CheckPart'; Soft = $false },
    @{ Id = 'ascii-paths'; Function = 'Test-CheckAsciiPaths'; Soft = $false },
    @{ Id = 'mcp-import'; Function = 'Test-CheckMcpImport'; Soft = $false },
    @{ Id = 'mcp-tools'; Function = 'Test-CheckMcpTools'; Soft = $false },
    @{ Id = 'license'; Function = 'Test-CheckLicense'; Soft = $true },
    @{ Id = 'bundle-installed'; Function = 'Test-CheckBundleInstalled'; Soft = $false },
    @{ Id = 'bundle-rendered'; Function = 'Test-CheckBundleRendered'; Soft = $false },
    @{ Id = 'mcp-patches'; Function = 'Test-CheckMcpPatches'; Soft = $true },
    @{ Id = 'compatibility'; Function = 'Test-CheckCompatibility'; Soft = $false },
    @{ Id = 'skills'; Function = 'Test-CheckSkills'; Soft = $false }
)

if ($configPath -ne '' -and $configProblem -eq '') {
    foreach ($c in $checkList) {
        $row = $null
        try {
            $row = & $c.Function
        } catch {
            $fallbackStatus = 'FAIL'
            if ($c.Soft) { $fallbackStatus = 'WARN' }
            $dbg = $_.Exception.GetType().Name + ': ' + $_.Exception.Message
            $row = New-Result $c.Id $c.Id $fallbackStatus ('check crashed: ' + $dbg) `
                'this is a doctor bug - please report it with the output of doctor.ps1'
        }
        if ($null -eq $row) {
            $row = New-Result $c.Id $c.Id 'FAIL' 'the check returned no result' 'this is a doctor bug - please report it'
        }
        Add-Result $row
    }
}

$pass = 0
$warn = 0
$fail = 0
foreach ($r in $script:Results) {
    if ($r.status -eq 'PASS') { $pass = $pass + 1 }
    elseif ($r.status -eq 'WARN') { $warn = $warn + 1 }
    else { $fail = $fail + 1 }
}
$elapsed = ((Get-Date) - $script:Started).TotalMilliseconds
$elapsedText = Format-DoctorSeconds $elapsed

if ($script:JsonMode) {
    $payload = @()
    foreach ($r in $script:Results) {
        $payload += [pscustomobject]@{
            id     = $r.id
            title  = $r.title
            status = $r.status
            detail = $r.detail
            fix    = $r.fix
        }
    }
    # -Compress keeps the whole array on ONE line, so `doctor.ps1 -Json | ConvertFrom-Json`
    # also works when doctor.ps1 is launched as a child process (PS 5.1 pipes line by line).
    $jsonText = ConvertTo-Json -InputObject $payload -Depth 4 -Compress
    [Console]::Out.WriteLine($jsonText)
} else {
    Write-Host ''
    $summaryText = ('summary: {0} PASS, {1} WARN, {2} FAIL ({3} checks) in {4}' -f $pass, $warn, $fail, $script:Results.Count, $elapsedText)
    if ($fail -gt 0) {
        Write-Host $summaryText -ForegroundColor Red
        Write-Host 'verdict: FAIL - fix the rows above, then re-run doctor.ps1' -ForegroundColor Red
    } elseif ($warn -gt 0) {
        Write-Host $summaryText -ForegroundColor Yellow
        Write-Host 'verdict: OK with warnings - the kit works; read the WARN rows for degraded behaviour' -ForegroundColor Yellow
    } else {
        Write-Host $summaryText -ForegroundColor Green
        Write-Host 'verdict: OK - all checks passed' -ForegroundColor Green
    }
    Write-Host 'reminder: the kit only takes effect after a HOST RESTART (Electron: no hot reload).' -ForegroundColor Gray
    Write-Host ''
}

if ($fail -gt 0) { exit 1 }
exit 0
