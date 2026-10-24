# lib/install-helpers.ps1 -- installer-only helpers for dsh-vivado.
#
# Dot-sourced by install.ps1 / uninstall.ps1 AFTER lib\common.ps1:
#
#     . (Join-Path $PSScriptRoot 'lib\common.ps1')
#     . (Join-Path $PSScriptRoot 'lib\install-helpers.ps1')
#
# Same constraints as common.ps1 (deliberate, do not "improve"):
#   * Windows PowerShell 5.1 (powershell.exe) only. No `??`, no `?.`, no ternary.
#   * ASCII-only literals: PS 5.1 reads a .ps1 with the ANSI code page, so non-ASCII
#     literals would garble. Chinese prose belongs in docs\install.md.
#   * No external modules.
#
# Everything here takes explicit paths; nothing guesses a machine-wide location except the
# read-only discovery helpers (Find-KitVivadoBin / Find-KitPython / Find-KitMcpSite).

# ---------------------------------------------------------------------------
#  text / hash / json primitives
# ---------------------------------------------------------------------------

function Write-KitUtf8File {
    <# Write text as UTF-8 without BOM (the only encoding DSH/Node/PS all read cleanly). #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Get-KitSha256 {
    <# SHA256 of a file; empty string when the file does not exist. #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-KitTextFile {
    <# Raw text of a UTF-8 file; '' when missing. #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($null -eq $text) { return '' }
    return $text
}

