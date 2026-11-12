#requires -Version 5.1
<#
  dsh-vivado-team-link :: install.ps1
  只做四件事：注册独立 bundle + 拷贝 skill 到用户 skills 目录 + 写自身配置 + 证明未改 kit 文件。
  绝不修改 dsh-vivado 的 cordis.patch.yml / install.ps1 / packages / patches / skills / tools / templates / config.yml。
  回滚：uninstall.ps1（本脚本失败时也会自动回滚）。
#>
[CmdletBinding()]
param(
  [string]$Profile = 'desktop',
  [string]$DshHome = 'C:\Users\15266\.dsh',
  [ValidateSet('pc1','pc2')][string]$Role = 'pc1',
  [string]$NodePath = '',
  [int]$A2aPort = 7310,
  [int]$McpPort = 18790,
  [ValidateSet('Cli','Manual','None')][string]$RegisterMode = 'Cli',
  [switch]$SkipSkill
)
$ErrorActionPreference = 'Stop'

function Write-Step($m) { Write-Host ""; Write-Host ("== " + $m) -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host ("  PASS " + $m) -ForegroundColor Green }
function Write-Info($m) { Write-Host ("       " + $m) }
function Write-Warn2($m){ Write-Host ("  WARN " + $m) -ForegroundColor Yellow }
function Write-Fail($m) { Write-Host ("  FAIL " + $m) -ForegroundColor Red }

$Bundle    = $PSScriptRoot
$OptionalD = Split-Path -Parent $Bundle
$KitRoot   = Split-Path -Parent $OptionalD
$StateDir  = Join-Path $Bundle "state"
$LogDir    = Join-Path $Bundle "logs"
$SkillSrc  = Join-Path $Bundle "skills\prj-team-collab"
$SkillDst  = Join-Path (Join-Path $DshHome "skills") "prj-team-collab"
$ProfileDir= Join-Path (Join-Path $DshHome "profiles") $Profile
$ProfilePkg= Join-Path $ProfileDir "package.json"
$Token     = ""
$Stamp     = Get-Date -Format "yyyyMMdd-HHmmss"

Write-Step "0/9 预检 (preflight)"
$required = @(
  (Join-Path $Bundle "plugin.json"),
  (Join-Path $Bundle "package.json"),
  (Join-Path $Bundle "lib\index.js"),
  (Join-Path $Bundle "cordis.patch.yml.tmpl"),
  (Join-Path $Bundle "state\config.example.json"),
  (Join-Path $Bundle "server\team-link-mcp.mjs")
)
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missing.Count -gt 0) {
  Write-Fail ("缺少必需文件: " + ($missing -join ", "))
  Write-Info "先确保 server/ 与 client/ 已就位（由 team-link 实现轮次产出）。"
  exit 1
}
if (-not (Test-Path -LiteralPath $KitRoot)) { Write-Fail ("kit 根目录不存在: " + $KitRoot); exit 1 }
if (-not (Test-Path -LiteralPath $ProfilePkg)) { Write-Fail ("profile 不存在: " + $ProfilePkg); exit 1 }
Write-Ok ("bundle 目录 " + $Bundle)
Write-Ok ("kit 根目录 " + $KitRoot + "  (注册目标 profile: " + $Profile + ")")

# node 解析
$node = $NodePath
if ([string]::IsNullOrWhiteSpace($node)) {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { $node = $cmd.Source }
}
if ([string]::IsNullOrWhiteSpace($node)) {
  $cand = Join-Path (Join-Path $DshHome "dsh-runtimes\dsh-primary-runtime\dependencies\node\bin") "node.exe"
  if (Test-Path -LiteralPath $cand) { $node = $cand }
}
if ([string]::IsNullOrWhiteSpace($node) -or -not (Test-Path -LiteralPath $node)) { Write-Fail "找不到 node（>=20）。用 -NodePath 指定。"; exit 1 }
$nodeVer = (& $node --version)
Write-Ok ("node " + $nodeVer + "  " + $node)
if ([int]($nodeVer.TrimStart("v").Split(".")[0]) -lt 20) { Write-Fail "node 版本必须 >= 20"; exit 1 }

