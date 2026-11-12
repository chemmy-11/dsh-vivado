#Requires -Version 5.1
<#
.SYNOPSIS
  team-link 协作通道状态检查（A2A / MCP）。
.DESCRIPTION
  用 System.Net.Sockets.TcpClient 以 800ms 超时探测 A2A 与 MCP 端口。
  任一通道不可用 -> 打印 [FALLBACK] 一行并追加一行 JSON 到 <logDir>\collab_status.log。
.EXAMPLE
  powershell.exe -NoProfile -File collab_status.ps1
  powershell.exe -NoProfile -File collab_status.ps1 -ConfigPath ..\state\config.test.json
  powershell.exe -NoProfile -File collab_status.ps1 -Json
.NOTES
  退出码: 0 全通 / 2 降级(转 issue 轮询) / 3 配置缺失
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$toolsDir = $PSScriptRoot
if (-not $toolsDir) { $toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$bundle = Split-Path -Parent $toolsDir

function Write-Usage {
    Write-Output '用法: collab_status.ps1 [-ConfigPath <cfg>] [-Json]'
    Write-Output '  缺省 -ConfigPath 取 <bundle>\state\config.json；不存在时回落 state\config.example.json'
    Write-Output '  -Json 只输出一行 JSON（机器判定见 verdict 字段）'
    Write-Output '  退出码: 0 双通道可用 / 2 降级(转 issue 轮询) / 3 配置缺失'
}

function Get-EffectiveConfigPath {
    param([string]$Path, [string]$BundleRoot, [switch]$Quiet)
    if ($Path) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Resolve-Path -LiteralPath $Path).Path }
        return ''
    }
    $primary = Join-Path (Join-Path $BundleRoot 'state') 'config.json'
    if (Test-Path -LiteralPath $primary -PathType Leaf) { return (Resolve-Path -LiteralPath $primary).Path }
    $alternate = Join-Path (Join-Path $BundleRoot 'state') 'config.example.json'
    if (Test-Path -LiteralPath $alternate -PathType Leaf) {
        if (-not $Quiet) { Write-Host ('[INFO] 未找到 state\config.json，回落使用: ' + $alternate) }
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

function Format-EndpointUrl {
    param([string]$HostName, [int]$Port, [string]$Path)
    $url = 'http://' + $HostName + ':' + $Port
    if (-not $Path) { return $url + '/' }
    if (-not $Path.StartsWith('/')) { $Path = '/' + $Path }
    return $url + $Path
}

function Show-PeerValue {
    param([string]$Value)
    if (-not $Value) { return '未上线' }
    return $Value
}

function Get-RecentLogText {
    param([string]$LogDir)
    if (-not (Test-Path -LiteralPath $LogDir)) { return '无日志目录' }
    $files = @(Get-ChildItem -LiteralPath $LogDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) { return '无日志文件' }
    return ($files[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + '  (' + $files[0].Name + ')')
}

# 只报 token **是否存在**（以及字节数），绝不读取/打印值本身。
# 这条纪律的原因：token 是本机与对端互认的唯一凭据，一旦进了终端历史、日志、issue 正文就等于泄露。
# 路径解析与服务端保持一致：绝对路径原样用；相对路径先按 <bundle> 再按配置文件目录解析。
function Get-TokenPresence {
    param(
        [string]$RelativeOrAbsolute,
        [string]$BundleRoot,
        [string]$ConfigDir
    )
    $result = [ordered]@{ path = ''; present = $false; bytes = 0 }
    if (-not $RelativeOrAbsolute) { return $result }
    $candidates = @()
    if ([System.IO.Path]::IsPathRooted($RelativeOrAbsolute)) {
        $candidates += $RelativeOrAbsolute
    } else {
        $candidates += (Join-Path $BundleRoot $RelativeOrAbsolute)
        $candidates += (Join-Path $ConfigDir $RelativeOrAbsolute)
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
            if ($item -and (-not $item.PSIsContainer)) {
                $result.path = $candidate
                $result.present = $true
                $result.bytes = [int]$item.Length
                return $result
            }
        }
    }
    $result.path = $candidates[0]
    return $result
}

$noArgs = ($PSBoundParameters.Count -eq 0)
if ($noArgs -and (-not $Json)) { Write-Usage }

$requestedConfigPath = $ConfigPath
$configPath = Get-EffectiveConfigPath -Path $ConfigPath -BundleRoot $bundle -Quiet:$Json
if (-not $configPath) {
    if ($Json) {
        $missingReason = '配置缺失: state\config.json 与 state\config.example.json 均不存在'
        if ($requestedConfigPath) { $missingReason = '配置缺失: -ConfigPath 指向的文件不存在: ' + $requestedConfigPath }
        $bad = [ordered]@{ time = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'); role = ''; a2a = $null; mcp = $null; verdict = 'FAIL'; reason = $missingReason }
        Write-Output ($bad | ConvertTo-Json -Compress -Depth 6)
    } else {
        if (-not $noArgs) { Write-Usage }
        if ($requestedConfigPath) { Write-Output ('FAIL: 配置缺失（-ConfigPath 指向的文件不存在: ' + $requestedConfigPath + '）') } else { Write-Output 'FAIL: 配置缺失（state\config.json 与 state\config.example.json 均不存在）' }
    }
    exit 3
}

try {
    $cfg = Import-CollabConfig -Path $configPath
} catch {
    $msg = '配置解析失败: ' + $_.Exception.Message
    if ($Json) {
        $bad = [ordered]@{ time = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'); role = ''; a2a = $null; mcp = $null; verdict = 'FAIL'; reason = $msg }
        Write-Output ($bad | ConvertTo-Json -Compress -Depth 6)
    } else {
        if (-not $noArgs) { Write-Usage }
        Write-Output ('FAIL: ' + $msg)
    }
    exit 3
}

$role = ''
if ($cfg.role) { $role = [string]$cfg.role }
$machine = ''
if ($cfg.machine) { $machine = [string]$cfg.machine }

$a2aHost = '127.0.0.1'
$a2aPort = 0
$a2aPath = '/'
if ($cfg.a2a) {
    if ($cfg.a2a.host) { $a2aHost = [string]$cfg.a2a.host }
    if ($cfg.a2a.port) { $a2aPort = [int]$cfg.a2a.port }
    if ($cfg.a2a.path) { $a2aPath = [string]$cfg.a2a.path }
}

$mcpHost = '127.0.0.1'
$mcpPort = 0
$mcpPath = '/mcp'
if ($cfg.mcp) {
    if ($cfg.mcp.host) { $mcpHost = [string]$cfg.mcp.host }
    if ($cfg.mcp.port) { $mcpPort = [int]$cfg.mcp.port }
    if ($cfg.mcp.path) { $mcpPath = [string]$cfg.mcp.path }
}

$a2aUrl = Format-EndpointUrl -HostName $a2aHost -Port $a2aPort -Path $a2aPath
$mcpUrl = Format-EndpointUrl -HostName $mcpHost -Port $mcpPort -Path $mcpPath

$peerWlan = ''
$peerTailscale = ''
$peerA2aUrl = ''
$peerMcpUrl = ''
$peerName = ''
if ($cfg.peer) {
    if ($cfg.peer.name) { $peerName = [string]$cfg.peer.name }
    if ($cfg.peer.wlan) { $peerWlan = [string]$cfg.peer.wlan }
    if ($cfg.peer.tailscale) { $peerTailscale = [string]$cfg.peer.tailscale }
    if ($cfg.peer.a2aUrl) { $peerA2aUrl = [string]$cfg.peer.a2aUrl }
    if ($cfg.peer.mcpUrl) { $peerMcpUrl = [string]$cfg.peer.mcpUrl }
}

$fbMode = 'issue-poll'
$fbRepo = ''
$fbLabel = ''
$fbPoll = 0
if ($cfg.fallback) {
    if ($cfg.fallback.mode) { $fbMode = [string]$cfg.fallback.mode }
    if ($cfg.fallback.repo) { $fbRepo = [string]$cfg.fallback.repo }
    if ($cfg.fallback.issueLabel) { $fbLabel = [string]$cfg.fallback.issueLabel }
    if ($cfg.fallback.pollSeconds) { $fbPoll = [int]$cfg.fallback.pollSeconds }
}

$logDirPath = Get-LogDirectory -Config $cfg -BundleRoot $bundle
$lastLog = Get-RecentLogText -LogDir $logDirPath

# 四个 token 槽位的存在性（只报 present/bytes，绝不打印值）。
$tokenDecl = @()
if ($cfg.a2a -and $cfg.a2a.tokenFile) { $tokenDecl += [pscustomobject]@{ slot = 'a2a'; file = [string]$cfg.a2a.tokenFile } }
if ($cfg.mcp -and $cfg.mcp.tokenFile) { $tokenDecl += [pscustomobject]@{ slot = 'mcp'; file = [string]$cfg.mcp.tokenFile } }
if ($cfg.peer -and $cfg.peer.a2a -and $cfg.peer.a2a.tokenFile) { $tokenDecl += [pscustomobject]@{ slot = 'peer-a2a'; file = [string]$cfg.peer.a2a.tokenFile } }
if ($cfg.peer -and $cfg.peer.mcp -and $cfg.peer.mcp.tokenFile) { $tokenDecl += [pscustomobject]@{ slot = 'peer-mcp'; file = [string]$cfg.peer.mcp.tokenFile } }
$configDir = Split-Path -Parent $configPath
$tokenFacts = [ordered]@{}
$tokenTexts = @()
foreach ($decl in $tokenDecl) {
    $presence = Get-TokenPresence -RelativeOrAbsolute $decl.file -BundleRoot $bundle -ConfigDir $configDir
    $tokenFacts[$decl.slot] = [ordered]@{ present = $presence.present; bytes = $presence.bytes; path = $presence.path }
    if ($presence.present) { $tokenTexts += ($decl.slot + '=present(' + $presence.bytes + 'B)') }
    else { $tokenTexts += ($decl.slot + '=MISSING') }
}
if ($tokenTexts.Count -eq 0) { $tokenTexts += '配置未声明任何 tokenFile' }

$a2aOk = Test-TcpPort -HostName $a2aHost -Port $a2aPort
$mcpOk = Test-TcpPort -HostName $mcpHost -Port $mcpPort

$a2aState = 'DOWN: 不可用'
if ($a2aOk) { $a2aState = 'OK: 可用' }
$mcpState = 'DOWN: 不可用'
if ($mcpOk) { $mcpState = 'OK: 可用' }

$degraded = (-not $a2aOk) -or (-not $mcpOk)
$reasonParts = @()
if (-not $a2aOk) { $reasonParts += ('A2A 端口 ' + $a2aPort + ' 不可用') }
if (-not $mcpOk) { $reasonParts += ('MCP 端口 ' + $mcpPort + ' 不可用') }
$reason = ($reasonParts -join '; ')

$nowText = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('==== team-link 协作通道状态 ====')
$lines.Add('配置文件 : ' + $configPath)
$lines.Add('角色     : ' + $role + ' (' + $machine + ')')
$lines.Add('A2A      : ' + $a2aUrl + '  [端口 ' + $a2aPort + '] ' + $a2aState)
$lines.Add('MCP      : ' + $mcpUrl + '  [端口 ' + $mcpPort + '] ' + $mcpState)
$lines.Add('对端     : name=' + (Show-PeerValue $peerName) + ' wlan=' + (Show-PeerValue $peerWlan) + ' tailscale=' + (Show-PeerValue $peerTailscale) + ' a2aUrl=' + (Show-PeerValue $peerA2aUrl) + ' mcpUrl=' + (Show-PeerValue $peerMcpUrl))
$lines.Add('回退     : mode=' + $fbMode + ' repo=' + $fbRepo + ' label=' + $fbLabel + ' 轮询间隔=' + $fbPoll + ' 秒')
$lines.Add('token    : ' + ($tokenTexts -join ' ') + '   （只报存在性，绝不打印值）')
$lines.Add('最近日志 : ' + $lastLog)

$fallbackLine = '[FALLBACK] 协作通道不可用 → 转 issue 轮询：repo=' + $fbRepo + ' label=' + $fbLabel + ' 每 ' + $fbPoll + ' 秒'

$verdict = 'PASS'
$exitCode = 0
if ($degraded) {
    $verdict = 'FAIL'
    $exitCode = 2
    $lines.Add($fallbackLine)
    $lines.Add('FAIL: 协作通道降级（A2A/MCP 至少一路不可用），已转 issue 轮询')
} else {
    $lines.Add('PASS: A2A 与 MCP 端口均可连，通道正常')
}

if ($degraded) {
    $logObj = [ordered]@{
        time   = $nowText
        role   = $role
        a2a    = [ordered]@{ url = $a2aUrl; port = $a2aPort; ok = $a2aOk }
        mcp    = [ordered]@{ url = $mcpUrl; port = $mcpPort; ok = $mcpOk }
        reason = $reason
    }
    $logFile = Add-JsonLogLine -LogDir $logDirPath -FileName 'collab_status.log' -Line ($logObj | ConvertTo-Json -Compress -Depth 6)
    if (-not $Json) { $lines.Add('日志     : 已追加 ' + $logFile) }
}

if ($Json) {
    $outObj = [ordered]@{
        time       = $nowText
        role       = $role
        configPath = $configPath
        a2a        = [ordered]@{ url = $a2aUrl; port = $a2aPort; ok = $a2aOk }
        mcp        = [ordered]@{ url = $mcpUrl; port = $mcpPort; ok = $mcpOk }
        peer       = [ordered]@{ name = $peerName; wlan = $peerWlan; tailscale = $peerTailscale; a2aUrl = $peerA2aUrl; mcpUrl = $peerMcpUrl }
        fallback   = [ordered]@{ mode = $fbMode; repo = $fbRepo; label = $fbLabel; pollSeconds = $fbPoll }
        tokens     = $tokenFacts
        lastLog    = $lastLog
        verdict    = $verdict
        reason     = $reason
    }
    Write-Output ($outObj | ConvertTo-Json -Compress -Depth 8)
} else {
    foreach ($l in $lines) { Write-Output $l }
}

exit $exitCode
