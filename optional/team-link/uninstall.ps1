#requires -Version 5.1
<#
  dsh-vivado-team-link :: uninstall.ps1
  完整回滚：摘除 profile 注册 + 删 skill 副本 + 清除自身产物，并复核 kit 文件 SHA256 与安装前一致。
  默认保留本插件源码目录（uninstall 正运行于此）；-Purge 只清生成物，不删源码。
#>
[CmdletBinding()]
param(
  [string]$Profile = 'desktop',
  [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh'),
  [ValidateSet('Cli','Manual','Restore')][string]$UnregisterMode = 'Cli',
  [switch]$Purge,
  [switch]$Force,
  [switch]$RestoreSkillBackup
)
$ErrorActionPreference = 'Stop'

function Write-Step($m) { Write-Host ""; Write-Host ("== " + $m) -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host ("  PASS " + $m) -ForegroundColor Green }
function Write-Info($m) { Write-Host ("       " + $m) }
function Write-Warn2($m){ Write-Host ("  WARN " + $m) -ForegroundColor Yellow }
function Write-Fail($m) { Write-Host ("  FAIL " + $m) -ForegroundColor Red }

$Bundle     = $PSScriptRoot
$OptionalD  = Split-Path -Parent $Bundle
$KitRoot    = Split-Path -Parent $OptionalD
$StateDir   = Join-Path $Bundle "state"
$LogDir     = Join-Path $Bundle "logs"
$SkillDst   = Join-Path (Join-Path $DshHome "skills") "prj-team-collab"
$ProfileDir = Join-Path (Join-Path $DshHome "profiles") $Profile
$ProfilePkg = Join-Path $ProfileDir "package.json"
$manifestPath = Join-Path $StateDir "install-manifest.json"
$fails = 0

Write-Step "0/6 预检"
$entryName = ""
$backupPkg = ""
if (Test-Path -LiteralPath $manifestPath) {
  $m = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
  $entryName = $m.entryName
  $backupPkg = $m.backups.profilePackage
  Write-Ok ("读安装清单：entry=" + $entryName + " mode=" + $m.registerMode)
} else {
  Write-Warn2 "无 state\install-manifest.json，按 package.json 名推断"
}
if ([string]::IsNullOrWhiteSpace($entryName)) {
  $entryName = (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Bundle "package.json") | ConvertFrom-Json).name
}
Write-Info ("entryName = " + $entryName + " ; profile = " + $Profile)

Write-Step "1/6 复核 kit 文件 SHA256（purge 之前）"
$baselinePath = Join-Path $StateDir "kit-manifest.before.sha256"
if (Test-Path -LiteralPath $baselinePath) {
  $base = @{}
  Get-Content -LiteralPath $baselinePath | ForEach-Object {
    if ($_ -match "^(?<h>[0-9A-Fa-f]{64})\s\s(?<p>.+)$") { $base[$Matches["p"]] = $Matches["h"] }
  }
  $changed = @()
  foreach ($k in $base.Keys) {
    $full = Join-Path $KitRoot $k
    if (-not (Test-Path -LiteralPath $full)) { $changed += ("删除 " + $k); continue }
    $h = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
    if ($h -ne $base[$k]) { $changed += ("改动 " + $k) }
  }
  if ($changed.Count -eq 0) { Write-Ok ("kit 未改动：" + $base.Count + " 个文件 SHA256 与安装前一致") }
  else { $fails++; Write-Fail ("kit 被改动 " + $changed.Count + " 项"); $changed | Select-Object -First 20 | ForEach-Object { Write-Info $_ } }
} else {
  Write-Warn2 "无 SHA256 基线（可能已 purge），跳过 kit 比对"
}

