#requires -Version 5.1
<#
  dsh-vivado-team-link :: tools/start-lan.ps1
  一键按 state\config.json 起 A2A(7310) 与 MCP(18790) 两个 HTTP 服务，并**自动带 --allow-lan**。

  为什么需要这个脚本：
  服务端默认只绑 127.0.0.1，要跨机必须显式给 --host <ip> --allow-lan（缺一个就回落回环）。
  面板（设置 → PC 协作）只能改配置，**不会替你起服务**，所以"面板填了 LAN 地址"和"服务真的绑了 LAN"
  是两件事 —— 手工起服务时最容易漏掉 --allow-lan，然后就出现"配置看着对、对端连不上"。本脚本消掉这个坑。

  用法：
    powershell -NoProfile -File tools\start-lan.ps1            # 按 config 起两个服务并自检
    powershell -NoProfile -File tools\start-lan.ps1 -WhatIf    # 只打印将要执行的命令，不启动
    powershell -NoProfile -File tools\start-lan.ps1 -Stop      # 停掉本脚本上次起的服务
    powershell -NoProfile -File tools\start-lan.ps1 -ConfigPath state\config.test.json
    powershell -NoProfile -File tools\start-lan.ps1 -ConfigPath state\config.test.json -PidFile state\lan-servers.test.json
    powershell -NoProfile -File tools\start-lan.ps1 -Stop -PidFile state\lan-servers.test.json

  -PidFile：pid 记录文件，缺省 state\lan-servers.json。用临时配置做联调/演练时必须给一个**独立**的
    pid 文件，否则 -Stop 会按缺省文件停掉生产服务。

  为什么启动要做成"完全脱离"（这是本脚本曾经的缺陷，别再改回去）：
    以前用 Start-Process -RedirectStandardOutput/-RedirectStandardError 起服务。这两种写法（以及
    `& cmd.exe /c ...`）都会让 Windows 以 bInheritHandles=TRUE 创建子进程，于是 node 除了拿到重定向
    后的 stdout/stderr，还会**继承父进程的 stdout 管道写句柄**。当调用方把本脚本的 stdout 接到管道
    （`powershell -File start-lan.ps1 2>&1 | ...`），管道永远等不到 EOF：服务其实起来了，脚本却不返回。
    现在改成  cmd /c start "" /b <node> <args> > <console.log> 2> <console.log.err>，
    并且用 Start-Process **不带任何 -Redirect* 开关**启动这个 cmd —— 不带重定向开关时 PowerShell 走
    ShellExecuteEx，新进程**不继承**父进程句柄；重定向由 cmd 自己完成并落到子进程上。实测：
    管道场景从"挂死"变为 0.6s 返回（最小复现）；本脚本端到端启动返回约 6s，其中大头是
    Get-NetTCPConnection 单次 ~0.9s，与原实现同量级；console 日志照常写入 a2a.console.log / *.err。

  退出码：0 两个服务都已在目标地址监听；2 端口被占；3 地址非法或配置不允许；4 启动后未能在目标地址监听
  红线：绝不绑 192.168.1.0/24（两板私有链路，同 IP/同 MAC，会打错板且不报错）。
#>
[CmdletBinding()]
param(
  [string]$ConfigPath = '',
  [string]$NodePath = '',
  [string]$PidFile = '',
  [switch]$WhatIf,
  [switch]$Stop,
  [switch]$SkipMcp,
  [switch]$SkipA2a
)
$ErrorActionPreference = 'Stop'

function Write-Step($m) { Write-Host ""; Write-Host ("== " + $m) -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host ("  PASS " + $m) -ForegroundColor Green }
function Write-Info($m) { Write-Host ("       " + $m) }
function Write-Warn2($m){ Write-Host ("  WARN " + $m) -ForegroundColor Yellow }
function Write-Fail($m) { Write-Host ("  FAIL " + $m) -ForegroundColor Red }

