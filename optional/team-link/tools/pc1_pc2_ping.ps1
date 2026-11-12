#Requires -Version 5.1
<#
.SYNOPSIS
  PC1 -> PC2 协作通道连通性探测（A2A / MCP）。
.DESCRIPTION
  缺省目标取 config.peer.a2aUrl（-UseMcp 时取 config.peer.mcpUrl）；为空表示 PC2 未上线 -> 退出 3。
  端口口径（-UseMcp 相关）：目标 URL 里的**显式端口**优先（如 http://h:18790/mcp）；URL 省略端口时
  用该通道的配置端口兜底（-UseMcp 用 mcp.port，否则 a2a.port）；-Port 显式给出时以 -Port 为准。
  打印里会写明"探测哪个 port、取自哪个配置项"，便于对账（以前 -UseMcp 只换了 host，端口仍是 7310，
  判据会骗人：对端 MCP 端口没开也可能显示 7310 的结果）。
  目标先过网段守卫：解析到 192.168.1.0/24（两板私有链路，同 IP/MAC）立刻拒绝 -> 退出 4。
  否则 TcpClient 800ms 探端口，可选 GET AgentCard 打印对端身份（防连错机器）。
.EXAMPLE
  powershell.exe -NoProfile -File pc1_pc2_ping.ps1
  powershell.exe -NoProfile -File pc1_pc2_ping.ps1 -Peer http://127.0.0.1:7311
  powershell.exe -NoProfile -File pc1_pc2_ping.ps1 -Peer 127.0.0.1 -Port 18791 -UseMcp
.NOTES
  退出码: 0 连通 / 2 通道不可用(转 issue 轮询) / 3 对端未上线(peer 空) / 4 命中 192.168.1.0/24 网段守卫
#>
[CmdletBinding()]
param(
    [string]$Peer = '',
    [int]$Port = 7310,
    [switch]$UseMcp,
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'

$toolsDir = $PSScriptRoot
if (-not $toolsDir) { $toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$bundle = Split-Path -Parent $toolsDir

function Write-Usage {
    Write-Output '用法: pc1_pc2_ping.ps1 [-Peer <url|ip>] [-Port 7310] [-UseMcp] [-ConfigPath <cfg>]'
    Write-Output '  缺省 -Peer 取 config.peer.a2aUrl（-UseMcp 时取 config.peer.mcpUrl），为空即 PC2 未上线'
    Write-Output '  退出码: 0 连通 / 2 通道不可用(转 issue 轮询) / 3 对端未上线 / 4 命中 192.168.1.0/24 网段守卫'
}

function Get-EffectiveConfigPath {
    param([string]$Path, [string]$BundleRoot)
    if ($Path) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Resolve-Path -LiteralPath $Path).Path }
        return ''
    }
    $primary = Join-Path (Join-Path $BundleRoot 'state') 'config.json'
    if (Test-Path -LiteralPath $primary -PathType Leaf) { return (Resolve-Path -LiteralPath $primary).Path }
    $alternate = Join-Path (Join-Path $BundleRoot 'state') 'config.example.json'
    if (Test-Path -LiteralPath $alternate -PathType Leaf) {
        Write-Host ('[INFO] 未找到 state\config.json，回落使用: ' + $alternate)
        return (Resolve-Path -LiteralPath $alternate).Path
    }
    return ''
}

function Import-CollabConfig {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $text = $text.TrimStart([char]0xFEFF)
    return ($text | ConvertFrom-Json)
}

# 把 AgentCard 里的 name 归一化成"角色名"用于和 config 的 peer.name 比较。
# 服务端拼出来的卡片名是 "team-link-<role>"（如 team-link-pc1），而 config 的 peer.name 按协议只写
# 角色名（如 pc1）。字面比较必然误报 WARN（等于这条"可能连错机器"的告警永远失效）。
# 这里的口径选"剥掉卡片名的 team-link- 前缀（大小写不敏感）"；等价做法是把 peer.name 补成
# "team-link-<peer.name>" 再比，选剥前缀是因为角色名是协议字段、前缀是服务端实现细节。
# 配置侧若也带 team-link- 前缀，同样会被剥掉，不会又变成不等。
function ConvertTo-PeerRoleName {
    param([string]$Name)
    if (-not $Name) { return '' }
    $n = ([string]$Name).Trim()
    if ($n -imatch '^team-link-(.+)$') { return [string]$Matches[1] }
    return $n
}