function ConvertTo-KitJsonString {
    <# JSON-escape one string, quotes included. #>
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '""' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int][char]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"'); continue }
        if ($ch -eq '\') { [void]$sb.Append('\\'); continue }
        if ($ch -eq "`n") { [void]$sb.Append('\n'); continue }
        if ($ch -eq "`r") { [void]$sb.Append('\r'); continue }
        if ($ch -eq "`t") { [void]$sb.Append('\t'); continue }
        if ($code -lt 32) {
            [void]$sb.Append(('\u{0:x4}' -f $code))
            continue
        }
        [void]$sb.Append($ch)
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-KitCanonicalJson {
    <#
    Deterministic JSON text for a parsed JSON value: object keys sorted, no whitespace.
    Used only for equality checks ("does this file differ from that backup by anything but
    our kit rows?"), never written to disk.
    #>
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return (ConvertTo-KitJsonString $Value) }
    if ($Value -is [bool]) { if ($Value) { return 'true' } return 'false' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [sbyte] -or $Value -is [byte]) {
        return ([string]$Value)
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return ([System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
        $parts = @()
        foreach ($k in $keys) { $parts += ((ConvertTo-KitJsonString $k) + ':' + (ConvertTo-KitCanonicalJson $Value[$k])) }
        return ('{' + ($parts -join ',') + '}')
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $names = @($Value.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object -CaseSensitive)
        $parts = @()
        foreach ($n in $names) {
            $parts += ((ConvertTo-KitJsonString $n) + ':' + (ConvertTo-KitCanonicalJson $Value.PSObject.Properties[$n].Value))
        }
        return ('{' + ($parts -join ',') + '}')
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = @()
        foreach ($item in $Value) { $parts += (ConvertTo-KitCanonicalJson $item) }
        return ('[' + ($parts -join ',') + ']')
    }
    return (ConvertTo-KitJsonString ([string]$Value))
}

function Get-KitJsonProp {
    <# Property lookup that is safe under Set-StrictMode 2.0 for $null / missing properties. #>
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
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
#  native command execution
# ---------------------------------------------------------------------------

function Invoke-KitNative {
    <#
    Run a native command (exe or .cmd), print the exact command line, capture stdout/stderr
    separately and return them with the exit code.

    Never throws for a non-zero exit code: the caller decides what a failure means. Throws only
    when the executable itself cannot be started.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [hashtable]$Environment,
        [switch]$Quiet
    )
    $shown = Format-KitCommand $FilePath
    foreach ($a in $Arguments) { $shown = $shown + ' ' + (Format-KitCommand $a) }
    if (-not $Quiet) { Write-KitLog STEP ('run: ' + $shown) }

    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    $savedEnv = @{}
    $prevEap = $ErrorActionPreference
    $prevEnc = $null
    $code = 1
    try {
        if ($Environment) {
            foreach ($k in $Environment.Keys) {
                $savedEnv[$k] = [System.Environment]::GetEnvironmentVariable($k, 'Process')
                [System.Environment]::SetEnvironmentVariable($k, [string]$Environment[$k], 'Process')
            }
        }
        try {
            $prevEnc = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        } catch { }
        # Native stderr must not become a terminating error: this script runs with EAP = Stop.
        $ErrorActionPreference = 'Continue'
        & $FilePath @Arguments 2> $tmpErr | Out-File -LiteralPath $tmpOut -Encoding UTF8
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } finally {
        $ErrorActionPreference = $prevEap
        if ($null -ne $prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { } }
        foreach ($k in $savedEnv.Keys) {
            [System.Environment]::SetEnvironmentVariable($k, $savedEnv[$k], 'Process')
        }
    }
    $stdout = ''
    $stderr = ''
    try { $stdout = Get-KitTextFile -Path $tmpOut } catch { $stdout = '' }
    try { $stderr = Get-KitTextFile -Path $tmpErr } catch { $stderr = '' }
    Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        ExitCode = $code
        StdOut   = $stdout
        StdErr   = $stderr
        Command  = $shown
    }
}

function Get-KitTextTail {
    <# Last N non-empty lines of a text blob, for error reporting. #>
    param([string]$Text, [int]$Lines = 12)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $all = @($Text -split "\r?\n" | Where-Object { $_.Trim().Length -gt 0 })
    if ($all.Count -le $Lines) { return ($all -join "`n") }
    return (($all[($all.Count - $Lines)..($all.Count - 1)]) -join "`n")
}

# ---------------------------------------------------------------------------
#  version + compatibility.json
# ---------------------------------------------------------------------------

function Get-KitRuntimeVersion {
    <#
    Version string of the DSH runtime that will load the profile.

    Order (both measured on 2026-10-24):
      1. `<dsh.cmd> --version`  -> "0.2.1-rc.2"  (0.35 s, exact, keeps the prerelease suffix).
         This is the only reliable source: compatibility.json keys must use exactly this string.
      2. `<install>\DeepSeek Harness.exe` VersionInfo.FileVersion -> "0.2.1-rc.2"
      3. VersionInfo.ProductVersion -> "0.2.1.0"  (DROPS the prerelease suffix: last resort only)
    Returns '' when none of them works.
    #>
    param([string]$DshCli, [string]$InstallDir)
    if (-not [string]::IsNullOrWhiteSpace($DshCli) -and (Test-Path -LiteralPath $DshCli)) {
        $r = Invoke-KitNative -FilePath $DshCli -Arguments @('--version') -Quiet
        if ($r.ExitCode -eq 0) {
            $m = [regex]::Match($r.StdOut, '\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?')
            if ($m.Success) { return $m.Value }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($InstallDir)) {
        $exe = Join-Path $InstallDir 'DeepSeek Harness.exe'
        if (Test-Path -LiteralPath $exe) {
            $info = (Get-Item -LiteralPath $exe).VersionInfo
            foreach ($cand in @($info.FileVersion, $info.ProductVersion)) {
                if ([string]::IsNullOrWhiteSpace($cand)) { continue }
                $m = [regex]::Match([string]$cand, '\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?')
                if ($m.Success) { return $m.Value }
            }
        }
    }
    return ''
}

function Get-KitMcpClientVersion {
    <# Version the profile actually resolves for @deepseek-ai/dsh-mcp-client, or ''. #>
    param([Parameter(Mandatory = $true)][string]$ProfileDir)
    $pkg = Join-Path $ProfileDir 'node_modules\@deepseek-ai\dsh-mcp-client\package.json'
    if (-not (Test-Path -LiteralPath $pkg)) { return '' }
    try {
        $json = ConvertFrom-Json -InputObject (Get-KitTextFile -Path $pkg)
        $v = Get-KitJsonProp $json 'version'
        if ($null -eq $v) { return '' }
        return ([string]$v)
    } catch {
        return ''
    }
}

function Test-KitCompatibility {
    <#
    Is a dsh compatibility.json version exemption needed for @deepseek-ai/dsh-mcp-client?

    compatibility.json is a map  "<package>@<installed version>" -> [ "<dsh version>", ... ].
    When the installed mcp-client version differs from the runtime version, DSH refuses to load
    that plugin line unless the exemption exists -- which silently drops the `mcp-vivado` row
    (and so the preset loses its 32 MCP tools).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProfileDir,
        [string]$RuntimeVersion
    )
    $compatPath = Join-Path $ProfileDir 'compatibility.json'
    $mcpVersion = Get-KitMcpClientVersion -ProfileDir $ProfileDir
    $result = [pscustomobject]@{
        CompatPath = $compatPath
        Runtime    = $RuntimeVersion
        McpVersion = $mcpVersion
        Needed     = $false
        State      = 'unknown'
        Key        = ''
        Exists     = (Test-Path -LiteralPath $compatPath)
    }
    if ($mcpVersion -eq '') {
        $result.State = 'unknown'
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($RuntimeVersion)) {
        $result.State = 'unknown'
        return $result
    }
    $result.Key = '@deepseek-ai/dsh-mcp-client@' + $mcpVersion
    if ($mcpVersion -eq $RuntimeVersion) {
        $result.Needed = $false
        $result.State = 'not-needed'
        return $result
    }
    $result.Needed = $true
    if (-not $result.Exists) {
        $result.State = 'absent'
        return $result
    }
    try {
        $map = ConvertFrom-Json -InputObject (Get-KitTextFile -Path $compatPath)
    } catch {
        $result.State = 'invalid'
        return $result
    }
    $versions = @(Get-KitJsonProp $map $result.Key)
    foreach ($v in $versions) {
        if ([string]$v -eq $RuntimeVersion) {
            $result.State = 'present'
            return $result
        }
    }
    $result.State = 'missing-version'
    return $result
}

function Set-KitCompatibility {
    <#
    Merge the exemption key for @deepseek-ai/dsh-mcp-client into <profile>\compatibility.json.
    Keeps every unrelated key (and every other allowed version). Backs the file up first.
    Returns the backup path, or '' when nothing had to change.

    The file is written by hand (2-space indent, one line per key, LF) instead of ConvertTo-Json
    because PS 5.1's serializer emits ragged indentation for nested arrays.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProfileDir,
        [Parameter(Mandatory = $true)][string]$RuntimeVersion,
        [Parameter(Mandatory = $true)][string]$Suffix,
        [switch]$WhatIf
    )
    $probe = Test-KitCompatibility -ProfileDir $ProfileDir -RuntimeVersion $RuntimeVersion
    if (-not $probe.Needed) { return '' }
    if ($probe.State -eq 'present') { return '' }
    if ($probe.State -eq 'unknown') { return '' }
    if ($probe.State -eq 'invalid') {
        throw ("compatibility.json is not valid JSON: {0}" -f $probe.CompatPath)
    }

    $compatPath = $probe.CompatPath
    $map = [ordered]@{}
    if (Test-Path -LiteralPath $compatPath) {
        $parsed = ConvertFrom-Json -InputObject (Get-KitTextFile -Path $compatPath)
        foreach ($p in $parsed.PSObject.Properties) { $map[$p.Name] = $p.Value }
    }
    $versions = New-Object System.Collections.Generic.List[string]
    if ($map.Contains($probe.Key)) {
        foreach ($v in @($map[$probe.Key])) {
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $versions.Add([string]$v) }
        }
    }
    if (-not $versions.Contains($RuntimeVersion)) { $versions.Add($RuntimeVersion) }
    $map[$probe.Key] = $versions.ToArray()

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("{`n")
    $keys = @($map.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $k = $keys[$i]
        $vals = @($map[$k])
        $rendered = @()
        foreach ($v in $vals) { $rendered += (ConvertTo-KitJsonString ([string]$v)) }
        $sep = ','
        if ($i -eq ($keys.Count - 1)) { $sep = '' }
        [void]$sb.Append(('  {0}: [{1}]{2}' -f (ConvertTo-KitJsonString $k), ($rendered -join ', '), $sep))
        [void]$sb.Append("`n")
    }
    [void]$sb.Append("}`n")
    $text = $sb.ToString()

    if ($WhatIf) {
        Write-KitLog INFO ('would merge compatibility exemption into {0}' -f $compatPath)
        return '<whatif>'
    }
    $backup = Backup-KitFile -Path $compatPath -Suffix $Suffix
    Write-KitUtf8File -Path $compatPath -Text $text
    Write-KitLog INFO ('compatibility.json: {0} -> [{1}]' -f $probe.Key, $RuntimeVersion)
    return $backup
}