$Bundle   = $PSScriptRoot | Split-Path -Parent          # tools\ 的上一级 = 插件根
if (-not (Test-Path -LiteralPath (Join-Path $Bundle 'state'))) { $Bundle = Split-Path -Parent $PSScriptRoot }
$StateDir = Join-Path $Bundle 'state'
$LogDir   = Join-Path $Bundle 'logs'

# -PidFile：缺省 state\lan-servers.json；相对路径按插件根解析；-Stop 与启动记录共用同一个解析结果
if ([string]::IsNullOrWhiteSpace($PidFile)) {
  $PidFile = Join-Path $StateDir 'lan-servers.json'
} elseif (-not [System.IO.Path]::IsPathRooted($PidFile)) {
  $PidFile = Join-Path $Bundle $PidFile
}
$PidFile = [System.IO.Path]::GetFullPath($PidFile)

function Resolve-PidFileDir([string]$Path) {
  $dir = [System.IO.Path]::GetDirectoryName($Path)
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

# 把一个参数安全地拼进 cmd 命令行：含空白/特殊字符才加引号；含双引号则直接拒绝（Windows 文件名里不会出现）
function Quote-CmdArg([string]$s) {
  if ($null -eq $s) { return '""' }
  $v = [string]$s
  if ($v.Length -eq 0) { return '""' }
  if ($v.Contains('"')) { throw ("参数含双引号，无法安全拼 cmd 命令行: " + $v) }
  if ($v -match '[\s&|<>^()]') { return ('"' + $v + '"') }
  return $v
}

# 完全脱离地启动一个服务：
#   cmd /c start "" /b "<node>" <args...> > "<console>" 2> "<console>.err"
# 且用 Start-Process **不带 -Redirect*** 启动 cmd，让它走 ShellExecuteEx（不继承父进程句柄）。
function Start-DetachedServer {
  param([string]$NodeExe, [string[]]$ServerArgs, [string]$WorkDir, [string]$ConsolePath, [string]$ConsoleErrPath)
  $inner = 'start "" /b ' + (Quote-CmdArg $NodeExe)
  foreach ($a in $ServerArgs) { $inner = $inner + ' ' + (Quote-CmdArg ([string]$a)) }
  $inner = $inner + ' > ' + (Quote-CmdArg $ConsolePath) + ' 2> ' + (Quote-CmdArg $ConsoleErrPath)
  $comspec = $env:ComSpec
  if ([string]::IsNullOrWhiteSpace($comspec)) { $comspec = 'cmd.exe' }
  # 注意：这里绝对不要加 -RedirectStandardOutput/-RedirectStandardError/-NoNewWindow，
  # 一旦加上就会回到 bInheritHandles=TRUE 的老路，管道调用方又会挂住。
  # -WorkingDirectory 必须给：服务端要按插件根解析相对路径（与原实现的 -WorkingDirectory $Bundle 等价）。
  $launcher = Start-Process -FilePath $comspec -ArgumentList @('/c', $inner) -WorkingDirectory $WorkDir -PassThru -WindowStyle Hidden
  return $launcher
}

# 反查真正的服务 pid：start /b 拿不到子进程 pid，但可以按"脚本名 + --port <端口>"匹配 node 进程。
# 用 WMI 单次查询（~0.3s）而不是反复 Get-NetTCPConnection 轮询（单次 ~0.9s，会把启动感知拖到 7s+）；
# 万一 WMI 查不到（权限/进程已退出），再退回按监听套接字反查一次。
function Get-ServerPid([string]$ScriptPath, [int]$Port, [int]$TimeoutMs = 6000) {
  $leaf = Split-Path -Leaf $ScriptPath
  $portPattern = '--port\s+' + [string]$Port + '(\s|$)'
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  while ((Get-Date) -lt $deadline) {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
      $cl = [string]$p.CommandLine
      if (-not $cl) { continue }
      if (($cl -like ('*' + $leaf + '*')) -and ($cl -match $portPattern)) { return [int]$p.ProcessId }
    }
    Start-Sleep -Milliseconds 300
  }
  $conns = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
  foreach ($c in $conns) {
    if ($c.OwningProcess) { return [int]$c.OwningProcess }
  }
  return 0
}

