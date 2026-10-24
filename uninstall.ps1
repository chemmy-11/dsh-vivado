<#
.SYNOPSIS
    Uninstall the dsh-vivado bundle from a DSH profile and delete its staging directory.

.DESCRIPTION
    What it does, in order:
      1. removes the profile rows this kit owns (the "dsh-vivado" dependency and its
         dsh.profile.bundles entry) - through the official CLI when available
         (`dsh plugin --profile <p> remove dsh-vivado`), and otherwise by editing
         package.json in place;
      2. removes the stale node_modules\<package> link (pnpm leaves it behind);
      3. deletes <StageDir> unless -KeepStage;
      4. verifies with `dsh --profile <p> --dump-config` that the kit is gone;
      5. prints the restart requirement and what was left in place (backups).

    Restoration rule (deliberate, documented in docs\install.md):
      * if a "<profile>\package.json.bak-*" exists AND the current package.json differs from it
        only by this kit's rows, the backup is copied back byte for byte (exact rollback);
      * otherwise only this kit's rows are removed from the current file (surgical edit), because
        the file changed for other reasons after the backup was taken and those later changes
        must survive.
      * pnpm-lock.yaml is restored from its backup under the same "only differs by this kit" rule;
        compatibility.json is left alone (the exemption is version-wide, not bundle-specific).

    Nothing else is touched: no other bundle, no other plugin row, no file under <DshHome>\skills.

.PARAMETER Config
    Accepted for symmetry with install.ps1; unused.

.PARAMETER Profile
    DSH profile name. Default: desktop.

.PARAMETER DshHome
    DSH config root. Default: $env:DSH_HOME, else %USERPROFILE%\.dsh.

.PARAMETER InstallDir
    DSH installation root (the directory containing "DeepSeek Harness.exe").
    Default: discovered by lib\common.ps1 Find-DshCli.

.PARAMETER StageDir
    The staged bundle to delete. Default: <DshHome>\bundles\dsh-vivado.

.PARAMETER Mode
    auto   (default) official CLI removal first when it is available, surgical edit otherwise
    cli    official CLI only, then repair whatever it left behind
    manual never touch pnpm: edit package.json in place

.PARAMETER Part
    Accepted for symmetry with install.ps1; unused.

.PARAMETER SkipCompatibility
    Accepted for symmetry with install.ps1; unused (compatibility.json is never reverted here).

.PARAMETER KeepStage
    Leave <StageDir> on disk (only the profile is cleaned).

.PARAMETER WhatIf
    Print the plan and exit without changing anything.

.PARAMETER NonInteractive
    Never prompt (this script never prompts; the switch is accepted for symmetry).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -DshHome D:\dsh-home -Profile work -KeepStage
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
    [switch]$WhatIf,
    [switch]$NonInteractive,
    [switch]$KeepStage
)

$ErrorActionPreference = 'Stop'
$script:KitRoot = $PSScriptRoot
$script:PackageName = 'dsh-vivado'
$script:StageLeaf = 'dsh-vivado'
$script:DateSuffix = (Get-Date -Format 'yyyyMMdd')
$script:ExitCode = 0

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\install-helpers.ps1')

function Get-KitEffectiveMode {
    param([string]$Requested)
    if ($Requested -ne 'auto') { return $Requested }
    if (-not [string]::IsNullOrWhiteSpace($script:DshCli)) { return 'cli' }
    return 'manual'
}

# ---------------------------------------------------------------------------
#  resolve targets
# ---------------------------------------------------------------------------

Write-KitLog INFO '=============================================================='
Write-KitLog INFO ' dsh-vivado uninstaller'
Write-KitLog INFO '=============================================================='

Write-KitLog STEP '1/5 resolve paths'
$dshHomePath = Get-DshHome -Override $DshHome
$profileDir = Get-DshProfileDir -DshHome $dshHomePath -Profile $Profile
$profilePkg = Join-Path $profileDir 'package.json'
if ([string]::IsNullOrWhiteSpace($StageDir)) {
    $StageDir = Join-Path (Join-Path $dshHomePath 'bundles') $script:StageLeaf
}
$script:DshCli = Find-DshCli -InstallDir $InstallDir
# Derived from the package name: `dsh-vivado` -> node_modules\dsh-vivado,
# `@scope/name` -> node_modules\@scope\name.
$linkRel = $script:PackageName -replace '/', '\'
$linkPath = Join-Path (Join-Path $profileDir 'node_modules') $linkRel
$lockPath = Join-Path $profileDir 'pnpm-lock.yaml'
$compatPath = Join-Path $profileDir 'compatibility.json'

