<#
.SYNOPSIS
    Install the dsh-vivado bundle into a DSH profile (one command + a host restart).

.DESCRIPTION
    What it does, in order:
      1. resolves and completes config.yml (and auto-detects Vivado / Python / vivado-mcp
         when a value is missing or obviously wrong);
      2. copies this kit into the staging directory <DshHome>\bundles\dsh-vivado
         (the installable bundle, excluding config/backups/scratch/team notes);
      3. renders cordis.patch.yml inside the staging directory with tools\render_patch.ps1,
         so every absolute path in the patch points at the staging directory;
      4. makes sure the profile carries a compatibility.json version exemption for
         @deepseek-ai/dsh-mcp-client when the installed version differs from the runtime
         (without it DSH silently drops the mcp-vivado row);
      5. installs the bundle through the official CLI
         (`dsh plugin --profile <p> add "link:<staging>"`, which runs the bundled pnpm and
         appends the bundle to dsh.profile.bundles), or - when that is not possible -
         edits the profile package.json in place and creates the node_modules link;
      6. verifies the composition with `dsh --profile <p> --dump-config` and asserts the four
         kit markers.

    It never writes to <DshHome>\skills, never edits any plugin row that it does not own and
    never requires admin rights. Every changed profile file is backed up first as
    "<file>.bak-<yyyyMMdd>"; the final block prints the restart requirement and the exact
    rollback commands.

.PARAMETER Config
    config.yml to use. Default: <kit>\config.yml, else <kit>\config.example.yml.

.PARAMETER Profile
    DSH profile name to install into. Default: desktop.

.PARAMETER DshHome
    DSH config root. Default: $env:DSH_HOME, else %USERPROFILE%\.dsh.

.PARAMETER InstallDir
    DSH installation root (the directory containing "DeepSeek Harness.exe").
    Default: discovered by lib\common.ps1 Find-DshCli.

.PARAMETER StageDir
    Where the bundle body is staged/installed. Default: <DshHome>\bundles\dsh-vivado.

.PARAMETER Mode
    auto   (default) official CLI first, manual fallback on failure
    cli    official CLI only (a failure is fatal)
    manual no pnpm at all: in-place package.json edit + mklink junction

.PARAMETER Part
    Device part; overrides the config value.

.PARAMETER SkipCompatibility
    Do not touch <profile>\compatibility.json. Only use this when you know the profile
    already carries the exemption; otherwise the mcp-vivado row is dropped by DSH.

.PARAMETER RenderOnly
    Stage + render only: no profile change, no backups, no CLI. Prints the rendered path.

.PARAMETER WhatIf
    Print the full plan and exit without changing anything.

.PARAMETER NonInteractive
    Never prompt; fail with a one-line fix instead.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -DshHome D:\dsh-home -Profile work -Mode manual