# ---------- -Stop ----------
if ($Stop) {
  Write-Step "停止上次由本脚本启动的服务"
  Write-Info ("pid 记录: " + $PidFile)
  if (-not (Test-Path -LiteralPath $PidFile)) { Write-Info "没有 $PidFile（本脚本没起过服务）"; exit 0 }
  $rec = Get-Content -Raw -Encoding UTF8 -LiteralPath $PidFile | ConvertFrom-Json
  foreach ($item in @($rec.servers)) {
    if (-not $item.pid) { continue }
    $proc = Get-Process -Id ([int]$item.pid) -ErrorAction SilentlyContinue
    if ($proc) {
      # 安全阀：pid 可能已被系统复用。只有"该 pid 仍持有记录里的端口"或"命令行含 team-link"才敢停，
      # 否则宁可拒停并报出真正的端口持有者，也不误杀别的进程。
      $ownsPort = $false
      if ($item.port) {
        $own = @(Get-NetTCPConnection -LocalPort ([int]$item.port) -State Listen -ErrorAction SilentlyContinue |
                 Where-Object { [int]$_.OwningProcess -eq [int]$item.pid })
        if ($own.Count -gt 0) { $ownsPort = $true }
      }
      $cmdLine = ''
      if (-not $ownsPort) {
        try { $cmdLine = [string](Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$item.pid) -ErrorAction SilentlyContinue).CommandLine } catch { }
      }
      if ((-not $ownsPort) -and ($cmdLine -notmatch 'team-link')) {
        Write-Warn2 ("跳过 " + $item.name + " pid=" + $item.pid + "：该 pid 既没持有端口 " + $item.port + "，命令也不像 team-link 服务，疑似 pid 已被复用")
        continue
      }
      try { Stop-Process -Id ([int]$item.pid) -Force; Write-Ok ("已停止 " + $item.name + " pid=" + $item.pid) }
      catch { Write-Warn2 ("停止失败 " + $item.name + " pid=" + $item.pid + " -> " + $_.Exception.Message) }
    } else { Write-Info ($item.name + " pid=" + $item.pid + " 已不在运行") }
  }
  Start-Sleep -Milliseconds 400
  # 停完核对端口是否真的释放（pid 记录与端口是两件事）
  foreach ($item in @($rec.servers)) {
    if (-not $item.port) { continue }
    $still = @(Get-NetTCPConnection -LocalPort ([int]$item.port) -State Listen -ErrorAction SilentlyContinue)
    if ($still.Count -eq 0) { Write-Ok ($item.name + " 端口 " + $item.port + " 已释放") }
    else {
      $holders = ($still | ForEach-Object { $_.OwningProcess } | Select-Object -Unique)
      Write-Warn2 ($item.name + " 端口 " + $item.port + " 仍在监听（pid=" + ($holders -join ',') + "），不是本记录里的进程")
    }
  }
  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
  Write-Info ("已删除 pid 记录: " + $PidFile)
  Write-Info "提示：端口若仍被别的进程占用，用 Get-NetTCPConnection -LocalPort <端口> -State Listen 查持有者"
  exit 0
}

# ---------- 0) 定位配置 ----------
Write-Step "0/5 读配置"
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $cand = Join-Path $StateDir 'config.json'
  if (-not (Test-Path -LiteralPath $cand)) {
    Write-Fail ("找不到 " + $cand + "（先跑 install.ps1，或在面板里保存一次）")
    exit 3
  }
  $ConfigPath = $cand
} elseif (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
  $ConfigPath = Join-Path $Bundle $ConfigPath
}
if (-not (Test-Path -LiteralPath $ConfigPath)) { Write-Fail ("配置不存在: " + $ConfigPath); exit 3 }
$cfg = Get-Content -Raw -Encoding UTF8 -LiteralPath $ConfigPath | ConvertFrom-Json
Write-Ok ("配置 " + $ConfigPath)