# ---------------------------------------------------------------------------
#  profile package.json inspection and editing
# ---------------------------------------------------------------------------

function Get-KitPackageState {
    <#
    Read a profile package.json and report the two rows this kit owns.

    Returns:
      Exists        file present
      Parsed        file parsed as JSON
      Dependency    the dependency value ('' when absent)
      HasDependency dependency row present
      Bundles       the bundle-name array, in file order
      HasBundle     our bundle name appears exactly once
      DupBundle     our bundle name appears more than once
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$PackageName
    )
    $state = [pscustomobject]@{
        Exists        = (Test-Path -LiteralPath $PackagePath)
        Parsed        = $false
        Dependency    = ''
        HasDependency = $false
        Bundles       = @()
        HasBundle     = $false
        DupBundle     = $false
        Error         = ''
    }
    if (-not $state.Exists) { return $state }
    try {
        $json = ConvertFrom-Json -InputObject (Get-KitTextFile -Path $PackagePath)
        $state.Parsed = $true
    } catch {
        $state.Error = $_.Exception.Message
        return $state
    }
    $deps = Get-KitJsonProp $json 'dependencies'
    $dep = Get-KitJsonProp $deps $PackageName
    if ($null -ne $dep) {
        $state.HasDependency = $true
        $state.Dependency = [string]$dep
    }
    $dsh = Get-KitJsonProp $json 'dsh'
    $profile = Get-KitJsonProp $dsh 'profile'
    $bundles = @(Get-KitJsonProp $profile 'bundles')
    $state.Bundles = $bundles
    $count = 0
    foreach ($b in $bundles) { if ([string]$b -eq $PackageName) { $count = $count + 1 } }
    $state.HasBundle = ($count -eq 1)
    $state.DupBundle = ($count -gt 1)
    return $state
}