Write-KitLog INFO ('DSH_HOME   : {0}' -f $dshHomePath)
Write-KitLog INFO ('profile dir: {0}' -f $profileDir)
Write-KitLog INFO ('staging dir: {0}' -f $StageDir)
if ($null -ne $script:DshCli) { Write-KitLog INFO ('DSH CLI    : {0}' -f $script:DshCli) } else { Write-KitLog WARN 'DSH CLI not found: no dump-config verification will be possible' }
if (-not [string]::IsNullOrWhiteSpace($Config) -or -not [string]::IsNullOrWhiteSpace($Part) -or $SkipCompatibility) {
    Write-KitLog INFO '-Config / -Part / -SkipCompatibility are accepted for symmetry with install.ps1 and ignored here'
}

# ---------------------------------------------------------------------------
#  inspect current state
# ---------------------------------------------------------------------------

Write-KitLog STEP '2/5 inspect the current state'
$state = Get-KitPackageState -PackagePath $profilePkg -PackageName $script:PackageName
$linkKind = Get-KitLinkTargetKind -Path $linkPath
$stageExists = Test-Path -LiteralPath $StageDir
$pkgBackup = Get-KitLatestBackup -Path $profilePkg
$lockBackup = Get-KitLatestBackup -Path $lockPath
$onlyKitDiffers = $false
if ($null -ne $pkgBackup -and $state.Exists -and $state.Parsed) {
    $onlyKitDiffers = Test-KitPackageEqualsBackupMinusKit -BackupPath $pkgBackup -CurrentPath $profilePkg -PackageName $script:PackageName
}
$rowsPresent = ($state.HasDependency -or $state.HasBundle)
$nothingToDo = (-not $rowsPresent) -and ($linkKind -eq 'none') -and (-not $stageExists)

Write-KitLog INFO ('dependency row : {0}' -f $(if ($state.HasDependency) { $state.Dependency } else { '(absent)' }))
Write-KitLog INFO ('bundles row    : {0}' -f $(if ($state.HasBundle) { 'present' } else { '(absent)' }))
Write-KitLog INFO ('node_modules   : {0}' -f $linkKind)
Write-KitLog INFO ('staging dir    : {0}' -f $(if ($stageExists) { 'present' } else { '(absent)' }))
Write-KitLog INFO ('package backup : {0}' -f $(if ($null -ne $pkgBackup) { $pkgBackup } else { '(none)' }))
if ($null -ne $pkgBackup) {
    Write-KitLog INFO ('backup relation: {0}' -f $(if ($onlyKitDiffers) { 'differs from the current file by this kit only -> exact restore' } else { 'other changes happened after the backup -> surgical removal' }))
}

if ($nothingToDo) {
    Write-KitLog PASS 'nothing to remove: the profile has no kit rows, no kit link and there is no staging dir'
    exit 0
}

# ---------------------------------------------------------------------------
#  plan / -WhatIf
# ---------------------------------------------------------------------------