Write-Step "1/9 记录 kit 文件 SHA256 基线（不含 optional/）"
$kitBaseline = @{}
Get-ChildItem -LiteralPath $KitRoot -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
  if ($_.FullName.StartsWith($OptionalD, [StringComparison]::OrdinalIgnoreCase)) { return }
  if ($_.FullName -match "\\node_modules\\") { return }
  $rel = $_.FullName.Substring($KitRoot.Length).TrimStart("\")
  $kitBaseline[$rel] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
}
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$baselinePath = Join-Path $StateDir "kit-manifest.before.sha256"
$lines = $kitBaseline.GetEnumerator() | Sort-Object Key | ForEach-Object { $_.Value + "  " + $_.Key }
[System.IO.File]::WriteAllLines($baselinePath, $lines)
Write-Ok ("基线 " + $kitBaseline.Count + " 个文件 -> state\kit-manifest.before.sha256")

Write-Step "2/9 生成 Token"
$a2aTokenPath = Join-Path $StateDir "a2a.token"
$mcpTokenPath = Join-Path $StateDir "mcp.token"
if (Test-Path -LiteralPath $a2aTokenPath) { $a2aToken = (Get-Content -Raw -Encoding UTF8 -LiteralPath $a2aTokenPath).Trim() } else {
  $b = New-Object byte[] 32; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  $a2aToken = ($b | ForEach-Object { $_.ToString("x2") }) -join ""
  [System.IO.File]::WriteAllText($a2aTokenPath, $a2aToken)
}
if (Test-Path -LiteralPath $mcpTokenPath) { $mcpToken = (Get-Content -Raw -Encoding UTF8 -LiteralPath $mcpTokenPath).Trim() } else {
  $b2 = New-Object byte[] 32; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b2)
  $mcpToken = ($b2 | ForEach-Object { $_.ToString("x2") }) -join ""
  [System.IO.File]::WriteAllText($mcpTokenPath, $mcpToken)
}
Write-Ok ("token 就绪（A2A " + $a2aToken.Length + " hex, MCP " + $mcpToken.Length + " hex），仅本机文件，不进 git")