Write-Step "2/6 摘除 profile 注册"
$removed = $false
if ($UnregisterMode -eq "Restore") {
  if ($backupPkg -and (Test-Path -LiteralPath $backupPkg)) {
    Copy-Item -LiteralPath $backupPkg -Destination $ProfilePkg -Force
    Write-Ok ("已用备份整体还原 package.json: " + $backupPkg)
    $removed = $true
    Write-Warn2 "整体还原会连带丢弃备份之后新装的插件；如不是刚安装就回滚，请改用 -UnregisterMode Manual"
  } else { Write-Fail "找不到 package.json 备份，无法 Restore"; $fails++ }
} else {
  if ($UnregisterMode -eq "Cli") {
    $dshCmd = Get-Command dsh -ErrorAction SilentlyContinue
    if (-not $dshCmd) {
    # dsh CLI 的兜底探测：从本机装的东西找，不要写死某台机器的安装盘。
    $cliCandidates = @(
      (Join-Path $DshHome 'dsh-runtimes\dsh-primary-runtime\cli\bin\dsh.cmd'),
      (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd'),
      (Join-Path $env:ProgramFiles 'DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd'),
      (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd')
    )
    foreach ($cand in $cliCandidates) {
      if ($cand -and (Test-Path -LiteralPath $cand)) { $dshCmd = Get-Item -LiteralPath $cand; break }
    }
  }
    if ($dshCmd) {
      $cliPath = if ($dshCmd -is [System.Management.Automation.CommandInfo]) { $dshCmd.Source } else { $dshCmd.FullName }
      Write-Info ("pnpm remove: " + $entryName)
$prevEA3 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $cliPath plugin --profile $Profile remove $entryName 2>&1 | ForEach-Object { Write-Info $_ }
$rmCode = $LASTEXITCODE
$ErrorActionPreference = $prevEA3
if ($rmCode -eq 0) { $removed = $true; Write-Ok "dsh plugin remove 成功" }
else { Write-Warn2 ("dsh plugin remove 退出码 " + $rmCode + "，转 Manual") }
    } else { Write-Warn2 "找不到 dsh CLI，转 Manual" }
  }
  if (-not $removed) {
    $junction = Join-Path (Join-Path $ProfileDir "node_modules") $entryName
    if (Test-Path -LiteralPath $junction) { [System.IO.Directory]::Delete($junction); Write-Ok ("删除 junction " + $junction) }
    $pkgObj = Get-Content -Raw -Encoding UTF8 -LiteralPath $ProfilePkg | ConvertFrom-Json
    $bundles = @(@($pkgObj.dsh.profile.bundles) | Where-Object { $_ -ne $entryName })
    $pkgObj.dsh.profile.bundles = $bundles
    [System.IO.File]::WriteAllText($ProfilePkg, ($pkgObj | ConvertTo-Json -Depth 32))
    $removed = $true
    Write-Ok "已从 dsh.profile.bundles 摘除并删除 junction"
  }
}

  # pnpm remove 会摘掉 package.json/lockfile，但 node_modules 里的 link 可能残留；
  # junction 必须用 Directory::Delete 删除（Remove-Item -Recurse 有删除目标内容的风险）。
  $linkPath = Join-Path (Join-Path $ProfileDir "node_modules") $entryName
  if (Test-Path -LiteralPath $linkPath) {
    try { [System.IO.Directory]::Delete($linkPath); Write-Ok ("清理残留链接 " + $linkPath) }
    catch { Write-Warn2 ("无法删除链接，请手工删除：" + $linkPath + " -> " + $_.Exception.Message) }
  }

  # install.ps1 在包内建的 schemastery 解析 shim（junction）也是本人造物，一并摘掉。
  # 只删链接本身：junction 必须用 Directory::Delete（Remove-Item -Recurse 有删穿目标内容的风险，
  # 而这里的目标是 profile 的 node_modules\@deepseek-ai\schemastery）。
  $shimPath = Join-Path $Bundle "node_modules\@deepseek-ai\schemastery"
  if (Test-Path -LiteralPath $shimPath) {
    try { [System.IO.Directory]::Delete($shimPath); Write-Ok ("删除 schemastery shim " + $shimPath) }
    catch { Write-Warn2 ("无法删除 shim，请手工删除：" + $shimPath + " -> " + $_.Exception.Message) }
  }
  # 空的 node_modules\@deepseek-ai 壳子留着无害，但仓库里不该出现，能删就删。
  foreach ($shell in @((Join-Path $Bundle "node_modules\@deepseek-ai"), (Join-Path $Bundle "node_modules"))) {
    if (Test-Path -LiteralPath $shell) {
      try { if (@(Get-ChildItem -LiteralPath $shell -Force).Count -eq 0) { [System.IO.Directory]::Delete($shell) } } catch { }
    }
  }

Write-Step "3/6 处理 skill 副本"
if (Test-Path -LiteralPath $SkillDst) {
  $skillMan = Join-Path $StateDir "skill-manifest.sha256"
  $drift = @()
  if (Test-Path -LiteralPath $skillMan) {
    Get-Content -LiteralPath $skillMan | ForEach-Object {
      $parts = $_ -split " ", 2
      $rel = $parts[0]; $want = $parts[1]
      $full = Join-Path $SkillDst $rel
      if (-not (Test-Path -LiteralPath $full)) { $drift += ("缺失 " + $rel) }
      elseif ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ne $want) { $drift += ("改动 " + $rel) }
    }
  }
  $prevSkill = Get-ChildItem -LiteralPath $StateDir -Directory -Filter "skill-backup-*" -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if ($drift.Count -gt 0 -and -not $Force) {
    Write-Warn2 ("skill 副本有 " + $drift.Count + " 处本地改动，未删除（可能含你的编辑）：" + ($drift -join ", "))
    Write-Info "确认可丢再跑 uninstall.ps1 -Force"
  } else {
    Remove-Item -LiteralPath $SkillDst -Recurse -Force
    Write-Ok ("删除 skill 副本 " + $SkillDst)
  }
  # 还原"安装前的 skill 副本"改成**显式开关**，不再无条件执行。
  # 原因（真踩过）：无条件还原会把刚删掉的副本又拷回来，于是紧接着的"残留检查"必然 FAIL ——
  # 而且拷回来的是同一插件上一轮自己的副本，等于卸载没卸干净。
  # 备份本身留在 state\skill-backup-*，要还原请显式加 -RestoreSkillBackup。
  if ($prevSkill) {
    if ($RestoreSkillBackup) {
      Copy-Item -Path (Join-Path $prevSkill.FullName "*") -Destination $SkillDst -Recurse -Force -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $SkillDst) { Write-Warn2 ("已按 -RestoreSkillBackup 还原安装前的副本: " + $prevSkill.Name) }
    } else {
      Write-Info ("安装前的 skill 副本备份保留（未自动还原）：" + $prevSkill.FullName)
      Write-Info "  需要还原：加 -RestoreSkillBackup 重跑，或手工把该目录内容拷回 skills\prj-team-collab"
    }
  }
} else { Write-Ok "skill 副本本就不存在" }