function Get-KitLineInfo {
    <# Split text into lines plus the EOL style, for byte-faithful text surgery. #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $eol = "`n"
    if ($Text.Contains("`r`n")) { $eol = "`r`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($Text -split "\r?\n")) { [void]$lines.Add($l) }
    return [pscustomobject]@{ Lines = $lines; Eol = $eol }
}

function Add-KitPackageRows {
    <#
    Insert the dependency row ("<name>": "link:<stage>") and the bundle name into a profile
    package.json WITHOUT re-serializing the document: indentation, EOL style, key order and
    every unrelated row are preserved byte for byte. This is the no-pnpm (manual) install path.

    Throws when the document shape is not supported; the caller validates the result with
    ConvertFrom-Json before writing anything.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$LinkSpec
    )
    $info = Get-KitLineInfo -Text $Text
    $lines = $info.Lines
    $changedDep = $false
    $changedBundle = $false

    # ---- 1. dependencies ----------------------------------------------------
    $depOpen = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^([ \t]*)"dependencies"[ \t]*:[ \t]*\{[ \t]*$') { $depOpen = $i; break }
    }
    if ($depOpen -ge 0) {
        $entries = @()
        for ($k = $depOpen + 1; $k -lt $lines.Count; $k++) {
            $m = [regex]::Match($lines[$k], '^([ \t]*)"([^"]+)"[ \t]*:')
            if (-not $m.Success) { break }
            $entries += [pscustomobject]@{ Line = $k; Indent = $m.Groups[1].Value; Name = $m.Groups[2].Value }
        }
        $present = $false
        foreach ($e in $entries) { if ($e.Name -eq $PackageName) { $present = $true } }
        if (-not $present) {
            $indent = '    '
            if ($entries.Count -gt 0) { $indent = $entries[0].Indent }
            $newLine = $indent + (ConvertTo-KitJsonString $PackageName) + ': ' + (ConvertTo-KitJsonString $LinkSpec)
            $insertAt = -1
            foreach ($e in $entries) {
                if ([string]::Compare($e.Name, $PackageName, [System.StringComparison]::OrdinalIgnoreCase) -gt 0) {
                    $insertAt = $e.Line
                    break
                }
            }
            if ($insertAt -ge 0) {
                $lines.Insert($insertAt, $newLine + ',')
            } elseif ($entries.Count -gt 0) {
                $last = $entries[$entries.Count - 1]
                if (-not ($lines[$last.Line].TrimEnd().EndsWith(','))) {
                    $lines[$last.Line] = $lines[$last.Line].TrimEnd() + ','
                }
                $lines.Insert($last.Line + 1, $newLine)
            } else {
                $lines.Insert($depOpen + 1, $newLine)
            }
            $changedDep = $true
        }
    } else {
        # No dependencies object at all: add one right after the root object opening brace.
        $rootOpen = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^[ \t]*\{[ \t]*$') { $rootOpen = $i; break }
        }
        if ($rootOpen -lt 0) { throw 'package.json: cannot find the root object opening brace' }
        $topIndent = '  '
        for ($i = $rootOpen + 1; $i -lt $lines.Count; $i++) {
            $m = [regex]::Match($lines[$i], '^([ \t]*)"')
            if ($m.Success) { $topIndent = $m.Groups[1].Value; break }
        }
        $block = @(
            ($topIndent + '"dependencies": {'),
            ($topIndent + $topIndent + (ConvertTo-KitJsonString $PackageName) + ': ' + (ConvertTo-KitJsonString $LinkSpec)),
            ($topIndent + '},')
        )
        $lines.InsertRange($rootOpen + 1, [string[]]$block)
        $changedDep = $true
    }

    # ---- 2. dsh.profile.bundles --------------------------------------------
    $bunOpen = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^([ \t]*)"bundles"[ \t]*:[ \t]*\[[ \t]*$') { $bunOpen = $i; break }
    }
    if ($bunOpen -lt 0) {
        throw 'package.json: "dsh.profile.bundles" not found; run once with -Mode cli (pnpm reconcile creates it)'
    }
    $items = @()
    for ($k = $bunOpen + 1; $k -lt $lines.Count; $k++) {
        $m = [regex]::Match($lines[$k], '^([ \t]*)("[^"]*")[ \t]*(,?)[ \t]*$')
        if (-not $m.Success) { break }
        $items += [pscustomobject]@{
            Line   = $k
            Indent = $m.Groups[1].Value
            Name   = $m.Groups[2].Value.Trim('"')
            Comma  = $m.Groups[3].Value
        }
    }
    $bundlePresent = $false
    foreach ($it in $items) { if ($it.Name -eq $PackageName) { $bundlePresent = $true } }
    if (-not $bundlePresent) {
        $indent = '        '
        if ($items.Count -gt 0) { $indent = $items[0].Indent }
        $newItem = $indent + (ConvertTo-KitJsonString $PackageName)
        if ($items.Count -gt 0) {
            $last = $items[$items.Count - 1]
            if ($last.Comma -eq '') {
                $lines[$last.Line] = $lines[$last.Line].TrimEnd() + ','
            }
            $lines.Insert($last.Line + 1, $newItem)
        } else {
            $lines.Insert($bunOpen + 1, $newItem)
        }
        $changedBundle = $true
    }

    return [pscustomobject]@{
        Text          = ($lines -join $info.Eol)
        ChangedDep    = $changedDep
        ChangedBundle = $changedBundle
    }
}