# 日志目录跟随配置的 logDir（与服务端、pc1_pc2_ping 一致）；缺省 logs 时行为与以前完全相同。
# 这一条是 -ConfigPath/-PidFile 做隔离演练的前提：临时配置能把 console 日志也带到临时目录，
# 否则会和正在跑的生产实例抢同一批 logs\*.console.log（Windows 共享冲突，cmd 的 > 打不开）。
if ($cfg.logDir) {
  $ld = [string]$cfg.logDir
  if ([System.IO.Path]::IsPathRooted($ld)) { $LogDir = $ld } else { $LogDir = Join-Path $Bundle $ld }
}

$role = if ($cfg.role) { [string]$cfg.role } else { 'pc1' }
$a2aHost = if ($cfg.a2a -and $cfg.a2a.host) { [string]$cfg.a2a.host } else { '127.0.0.1' }
$a2aPort = if ($cfg.a2a -and $cfg.a2a.port) { [int]$cfg.a2a.port } else { 7310 }
$mcpHost = if ($cfg.mcp -and $cfg.mcp.host) { [string]$cfg.mcp.host } else { '127.0.0.1' }
$mcpPort = if ($cfg.mcp -and $cfg.mcp.port) { [int]$cfg.mcp.port } else { 18790 }
Write-Info ("role=" + $role + "  A2A=" + $a2aHost + ":" + $a2aPort + "  MCP=" + $mcpHost + ":" + $mcpPort)

# ---------- 1) 地址守卫 ----------
Write-Step "1/5 地址守卫（本机地址 / 私有链路 / 回环）"
$localIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
  ForEach-Object { $_.IPAddress })
foreach ($h in @($a2aHost, $mcpHost)) {
  if ($h -like '192.168.1.*') {
    Write-Fail ("拒绝: " + $h + " 属于 192.168.1.0/24 —— 两板私有链路（同 IP/同 MAC），PC<->PC 会命中错误的那块板且不报错。")
    Write-Info ("本机可用地址: " + ($localIps -join ', '))
    exit 3
  }
  if ($h -eq '0.0.0.0') { Write-Fail "拒绝: 0.0.0.0 会暴露到所有网卡；请填本机具体 LAN 地址。"; exit 3 }
  if ($h -ne '127.0.0.1' -and $h -ne 'localhost' -and $h -ne '::1') {
    if ($localIps -notcontains $h) {
      Write-Fail ("地址 " + $h + " 不是本机当前已有的 IPv4 地址，绑不上。")
      Write-Info ("本机可用地址: " + ($localIps -join ', '))
      exit 3
    }
    Write-Ok ($h + " 是本机地址（将按跨机模式绑 LAN）")
  } else {
    Write-Warn2 ($h + " 是回环地址：只会开本机可达的通道。要跨机，请先在面板把「A2A/MCP 监听地址」改成本机 LAN 地址。")
  }
}

# ---------- 2) 端口与 token 预检 ----------
Write-Step "2/5 端口 / token 预检"
$portBusy = $false
foreach ($pair in @(@('A2A', $a2aPort), @('MCP', $mcpPort))) {
  $busy = @(Get-NetTCPConnection -LocalPort ([int]$pair[1]) -State Listen -ErrorAction SilentlyContinue)
  if ($busy.Count -gt 0) {
    $holder = ($busy | ForEach-Object { $_.OwningProcess } | Select-Object -Unique)
    Write-Fail ($pair[0] + " 端口 " + $pair[1] + " 已被占用（pid=" + ($holder -join ',') + "）")
    $portBusy = $true
  } else { Write-Ok ($pair[0] + " 端口 " + $pair[1] + " 空闲") }
}
if ($portBusy) { Write-Info "先停掉占用者，或用 -Stop 停掉本脚本上次起的服务。"; exit 2 }