Write-Step "4/6 残留检查"
$pkgNow = Get-Content -Raw -Encoding UTF8 -LiteralPath $ProfilePkg | ConvertFrom-Json
$stillListed = @(@($pkgNow.dsh.profile.bundles) ) -contains $entryName
$stillLinked = Test-Path -LiteralPath (Join-Path (Join-Path $ProfileDir "node_modules") $entryName)
if (-not $stillListed -and -not $stillLinked) { Write-Ok "profile 无残留（bundles 与 node_modules 均干净）" }
else { $fails++; Write-Fail ("仍有残留 listed=" + $stillListed + " linked=" + $stillLinked) }
if (Test-Path -LiteralPath $SkillDst) { $fails++; Write-Fail ("skills 目录仍存在 " + $SkillDst) } else { Write-Ok "skills 目录无残留" }

Write-Step "5/6 清理自身生成物"
$genPatch = Join-Path $Bundle "cordis.patch.yml"
if ($Purge) {
  if (Test-Path -LiteralPath $genPatch) { Remove-Item -LiteralPath $genPatch -Force; Write-Ok "删除渲染产物 cordis.patch.yml" }
  foreach ($p in @("config.json","a2a.token","mcp.token")) {
    $full = Join-Path $StateDir $p
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Force; Write-Ok ("删除 state\" + $p) }
  }
  foreach ($d in @($LogDir, (Join-Path $StateDir "tasks"), (Join-Path $StateDir "inbox"), (Join-Path $StateDir "verify"))) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    try { Remove-Item -LiteralPath $d -Recurse -Force; Write-Ok ("删除 " + $d) }
    catch { Write-Warn2 ("有文件被占用，未能完全删除（不影响回滚结论）：" + $d + " -> " + $_.Exception.Message.Split([char]10)[0]) }
  }
  Write-Info "保留审计痕迹（有意）：install-manifest.json / kit-manifest.before.sha256 / skill-manifest.sha256 / *.bak-*"
  Get-ChildItem -LiteralPath $StateDir -Directory -Filter "skill-backup-*" -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force; Write-Ok ("删除 " + $_.Name) }
  Write-Info "源码目录保留（uninstall.ps1 自身在运行；需要彻底移除请手动删除 optional\team-link）"
} else {
  Write-Info "-Purge 未指定：保留 cordis.patch.yml、token、日志（便于复查）"
}

Write-Step "6/6 结论"
if ($fails -eq 0) {
  Write-Host ""
  Write-Host "卸载完成，无残留，kit 文件未被改动。重启宿主后 mcp__team_link__* 工具消失。" -ForegroundColor Green
  exit 0
} else {
  Write-Host ""
  Write-Host ("卸载完成但存在 " + $fails + " 项告警，见上方 FAIL 行。") -ForegroundColor Yellow
  exit 1
}