function Remove-KitPackageRows {
    <#
    Remove the dependency row and the bundle item for one package from profile package.json text,
    leaving every other row and the file's formatting untouched. Returns the new text plus what
    was removed. The caller must re-parse (ConvertFrom-Json) before writing.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$PackageName
    )
    $info = Get-KitLineInfo -Text $Text
    $lines = $info.Lines
    $removedDep = $false
    $removedBundle = $false

    # ---- dependency row ----------------------------------------------------
    $namePattern = '^([ \t]*)' + [regex]::Escape((ConvertTo-KitJsonString $PackageName)) + '[ \t]*:'
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -notmatch $namePattern) { continue }
        $hadComma = $lines[$i].TrimEnd().EndsWith(',')
        $lines.RemoveAt($i)
        $removedDep = $true
        if (-not $hadComma) {
            # the removed row was the last member: drop the now dangling comma above it
            for ($j = $i - 1; $j -ge 0; $j--) {
                if ($lines[$j] -match '^[ \t]*"[^"]+"[ \t]*:') {
                    $lines[$j] = $lines[$j].TrimEnd().TrimEnd(',')
                    break
                }
            }
        }
        break
    }

    # ---- bundle item -------------------------------------------------------
    $itemPattern = '^[ \t]*' + [regex]::Escape((ConvertTo-KitJsonString $PackageName)) + '[ \t]*(,?)[ \t]*$'
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $m = [regex]::Match($lines[$i], $itemPattern)
        if (-not $m.Success) { continue }
        $hadComma = ($m.Groups[1].Value -eq ',')
        $lines.RemoveAt($i)
        $removedBundle = $true
        if (-not $hadComma) {
            for ($j = $i - 1; $j -ge 0; $j--) {
                if ($lines[$j] -match '^[ \t]*"[^"]*"[ \t]*,?[ \t]*$') {
                    $lines[$j] = $lines[$j].TrimEnd().TrimEnd(',')
                    break
                }
            }
        }
        break
    }

    return [pscustomobject]@{
        Text          = ($lines -join $info.Eol)
        RemovedDep    = $removedDep
        RemovedBundle = $removedBundle
    }
}

function Test-KitPackageEqualsBackupMinusKit {
    <#
    True when the current package.json, with our two rows stripped out, is JSON-equal to the
    backup. That is the "this file only differs by our kit" test: the only case where restoring
    the pristine backup byte for byte is both correct and preferable to a surgical edit.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$CurrentPath,
        [Parameter(Mandatory = $true)][string]$PackageName
    )
    if (-not (Test-Path -LiteralPath $BackupPath)) { return $false }
    if (-not (Test-Path -LiteralPath $CurrentPath)) { return $false }
    try {
        $bakJson = ConvertFrom-Json -InputObject (Get-KitTextFile -Path $BackupPath)
    } catch {
        return $false
    }
    $current = Get-KitTextFile -Path $CurrentPath
    $stripped = Remove-KitPackageRows -Text $current -PackageName $PackageName
    try {
        $curJson = ConvertFrom-Json -InputObject $stripped.Text
    } catch {
        return $false
    }
    return ((ConvertTo-KitCanonicalJson $bakJson) -eq (ConvertTo-KitCanonicalJson $curJson))
}

function Test-KitTextEqualsMinusKit {
    <#
    Text-level version of the "only differs by this kit" rule, for files that are not JSON
    (pnpm-lock.yaml). Both sides are compared after dropping every line that mentions the kit
    directory name.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$CurrentPath,
        [Parameter(Mandatory = $true)][string]$Needle
    )
    if (-not (Test-Path -LiteralPath $BackupPath)) { return $false }
    if (-not (Test-Path -LiteralPath $CurrentPath)) { return $false }
    $a = @((Get-KitTextFile -Path $BackupPath) -split "\r?\n" | Where-Object { $_.IndexOf($Needle) -lt 0 })
    $b = @((Get-KitTextFile -Path $CurrentPath) -split "\r?\n" | Where-Object { $_.IndexOf($Needle) -lt 0 })
    return (($a -join "`n") -eq ($b -join "`n"))
}

function Get-KitLatestBackup {    <# Newest "<Path>.bak-*" sibling, or $null. #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $dir = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $items = @(Get-ChildItem -LiteralPath $dir -Filter ($leaf + '.bak-*') -File -ErrorAction SilentlyContinue |
               Sort-Object -Property LastWriteTime -Descending)
    if ($items.Count -eq 0) { return $null }
    return $items[0].FullName
}

# ---------------------------------------------------------------------------
#  directory links (manual mode: node_modules resolution without pnpm)
# ---------------------------------------------------------------------------