if ($WhatIf) {
    Write-KitLog STEP 'PLAN (-WhatIf: nothing will be changed)'
    $plannedMode = Get-KitEffectiveMode -Requested $Mode
    Write-Host ('  profile        : {0}' -f $profilePkg)
    Write-Host ('  install mode   : {0}' -f $plannedMode)
    Write-Host ("  rows           : dependency={0} bundles={1}" -f $state.HasDependency, $state.HasBundle)
    if ($plannedMode -eq 'cli' -and $state.HasDependency) {
        Write-Host ('  CLI command    : set DSH_HOME={0} && {1} plugin --profile {2} remove {3}' -f $dshHomePath, (Format-KitCommand $script:DshCli), $Profile, (Format-KitCommand $script:PackageName))
    }
    if ($null -ne $pkgBackup) {
        if ($onlyKitDiffers) {
            Write-Host ('  package.json   : restore backup byte for byte <- {0}' -f $pkgBackup)
        } else {
            Write-Host ('  package.json   : surgical removal of the two kit rows (backup is stale: it differs by more than this kit)')
        }
    } else {
        Write-Host ('  package.json   : surgical removal of the two kit rows (no backup exists)')
    }
    Write-Host ('  node_modules   : remove the {0} link ({1})' -f ($script:PackageName -replace '/', '\'), $linkKind)
    if ($KeepStage) {
        Write-Host ('  staging dir    : KEEP (-KeepStage) {0}' -f $StageDir)
    } elseif ($stageExists) {
        Write-Host ('  staging dir    : delete {0}' -f $StageDir)
    } else {
        Write-Host '  staging dir    : already absent'
    }
    Write-Host '  compatibility.json: left as is'
    Write-Host '  restart         : REQUIRED afterwards (Electron host; dsh-hmr does not apply)'
    Write-Host '  no file was created, modified or deleted by this -WhatIf run.'
    exit 0
}

# ---------------------------------------------------------------------------
#  remove the profile rows
# ---------------------------------------------------------------------------

Write-KitLog STEP '3/5 remove the profile rows'
$branch = 'none'
if ($rowsPresent) {
    $usedMode = Get-KitEffectiveMode -Requested $Mode
    if ($usedMode -eq 'cli' -and $state.HasDependency) {
        Write-KitLog INFO ('official removal path: dsh plugin --profile {0} remove {1}' -f $Profile, $script:PackageName)
        $cliRun = Invoke-KitNative -FilePath $script:DshCli -Arguments @('plugin', '--profile', $Profile, 'remove', $script:PackageName) -Environment @{ DSH_HOME = $dshHomePath }
        if ($cliRun.ExitCode -eq 0) {
            Write-KitLog PASS 'the official CLI removed the dependency and npm/pnpm bookkeeping'
        } else {
            $both = ($cliRun.StdErr + "`n" + $cliRun.StdOut)
            if ($both -match 'ERR_PNPM_CANNOT_REMOVE_MISSING_DEPS') {
                Write-KitLog INFO 'pnpm reports the dependency is already absent (idempotent re-run): ERR_PNPM_CANNOT_REMOVE_MISSING_DEPS'
            } elseif ($both -match 'ERR_PNPM_NO_MATCHING_VERSION|ERR_PNPM_NOT_FOUND') {
                Write-KitLog WARN ('pnpm could not see the dependency (exit {0}); continuing with the in-place edit' -f $cliRun.ExitCode)
            } else {
                Write-KitLog WARN ('official CLI removal failed (exit {0})' -f $cliRun.ExitCode)
                Write-KitLog WARN ('CLI stderr tail: ' + (Get-KitTextTail $cliRun.StdErr 10))
            }
        }
        $state = Get-KitPackageState -PackagePath $profilePkg -PackageName $script:PackageName
        $rowsPresent = ($state.HasDependency -or $state.HasBundle)
        if (-not $rowsPresent) { $branch = 'removed-by-pnpm' }
    }

    # Decide how to finish. The rule is applied to the LIVE file: a pnpm run may already have
    # removed the rows (but rewritten the whole file, e.g. CRLF -> LF), in which case restoring
    # the pristine backup is still the byte-exact rollback and is preferred over doing nothing.
    if ($null -ne $pkgBackup) {
        $onlyKitDiffers = Test-KitPackageEqualsBackupMinusKit -BackupPath $pkgBackup -CurrentPath $profilePkg -PackageName $script:PackageName
    }

    if ($rowsPresent) {
        $pkgText = Get-KitTextFile -Path $profilePkg
        $strip = Remove-KitPackageRows -Text $pkgText -PackageName $script:PackageName
        try {
            $null = ConvertFrom-Json -InputObject $strip.Text
        } catch {
            Write-KitLog FAIL ('removing the two rows would leave invalid JSON, nothing was written: {0}' -f $_.Exception.Message)
            exit 1
        }
        if ($null -ne $pkgBackup -and $onlyKitDiffers) {
            Copy-Item -LiteralPath $pkgBackup -Destination $profilePkg -Force
            Write-KitLog PASS ('package.json restored byte for byte from {0}' -f (Split-Path -Leaf $pkgBackup))
            $branch = 'restore-backup'
        } else {
            Write-KitUtf8File -Path $profilePkg -Text $strip.Text
            Write-KitLog PASS ('package.json edited in place: dependency removed={0}, bundles row removed={1}' -f $strip.RemovedDep, $strip.RemovedBundle)
            if ($null -eq $pkgBackup) {
                Write-KitLog WARN 'there was no backup to restore from; the rows were removed surgically'
            } else {
                Write-KitLog WARN ('the backup {0} was kept but not restored: the file changed for other reasons after it was taken' -f (Split-Path -Leaf $pkgBackup))
            }
            $branch = 'surgical'
        }
    } elseif ($null -ne $pkgBackup -and $onlyKitDiffers) {
        # pnpm already removed the rows; put the original bytes back so an uninstall leaves the
        # profile exactly as install.ps1 found it (pnpm normalises line endings on rewrite).
        Copy-Item -LiteralPath $pkgBackup -Destination $profilePkg -Force
        Write-KitLog PASS ('package.json restored byte for byte from {0} (the rows were already gone; pnpm had rewritten the file)' -f (Split-Path -Leaf $pkgBackup))
        $branch = 'restore-backup'
    }
} else {
    Write-KitLog INFO 'the profile has no kit rows: nothing to edit'
    $branch = 'already-absent'
}

# pnpm-lock.yaml: same "only differs by this kit" rule.
Write-KitLog INFO 'pnpm-lock.yaml'
if ($null -eq $lockBackup) {
    Write-KitLog INFO '  no lockfile backup: left as is'
} elseif (Test-KitTextEqualsMinusKit -BackupPath $lockBackup -CurrentPath $lockPath -Needle $script:StageLeaf) {
    Copy-Item -LiteralPath $lockBackup -Destination $lockPath -Force
    Write-KitLog PASS ('  restored from {0}' -f (Split-Path -Leaf $lockBackup))
} else {
    Write-KitLog INFO '  left as is (it changed for reasons unrelated to this kit)'
}

# ---------------------------------------------------------------------------
#  remove the node_modules link, then the staging dir
# ---------------------------------------------------------------------------

Write-KitLog STEP '4/5 remove the link and the staging dir'
if ($linkKind -ne 'none') {
    $removed = Remove-KitDirectoryLink -Path $linkPath -PackageName $script:PackageName
    if ($removed -eq 'foreign-dir') {
        Write-KitLog WARN ('left in place: {0} is not this kit' -f $linkPath)
    }
} else {
    Write-KitLog INFO ('no node_modules entry at {0}' -f $linkPath)
}

if ($KeepStage) {
    Write-KitLog INFO ('-KeepStage: staging kept at {0}' -f $StageDir)
} elseif (-not $stageExists) {
    Write-KitLog INFO ('staging dir already absent: {0}' -f $StageDir)
} else {
    $stageOwn = ''
    $stagePkg = Join-Path $StageDir 'package.json'
    if (Test-Path -LiteralPath $stagePkg) {
        try { $stageOwn = [string](Get-KitJsonProp (ConvertFrom-Json -InputObject (Get-KitTextFile -Path $stagePkg)) 'name') } catch { $stageOwn = '' }
    }
    $stageEmpty = (@(Get-ChildItem -LiteralPath $StageDir -Force -ErrorAction SilentlyContinue).Count -eq 0)
    if ($stageOwn -eq $script:PackageName -or $stageEmpty) {
        $rm = Invoke-KitNative -FilePath $env:ComSpec -Arguments @('/c', 'rmdir', '/S', '/Q', $StageDir)
        if ($rm.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $StageDir)) {
            Write-KitLog PASS ('deleted staging dir: {0}' -f $StageDir)
        } else {
            Write-KitLog FAIL ('could not delete the staging dir (exit {0}): {1}' -f $rm.ExitCode, (Get-KitTextTail $rm.StdErr 5))
            $script:ExitCode = 1
        }
    } else {
        Write-KitLog WARN ('not deleting {0}: it does not contain this kit (package name "{1}"); pass -StageDir to point at the right directory' -f $StageDir, $stageOwn)
    }
}

# ---------------------------------------------------------------------------
#  verify absence
# ---------------------------------------------------------------------------

Write-KitLog STEP '5/5 verify that the kit is gone'
$verifyFailed = 0
if ($null -ne $script:DshCli) {
    $run = Invoke-KitNative -FilePath $script:DshCli -Arguments @('--profile', $Profile, '--dump-config') -Environment @{ DSH_HOME = $dshHomePath }
    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($run.StdOut)) { $lines = @($run.StdOut -split "\r?\n") }
    $stageSlash = ConvertTo-SlashPath $StageDir
    $checks = @(
        [pscustomobject]@{ Name = 'preset row "- id: preset-vivado" absent anywhere'; Pattern = [regex]::Escape('- id: preset-vivado') },
        [pscustomobject]@{ Name = 'bundle banner "# == dsh-vivado" absent anywhere'; Pattern = [regex]::Escape('# == dsh-vivado') },
        [pscustomobject]@{ Name = 'mcp row "- id: mcp-vivado" absent anywhere'; Pattern = [regex]::Escape('- id: mcp-vivado') },
        [pscustomobject]@{ Name = ('staging path reference "{0}" absent' -f $stageSlash); Pattern = [regex]::Escape($stageSlash) }
    )
    foreach ($c in $checks) {
        $hits = @()
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $c.Pattern) { $hits += ($i + 1) } }
        if ($hits.Count -eq 0) {
            Write-KitLog PASS $c.Name
        } else {
            $verifyFailed = $verifyFailed + 1
            Write-KitLog FAIL ('{0}  -> found on line {1}' -f $c.Name, ($hits -join ','))
        }
    }
    if ($run.ExitCode -ne 0) {
        $verifyFailed = $verifyFailed + 1
        Write-KitLog FAIL ('dsh --dump-config exited {0}' -f $run.ExitCode)
        Write-KitLog WARN ('stderr tail: ' + (Get-KitTextTail $run.StdErr 10))
    } else {
        Write-KitLog INFO ('dump-config exit 0, {0} lines' -f $lines.Count)
    }
} else {
    Write-KitLog WARN 'no DSH CLI available: the composition could not be verified'
}

