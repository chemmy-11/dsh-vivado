<#
.SYNOPSIS
    Render cordis.patch.yml for dsh-vivado from templates + config.yml.

.DESCRIPTION
    The bundle patch must carry absolute paths (skill-filesystem customSkillDirs, the MCP
    server command/env/cwd), so it cannot be shipped verbatim in a git repo. This script is the
    only place that turns config.yml + templates into the installed patch:

        templates/preset.patch.yml.tmpl   +  templates/persona/<tier>.frag.yml  +  config.yml
                                   ->  <OutFile>

    Substitution is literal (String.Replace), never regex, so paths with backslashes, `$`, `[`
    or spaces are safe. Output: LF line endings, UTF-8 without BOM.

    Placeholders: {{PERSONA_BLOCK}} {{SKILLS_DIR}} {{MCP_PYTHON}} {{MCP_SITE}} {{VIVADO_BAT}}
                  {{MCP_CWD}} {{TEMP_DIR}} {{PART}} {{PROJECT_ROOT}} {{VIVADO_VERSION}}
                  {{VIVADO_PATH}} {{PYTHON}} {{TOOL_COUNT}} {{KIT_VERSION}}
    `{{model}}` inside the persona is a DSH prompt placeholder and is deliberately left alone.

.PARAMETER ConfigPath
    config.yml path (see config.example.yml).

.PARAMETER OutFile
    Patch file to write, normally <staging>\cordis.patch.yml.