function Get-KitLinkTargetKind {
    <# 'none' | 'link' | 'dir' for a path that may be a junction/symlink. #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'none' }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return 'link' }
    if ($item.PSIsContainer) { return 'dir' }
    return 'file'
}

function Remove-KitDirectoryLink {
    <#
    Remove a junction/symlink WITHOUT touching its target. A plain directory is only removed when
    it carries our own package.json (i.e. it is a Copy-Item fallback copy), never otherwise.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$PackageName
    )
    $kind = Get-KitLinkTargetKind -Path $Path
    if ($kind -eq 'none') { return 'absent' }
    if ($kind -eq 'link') {
        [System.IO.Directory]::Delete($Path, $false)
        Write-KitLog INFO ('removed directory link: {0}' -f $Path)
        return 'link-removed'
    }
    if ($kind -eq 'dir') {
        $pkg = Join-Path $Path 'package.json'
        $own = ''
        if (Test-Path -LiteralPath $pkg) {
            try { $own = [string](Get-KitJsonProp (ConvertFrom-Json -InputObject (Get-KitTextFile -Path $pkg)) 'name') } catch { $own = '' }
        }
        if ($own -eq $PackageName) {
            Remove-Item -LiteralPath $Path -Recurse -Force
            Write-KitLog INFO ('removed copied bundle directory: {0}' -f $Path)
            return 'dir-removed'
        }
        Write-KitLog WARN ('not removing {0}: it is a plain directory that does not look like this kit' -f $Path)
        return 'foreign-dir'
    }
    Write-KitLog WARN ('not removing {0}: it is a file' -f $Path)
    return 'file'
}

function New-KitDirectoryLink {
    <#
    Make <LinkPath> resolve to <TargetPath> for Node's module resolution, without pnpm and without
    admin rights: `mklink /J` (junction) first, `mklink /D` second, `Copy-Item -Recurse` last.
    Returns 'junction' | 'symlink' | 'copy' | 'present'.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$LinkPath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )
    if (-not (Test-Path -LiteralPath $TargetPath)) { throw ("link target does not exist: {0}" -f $TargetPath) }
    $parent = Split-Path -Parent $LinkPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $kind = Get-KitLinkTargetKind -Path $LinkPath
    if ($kind -eq 'link') {
        $existing = (Get-Item -LiteralPath $LinkPath -Force).Target
        $want = (Get-Item -LiteralPath $TargetPath -Force).FullName
        if ($null -ne $existing) {
            $resolved = @($existing)[0]
            if (-not [System.IO.Path]::IsPathRooted($resolved)) {
                $resolved = Join-Path $parent $resolved
            }
            $resolved = [System.IO.Path]::GetFullPath($resolved)
            if ($resolved.TrimEnd('\') -eq $want.TrimEnd('\')) { return 'present' }
        }
        Write-KitLog WARN ('replacing directory link {0} (new target {1})' -f $LinkPath, $TargetPath)
        [System.IO.Directory]::Delete($LinkPath, $false)
    } elseif ($kind -eq 'dir') {
        throw ("refusing to create a link over an existing plain directory: {0}" -f $LinkPath)
    }

    $mklink = Invoke-KitNative -FilePath $env:ComSpec -Arguments @('/c', 'mklink', '/J', $LinkPath, $TargetPath)
    if ($mklink.ExitCode -eq 0 -and (Test-Path -LiteralPath $LinkPath)) {
        Write-KitLog INFO ('node_modules junction created: {0} -> {1}' -f $LinkPath, $TargetPath)
        return 'junction'
    }
    Write-KitLog WARN ('mklink /J failed ({0}), trying mklink /D' -f $mklink.ExitCode)
    $sym = Invoke-KitNative -FilePath $env:ComSpec -Arguments @('/c', 'mklink', '/D', $LinkPath, $TargetPath)
    if ($sym.ExitCode -eq 0 -and (Test-Path -LiteralPath $LinkPath)) {
        Write-KitLog INFO ('node_modules symlink created: {0} -> {1}' -f $LinkPath, $TargetPath)
        return 'symlink'
    }
    Write-KitLog WARN ('mklink /D failed ({0}), falling back to a recursive copy' -f $sym.ExitCode)
    Copy-Item -LiteralPath $TargetPath -Destination $LinkPath -Recurse -Force
    Write-KitLog WARN ('bundle copied into node_modules (a later re-install will not refresh it): {0}' -f $LinkPath)
    return 'copy'
}

# ---------------------------------------------------------------------------
#  staging
# ---------------------------------------------------------------------------

function Copy-KitStageTree {
    <#
    Copy the kit into the staging directory (the installable bundle), excluding the files that
    must not ship: a stale rendered patch, machine config, backups, scratch dirs, the team
    contract, and VCS metadata. Additive: re-running over an existing stage is safe.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$KitRoot,
        [Parameter(Mandatory = $true)][string]$StageDir
    )
    if (-not (Test-Path -LiteralPath $StageDir)) {
        New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
    }
    $robArgs = @(
        $KitRoot, $StageDir,
        '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP',
        '/XD', '.git', '.tmp*', 'node_modules',
        '/XF', 'cordis.patch.yml', 'config.yml', 'KIT-SPEC.md', '*.bak-*', '*.bak'
    )
    $r = Invoke-KitNative -FilePath 'robocopy.exe' -Arguments $robArgs
    if ($r.ExitCode -ge 8) {
        throw ('staging copy failed (robocopy exit {0})' -f $r.ExitCode)
    }
    $files = @(Get-ChildItem -LiteralPath $StageDir -Recurse -File -ErrorAction SilentlyContinue)
    Write-KitLog INFO ('staged {0} files into {1} (robocopy exit {2})' -f $files.Count, $StageDir, $r.ExitCode)
    return $files.Count
}