# ---------------------------------------------------------------------------
#  summary
# ---------------------------------------------------------------------------

Write-KitLog INFO '=============================================================='
Write-Host '================= dsh-vivado uninstalled ================='
Write-Host ('  profile       : {0}' -f $profilePkg)
Write-Host ('  row removal   : {0}' -f $branch)
Write-Host ('  staging dir   : {0}' -f $(if ($KeepStage) { 'kept (-KeepStage)' } else { 'deleted' }))
Write-Host '  compatibility : compatibility.json left as is (version-wide exemption, harmless)'
Write-Host '  ~/.dsh/skills : untouched (this kit never wrote there)'
Write-Host ''
Write-Host '  Backups left in place (not deleted - remove them yourself once you are sure):'
$found = 0
foreach ($cand in @($pkgBackup, $lockBackup)) {
    if (-not [string]::IsNullOrWhiteSpace($cand) -and (Test-Path -LiteralPath $cand)) { Write-Host ('    {0}' -f $cand); $found = $found + 1 }
}
$compatBackup = Get-KitLatestBackup -Path $compatPath
if ($null -ne $compatBackup) { Write-Host ('    {0}' -f $compatBackup); $found = $found + 1 }
if ($found -eq 0) { Write-Host '    (none)' }
Write-Host ''
Write-Host '  RESTART DeepSeek Harness now (Electron host; dsh-hmr does not apply).'
Write-Host '  The `Vivado` preset disappears from the new-session picker after the restart.'
Write-Host '=============================================================='

if ($verifyFailed -gt 0) {
    Write-KitLog FAIL ('exit 1: {0} absence check(s) failed' -f $verifyFailed)
    $script:ExitCode = 1
}
exit $script:ExitCode