.PARAMETER BundleDir
    Bundle root that contains templates\ (defaults to this script's parent directory).

.PARAMETER SkillsDir
    Absolute skills directory the preset should mount at rank 300. Defaults to <BundleDir>\skills.

.EXAMPLE
    powershell -File tools\render_patch.ps1 -ConfigPath .\config.yml -OutFile .\cordis.patch.yml
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$BundleDir,
    [string]$SkillsDir,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Say {
    param([string]$Level, [string]$Message)
    if ($Quiet) { return }
    Write-KitLog $Level $Message
}

if ([string]::IsNullOrWhiteSpace($BundleDir)) {
    $BundleDir = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
} else {
    $BundleDir = (Resolve-Path -LiteralPath $BundleDir).Path
}
if ([string]::IsNullOrWhiteSpace($SkillsDir)) {
    $SkillsDir = Join-Path $BundleDir 'skills'
}

# ---- 1. config -----------------------------------------------------------------------------
$cfg = Read-KitConfig -Path $ConfigPath
$required = @('part', 'project_root', 'vivado_version', 'vivado_path', 'python',
              'vivado_mcp_site', 'vivado_mcp_cwd', 'temp_dir')
$missing = @()
foreach ($k in $required) {
    if (-not $cfg.Contains($k) -or [string]::IsNullOrWhiteSpace($cfg[$k])) { $missing += $k }
}
if ($missing.Count -gt 0) {
    throw ("config is missing required keys: {0}  (file: {1})" -f ($missing -join ', '), $ConfigPath)
}

# ---- 2. tier -------------------------------------------------------------------------------
$versionText = $cfg['vivado_version']
$tier = '2023.1'
try {
    $v = [version]($versionText -replace '[^0-9.]', '')
    if ($v -ge [version]'2025.2') { $tier = '2025.2plus' }
} catch {
    throw ("vivado_version is not parseable: '{0}'" -f $versionText)
}
$fragPath = Join-Path $BundleDir ('templates\persona\{0}.frag.yml' -f $tier)
if (-not (Test-Path -LiteralPath $fragPath)) {
    throw ("persona fragment for tier '{0}' not found: {1}" -f $tier, $fragPath)
}

# ---- 3. values -----------------------------------------------------------------------------
$vizPath = ConvertTo-SlashPath ($cfg['vivado_path'].TrimEnd('\', '/'))
$batPath = $vizPath + '/vivado.bat'
if ($cfg.Contains('vivado_bat') -and -not [string]::IsNullOrWhiteSpace($cfg['vivado_bat'])) {
    $batPath = ConvertTo-SlashPath $cfg['vivado_bat']
}
$skillsSlash = ConvertTo-SlashPath $SkillsDir
$values = [ordered]@{
    'PERSONA_BLOCK'  = ''   # filled below
    'SKILLS_DIR'     = $skillsSlash
    'MCP_PYTHON'     = ConvertTo-SlashPath $cfg['python']
    'MCP_SITE'       = ConvertTo-SlashPath $cfg['vivado_mcp_site']
    'VIVADO_BAT'     = $batPath
    'MCP_CWD'        = ConvertTo-SlashPath $cfg['vivado_mcp_cwd']
    'TEMP_DIR'       = ConvertTo-SlashPath $cfg['temp_dir']
    'PART'           = $cfg['part']
    'PROJECT_ROOT'   = ConvertTo-SlashPath $cfg['project_root']
    'VIVADO_VERSION' = $versionText
    'VIVADO_PATH'    = $vizPath
    'PYTHON'         = ConvertTo-SlashPath $cfg['python']
    'TOOL_COUNT'     = '32'
    'KIT_VERSION'    = (Get-KitVersion -KitRoot $BundleDir)
}

# ASCII guard: a non-ASCII path in the rendered patch breaks Vivado (GBK) and is a doctor FAIL.
foreach ($k in @('SKILLS_DIR', 'MCP_SITE', 'MCP_CWD', 'TEMP_DIR', 'VIVADO_BAT', 'PROJECT_ROOT', 'MCP_PYTHON')) {
    if (-not (Test-AsciiPath $values[$k])) {
        throw ("rendered value for {0} contains non-ASCII characters and would break Vivado: {1}" -f $k, $values[$k])
    }
}

# ---- 4. assemble ---------------------------------------------------------------------------
function Expand-Placeholders {
    param([string]$Text, $Map, [switch]$KeepPersona)
    foreach ($key in $Map.Keys) {
        if ($KeepPersona -and $key -eq 'PERSONA_BLOCK') { continue }
        $Text = $Text.Replace('{{' + $key + '}}', [string]$Map[$key])
    }
    return $Text
}

$frag = Get-Content -LiteralPath $fragPath -Raw -Encoding UTF8
if ($null -eq $frag) { throw ("empty persona fragment: {0}" -f $fragPath) }
$frag = $frag.Replace("`r`n", "`n").TrimEnd("`n")
$persona = Expand-Placeholders -Text $frag -Map $values -KeepPersona
$values['PERSONA_BLOCK'] = $persona

$tmplPath = Join-Path $BundleDir 'templates\preset.patch.yml.tmpl'
if (-not (Test-Path -LiteralPath $tmplPath)) { throw ("template not found: {0}" -f $tmplPath) }
$tmpl = Get-Content -LiteralPath $tmplPath -Raw -Encoding UTF8
$tmpl = $tmpl.Replace("`r`n", "`n")
$out = Expand-Placeholders -Text $tmpl -Map $values

# ---- 5. self-check -------------------------------------------------------------------------
$leftover = [regex]::Matches($out, '\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$bad = @($leftover | Where-Object { $_ -ne 'model' })
if ($bad.Count -gt 0) {
    throw ("unsubstituted placeholders remain in the rendered patch: {0}" -f ($bad -join ', '))
}
if ($out -notmatch '(?m)^- insert:') { throw 'rendered patch has no top-level "- insert:" row list' }
$rows = [regex]::Matches($out, '(?m)^ {10}- id: (\S+)$') | ForEach-Object { $_.Groups[1].Value }
if ($rows.Count -ne 23) { throw ("rendered patch should carry 22 shipped plugin rows + mcp-vivado = 23 rows, got {0}: {1}" -f $rows.Count, ($rows -join ',')) }
if ($rows -notcontains 'persona') { throw 'rendered patch lost the persona row' }
if ($rows -notcontains 'skill-filesystem') { throw 'rendered patch lost the skill-filesystem row' }
if ($rows -notcontains 'mcp-vivado') { throw 'rendered patch lost the mcp-vivado row' }
if ($out -match '(?m)^ +prefix: \|\n {16}You are a coding agent' -eq $false) {
    throw 'persona prefix block does not look like an indented YAML block scalar'
}

# ---- 6. write ------------------------------------------------------------------------------
$outDir = Split-Path -Parent $OutFile
if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutFile, $out, $enc)

Say PASS ("rendered {0} ({1} bytes, tier {2}, 22 plugin rows)" -f $OutFile, (Get-Item -LiteralPath $OutFile).Length, $tier)
Say INFO ("skills dir mounted at rank 300: {0}" -f $skillsSlash)
Say INFO ("mcp-vivado: {0} -m vivado_mcp (cwd {1})" -f $values['MCP_PYTHON'], $values['MCP_CWD'])