# ---------------------------------------------------------------------------
#  verification (composition oracle)
# ---------------------------------------------------------------------------

function Test-KitComposition {
    <#
    Compose the profile the way the host will (dsh --dump-config) and assert the four kit markers.
    This is the cheap, offline proof that the bundle patch actually took effect; it does not need
    a session and does not need the Electron host.

    The patterns encode "hit + paragraph ownership", not hard-coded line numbers:
      * the bundle banner must be a top-level comment row (column 0);
      * preset-vivado must exist as a row;
      * customSkillDirs must exist AND the skills path mounted must be this staging dir;
      * mcp-vivado must be INDENTED, i.e. nested inside the preset's plugin list (a top-level
        mcp-vivado row would mean the kit leaked into the profile patch instead of the preset).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DshCli,
        [Parameter(Mandatory = $true)][string]$DshHome,
        [Parameter(Mandatory = $true)][string]$Profile,
        [string]$SkillsPath
    )
    $run = Invoke-KitNative -FilePath $DshCli -Arguments @('--profile', $Profile, '--dump-config') -Environment @{ DSH_HOME = $DshHome }
    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($run.StdOut)) { $lines = @($run.StdOut -split "\r?\n") }
    $defs = @(
        [pscustomobject]@{ Kind = 'banner'; Name = 'bundle banner "# == dsh-vivado"'; Pattern = '^#\s*==\s*dsh-vivado[ \t]*$' },
        [pscustomobject]@{ Kind = 'preset'; Name = 'preset row "- id: preset-vivado"'; Pattern = '^[ \t]*- id: preset-vivado[ \t]*$' },
        [pscustomobject]@{ Kind = 'skills'; Name = 'skill mount "customSkillDirs" -> <staging>/skills'; Pattern = 'customSkillDirs' },
        [pscustomobject]@{ Kind = 'mcp'; Name = 'mcp row "- id: mcp-vivado" nested in the preset'; Pattern = '^[ ]+- id: mcp-vivado[ \t]*$' }
    )
    $results = @()
    foreach ($d in $defs) {
        $hits = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $d.Pattern) { $hits += ($i + 1) }
        }
        $ok = ($hits.Count -gt 0)
        $note = ''
        if ($ok -and $d.Kind -eq 'skills' -and -not [string]::IsNullOrWhiteSpace($SkillsPath)) {
            $needle = [regex]::Escape((ConvertTo-SlashPath $SkillsPath))
            $pathHits = @()
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match $needle) { $pathHits += ($i + 1) }
            }
            if ($pathHits.Count -gt 0) {
                $hits += $pathHits
            } else {
                $ok = $false
                $note = ('customSkillDirs is present but does not point at {0}' -f $SkillsPath)
            }
        }
        $sample = ''
        if ($hits.Count -gt 0) { $sample = $lines[$hits[0] - 1].Trim() }
        if ($note -ne '') { $sample = $note }
        $results += [pscustomobject]@{
            Name   = $d.Name
            Pass   = $ok
            Lines  = $hits
            Sample = $sample
        }
    }
    $allPass = ($run.ExitCode -eq 0)
    foreach ($r in $results) { if (-not $r.Pass) { $allPass = $false } }
    return [pscustomobject]@{
        ExitCode  = $run.ExitCode
        LineCount = $lines.Count
        Results   = $results
        AllPass   = $allPass
        StdErr    = $run.StdErr
        Command   = $run.Command
    }
}

# ---------------------------------------------------------------------------
#  discovery (read-only)
# ---------------------------------------------------------------------------