foreach ($f in @($cfg.a2a.tokenFile, $cfg.mcp.tokenFile, $cfg.peer.a2a.tokenFile, $cfg.peer.mcp.tokenFile)) {
  if ([string]::IsNullOrWhiteSpace([string]$f)) { continue }
  $p = [string]$f
  if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $Bundle $p }
  if (Test-Path -LiteralPath $p) {
    $len = (Get-Item -LiteralPath $p).Length
    Write-Ok ("token " + (Split-Path $p -Leaf) + " present(" + $len + "B)")
  } else {
    Write-Warn2 ("token 缺失 " + (Split-Path $p -Leaf) + " —— 该方向无法认证（入站缺本机 token 会让服务端退出；出站缺对端 token 会拒绝发起请求）")
  }
}

# ---------- 3) node ----------
Write-Step "3/5 定位 node"
$node = $NodePath
if ([string]::IsNullOrWhiteSpace($node)) {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { $node = $cmd.Source }
}
if ([string]::IsNullOrWhiteSpace($node)) {
  $dshHome = Join-Path $env:USERPROFILE '.dsh'
  $cand = Join-Path (Join-Path $dshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\node\bin') 'node.exe'
  if (Test-Path -LiteralPath $cand) { $node = $cand }
}
if ([string]::IsNullOrWhiteSpace($node) -or -not (Test-Path -LiteralPath $node)) { Write-Fail "找不到 node（>=20）。用 -NodePath 指定。"; exit 3 }
Write-Ok ("node " + (& $node --version) + "  " + $node)

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# ---------- 4) 启动 ----------
Write-Step "4/5 启动服务（自动带 --allow-lan）"
$serverA2a = Join-Path $Bundle 'server\team-link-a2a.mjs'
$serverMcp = Join-Path $Bundle 'server\team-link-mcp.mjs'
$targets = @()
if (-not $SkipA2a) {
  $targets += [pscustomobject]@{
    name = 'a2a'; host = $a2aHost; port = $a2aPort; script = $serverA2a
    args = @($serverA2a, '--http', '--host', $a2aHost, '--allow-lan', '--port', [string]$a2aPort, '--config', $ConfigPath)
    console = (Join-Path $LogDir 'a2a.console.log'); log = (Join-Path $LogDir 'a2a.log')
  }
}
if (-not $SkipMcp) {
  $targets += [pscustomobject]@{
    name = 'mcp'; host = $mcpHost; port = $mcpPort; script = $serverMcp
    args = @($serverMcp, '--http', '--host', $mcpHost, '--allow-lan', '--port', [string]$mcpPort, '--config', $ConfigPath)
    console = (Join-Path $LogDir 'mcp.console.log'); log = (Join-Path $LogDir 'mcp.log')
  }
}

$servers = @()
foreach ($t in $targets) {
  if (-not (Test-Path -LiteralPath $t.script)) { Write-Fail ("缺少 " + $t.script); exit 3 }
  if ($WhatIf) {
    Write-Info ("[WhatIf] " + $node + " " + ($t.args -join ' '))
    continue
  }
  try {
    $null = Start-DetachedServer -NodeExe $node -ServerArgs $t.args -WorkDir $Bundle `
              -ConsolePath $t.console -ConsoleErrPath ($t.console + '.err')
  } catch {
    Write-Fail ($t.name + " 启动失败: " + $_.Exception.Message)
    exit 4
  }
  # 脱离式启动拿不到子进程 pid（cmd 立刻退出），改按"脚本名 + --port"匹配真正的 node 服务进程
  $svcPid = Get-ServerPid -ScriptPath $t.script -Port ([int]$t.port) -TimeoutMs 6000
  if ($svcPid -gt 0) { Write-Ok ($t.name + " 已启动 pid=" + $svcPid) }
  else { Write-Warn2 ($t.name + " 已脱离式拉起，但端口 " + $t.port + " 还没监听（下一步自检会判定）") }
  $servers += [pscustomobject]@{ name = $t.name; pid = $svcPid; host = $t.host; port = $t.port; log = $t.log; console = $t.console }
}
if ($WhatIf) { Write-Info "（-WhatIf：只打印，不启动）"; exit 0 }

$rec = [ordered]@{ startedAt = (Get-Date).ToString('s'); config = $ConfigPath; servers = $servers }
Resolve-PidFileDir $PidFile
[System.IO.File]::WriteAllText($PidFile, ($rec | ConvertTo-Json -Depth 6))
Write-Info ("pid 记录: " + $PidFile)

# ---------- 5) 自检：真的绑到目标地址了吗 ----------
Write-Step "5/5 自检绑定地址（这一步才是判据）"
Start-Sleep -Milliseconds 1200
$bad = 0
foreach ($s in $servers) {
  $listen = @(Get-NetTCPConnection -LocalPort ([int]$s.port) -State Listen -ErrorAction SilentlyContinue)
  $addrs = @($listen | ForEach-Object { $_.LocalAddress } | Select-Object -Unique)
  if ($listen.Count -eq 0) { Write-Fail ($s.name + " 端口 " + $s.port + " 未在监听"); $bad++; continue }
  if ($s.host -eq '127.0.0.1') {
    if ($addrs -contains '127.0.0.1') { Write-Ok ($s.name + " 监听 127.0.0.1:" + $s.port + "（仅本机）") }
    else { Write-Fail ($s.name + " 监听地址异常: " + ($addrs -join ',')); $bad++ }
  } else {
    if ($addrs -contains $s.host) { Write-Ok ($s.name + " 监听 " + $s.host + ":" + $s.port + "（跨机模式）") }
    else { Write-Fail ($s.name + " 期望监听 " + $s.host + "，实际 " + ($addrs -join ',')); $bad++ }
  }
}

Write-Host ""
if ($bad -gt 0) {
  Write-Fail ("有 " + $bad + " 个服务未达预期。看日志: " + (Join-Path $LogDir 'a2a.console.log') + " / " + (Join-Path $LogDir 'mcp.console.log'))
  Write-Info "常见原因：端口被占、配置里 host 与实际网卡不符、token 文件缺失。"
  exit 4
}

Write-Host "两个服务已就绪（配置里的地址与端口）。对端要用的地址：" -ForegroundColor Green
$peerA2a = if ($cfg.peer -and $cfg.peer.a2aUrl) { [string]$cfg.peer.a2aUrl } else { '' }
$peerMcp = if ($cfg.peer -and $cfg.peer.mcpUrl) { [string]$cfg.peer.mcpUrl } else { '' }
Write-Info ("本机（给对端填）: A2A http://" + $a2aHost + ":" + $a2aPort + "/   MCP http://" + $mcpHost + ":" + $mcpPort + "/mcp")
if ($peerA2a -or $peerMcp) { Write-Info ("对端（你在面板里填的）: A2A " + $peerA2a + "   MCP " + $peerMcp) }
else { Write-Warn2 "面板里「对端 A2A/MCP 地址」还是空的 —— 出站方向用不了，填上再跑一次本脚本即可（不用重启宿主）" }

if ($a2aHost -ne '127.0.0.1' -or $mcpHost -ne '127.0.0.1') {
  Write-Host ""
  Write-Host "跨机还需要一条只放对端的入站规则（管理员）：" -ForegroundColor Cyan
  $remote = ''
  if ($peerA2a -match '//([^/:]+)') { $remote = $Matches[1] }
  elseif ($peerMcp -match '//([^/:]+)') { $remote = $Matches[1] }
  if (-not $remote) { $remote = '<对端IP>' }
  Write-Info ('New-NetFirewallRule -DisplayName "team-link from ' + $remote + '" -Direction Inbound -Action Allow -Protocol TCP -LocalPort ' + $a2aPort + ',' + $mcpPort + ' -RemoteAddress ' + $remote + '/32')
  Write-Info ('Remove-NetFirewallRule -DisplayName "team-link from ' + $remote + '"   # 回滚')
}
$stopHint = "停止：powershell -NoProfile -File tools\start-lan.ps1 -Stop"
if ($PidFile -ne (Join-Path $StateDir 'lan-servers.json')) { $stopHint = $stopHint + ' -PidFile "' + $PidFile + '"' }
Write-Info $stopHint
exit 0