function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 800)
    if (-not $HostName -or $Port -le 0) { return $false }
    $client = New-Object System.Net.Sockets.TcpClient
    $ok = $false
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            try {
                $client.EndConnect($async)
                $ok = [bool]$client.Connected
            } catch { $ok = $false }
        }
    } catch { $ok = $false }
    finally {
        try { $client.Close() } catch { }
    }
    return $ok
}

function Get-LogDirectory {
    param($Config, [string]$BundleRoot)
    $dir = 'logs'
    if ($Config -and ($Config.PSObject.Properties.Name -contains 'logDir') -and $Config.logDir) { $dir = [string]$Config.logDir }
    if ([System.IO.Path]::IsPathRooted($dir)) { return $dir }
    return (Join-Path $BundleRoot $dir)
}

function Add-JsonLogLine {
    param([string]$LogDir, [string]$FileName, [string]$Line)
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $file = Join-Path $LogDir $FileName
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($file, $Line + [Environment]::NewLine, $enc)
    return $file
}

$noArgs = ($PSBoundParameters.Count -eq 0)
if ($noArgs) { Write-Usage }

$requestedConfigPath = $ConfigPath
$configPath = Get-EffectiveConfigPath -Path $ConfigPath -BundleRoot $bundle
if (-not $configPath) {
    if ($requestedConfigPath) { Write-Output ('FAIL: 配置缺失（-ConfigPath 指向的文件不存在: ' + $requestedConfigPath + '）') } else { Write-Output 'FAIL: 配置缺失（state\config.json 与 state\config.example.json 均不存在）' }
    exit 3
}

try {
    $cfg = Import-CollabConfig -Path $configPath
} catch {
    Write-Output ('FAIL: 配置解析失败: ' + $_.Exception.Message)
    exit 3
}

$fbRepo = ''
$fbLabel = ''
$fbPoll = 0
if ($cfg.fallback) {
    if ($cfg.fallback.repo) { $fbRepo = [string]$cfg.fallback.repo }
    if ($cfg.fallback.issueLabel) { $fbLabel = [string]$cfg.fallback.issueLabel }
    if ($cfg.fallback.pollSeconds) { $fbPoll = [int]$cfg.fallback.pollSeconds }
}

$peerName = ''
$peerA2aUrl = ''
$peerMcpUrl = ''
if ($cfg.peer) {
    if ($cfg.peer.name) { $peerName = [string]$cfg.peer.name }
    if ($cfg.peer.a2aUrl) { $peerA2aUrl = [string]$cfg.peer.a2aUrl }
    if ($cfg.peer.mcpUrl) { $peerMcpUrl = [string]$cfg.peer.mcpUrl }
}

# 各通道的"本机配置端口"：目标 URL 不写端口时用它兜底（打印里也会带上，便于对账）
$a2aCfgPort = 7310
$mcpCfgPort = 18790
if ($cfg.a2a -and $cfg.a2a.port) { $a2aCfgPort = [int]$cfg.a2a.port }
if ($cfg.mcp -and $cfg.mcp.port) { $mcpCfgPort = [int]$cfg.mcp.port }
if ($UseMcp) { $cfgPort = $mcpCfgPort; $cfgPortField = 'mcp.port' }
else { $cfgPort = $a2aCfgPort; $cfgPortField = 'a2a.port' }

$logDirPath = Get-LogDirectory -Config $cfg -BundleRoot $bundle
$fallbackLine = '[FALLBACK] 协作通道不可用 → 转 issue 轮询：repo=' + $fbRepo + ' label=' + $fbLabel + ' 每 ' + $fbPoll + ' 秒'