function Find-KitVivadoBin {
    <#
    Probe a few plausible Xilinx roots for "<root>\Vivado\<version>\bin\vivado.bat" (and the
    "<root>\<version>\bin\vivado.bat" shape used by the installer itself). Explicitly bounded:
    no full-disk scan. Returns { BinDir; Version; BatPath } or $null.
    #>
    param([string]$PreferVersion)
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($r in @('D:\Xilinx', 'C:\Xilinx', 'E:\Xilinx')) { $roots.Add($r) }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) { $roots.Add((Join-Path $env:ProgramFiles 'Xilinx')) }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) { $roots.Add((Join-Path ${env:ProgramFiles(x86)} 'Xilinx')) }

    $found = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        foreach ($base in @($root, (Join-Path $root 'Vivado'))) {
            if (-not (Test-Path -LiteralPath $base)) { continue }
            $bat = Join-Path $base 'bin\vivado.bat'
            if (Test-Path -LiteralPath $bat) {
                $leaf = Split-Path -Leaf $base
                if ($leaf -eq 'Vivado') { $leaf = Split-Path -Leaf (Split-Path -Parent $base) }
                if (-not $seen.ContainsKey($bat)) {
                    $seen[$bat] = $true
                    $found.Add([pscustomobject]@{ BinDir = $base; Version = $leaf; BatPath = $bat })
                }
            }
            foreach ($verDir in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
                $bat2 = Join-Path $verDir.FullName 'bin\vivado.bat'
                if ((Test-Path -LiteralPath $bat2) -and -not $seen.ContainsKey($bat2)) {
                    $seen[$bat2] = $true
                    $found.Add([pscustomobject]@{ BinDir = $verDir.FullName; Version = $verDir.Name; BatPath = $bat2 })
                }
            }
        }
    }
    if ($found.Count -eq 0) { return $null }
    if (-not [string]::IsNullOrWhiteSpace($PreferVersion)) {
        foreach ($f in $found) { if ($f.Version -eq $PreferVersion) { return $f } }
    }
    $best = $found[0]
    $bestVersion = $null
    foreach ($f in $found) {
        $parsed = $null
        try { $parsed = [version]($f.Version -replace '[^0-9.]', '') } catch { $parsed = $null }
        if ($null -eq $parsed) { continue }
        if ($null -eq $bestVersion -or $parsed -gt $bestVersion) { $bestVersion = $parsed; $best = $f }
    }
    return $best
}

function Find-KitPython {
    <#
    Locate a Python 3 interpreter that can run vivado-mcp: `py -3` first (the Windows launcher
    knows every installed interpreter), then `where python`. Returns '' when nothing works.
    #>
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& py -3 -c "import sys;print(sys.executable)" 2> $null)
        if ($LASTEXITCODE -eq 0 -and $out.Count -gt 0) {
            $line = ([string]($out[$out.Count - 1])).Trim()
            if (Test-Path -LiteralPath $line) { return $line }
        }
    } catch { }
    try {
        $where = @(& where.exe python 2> $null)
        if ($LASTEXITCODE -eq 0) {
            foreach ($w in $where) {
                $cand = ([string]$w).Trim()
                if ($cand -ne '' -and (Test-Path -LiteralPath $cand)) { return $cand }
            }
        }
    } catch { }
    finally {
        $ErrorActionPreference = $savedEap
    }
    return ''
}

function Find-KitMcpSite {
    <#
    Guess the directory that must be on PYTHONPATH for `import vivado_mcp`. The known-good layout
    is <mcp root>\venv\Scripts\python.exe + <mcp root>\site, so the guesses are derived from the
    interpreter path first and only then from the usual install root.
    #>
    param([string]$Python)
    $cands = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Python)) {
        $binDir = Split-Path -Parent $Python
        if (-not [string]::IsNullOrWhiteSpace($binDir)) {
            $cands.Add([System.IO.Path]::GetFullPath((Join-Path $binDir '..\..\site')))
            $cands.Add([System.IO.Path]::GetFullPath((Join-Path $binDir '..\site')))
            $cands.Add([System.IO.Path]::GetFullPath((Join-Path $binDir '..\..\..\site')))
        }
    }
    $cands.Add('D:\vivado-mcp\site')
    $cands.Add('C:\vivado-mcp\site')
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath $c) {
            if (@(Get-ChildItem -LiteralPath $c -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'vivado_mcp' }).Count -gt 0) {
                return $c
            }
        }
    }
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return ''
}

# ---------------------------------------------------------------------------
#  reporting
# ---------------------------------------------------------------------------

function Format-KitRollbackLines {
    <#
    The copy/paste rollback block. Every backup that exists is listed as a literal copy command;
    the bundles row and the staging directory are named explicitly.
    #>
    param(
        [string[]]$BackupPairs = @(),
        [Parameter(Mandatory = $true)][string]$ProfileDir,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$StageDir
    )
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('  REM 1. restore the backed-up profile files:')
    if ($BackupPairs.Count -eq 0) {
        $out.Add('     (no backups were made by this run)')
    }
    foreach ($line in $BackupPairs) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $out.Add('     ' + $line) }
    }
    $out.Add('  REM 2. remove the "' + $PackageName + '" row from')
    $out.Add('     ' + (Join-Path $ProfileDir 'package.json') + '  (dsh.profile.bundles)')
    $out.Add('     and its "dependencies" row; or just run uninstall.ps1 (it does both).')
    $out.Add('  REM 3. delete the staging bundle:')
    $out.Add('     rmdir /S /Q "' + $StageDir + '"')
    $out.Add('  REM 4. restart DeepSeek Harness (Electron: dsh-hmr does not apply).')
    return $out
}