#>
[CmdletBinding()]
param(
    [string]$Config,
    [string]$Profile = 'desktop',
    [string]$DshHome,
    [string]$InstallDir,
    [string]$StageDir,
    [ValidateSet('auto', 'cli', 'manual')][string]$Mode = 'auto',
    [string]$Part,
    [switch]$SkipCompatibility,
    [switch]$RenderOnly,
    [switch]$WhatIf,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$script:KitRoot = $PSScriptRoot
$script:PackageName = 'dsh-vivado'
$script:StageLeaf = 'dsh-vivado'
$script:DateSuffix = (Get-Date -Format 'yyyyMMdd')
$script:RestorePoints = New-Object System.Collections.Generic.List[object]
$script:CreatedLink = ''
$script:ExitCode = 0

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\install-helpers.ps1')

# ---------------------------------------------------------------------------
#  local helpers
# ---------------------------------------------------------------------------

function Add-KitRestorePoint {
    param([string]$BackupPath, [string]$TargetPath)
    if ([string]::IsNullOrWhiteSpace($BackupPath)) { return }
    if ([string]::IsNullOrWhiteSpace($TargetPath)) { return }
    $script:RestorePoints.Add([pscustomobject]@{ Backup = $BackupPath; Target = $TargetPath })
}

function Restore-KitFromBackups {
    <# Undo every mutation this run made to the profile, then report what was restored. #>
    if ($script:RestorePoints.Count -eq 0) {
        Write-KitLog WARN 'no profile backup to restore (nothing was changed yet)'
        return
    }
    foreach ($rp in $script:RestorePoints) {
        if (Test-Path -LiteralPath $rp.Backup) {
            Copy-Item -LiteralPath $rp.Backup -Destination $rp.Target -Force
            Write-KitLog WARN ('restored: {0}  <-  {1}' -f $rp.Target, (Split-Path -Leaf $rp.Backup))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($script:CreatedLink)) {
        $kind = Get-KitLinkTargetKind -Path $script:CreatedLink
        if ($kind -eq 'link') {
            try { [System.IO.Directory]::Delete($script:CreatedLink, $false); Write-KitLog WARN ('removed link: {0}' -f $script:CreatedLink) } catch { }
        }
    }
}

function Get-KitCfgValue {
    param($ConfigMap, [string]$Key)
    if ($null -eq $ConfigMap) { return '' }
    if (-not $ConfigMap.Contains($Key)) { return '' }
    $v = $ConfigMap[$Key]
    if ($null -eq $v) { return '' }
    if ([string]::IsNullOrWhiteSpace([string]$v)) { return '' }
    return ([string]$v).Trim()
}

function Show-KitVerifyResult {
    param($Verify)
    $failed = 0
    foreach ($r in $Verify.Results) {
        if ($r.Pass) {
            Write-KitLog PASS ('{0}  -> line {1}  | {2}' -f $r.Name, ($r.Lines -join ','), $r.Sample)
        } else {
            $failed = $failed + 1
            Write-KitLog FAIL ('{0}  -> NOT FOUND' -f $r.Name)
        }
    }
    if ($Verify.ExitCode -ne 0) {
        Write-KitLog FAIL ('dsh --dump-config exited {0}' -f $Verify.ExitCode)
        Write-KitLog WARN ('stderr tail: ' + (Get-KitTextTail $Verify.StdErr 10))
    }
    return $failed
}

# ---------------------------------------------------------------------------
#  banner
# ---------------------------------------------------------------------------

$kitVersion = Get-KitVersion -KitRoot $script:KitRoot
Write-KitLog INFO '=============================================================='
Write-KitLog INFO (' dsh-vivado installer  (kit {0})' -f $kitVersion)
Write-KitLog INFO '=============================================================='

# ---------------------------------------------------------------------------
#  1. config + detection
# ---------------------------------------------------------------------------

Write-KitLog STEP '1/9 resolve config'
$dshHomePath = Get-DshHome -Override $DshHome
$profileDir = Get-DshProfileDir -DshHome $dshHomePath -Profile $Profile
$profilePkg = Join-Path $profileDir 'package.json'
if ([string]::IsNullOrWhiteSpace($StageDir)) {
    $StageDir = Join-Path (Join-Path $dshHomePath 'bundles') $script:StageLeaf
}
# Re-running the installer to UPDATE an existing install must not fall back to the example
# values (those are placeholders such as D:/fpga_project): prefer the effective config the
# previous run wrote into the staging directory.
$stagedConfig = Join-Path $StageDir 'config.yml'
if ([string]::IsNullOrWhiteSpace($Config) -and -not (Test-Path -LiteralPath (Join-Path $script:KitRoot 'config.yml')) -and (Test-Path -LiteralPath $stagedConfig)) {
    $Config = $stagedConfig
    Write-KitLog INFO ('re-using the effective config from the previous install: {0}' -f $stagedConfig)
}
$configPath = Resolve-KitConfigPath -KitRoot $script:KitRoot -Config $Config
$sourceCfg = Read-KitConfig -Path $configPath
Write-KitLog INFO ('config source: {0}' -f $configPath)
Write-KitLog INFO ('DSH_HOME   : {0}' -f $dshHomePath)
Write-KitLog INFO ('profile dir: {0}' -f $profileDir)
Write-KitLog INFO ('staging dir: {0}' -f $StageDir)

$dshCli = Find-DshCli -InstallDir $InstallDir
if ($null -ne $dshCli) {
    Write-KitLog INFO ('DSH CLI    : {0}' -f $dshCli)
} else {
    Write-KitLog WARN 'DSH CLI not found; mode cli is unavailable, detection/verification limited'
}

Write-KitLog STEP '2/9 detect values (only fills what is missing or obviously wrong)'
$detected = New-Object System.Collections.Generic.List[string]

# --- part -------------------------------------------------------------------
$partValue = Get-KitCfgValue $sourceCfg 'part'
if (-not [string]::IsNullOrWhiteSpace($Part)) {
    $partValue = $Part.Trim()
    Write-KitLog INFO ('part overridden by -Part: {0}' -f $partValue)
}

# --- vivado -----------------------------------------------------------------
$vivadoPath = Get-KitCfgValue $sourceCfg 'vivado_path'
$vivadoVersion = Get-KitCfgValue $sourceCfg 'vivado_version'
$vivadoBat = ''
if ($vivadoPath -ne '') { $vivadoBat = Join-Path ($vivadoPath -replace '/', '\') 'vivado.bat' }
$vivadoOk = ($vivadoBat -ne '') -and (Test-Path -LiteralPath $vivadoBat)
if (-not $vivadoOk) {
    $hit = Find-KitVivadoBin -PreferVersion $vivadoVersion
    if ($null -ne $hit) {
        Write-KitLog WARN ('vivado_path is not runnable ("{0}"); detected {1}' -f $vivadoPath, $hit.BinDir)
        $vivadoPath = ConvertTo-SlashPath $hit.BinDir
        if ($vivadoVersion -eq '') {
            $vivadoVersion = $hit.Version
            $detected.Add('vivado_version')
        }
        $detected.Add('vivado_path')
    } else {
        Write-KitLog WARN 'no Vivado installation detected in the probed roots; keeping the config value'
    }
}
if ($vivadoVersion -eq '' -and $vivadoPath -ne '') {
    $parent = Split-Path -Parent ($vivadoPath -replace '/', '\')
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        $vivadoVersion = Split-Path -Leaf $parent
        Write-KitLog INFO ('vivado_version derived from vivado_path: {0}' -f $vivadoVersion)
        $detected.Add('vivado_version')
    }
}

# --- python -----------------------------------------------------------------
$pythonPath = Get-KitCfgValue $sourceCfg 'python'
if ($pythonPath -eq '' -or -not (Test-Path -LiteralPath $pythonPath)) {
    $hit = Find-KitPython
    if ($hit -ne '') {
        Write-KitLog WARN ('python is missing/not a file ("{0}"); detected {1}' -f $pythonPath, $hit)
        $pythonPath = $hit
        $detected.Add('python')
    } else {
        Write-KitLog WARN 'no Python 3 interpreter detected; keeping the config value'
    }
}

# --- vivado-mcp site --------------------------------------------------------
$mcpSite = Get-KitCfgValue $sourceCfg 'vivado_mcp_site'
if ($mcpSite -eq '' -or -not (Test-Path -LiteralPath $mcpSite)) {
    $hit = Find-KitMcpSite -Python $pythonPath
    if ($hit -ne '') {
        Write-KitLog WARN ('vivado_mcp_site is missing ("{0}"); detected {1}' -f $mcpSite, $hit)
        $mcpSite = ConvertTo-SlashPath $hit
        $detected.Add('vivado_mcp_site')
    } else {
        Write-KitLog WARN 'no vivado-mcp site directory detected; keeping the config value'
    }
}

# --- project root / mcp cwd / temp dir --------------------------------------
$projectRoot = Get-KitCfgValue $sourceCfg 'project_root'
$mcpCwd = Get-KitCfgValue $sourceCfg 'vivado_mcp_cwd'
$tempDir = Get-KitCfgValue $sourceCfg 'temp_dir'
if ($projectRoot -eq '') {
    $projectRoot = ConvertTo-SlashPath (Get-Location).Path
    Write-KitLog WARN ('project_root is empty; using the current directory {0}' -f $projectRoot)
    $detected.Add('project_root')
}
if ($mcpCwd -eq '') {
    $mcpCwd = $projectRoot
    Write-KitLog WARN ('vivado_mcp_cwd is empty; using project_root {0}' -f $mcpCwd)
    $detected.Add('vivado_mcp_cwd')
}
if ($tempDir -eq '') {
    $tempDir = (ConvertTo-SlashPath $projectRoot).TrimEnd('/') + '/.tmp'
    Write-KitLog WARN ('temp_dir is empty; using {0}' -f $tempDir)
    $detected.Add('temp_dir')
}

# --- part: prompt or fail ---------------------------------------------------
if ($partValue -eq '') {
    if ($NonInteractive) {
        Write-KitLog FAIL 'part is empty: pass -Part <device> (e.g. -Part xc7a35tftg256-1) or set `part:` in config.yml'
        exit 1
    }
    $examplePart = 'xcku060-ffva1156-2-i'
    $exampleCfg = Join-Path $script:KitRoot 'config.example.yml'
    if (Test-Path -LiteralPath $exampleCfg) {
        $exampleMap = Read-KitConfig -Path $exampleCfg
        $examplePartTmp = Get-KitCfgValue $exampleMap 'part'
        if ($examplePartTmp -ne '') { $examplePart = $examplePartTmp }
    }
    $answer = Read-Host ('part [{0}]' -f $examplePart)
    if ([string]::IsNullOrWhiteSpace($answer)) { $partValue = $examplePart } else { $partValue = $answer.Trim() }
    $detected.Add('part')
}

# --- required values --------------------------------------------------------
$effective = [ordered]@{}
foreach ($k in $sourceCfg.Keys) { $effective[$k] = $sourceCfg[$k] }
$effective['part'] = $partValue
$effective['project_root'] = $projectRoot
$effective['vivado_version'] = $vivadoVersion
$effective['vivado_path'] = $vivadoPath
$effective['python'] = $pythonPath
$effective['vivado_mcp_site'] = $mcpSite
$effective['vivado_mcp_cwd'] = $mcpCwd
$effective['temp_dir'] = $tempDir

$missing = @()
foreach ($k in @('part', 'project_root', 'vivado_version', 'vivado_path', 'python', 'vivado_mcp_site', 'vivado_mcp_cwd', 'temp_dir')) {
    if ([string]::IsNullOrWhiteSpace([string]$effective[$k])) { $missing += $k }
}
if ($missing.Count -gt 0) {
    Write-KitLog FAIL ('config is missing required values: {0}' -f ($missing -join ', '))
    Write-KitLog FAIL ('fix: set them in {0} (see config.example.yml) and re-run' -f $configPath)
    exit 1
}

Write-KitLog INFO ('part            : {0}' -f $effective['part'])
Write-KitLog INFO ('project_root    : {0}' -f $effective['project_root'])
Write-KitLog INFO ('vivado          : {0} ({1})' -f $effective['vivado_path'], $effective['vivado_version'])
Write-KitLog INFO ('python          : {0}' -f $effective['python'])
Write-KitLog INFO ('vivado_mcp_site : {0}' -f $effective['vivado_mcp_site'])
Write-KitLog INFO ('mcp cwd / temp  : {0} / {1}' -f $effective['vivado_mcp_cwd'], $effective['temp_dir'])
if ($detected.Count -gt 0) {
    Write-KitLog INFO ('auto-detected/overridden: {0}' -f (($detected | Sort-Object -Unique) -join ', '))
}

# ASCII guard: the rendered patch carries absolute paths into Vivado/MCP world; a non-ASCII
# path there breaks Vivado's Tcl layer and is a doctor FAIL, so refuse early with a fix.
foreach ($pair in @(@('staging dir', $StageDir), @('skills dir', (Join-Path $StageDir 'skills')), @('temp_dir', $effective['temp_dir']), @('vivado_mcp_cwd', $effective['vivado_mcp_cwd']), @('project_root', $effective['project_root']))) {
    if (-not (Test-AsciiPath ([string]$pair[1]))) {
        Write-KitLog FAIL ('{0} is not ASCII: {1}' -f $pair[0], $pair[1])
        Write-KitLog FAIL 'fix: keep every path ASCII (pass -StageDir D:/dsh-bundles/dsh-vivado, set temp_dir/project_root to ASCII paths)'
        exit 1
    }
}

# Existence guard (learned the hard way, 2026-10-24): the MCP row's `cwd` and `TEMP/TMP` are
# taken from project_root / vivado_mcp_cwd / temp_dir. A path that does not exist makes the
# stdio server fail to spawn, and `failOnStartupError: false` keeps that silent -> the session
# simply has zero `mcp__vivado__*` tools. Refuse up front (temp_dir is ours to create).
foreach ($pair in @(@('project_root', $effective['project_root']), @('vivado_mcp_cwd', $effective['vivado_mcp_cwd']), @('temp_dir', $effective['temp_dir']))) {
    $key = $pair[0]
    $val = ([string]$pair[1]) -replace '/', '\'
    if ([string]::IsNullOrWhiteSpace($val)) { continue }
    if (Test-Path -LiteralPath $val) { continue }
    if ($key -eq 'temp_dir') {
        New-Item -ItemType Directory -Path $val -Force | Out-Null
        Write-KitLog WARN ('created missing temp_dir: {0}' -f $pair[1])
        continue
    }
    Write-KitLog FAIL ('{0} does not exist: {1}' -f $key, $pair[1])
    Write-KitLog FAIL ('fix: set {0} to an existing pure-ASCII directory in config.yml (copy config.example.yml to config.yml if you have none), then re-run' -f $key)
    Write-KitLog FAIL 'why: these paths become the MCP server cwd and TEMP/TMP; a missing path makes the server fail silently and the session shows no mcp__vivado__* tools'
    exit 1
}

$stageConfig = Join-Path $StageDir 'config.yml'
$patchPath = Join-Path $StageDir 'cordis.patch.yml'
$depSpec = 'link:' + (ConvertTo-SlashPath $StageDir)
$preHash = Get-KitSha256 -Path $patchPath

# ---------------------------------------------------------------------------
#  3. plan / -WhatIf
# ---------------------------------------------------------------------------

$runtimeVersion = Get-KitRuntimeVersion -DshCli $dshCli -InstallDir $InstallDir
$compatProbe = Test-KitCompatibility -ProfileDir $profileDir -RuntimeVersion $runtimeVersion

function Get-KitEffectiveMode {
    param([string]$Requested)
    if ($Requested -ne 'auto') { return $Requested }
    if (-not [string]::IsNullOrWhiteSpace($dshCli)) { return 'cli' }
    return 'manual'
}
$plannedMode = Get-KitEffectiveMode -Requested $Mode

if ($WhatIf) {
    Write-KitLog STEP 'PLAN (-WhatIf: nothing will be changed)'
    Write-Host ('  kit root        : {0}' -f $script:KitRoot)
    Write-Host ('  kit version     : {0}' -f $kitVersion)
    Write-Host ('  config source   : {0}' -f $configPath)
    Write-Host ('  DSH_HOME        : {0}' -f $dshHomePath)
    Write-Host ('  profile dir     : {0}' -f $profileDir)
    Write-Host ('  profile file    : {0}' -f $profilePkg)
    Write-Host ('  staging dir     : {0}' -f $StageDir)
    Write-Host ('  runtime version : {0}' -f $runtimeVersion)
    Write-Host ('  install mode    : {0}' -f $plannedMode)
    if ($plannedMode -eq 'cli') {
        $shownCli = (Format-KitCommand $dshCli) + ' plugin --profile ' + (Format-KitCommand $Profile) + ' add ' + (Format-KitCommand $depSpec)
        Write-Host ('  CLI command     : set DSH_HOME={0} && {1}' -f $dshHomePath, $shownCli)
    } else {
        Write-Host ('  manual edits    : {0}  (dependencies + dsh.profile.bundles)' -f $profilePkg)
        Write-Host ('  manual link     : {0}\node_modules\{1}  ->  {2}' -f $profileDir, ($script:PackageName -replace '/', '\'), $StageDir)
    }
    if ($SkipCompatibility) {
        Write-Host '  compatibility   : skipped (-SkipCompatibility)'
    } else {
        Write-Host ('  compatibility   : needed={0} state={1} key={2}' -f $compatProbe.Needed, $compatProbe.State, $compatProbe.Key)
    }
    Write-Host ('  render command  : powershell -NoProfile -File "{0}" -ConfigPath "{1}" -OutFile "{2}" -BundleDir "{3}"' -f (Join-Path $StageDir 'tools\render_patch.ps1'), $stageConfig, $patchPath, $StageDir)
    Write-Host ('  backups (on change): {0}.bak-* , pnpm-lock.yaml.bak-* , compatibility.json.bak-*' -f $profilePkg)
    Write-Host '  restart         : REQUIRED (Electron host; dsh-hmr does not apply)'
    Write-Host '  no file was created, modified or deleted by this -WhatIf run.'
    exit 0
}

# ---------------------------------------------------------------------------
#  4. profile must exist
# ---------------------------------------------------------------------------

Write-KitLog STEP '3/9 check profile'
if (-not (Test-DshProfile -ProfileDir $profileDir)) {
    Write-KitLog FAIL ('profile package.json not found: {0}' -f $profilePkg)
    Write-KitLog FAIL ('fix: pass -Profile <existing profile> -DshHome <its DSH_HOME>; existing profiles: {0}' -f ((@(Get-ChildItem -LiteralPath (Join-Path $dshHomePath 'profiles') -Directory -ErrorAction SilentlyContinue) | ForEach-Object { $_.Name }) -join ', '))
    exit 1
}
$probeState = Get-KitPackageState -PackagePath $profilePkg -PackageName $script:PackageName
if (-not $probeState.Parsed) {
    Write-KitLog FAIL ('profile package.json is not valid JSON: {0}' -f $probeState.Error)
    exit 1
}
Write-KitLog PASS ('profile found: {0}' -f $profilePkg)

# ---------------------------------------------------------------------------
#  5. stage + 6. render
# ---------------------------------------------------------------------------

Write-KitLog STEP '4/9 stage the kit'
Write-KitLog INFO ('source: {0}' -f $script:KitRoot)
Copy-KitStageTree -KitRoot $script:KitRoot -StageDir $StageDir | Out-Null

Write-KitLog STEP '5/9 persist the values that were actually used'
# Two DIFFERENT questions, two variables (they were one boolean once, and that was a P0 bug):
#   * $sourceNeedsUpdate : does the config file the user gave us need the detected values written
#                          back into it (with a backup)?
#   * the staging config : a derived artifact - ALWAYS rewritten, so that a second run with a
#                          different -Config can never silently keep the previous values.
$sourceNeedsUpdate = $false
foreach ($k in $effective.Keys) {
    $before = Get-KitCfgValue $sourceCfg $k
    $after = [string]$effective[$k]
    if ($before -ne $after) { $sourceNeedsUpdate = $true }
}
Write-KitLog INFO ('write: {0}' -f $stageConfig)
Write-KitConfigFile -Config $effective -Path $stageConfig

$exampleFull = Join-Path $script:KitRoot 'config.example.yml'
$configInKit = $configPath.ToLowerInvariant().StartsWith($script:KitRoot.ToLowerInvariant())
if ($sourceNeedsUpdate) {
    if (-not $configInKit -and $configPath -ne $exampleFull) {
        $null = Backup-KitFile -Path $configPath -Suffix $script:DateSuffix
        Write-KitLog INFO ('write: {0} (detected values persisted to the config you passed)' -f $configPath)
        Write-KitConfigFile -Config $effective -Path $configPath
    } else {
        Write-KitLog INFO ('detected values are recorded in {0}; {1} was left untouched' -f $stageConfig, $configPath)
    }
}

Write-KitLog STEP '6/9 render the bundle patch'
$renderScript = Join-Path $StageDir 'tools\render_patch.ps1'
if (-not (Test-Path -LiteralPath $renderScript)) {
    Write-KitLog FAIL ('renderer not found in the staging dir: {0}' -f $renderScript)
    exit 1
}
$renderArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $renderScript,
                '-ConfigPath', $stageConfig, '-OutFile', $patchPath, '-BundleDir', $StageDir)
$renderRun = Invoke-KitNative -FilePath 'powershell.exe' -Arguments $renderArgs
if ($renderRun.ExitCode -ne 0) {
    Write-KitLog FAIL ('render_patch.ps1 failed (exit {0})' -f $renderRun.ExitCode)
    Write-KitLog FAIL ('stderr tail: ' + (Get-KitTextTail $renderRun.StdErr 15))
    exit 1
}
if (-not (Test-Path -LiteralPath $patchPath)) {
    Write-KitLog FAIL ('render_patch.ps1 reported success but wrote no patch: {0}' -f $patchPath)
    exit 1
}
$postHash = Get-KitSha256 -Path $patchPath
Write-KitLog PASS ('rendered: {0} (sha256 {1})' -f $patchPath, $postHash.Substring(0, 12))

if ($RenderOnly) {
    Write-KitLog STEP 'RenderOnly: stopping before any profile change'
    Write-KitLog PASS ('rendered patch: {0}' -f $patchPath)
    Write-KitLog INFO ('staging dir   : {0}' -f $StageDir)
    Write-KitLog WARN 'the profile was not touched; run install.ps1 again without -RenderOnly to install'
    exit 0
}

# ---------------------------------------------------------------------------
#  7..9 install + verify (every mutation is undoable from here on)
# ---------------------------------------------------------------------------

$verifyFailed = 0
try {
    Write-KitLog STEP '7/9 install the bundle into the profile'
    $state = Get-KitPackageState -PackagePath $profilePkg -PackageName $script:PackageName
    $depMatches = $state.HasDependency -and ($state.Dependency -eq $depSpec)
    $bundleMatches = $state.HasBundle
    $patchStable = (-not [string]::IsNullOrWhiteSpace($preHash)) -and ($preHash -eq $postHash)
    $alreadyInstalled = $depMatches -and $bundleMatches -and $patchStable

    if ($state.DupBundle) {
        Write-KitLog WARN ('the bundle name appears more than once in dsh.profile.bundles; uninstall.ps1 - then reinstall to clean it')
    }

    if ($alreadyInstalled) {
        Write-KitLog PASS 'already installed (refreshed): profile rows already point at the staging dir and the rendered patch is unchanged'
    } else {
        # ---- backups before the first profile mutation ----
        $pkgBackup = Backup-KitFile -Path $profilePkg -Suffix $script:DateSuffix
        Add-KitRestorePoint -BackupPath $pkgBackup -TargetPath $profilePkg
        $lockPath = Join-Path $profileDir 'pnpm-lock.yaml'
        $lockBackup = Backup-KitFile -Path $lockPath -Suffix $script:DateSuffix
        Add-KitRestorePoint -BackupPath $lockBackup -TargetPath $lockPath

        # ---- install: official CLI, or in-place edit without pnpm ----
        $usedMode = Get-KitEffectiveMode -Requested $Mode
        $cliTried = $false
        $cliOk = $false
        if ($usedMode -eq 'cli') {
            $cliTried = $true
            $cliArgs = @('plugin', '--profile', $Profile, 'add', $depSpec)
            $cliRun = Invoke-KitNative -FilePath $dshCli -Arguments $cliArgs -Environment @{ DSH_HOME = $dshHomePath }
            if ($cliRun.ExitCode -eq 0) {
                $cliOk = $true
                Write-KitLog PASS ('official CLI install finished (exit 0): dsh plugin add {0}' -f $depSpec)
            } else {
                Write-KitLog WARN ('official CLI install failed (exit {0})' -f $cliRun.ExitCode)
                Write-KitLog WARN ('CLI stderr tail: ' + (Get-KitTextTail $cliRun.StdErr 12))
                $logHit = [regex]::Match(($cliRun.StdErr + "`n" + $cliRun.StdOut), '(?im)^\s*(?:.*?)(Log (?:file|path)\s*:?\s*.+)$')
                if ($logHit.Success) { Write-KitLog WARN ('CLI log: ' + $logHit.Groups[1].Value.Trim()) }
                $cliPreExisting = [regex]::Match($cliRun.StdErr, 'dsh-computer-use|dsh-cua-driver-native')
                if ($cliPreExisting.Success) {
                    Write-KitLog INFO 'note: the @deepseek-ai/dsh-computer-use warnings above pre-date this kit (copied profile) and are not the cause'
                }
                if ($Mode -ne 'auto') {
                    throw ('the official CLI install failed and -Mode cli was requested; re-run with -Mode manual')
                }
                Write-KitLog WARN 'falling back to the manual (no-pnpm) install path'
            }
        }

        if (-not $cliOk) {
            if ($cliTried) {
                # A failed pnpm run may have left a half-edited package.json: start from the backup.
                foreach ($rp in $script:RestorePoints) {
                    if (Test-Path -LiteralPath $rp.Backup) {
                        Copy-Item -LiteralPath $rp.Backup -Destination $rp.Target -Force
                        Write-KitLog INFO ('reset before the manual edit: {0}' -f (Split-Path -Leaf $rp.Target))
                    }
                }
            }
            $pkgText = Get-KitTextFile -Path $profilePkg
            $edit = Add-KitPackageRows -Text $pkgText -PackageName $script:PackageName -LinkSpec $depSpec
            # Validate BEFORE writing: valid JSON, both rows present, nothing else changed.
            $reparsed = $null
            try {
                $reparsed = ConvertFrom-Json -InputObject $edit.Text
            } catch {
                throw ('manual package.json edit would not be valid JSON, nothing was written: {0}' -f $_.Exception.Message)
            }
            $depCheck = Get-KitJsonProp (Get-KitJsonProp $reparsed 'dependencies') $script:PackageName
            $bundlesCheck = @(Get-KitJsonProp (Get-KitJsonProp (Get-KitJsonProp $reparsed 'dsh') 'profile') 'bundles')
            $bundleCount = 0
            foreach ($b in $bundlesCheck) { if ([string]$b -eq $script:PackageName) { $bundleCount = $bundleCount + 1 } }
            if ([string]$depCheck -ne $depSpec) { throw ('manual edit validation failed: dependencies["{0}"] = "{1}"' -f $script:PackageName, [string]$depCheck) }
            if ($bundleCount -ne 1) { throw ('manual edit validation failed: dsh.profile.bundles contains the bundle {0} times' -f $bundleCount) }
            $stripped = Remove-KitPackageRows -Text $edit.Text -PackageName $script:PackageName
            $beforeJson = ConvertFrom-Json -InputObject $pkgText
            $afterJson = ConvertFrom-Json -InputObject $stripped.Text
            if ((ConvertTo-KitCanonicalJson $beforeJson) -ne (ConvertTo-KitCanonicalJson $afterJson)) {
                throw 'manual edit validation failed: unrelated rows would have changed'
            }
            Write-KitUtf8File -Path $profilePkg -Text $edit.Text
            Write-KitLog PASS ('edited in place (formatting preserved): {0}' -f $profilePkg)
            Write-KitLog INFO ('  dependencies += "{0}": "{1}"  (changed: {2})' -f $script:PackageName, $depSpec, $edit.ChangedDep)
            Write-KitLog INFO ('  dsh.profile.bundles += "{0}"      (changed: {1})' -f $script:PackageName, $edit.ChangedBundle)
        }

        # The CLI writes the dependency row through pnpm and the bundles row through its own
        # reconcile; repair a row that one of them missed, and make sure node_modules resolves.
        $after = Get-KitPackageState -PackagePath $profilePkg -PackageName $script:PackageName
        if ($after.Parsed -and (-not ($after.HasDependency -and $after.HasBundle))) {
            Write-KitLog WARN 'the profile is still missing one of the two rows; repairing it in place'
            $repair = Add-KitPackageRows -Text (Get-KitTextFile -Path $profilePkg) -PackageName $script:PackageName -LinkSpec $depSpec
            try { $null = ConvertFrom-Json -InputObject $repair.Text } catch { throw 'row repair produced invalid JSON' }
            Write-KitUtf8File -Path $profilePkg -Text $repair.Text
            $after = Get-KitPackageState -PackagePath $profilePkg -PackageName $script:PackageName
        }

    }

    # ---- node_modules must resolve the bundle: both install paths depend on it ----------
    # The link path follows the package name, so `dsh-vivado` -> node_modules\dsh-vivado and a
    # scoped `@scope/name` -> node_modules\@scope\name. Never hardcode the scope.
    $linkRel = $script:PackageName -replace '/', '\'
    $linkPath = Join-Path (Join-Path $profileDir 'node_modules') $linkRel
    $linkKind = Get-KitLinkTargetKind -Path $linkPath
    if ($linkKind -eq 'link' -or $linkKind -eq 'none') {
        $made = New-KitDirectoryLink -LinkPath $linkPath -TargetPath $StageDir
        if ($made -eq 'junction' -or $made -eq 'symlink' -or $made -eq 'copy') { $script:CreatedLink = $linkPath }
        if ($made -eq 'present') { Write-KitLog INFO ('node_modules link already correct: {0}' -f $linkPath) }
    } else {
        Write-KitLog WARN ('node_modules entry exists and is a plain directory, not a link: {0} (left as is)' -f $linkPath)
    }

    # ---- compatibility.json: the version exemption the mcp-vivado row needs ------------
    # Measured 2026-10-24: `--dump-config` does NOT validate compatibility.json (the output is
    # byte-identical with the exemption, without it, and even when the file is invalid JSON), so
    # this step cannot be proven by the dump oracle - it protects the session-time plugin load.
    if ($SkipCompatibility) {
        if ($compatProbe.Needed -and $compatProbe.State -ne 'present') {
            Write-KitLog WARN ('-SkipCompatibility: {0} has no exemption for [{1}]; DSH may drop the mcp-vivado row at session load' -f $compatProbe.Key, $runtimeVersion)
        } else {
            Write-KitLog INFO 'compatibility.json: skipped by -SkipCompatibility'
        }
    } elseif ($compatProbe.State -eq 'invalid') {
        Write-KitLog WARN ('compatibility.json is not valid JSON, leaving it alone: {0}' -f $compatProbe.CompatPath)
        Write-KitLog WARN ('fix: make it a JSON object, or delete it and re-run this installer; DSH may drop the mcp-vivado row until then')
    } elseif ($compatProbe.Needed -and $compatProbe.State -ne 'present' -and $compatProbe.State -ne 'unknown') {
        # Set-KitCompatibility backs the file up itself and returns the backup path.
        $compatBackup = Set-KitCompatibility -ProfileDir $profileDir -RuntimeVersion $runtimeVersion -Suffix $script:DateSuffix
        Add-KitRestorePoint -BackupPath $compatBackup -TargetPath $compatProbe.CompatPath
        Write-KitLog PASS ('compatibility exemption ensured: {0} -> [{1}]' -f $compatProbe.Key, $runtimeVersion)
        $compatProbe = Test-KitCompatibility -ProfileDir $profileDir -RuntimeVersion $runtimeVersion
    } elseif ($compatProbe.State -eq 'present') {
        Write-KitLog INFO ('compatibility exemption already present: {0}' -f $compatProbe.Key)
    } elseif ($compatProbe.State -eq 'not-needed') {
        Write-KitLog INFO 'compatibility exemption not needed: the mcp-client version equals the runtime version'
    } else {
        Write-KitLog WARN ('compatibility: could not determine the versions (runtime "{0}", mcp-client "{1}"); leaving compatibility.json alone' -f $runtimeVersion, $compatProbe.McpVersion)
    }

    # -----------------------------------------------------------------------
    #  8. verify with the composition oracle
    # -----------------------------------------------------------------------
    if (-not [string]::IsNullOrWhiteSpace($dshCli)) {
        Write-KitLog STEP '8/9 verify the composed profile (dsh --dump-config)'
        $verify = Test-KitComposition -DshCli $dshCli -DshHome $dshHomePath -Profile $Profile -SkillsPath (Join-Path $StageDir 'skills')
        Write-KitLog INFO ('dump-config exit {0}, {1} lines' -f $verify.ExitCode, $verify.LineCount)
        $verifyFailed = Show-KitVerifyResult -Verify $verify
        if ($verifyFailed -eq 0 -and $verify.ExitCode -eq 0) {
            Write-KitLog PASS ('verification: 4/4 kit markers present')
        } else {
            Write-KitLog FAIL ('verification failed: {0} of 4 markers missing' -f $verifyFailed)
        }
    } else {
        Write-KitLog STEP '8/9 verify the composed profile'
        Write-KitLog WARN 'no DSH CLI available, so the composition could not be verified; run doctor.ps1 on the target machine'
    }
} catch {
    Write-KitLog FAIL ('install failed: {0}' -f $_.Exception.Message)
    Restore-KitFromBackups
    Write-KitLog WARN 'the profile was rolled back to the state before this run; the staging dir is left in place'
    $rb = Format-KitRollbackLines -BackupPairs @() -ProfileDir $profileDir -PackageName $script:PackageName -StageDir $StageDir
    foreach ($line in $rb) { Write-Host $line }
    exit 1
}

# ---------------------------------------------------------------------------
#  9. final block: restart + rollback
# ---------------------------------------------------------------------------

Write-KitLog STEP '9/9 done'
Write-Host ''
Write-Host '================== dsh-vivado installed =================='
Write-Host ('  kit version   : {0}' -f $kitVersion)
Write-Host ('  staging dir   : {0}' -f $StageDir)
Write-Host ('  profile       : {0}' -f $profilePkg)
$finalMode = Get-KitEffectiveMode -Requested $Mode
Write-Host ('  install mode  : {0}' -f $finalMode)
if ($SkipCompatibility) {
    Write-Host '  compatibility : skipped (-SkipCompatibility)'
} else {
    Write-Host ('  compatibility : {0}' -f $compatProbe.Key)
}
Write-Host ('  skills        : mounted at rank 300 from {0}' -f (Join-Path $StageDir 'skills'))
Write-Host '  ~/.dsh/skills : NOT touched (no file was written there)'
Write-Host ''
if ($verifyFailed -gt 0) {
    Write-Host '  !! VERIFICATION FAILED - the kit is installed but the composed profile does not show it.'
} else {
    Write-Host '  verification  : PASS (dsh --dump-config shows the 4 kit markers)'
}
Write-Host ''
Write-Host '  RESTART DeepSeek Harness NOW (Electron host; dsh-hmr does not apply),'
Write-Host '  then create a NEW session and pick the `Vivado` preset.'
Write-Host ''
Write-Host '  Backups left in place (keep them while you may want to roll back):'
$printed = 0
foreach ($rp in $script:RestorePoints) {
    if (Test-Path -LiteralPath $rp.Backup) { Write-Host ('    {0}' -f $rp.Backup); $printed = $printed + 1 }
}
if ($printed -eq 0) { Write-Host '    (none on this run: the profile was already in the target state)' }
Write-Host ''
Write-Host '  ROLLBACK, one line at a time:'
Write-Host ('    powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -DshHome "{1}" -Profile {2}' -f (Join-Path $script:KitRoot 'uninstall.ps1'), $dshHomePath, $Profile)
foreach ($rp in $script:RestorePoints) {
    if (Test-Path -LiteralPath $rp.Backup) {
        Write-Host ('    copy /Y "{0}" "{1}"' -f $rp.Backup, $rp.Target)
    }
}
Write-Host ('    REM then remove "' + $script:PackageName + '" from dsh.profile.bundles in ' + $profilePkg)
Write-Host ('    rmdir /S /Q "{0}"' -f $StageDir)
Write-Host '    REM then restart DeepSeek Harness again.'
Write-Host '=============================================================='

if ($verifyFailed -gt 0) {
    $script:ExitCode = 1
    Write-KitLog FAIL ('exit {0}: verification failed; backups are kept, see the rollback block above' -f $script:ExitCode)
}
exit $script:ExitCode