$target = $Peer
$sourceField = 'peer.a2aUrl'
if ($UseMcp) { $sourceField = 'peer.mcpUrl' }
$hostSource = $sourceField
if (-not $target) {
    if ($UseMcp) { $target = $peerMcpUrl } else { $target = $peerA2aUrl }
} else {
    $hostSource = '-Peer 参数'
}

if (-not $target) {
    Write-Output ('[PEER] PC2 未上线（' + $sourceField + ' 空）→ 先走 issue 轮询')
    Write-Output $fallbackLine
    $logObj = [ordered]@{
        time   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        role   = [string]$cfg.role
        target = ''
        port   = 0
        ok     = $false
        reason = ('对端未上线: ' + $sourceField + ' 为空')
    }
    [void](Add-JsonLogLine -LogDir $logDirPath -FileName 'peer_ping.log' -Line ($logObj | ConvertTo-Json -Compress -Depth 6))
    Write-Output ('FAIL: ' + $sourceField + ' 为空，PC2 未上线，协作走 issue 轮询')
    exit 3
}

# 解析目标：可能是 URL（带路径、带/不带端口）或 host[:port]
$targetHost = $target
$urlPort = 0
if ($target -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
    try {
        $uri = New-Object System.Uri($target)
        $targetHost = $uri.Host
        # IsDefaultPort=true 表示 URL 里**没写**端口（http->80），不能当成"探 80"，必须走配置兜底
        if (-not $uri.IsDefaultPort) { $urlPort = $uri.Port }
    } catch {
        Write-Output ('FAIL: 目标地址解析失败（' + $target + '）: ' + $_.Exception.Message)
        exit 3
    }
} elseif ($target -match ':([0-9]+)$') {
    $urlPort = [int]$Matches[1]
    $targetHost = $target.Substring(0, $target.Length - $Matches[0].Length)
}

# 端口优先级：显式 -Port > 目标里的显式端口 > 该通道配置端口（-UseMcp 用 mcp.port，否则 a2a.port）
if ($PSBoundParameters.ContainsKey('Port')) {
    $targetPort = $Port
    $portSource = '-Port 参数'
} elseif ($urlPort -gt 0) {
    $targetPort = $urlPort
    $portSource = $hostSource + ' 里的显式端口'
} else {
    $targetPort = $cfgPort
    $portSource = $cfgPortField + ' 配置（目标 URL 未写端口）'
}

$resolvedIps = @()
if ($targetHost -match '^[0-9]{1,3}(\.[0-9]{1,3}){3}$') {
    $resolvedIps = @($targetHost)
} else {
    try {
        $resolvedIps = @([System.Net.Dns]::GetHostAddresses($targetHost) | ForEach-Object { $_.IPAddressToString })
    } catch {
        $resolvedIps = @()
    }
}

$guardHits = @($resolvedIps | Where-Object { $_ -like '192.168.1.*' })
if ($guardHits.Count -gt 0) {
    Write-Output ('[GUARD] 目标 ' + $targetHost + ' 解析到 ' + ($guardHits -join ',') + '：192.168.1.0/24 是两板（PC1/PC2 板卡）私有链路，同 IP/MAC，禁止在此网段做协作探测，可能打错板子。')
    Write-Output 'FAIL: 已命中 192.168.1.0/24 网段守卫并拒绝执行'
    exit 4
}

Write-Output ('[PEER] 目标: ' + $targetHost + ':' + $targetPort + '（host 来自 ' + $hostSource + '）')
Write-Output ('[PEER] 探测端口: ' + $targetPort + ' 取自 ' + $portSource + '；兜底口径 ' + $cfgPortField + '=' + $cfgPort + '（-UseMcp=' + [string][bool]$UseMcp + '）')
if ($resolvedIps.Count -gt 0) { Write-Output ('[PEER] 解析 IP: ' + ($resolvedIps -join ',')) }