Write-Step "3/9 写 state\config.json"
  # 以**既有 config.json 为底**，只有它不存在时才拿 config.example.json 当种子。
  # 理由：重装 kit / 重跑 install 不该把你手写的 roots（evidence / delivery）、
  # peer.wlan 之类抹掉 —— 这是真实踩过的升级坑。首版由本脚本播种，此后由
  # lib/index.js 的 apply() 在每次宿主启动时按「配置项 → 磁盘 → 默认值」物化。
  $existingCfg = Join-Path $StateDir "config.json"
  if (Test-Path -LiteralPath $existingCfg) {
    $cfg = Get-Content -Raw -Encoding UTF8 -LiteralPath $existingCfg | ConvertFrom-Json
    Write-Info ("沿用既有 config.json 为底: " + $existingCfg)
  } else {
    $cfg = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $StateDir "config.example.json") | ConvertFrom-Json
    Write-Info "首版：以 config.example.json 为种子"
  }
  $cfg.role = $Role
  $cfg.machine = $Role.ToUpper()
  $cfg.a2a.port = $A2aPort
  $cfg.mcp.port = $McpPort
  # tokenFile 一律写绝对路径：服务端按 BUNDLE 解析、运维脚本按 BUNDLE\state 解析，
  # 相对路径会让两边指向不同文件（曾导致 evidence_pull 拿到空 token）。
  $cfg.a2a.tokenFile = ((Join-Path $StateDir "a2a.token").Replace("\","/"))
  $cfg.mcp.tokenFile = ((Join-Path $StateDir "mcp.token").Replace("\","/"))
  # 对端 token（出站用）：由人线下放入，install 只写路径、绝不生成，避免误用自己 token 冒充对端。
  if (-not $cfg.peer) { $cfg | Add-Member -NotePropertyName peer -NotePropertyValue ([pscustomobject]@{}) -Force }
  if (-not $cfg.peer.mcp) { $cfg.peer | Add-Member -NotePropertyName mcp -NotePropertyValue ([pscustomobject]@{}) -Force }
  if (-not $cfg.peer.a2a) { $cfg.peer | Add-Member -NotePropertyName a2a -NotePropertyValue ([pscustomobject]@{}) -Force }
  $cfg.peer.mcp | Add-Member -NotePropertyName tokenFile -NotePropertyValue (((Join-Path $StateDir "peer-mcp.token").Replace("\","/"))) -Force
  $cfg.peer.a2a | Add-Member -NotePropertyName tokenFile -NotePropertyValue (((Join-Path $StateDir "peer-a2a.token").Replace("\","/"))) -Force
$roots = @()
foreach ($r in $cfg.roots) {
  if ($r.id -eq "state") { $r.path = $StateDir.Replace("\","/") }
  $roots += $r
}
$cfg.roots = $roots
$cfgPath = Join-Path $StateDir "config.json"
[System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 20))
$evRoot = ($cfg.roots | Where-Object { $_.id -eq "evidence" }).path
if ($evRoot -and -not (Test-Path -LiteralPath $evRoot)) { Write-Warn2 ("evidence 根目录当前不存在（PC2 上线前可接受）: " + $evRoot) }
Write-Ok ("config.json  role=" + $Role + " a2a=" + $A2aPort + " mcp=" + $McpPort + " roots=" + $cfg.roots.Count)

Write-Step "4/9 服务端自检（--config 指向刚生成的 config.json；不监听）"
$serverMjs = Join-Path $Bundle "server\team-link-mcp.mjs"
$selftestOut = @()
$prevEA = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$selftestOut = & $node $serverMjs --selftest --config $cfgPath 2>&1
$ErrorActionPreference = $prevEA
$selftestCode = $LASTEXITCODE
if ($selftestCode -ne 0) {
  Write-Fail ("server --selftest 退出码 " + $selftestCode)
  $selftestOut | Select-Object -Last 12 | ForEach-Object { Write-Info $_ }
  Write-Info "不修改 profile，直接中止（保证半装不会留下不可用插件）。"
  exit 1
}
Write-Ok "server --selftest 退出码 0"

Write-Step "5/9 渲染 cordis.patch.yml（仅本插件目录内）"
$tmpl = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Bundle "cordis.patch.yml.tmpl")
$fwd = { param($p) $p.Replace("\","/") }
$rendered = $tmpl
$rendered = $rendered.Replace("{{NODE}}",   (& $fwd $node))
$rendered = $rendered.Replace("{{SERVER}}", (& $fwd $serverMjs))
$rendered = $rendered.Replace("{{BUNDLE}}", (& $fwd $Bundle))
$rendered = $rendered.Replace("{{CONFIG}}", (& $fwd $cfgPath))
$rendered = $rendered.Replace("{{ROLE}}",   $Role)
# 端口也要渲染：本插件那一行的 config 里 a2a.port/mcp.port 必须与 state\config.json 一致，
# 否则「宿主插件物化的配置」和「install 写的配置」会在端口上打架。
$rendered = $rendered.Replace("{{A2A_PORT}}", [string]$A2aPort)
$rendered = $rendered.Replace("{{MCP_PORT}}", [string]$McpPort)
$patchOut = Join-Path $Bundle "cordis.patch.yml"
[System.IO.File]::WriteAllText($patchOut, $rendered)
Write-Ok "cordis.patch.yml 渲染完成（team-link 行在前 + stdio MCP 行在后）"

Write-Step "6/9 拷贝 skill 到用户 skills 目录"
$skillManifest = @()
if ($SkipSkill) { Write-Warn2 "已跳过（-SkipSkill）" } else {
  if (-not (Test-Path -LiteralPath $SkillSrc)) { Write-Fail ("skill 源缺失: " + $SkillSrc); exit 1 }
  if (Test-Path -LiteralPath $SkillDst) {
    $prev = Join-Path $StateDir ("skill-backup-" + $Stamp)
    Copy-Item -LiteralPath $SkillDst -Destination $prev -Recurse -Force
    Write-Warn2 ("目标已存在，旧副本备份到 " + $prev)
  }
  New-Item -ItemType Directory -Force -Path $SkillDst | Out-Null
  Copy-Item -Path (Join-Path $SkillSrc "*") -Destination $SkillDst -Recurse -Force
  foreach ($sf in (Get-ChildItem -LiteralPath $SkillDst -Recurse -File)) {
    $skillManifest += (($sf.FullName.Substring($SkillDst.Length)).TrimStart("\") + " " + (Get-FileHash -LiteralPath $sf.FullName -Algorithm SHA256).Hash)
  }
  [System.IO.File]::WriteAllLines((Join-Path $StateDir "skill-manifest.sha256"), $skillManifest)
  Write-Ok ("skill -> " + $SkillDst + " (" + $skillManifest.Count + " 文件, 已记指纹)")
}

Write-Step "7/9 注册独立 bundle 到 profile "
$pkgBackup = Join-Path $StateDir ("profile-package.json.bak-" + $Stamp)
Copy-Item -LiteralPath $ProfilePkg -Destination $pkgBackup -Force
$lockPath = Join-Path $ProfileDir "pnpm-lock.yaml"
$lockBackup = ""
if (Test-Path -LiteralPath $lockPath) { $lockBackup = Join-Path $StateDir ("pnpm-lock.yaml.bak-" + $Stamp); Copy-Item -LiteralPath $lockPath -Destination $lockBackup -Force }
Write-Info ("备份 -> " + $pkgBackup)
$entryName = (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Bundle "package.json") | ConvertFrom-Json).name
$registered = $false
if ($RegisterMode -eq "None") {
  Write-Warn2 "-RegisterMode None：只装文件与 skill，不注册（不重启宿主即可用 tools/ 与 skill）"
} elseif ($RegisterMode -eq "Cli") {
  $dshCmd = Get-Command dsh -ErrorAction SilentlyContinue
  if (-not $dshCmd) { $cand = "D:\dsh\resources\runtime\cli\bin\dsh.cmd"; if (Test-Path -LiteralPath $cand) { $dshCmd = Get-Item $cand } }
  if (-not $dshCmd) { Write-Fail "找不到 dsh CLI；改用 -RegisterMode Manual"; exit 1 }
  $cliPath = if ($dshCmd -is [System.Management.Automation.CommandInfo]) { $dshCmd.Source } else { $dshCmd.FullName }
  Write-Info ("pnpm link: " + $cliPath + " plugin --profile " + $Profile + " add link:" + $Bundle)
$prevEA2 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $cliPath plugin --profile $Profile add ("link:" + $Bundle) 2>&1 | ForEach-Object { Write-Info $_ }
$ErrorActionPreference = $prevEA2
  $cliCode = $LASTEXITCODE
  if ($cliCode -ne 0) {
    Write-Fail ("dsh plugin add 退出码 " + $cliCode)
    Write-Info "回滚 package.json 并中止；如只是想先试文件，用 -RegisterMode Manual 或 None。"
    Copy-Item -LiteralPath $pkgBackup -Destination $ProfilePkg -Force
    if ($lockBackup) { Copy-Item -LiteralPath $lockBackup -Destination $lockPath -Force }
    exit 1
  }
  $registered = $true
} else {
  # Manual：等价于 pnpm link: 的两件事（node_modules junction + dsh.profile.bundles 条目），完全离线
  $nm = Join-Path $ProfileDir "node_modules"
  New-Item -ItemType Directory -Force -Path $nm | Out-Null
  $junction = Join-Path $nm $entryName
  if (Test-Path -LiteralPath $junction) { Remove-Item -LiteralPath $junction -Recurse -Force }
  New-Item -ItemType Junction -Path $junction -Target $Bundle | Out-Null
  $pkgObj = Get-Content -Raw -Encoding UTF8 -LiteralPath $ProfilePkg | ConvertFrom-Json
  $bundles = @($pkgObj.dsh.profile.bundles)
  if ($bundles -notcontains $entryName) { $bundles += $entryName }
  $pkgObj.dsh.profile.bundles = $bundles
  [System.IO.File]::WriteAllText($ProfilePkg, ($pkgObj | ConvertTo-Json -Depth 32))
  Write-Ok ("junction " + $junction + " -> " + $Bundle)
  $registered = $true
}
if ($registered) {
  $chk = Get-Content -Raw -Encoding UTF8 -LiteralPath $ProfilePkg | ConvertFrom-Json
  $listed = @($chk.dsh.profile.bundles) -contains $entryName
  $linked = Test-Path -LiteralPath (Join-Path (Join-Path $ProfileDir "node_modules") $entryName)
  if ($listed -and $linked) { Write-Ok ("已注册 " + $entryName + "（dsh.profile.bundles + node_modules 链接）") }
  else {
    Write-Fail ("注册校验失败 listed=" + $listed + " linked=" + $linked)
    Copy-Item -LiteralPath $pkgBackup -Destination $ProfilePkg -Force
    if ($lockBackup) { Copy-Item -LiteralPath $lockBackup -Destination $lockPath -Force }
    exit 1
  }
}

Write-Step "7.1/9 建 schemastery 解析 shim（供 lib\index.js 用）"
  # 为什么需要：本插件按 link: 注册，profile 里是指向源码目录的 junction。
  # Node 解析裸标识符时会先 realpath 到源码目录再向上找 node_modules，因此
  # "@deepseek-ai/schemastery" 在源码目录这一层**找不到**（实测：同一 junction 下裸 import
  # 直接 ERR_MODULE_NOT_FOUND，见 lib\index.js 文件头注释）。这里建一个指向 profile 副本的
  # junction 作为确定性锚点；lib 里另有一条候选链（向上找 / DSH_HOME\profiles\*），
  # 两处都落空时 Config 降级为 undefined，插件仍可启动。
  $schemaSrc = Join-Path $ProfileDir "node_modules\@deepseek-ai\schemastery"
  $shimParent = Join-Path $Bundle "node_modules\@deepseek-ai"
  $shimPath = Join-Path $shimParent "schemastery"
  if (Test-Path -LiteralPath $schemaSrc) {
    New-Item -ItemType Directory -Force -Path $shimParent | Out-Null
    # junction 一律 Directory::Delete（Remove-Item -Recurse 有删穿目标内容的风险）。
    if (Test-Path -LiteralPath $shimPath) { [System.IO.Directory]::Delete($shimPath) }
    New-Item -ItemType Junction -Path $shimPath -Target $schemaSrc | Out-Null
    Write-Ok ("schemastery shim -> " + $schemaSrc)
  } else {
    Write-Warn2 ("profile 无 @deepseek-ai/schemastery（" + $schemaSrc + "）：lib 会走候选链，落空则 Config 降级")
  }

Write-Step "8/9 复核 kit 文件未被改动"
$changed = @()
foreach ($kf in (Get-ChildItem -LiteralPath $KitRoot -Recurse -File -Force -ErrorAction SilentlyContinue)) {
  if ($kf.FullName.StartsWith($OptionalD, [StringComparison]::OrdinalIgnoreCase)) { continue }
  if ($kf.FullName -match "\\node_modules\\") { continue }
  $rel = $kf.FullName.Substring($KitRoot.Length).TrimStart("\")
  $h = (Get-FileHash -LiteralPath $kf.FullName -Algorithm SHA256).Hash
  if (-not $kitBaseline.ContainsKey($rel)) { $changed += ("新增 " + $rel) }
  elseif ($kitBaseline[$rel] -ne $h) { $changed += ("改动 " + $rel) }
}
foreach ($k in $kitBaseline.Keys) { if (-not (Test-Path -LiteralPath (Join-Path $KitRoot $k))) { $changed += ("删除 " + $k) } }
if ($changed.Count -eq 0) { Write-Ok ("kit 未改动：" + $kitBaseline.Count + " 个文件 SHA256 全部一致") }
else {
  Write-Fail ("kit 被改动 " + $changed.Count + " 项")
  $changed | Select-Object -First 20 | ForEach-Object { Write-Info $_ }
  exit 1
}

Write-Step "9/9 写安装清单并给出下一步"
$manifest = [ordered]@{
  installedAt = (Get-Date).ToString("s")
  bundle      = $Bundle
  kitRoot     = $KitRoot
  profile     = $Profile
  entryName   = $entryName
  registerMode= $RegisterMode
  registered  = $registered
  node        = $node
  role        = $Role
  ports       = [ordered]@{ a2a = $A2aPort; mcp = $McpPort }
  backups     = [ordered]@{ profilePackage = $pkgBackup; pnpmLock = $lockBackup }
  skill       = $SkillDst
  skillCopied = (-not $SkipSkill)
  kitFileCount= $kitBaseline.Count
}
[System.IO.File]::WriteAllText((Join-Path $StateDir "install-manifest.json"), ($manifest | ConvertTo-Json -Depth 10))
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Write-Ok "state\install-manifest.json"

Write-Host ""
Write-Host "安装完成。下一步：" -ForegroundColor Cyan
Write-Host "  1) 重启宿主（Electron 下 dsh-hmr 不生效），新会话里才会出现 mcp__team_link__* 工具"
Write-Host ("  2) 单机状态检查： powershell -NoProfile -File " + (Join-Path $Bundle "tools\collab_status.ps1"))
Write-Host ("  3) 自环验证：     node " + (Join-Path $Bundle "client\a2a-selfloop.mjs"))
Write-Host ("  4) 回滚：         powershell -NoProfile -File " + (Join-Path $Bundle "uninstall.ps1") + " -Profile " + $Profile)
Write-Host "  端口与安全：只在 127.0.0.1 监听；跨机走 WLAN/第二网卡/Tailscale，绝不走 192.168.1.x（两板私有链路且同 IP/MAC）。"