$ok = Test-TcpPort -HostName $targetHost -Port $targetPort
if (-not $ok) {
    Write-Output $fallbackLine
    $logObj = [ordered]@{
        time   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        role   = [string]$cfg.role
        target = $targetHost
        port   = $targetPort
        ok     = $false
        reason = 'TCP 探测失败（800ms 超时或拒绝连接）'
    }
    [void](Add-JsonLogLine -LogDir $logDirPath -FileName 'peer_ping.log' -Line ($logObj | ConvertTo-Json -Compress -Depth 6))
    Write-Output ('FAIL: ' + $targetHost + ':' + $targetPort + ' 不可连，协作通道不可用，转 issue 轮询')
    exit 2
}

Write-Output ('PASS: TCP ' + $targetHost + ':' + $targetPort + ' 可连')

if ($UseMcp) {
    Write-Output '[PEER] MCP 端口可用；对端身份需 MCP initialize 确认（本脚本只做端口级探测）'
    Write-Output ('PASS: MCP 通道 ' + $targetHost + ':' + $targetPort + ' 可用')
    exit 0
}

$cardPath = '/.well-known/agent.json'
if ($cfg.a2a -and $cfg.a2a.agentCardPath) { $cardPath = [string]$cfg.a2a.agentCardPath }
$cardUrl = 'http://' + $targetHost + ':' + $targetPort + $cardPath
$card = $null
$cardText = ''
try {
    $request = [System.Net.HttpWebRequest]::Create($cardUrl)
    $request.Method = 'GET'
    $request.Accept = 'application/json'
    $request.Timeout = 3000
    $request.ReadWriteTimeout = 3000
    $request.KeepAlive = $false
    $request.ServicePoint.Expect100Continue = $false
    $response = $request.GetResponse()
    $contentType = [string]$response.ContentType
    $cardEncoding = [System.Text.Encoding]::UTF8
    if ($contentType -match 'charset=([^;\s]+)') {
        try { $cardEncoding = [System.Text.Encoding]::GetEncoding($Matches[1].Trim('"')) } catch { $cardEncoding = [System.Text.Encoding]::UTF8 }
    }
    $stream = $response.GetResponseStream()
    $ms = New-Object System.IO.MemoryStream
    $buffer = New-Object byte[] 8192
    while ($true) {
        $n = $stream.Read($buffer, 0, $buffer.Length)
        if ($n -le 0) { break }
        $ms.Write($buffer, 0, $n)
    }
    $stream.Close()
    $response.Close()
    $cardText = $cardEncoding.GetString($ms.ToArray()).TrimStart([char]0xFEFF)
    $ms.Close()
} catch {
    $cardText = ''
}
if ($cardText) {
    try { $card = $cardText | ConvertFrom-Json } catch { $card = $null }
}


if ($card -eq $null) {
    Write-Output ('[WARN] AgentCard 取不到（' + $cardUrl + '）：对端身份未确认，注意别连错机器')
    Write-Output ('PASS: A2A 端口 ' + $targetHost + ':' + $targetPort + ' 可连（AgentCard 未取到）')
    exit 0
}

$cardName = ''
if ($card.name) { $cardName = [string]$card.name }
$cardDesc = ''
if ($card.description) { $cardDesc = [string]$card.description }
$skillNames = @()
if ($card.skills) { $skillNames = @($card.skills | ForEach-Object { [string]$_.name }) }

Write-Output ('[PEER] 对端身份: name=' + $cardName + ' description=' + $cardDesc)
if ($skillNames.Count -gt 0) {
    Write-Output ('[PEER] 对端 skills: ' + ($skillNames -join ', '))
} else {
    Write-Output '[PEER] 对端 skills: (空)'
}
if ($peerName -and $cardName) {
    # 归一化后再比：卡片名 "team-link-pc1" 与 peer.name "pc1" 是同一台机器，不应报警。
    $cardRole = ConvertTo-PeerRoleName $cardName
    $peerRole = ConvertTo-PeerRoleName $peerName
    if ($cardRole -ne $peerRole) {
        Write-Output ('[WARN] 对端 name=' + $cardName + ' 与配置 peer.name=' + $peerName + ' 不一致，可能连错机器')
    }
}
Write-Output ('PASS: A2A 通道 ' + $targetHost + ':' + $targetPort + ' 可用，对端=' + $cardName)
exit 0
