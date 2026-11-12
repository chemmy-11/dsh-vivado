#Requires -Version 5.1
<#
.SYNOPSIS
  从对端 MCP 拉取证据文件，并在本地重算 SHA256 与服务端值比对。

.DESCRIPTION
  流程: TCP 探端口 -> MCP initialize -> notifications/initialized -> tools/call sha256_file
        -> tools/call read_file -> 落盘到 -OutDir -> 本地 Get-FileHash 重算 SHA256
        -> 与服务端值比对 -> 一致则写/更新 manifest.json；不一致删本地文件并退出 5。

  通道不可用（TCP 探端口失败 / MCP 握手失败）打印 [FALLBACK]（转 issue 轮询）并退出 2，
  绝不静默失败：不落盘、不写 manifest 时一定伴随非 0 退出码与非空日志。

.PARAMETER ConfigPath
  配置文件路径。缺省 <BUNDLE>\state\config.json；该文件不存在时回落 state\config.example.json 并提示。

.PARAMETER Peer
  对端 MCP endpoint，形如 http://127.0.0.1:18790/mcp。缺省取 config.peer.mcpUrl；为空表示 PC2 未上线。

.PARAMETER Remote
  要拉取的证据列表，逗号分隔，每项 <root>:<relPath>，如 evidence:report.txt,delivery:x.bin。
  未知 root 或格式非法一律报中文原因并退出 1（通道不可用优先，此时退出 2）。

.PARAMETER OutDir
  落盘目录。缺省 config.evidenceDir\inbox；相对路径按 <BUNDLE> 解析。

.EXAMPLE
  powershell.exe -NoProfile -File evidence_pull.ps1 -Remote evidence:report.txt

.EXAMPLE
  powershell.exe -NoProfile -File evidence_pull.ps1 -Peer http://127.0.0.1:18790/mcp -Remote evidence:a.txt,delivery:b.bin

.EXAMPLE
  powershell.exe -NoProfile -File evidence_pull.ps1 -ConfigPath ..\state\config.json -Remote state:collab_status.log -OutDir D:\FPGA\prj\project_12\out\inbox

.NOTES
  退出码: 0 成功 / 1 参数错误(含未知 root) / 2 通道不可用或 peer 未配置(转 issue 轮询)
          3 配置缺失或不可解析 / 5 SHA256 不一致(已删本地文件)
  日志: config.logDir\evidence_pull.log（UTF-8 无 BOM，每行带 ISO 时间）
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$Peer = '',
    [string]$Remote = '',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:Bundle = $PSScriptRoot
if (-not $script:Bundle) { $script:Bundle = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:Bundle = Split-Path -Parent $script:Bundle
$script:Config = $null
$script:LogFile = ''
$script:ManifestName = 'manifest.json'
$script:RpcId = 0

function Get-IsoNow {
    return (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
}

function Test-HasProp {
    param($Node, [string]$Name)
    if ($null -eq $Node) { return $false }
    if ($Node -is [System.Collections.IDictionary]) { return $Node.Contains($Name) }
    return (@($Node.PSObject.Properties.Name) -contains $Name)
}

function Get-NodeValue {
    param($Node, [string]$Name)
    if (-not (Test-HasProp -Node $Node -Name $Name)) { return $null }
    return $Node.$Name
}

function Write-Usage {
    Write-Host '用法: evidence_pull.ps1 -ConfigPath <cfg> [-Peer <mcpUrl>] -Remote <root>:<relPath>[,<root>:<relPath>...] [-OutDir <dir>]'
    Write-Host '  -ConfigPath  缺省 <BUNDLE>\state\config.json（不存在则回落 state\config.example.json）'
    Write-Host '  -Peer        缺省取 config.peer.mcpUrl；为空表示 PC2 未上线，转 issue 轮询'
    Write-Host '  -Remote      root:relPath，逗号分隔可传多个，例如 evidence:report.txt,delivery:x.bin'
    Write-Host '  -OutDir      缺省 config.evidenceDir\inbox；同目录写/更新 manifest.json'
    Write-Host '示例: powershell.exe -NoProfile -File evidence_pull.ps1 -Remote evidence:report.txt'
    Write-Host '示例: powershell.exe -NoProfile -File evidence_pull.ps1 -Peer http://127.0.0.1:18790/mcp -Remote evidence:a.txt,delivery:b.bin'
    Write-Host '退出码: 0 成功 / 1 参数错误(含未知 root) / 2 通道不可用或 peer 未配置(转 issue 轮询) / 3 配置缺失 / 5 SHA256 不一致'
}

function Add-LogLine {
    param([string]$Level, [string]$Message)
    if (-not $script:LogFile) { return }
    $line = (Get-IsoNow) + ' [' + $Level + '] ' + $Message
    try {
        $dir = Split-Path -Parent $script:LogFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, $script:Utf8NoBom)
    } catch { }
}

function Get-LogDirectory {
    param($Config)
    $dir = 'logs'
    $v = Get-NodeValue -Node $Config -Name 'logDir'
    if ($v) { $dir = [string]$v }
    if ([System.IO.Path]::IsPathRooted($dir)) { return $dir }
    return (Join-Path $script:Bundle $dir)
}

function Get-EffectiveConfigPath {
    param([string]$Path)
    if ($Path) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Resolve-Path -LiteralPath $Path).Path }
        return ''
    }
    $stateDir = Join-Path $script:Bundle 'state'
    $primary = Join-Path $stateDir 'config.json'
    if (Test-Path -LiteralPath $primary -PathType Leaf) { return (Resolve-Path -LiteralPath $primary).Path }
    $alternate = Join-Path $stateDir 'config.example.json'
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
    if (-not $text.Trim()) { throw '配置文件为空' }
    return ($text | ConvertFrom-Json)
}

function Get-ConfigNode {
    param($Config, [string]$Name)
    if (-not (Test-HasProp -Node $Config -Name $Name)) { return $null }
    return $Config.$Name
}

function Write-FallbackLine {
    param($Config)
    $repo = '<repo>'
    $label = '<label>'
    $poll = 900
    $fb = Get-ConfigNode -Config $Config -Name 'fallback'
    if ($fb) {
        $v = Get-NodeValue -Node $fb -Name 'repo'
        if ($v) { $repo = [string]$v }
        $v = Get-NodeValue -Node $fb -Name 'issueLabel'
        if ($v) { $label = [string]$v }
        $v = Get-NodeValue -Node $fb -Name 'pollSeconds'
        if ($null -ne $v -and ([string]$v)) { $poll = [int]$v }
    }
    Write-Host ('[FALLBACK] 协作通道不可用 → 转 issue 轮询：repo=' + $repo + ' label=' + $label + ' 每 ' + $poll + ' 秒')
    Add-LogLine -Level 'WARN' -Message ('[FALLBACK] repo=' + $repo + ' label=' + $label + ' pollSeconds=' + $poll)
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

function Get-PeerEndpoint {
    param([string]$Url)
    $u = [string]$Url
    if (-not $u) { return $null }
    if ($u -notmatch '^[A-Za-z][A-Za-z0-9+.\-]*://') { $u = 'http://' + $u }
    try { $uri = New-Object System.Uri($u) } catch { return $null }
    if (-not $uri.Host) { return $null }
    $port = $uri.Port
    if ($port -le 0) { $port = 80 }
    $pathPart = $uri.AbsolutePath
    if (-not $pathPart) { $pathPart = '/mcp' }
    return [pscustomobject]@{
        Host = $uri.Host
        Port = $port
        Url = ($uri.GetLeftPart([System.UriPartial]::Authority) + $pathPart)
    }
}

function Resolve-TokenPath {
    param([string]$TokenFile)
    if (-not $TokenFile) { return '' }
    if ([System.IO.Path]::IsPathRooted($TokenFile)) { return $TokenFile }
    $candBundle = Join-Path $script:Bundle $TokenFile
    if (Test-Path -LiteralPath $candBundle -PathType Leaf) { return $candBundle }
    return (Join-Path (Join-Path $script:Bundle 'state') $TokenFile)
}

function Get-PeerToken {
    param($Config)
    # 出站 token 候选链：先「对端 token」（peer.mcp.tokenFile），再回落自身 mcp.tokenFile。
    # 两端各自持有自己的入站 token、只各自持有对方的 token，因此不需要共享同一份凭据。
    # 判定依据是【文件是否存在】，不是路径是否配置：对端 token 路径已配但文件没放时，
    # 必须继续回落，否则会把「还没交换 token」误报成「服务器拒绝」。
    $candidates = New-Object System.Collections.ArrayList
    $peerNode = Get-ConfigNode -Config $Config -Name 'peer'
    if ($peerNode) {
        $peerMcpNode = Get-NodeValue -Node $peerNode -Name 'mcp'
        if ($peerMcpNode) {
            $pv = Get-NodeValue -Node $peerMcpNode -Name 'tokenFile'
            if ($pv) { [void]$candidates.Add([string]$pv) }
        }
        $pv2 = Get-NodeValue -Node $peerNode -Name 'mcpTokenFile'
        if ($pv2) { [void]$candidates.Add([string]$pv2) }
    }
    $mcpNode = Get-ConfigNode -Config $Config -Name 'mcp'
    if ($mcpNode) {
        $v = Get-NodeValue -Node $mcpNode -Name 'tokenFile'
        if ($v) { [void]$candidates.Add([string]$v) }
    }
    [void]$candidates.Add('state/mcp.token')
    foreach ($cand in $candidates) {
        $path = Resolve-TokenPath -TokenFile $cand
        if (-not $path) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $raw = ''
        try { $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) } catch { continue }
        $token = $raw.TrimStart([char]0xFEFF).Trim()
        if (-not $token) { continue }
        return [pscustomobject]@{ Token = $token; File = $path }
    }
    return $null
}
function Convert-RpcText {
    param([string]$Text)
    if (-not $Text) { return $null }
    $trimmed = $Text.Trim()
    if (-not $trimmed) { return $null }
    if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
        try { return ($trimmed | ConvertFrom-Json) } catch { return $null }
    }
    $candidate = ''
    foreach ($rawLine in $trimmed.Split([char]10)) {
        $line = $rawLine.Trim()
        if ($line.StartsWith('data:')) {
            $payload = $line.Substring(5).Trim()
            if ($payload.StartsWith('{') -or $payload.StartsWith('[')) { $candidate = $payload }
        }
    }
    if ($candidate) {
        try { return ($candidate | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Get-ShortText {
    param([string]$Text)
    if (-not $Text) { return '(空响应)' }
    $t = $Text.Trim()
    if (-not $t) { return '(空响应)' }
    if ($t.Length -gt 400) { $t = $t.Substring(0, 400) + '...' }
    return $t
}

function Invoke-McpRpc {
    param(
        [string]$Url,
        [int]$Id = 0,
        [string]$Method = '',
        $Params = $null,
        [string]$Token = '',
        [switch]$Notify,
        [int]$TimeoutMs = 10000
    )
    $msg = [ordered]@{ jsonrpc = '2.0'; method = $Method }
    if (-not $Notify) { $msg.id = $Id }
    if ($null -ne $Params) { $msg.params = $Params }
    $json = ($msg | ConvertTo-Json -Compress -Depth 12)

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'POST'
    $request.ContentType = 'application/json; charset=utf-8'
    $request.Accept = 'application/json, text/event-stream'
    $request.Timeout = $TimeoutMs
    $request.ReadWriteTimeout = $TimeoutMs
    $request.KeepAlive = $false
    $request.Proxy = $null
    $request.ServicePoint.Expect100Continue = $false
    if ($Token) { $request.Headers['Authorization'] = 'Bearer ' + $Token }

    $payload = $script:Utf8NoBom.GetBytes($json)
    $request.ContentLength = $payload.Length
    $reqStream = $request.GetRequestStream()
    try { $reqStream.Write($payload, 0, $payload.Length) } finally { $reqStream.Close() }

    $response = $null
    $status = 0
    try {
        $response = $request.GetResponse()
        $status = [int]$response.StatusCode
    } catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($null -eq $response) { throw }
        $status = [int]$response.StatusCode
    }
    $text = ''
    try {
        $respStream = $response.GetResponseStream()
        if ($null -ne $respStream) {
            $reader = New-Object System.IO.StreamReader($respStream, [System.Text.Encoding]::UTF8)
            try { $text = $reader.ReadToEnd() } finally { $reader.Close() }
        }
    } finally {
        try { $response.Close() } catch { }
    }
    return [pscustomobject]@{ Status = $status; Text = $text; Json = (Convert-RpcText -Text $text) }
}

function Invoke-McpInitialize {
    param([string]$Url, [string]$Token)
    $script:RpcId = $script:RpcId + 1
    $params = [ordered]@{
        protocolVersion = '2024-11-05'
        capabilities = [ordered]@{}
        clientInfo = [ordered]@{ name = 'evidence_pull.ps1'; version = '1.0.0' }
    }
    $resp = Invoke-McpRpc -Url $Url -Id $script:RpcId -Method 'initialize' -Params $params -Token $Token
    if ($resp.Status -ne 200) { throw ('initialize 返回 HTTP ' + $resp.Status + '：' + (Get-ShortText -Text $resp.Text)) }
    if ($null -eq $resp.Json) { throw ('initialize 响应不是合法 JSON：' + (Get-ShortText -Text $resp.Text)) }
    if (Test-HasProp -Node $resp.Json -Name 'error') { throw ('initialize 返回 JSON-RPC 错误：' + (Get-ShortText -Text $resp.Text)) }
    $result = Get-NodeValue -Node $resp.Json -Name 'result'
    if ($null -eq $result) { throw 'initialize 响应缺少 result 字段' }
    $null = Invoke-McpRpc -Url $Url -Method 'notifications/initialized' -Token $Token -Notify
    return $result
}

function Invoke-McpTool {
    param([string]$Url, [string]$Token, [string]$Name, $Arguments)
    $script:RpcId = $script:RpcId + 1
    $params = [ordered]@{ name = $Name; arguments = $Arguments }
    $resp = Invoke-McpRpc -Url $Url -Id $script:RpcId -Method 'tools/call' -Params $params -Token $Token
    if ($resp.Status -ne 200) { throw ('tools/call ' + $Name + ' 返回 HTTP ' + $resp.Status + '：' + (Get-ShortText -Text $resp.Text)) }
    if ($null -eq $resp.Json) { throw ('tools/call ' + $Name + ' 响应不是合法 JSON：' + (Get-ShortText -Text $resp.Text)) }
    if (Test-HasProp -Node $resp.Json -Name 'error') { throw ('tools/call ' + $Name + ' 返回 JSON-RPC 错误：' + (Get-ShortText -Text $resp.Text)) }
    $result = Get-NodeValue -Node $resp.Json -Name 'result'
    if ($null -eq $result) { throw ('tools/call ' + $Name + ' 响应缺少 result 字段') }
    $isError = Get-NodeValue -Node $result -Name 'isError'
    if ($isError -eq $true) {
        $detail = ''
        $content = Get-NodeValue -Node $result -Name 'content'
        if ($content) {
            foreach ($c in @($content)) {
                $t = Get-NodeValue -Node $c -Name 'text'
                if ($t) { $detail = $detail + [string]$t }
            }
        }
        throw ('工具 ' + $Name + ' 返回错误：' + (Get-ShortText -Text $detail))
    }
    return $result
}

function Get-ToolPayload {
    param($Result)
    if ($null -eq $Result) { return $null }
    $structured = Get-NodeValue -Node $Result -Name 'structuredContent'
    if ($null -ne $structured) { return $structured }
    $texts = @()
    $content = Get-NodeValue -Node $Result -Name 'content'
    if ($content) {
        foreach ($c in @($content)) {
            $t = Get-NodeValue -Node $c -Name 'text'
            if ($t) { $texts += [string]$t }
        }
    }
    if ($texts.Count -eq 0) { return $null }
    $joined = ($texts -join '')
    $trimmed = $joined.Trim()
    if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
        try { return ($trimmed | ConvertFrom-Json) } catch { }
    }
    return $joined
}

function Get-ShaFromPayload {
    param($Payload)
    if ($null -eq $Payload) { return '' }
    if ($Payload -is [string]) {
        $m = [regex]::Match($Payload.ToLower(), '[0-9a-f]{64}')
        if ($m.Success) { return $m.Value }
        return ''
    }
    foreach ($n in @('sha256', 'hash', 'digest', 'checksum')) {
        $v = Get-NodeValue -Node $Payload -Name $n
        if ($v) {
            $s = ([string]$v) -replace '^sha256:', ''
            return $s.Trim().ToLower()
        }
    }
    return ''
}

function Get-ContentFromPayload {
    param($Payload)
    if ($null -eq $Payload) { return $null }
    if ($Payload -is [string]) { return $Payload }
    foreach ($n in @('contentBase64', 'base64', 'dataBase64')) {
        $v = Get-NodeValue -Node $Payload -Name $n
        if ($v) { return [System.Convert]::FromBase64String([string]$v) }
    }
    $encoding = ''
    $encNode = Get-NodeValue -Node $Payload -Name 'encoding'
    if ($encNode) { $encoding = [string]$encNode }
    foreach ($n in @('content', 'text', 'data')) {
        $v = Get-NodeValue -Node $Payload -Name $n
        if ($null -ne $v) {
            if ($encoding -match 'base64') { return [System.Convert]::FromBase64String([string]$v) }
            return [string]$v
        }
    }
    return $null
}

function Parse-RemoteList {
    param([string]$Spec)
    $items = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    foreach ($raw in ([string]$Spec).Split(',')) {
        $piece = $raw.Trim()
        if (-not $piece) { continue }
        $idx = $piece.IndexOf(':')
        if ($idx -lt 1 -or $idx -eq ($piece.Length - 1)) {
            [void]$errors.Add('非法 -Remote 项 "' + $piece + '"：应为 <root>:<relPath>（冒号不能缺、两侧不能为空）')
            continue
        }
        $rootId = $piece.Substring(0, $idx).Trim()
        $rel = $piece.Substring($idx + 1).Trim()
        if (-not $rootId -or -not $rel) {
            [void]$errors.Add('非法 -Remote 项 "' + $piece + '"：root 或 relPath 为空')
            continue
        }
        if ($rel.Contains('..')) {
            [void]$errors.Add('非法 -Remote 项 "' + $piece + '"：relPath 不能包含 ..')
            continue
        }
        if ($rel.StartsWith('/') -or $rel.StartsWith('\') -or $rel -match '^[A-Za-z]:') {
            [void]$errors.Add('非法 -Remote 项 "' + $piece + '"：relPath 必须是 root 内相对路径，不能是绝对路径')
            continue
        }
        [void]$items.Add([pscustomobject]@{ Root = $rootId; Path = $rel })
    }
    if (($items.Count -eq 0) -and ($errors.Count -eq 0)) {
        [void]$errors.Add('未提供有效 -Remote（示例: -Remote evidence:report.txt）')
    }
    return [pscustomobject]@{ Items = $items; Errors = $errors }
}

function Get-RelativeSegments {
    param([string]$RelPath)
    $segments = New-Object System.Collections.ArrayList
    foreach ($p in ([string]$RelPath).Split([char[]]@('\', '/'))) {
        if (-not $p) { continue }
        if ($p -eq '.') { continue }
        [void]$segments.Add($p)
    }
    return $segments
}

function Get-EvidenceTargetPath {
    param([string]$BaseDir, $Segments)
    $path = $BaseDir
    foreach ($s in $Segments) { $path = Join-Path $path $s }
    return $path
}

function Write-EvidenceFile {
    param([string]$FullPath, $Content)
    $dir = Split-Path -Parent $FullPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bytes = $null
    if ($Content -is [byte[]]) { $bytes = $Content } else { $bytes = $script:Utf8NoBom.GetBytes([string]$Content) }
    [System.IO.File]::WriteAllBytes($FullPath, $bytes)
    return $bytes.Length
}

function Get-LocalSha256 {
    param([string]$FullPath)
    return (Get-FileHash -LiteralPath $FullPath -Algorithm SHA256).Hash.ToLower()
}

function Read-Manifest {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $text = $text.TrimStart([char]0xFEFF)
        if (-not $text.Trim()) { return $null }
        return ($text | ConvertFrom-Json)
    } catch { return $null }
}

function Get-ManifestItemTime {
    param($Manifest, [string]$Source, [string]$Sha)
    if (-not $Manifest) { return '' }
    $items = Get-NodeValue -Node $Manifest -Name 'items'
    if (-not $items) { return '' }
    foreach ($it in @($items)) {
        if ($null -eq $it) { continue }
        $src = Get-NodeValue -Node $it -Name 'source'
        if (-not $src) { continue }
        if ([string]$src -ne $Source) { continue }
        $sha = Get-NodeValue -Node $it -Name 'sha256'
        if ($sha -and ([string]$sha -ne $Sha)) { continue }
        $t = Get-NodeValue -Node $it -Name 'time'
        if ($t) { return [string]$t }
        return ''
    }
    return ''
}

function Merge-ManifestItems {
    param($Existing, $Updates)
    $map = New-Object System.Collections.Specialized.OrderedDictionary
    $existingItems = Get-NodeValue -Node $Existing -Name 'items'
    if ($existingItems) {
        foreach ($it in @($existingItems)) {
            if ($null -eq $it) { continue }
            $src = Get-NodeValue -Node $it -Name 'source'
            if (-not $src) { continue }
            $src = [string]$src
            $map[$src] = [ordered]@{
                source = $src
                file   = [string](Get-NodeValue -Node $it -Name 'file')
                bytes  = [int64](Get-NodeValue -Node $it -Name 'bytes')
                sha256 = [string](Get-NodeValue -Node $it -Name 'sha256')
                time   = [string](Get-NodeValue -Node $it -Name 'time')
            }
        }
    }
    foreach ($u in @($Updates)) {
        if ($null -eq $u) { continue }
        $map[[string]$u.source] = $u
    }
    return @($map.Values)
}

function Write-Manifest {
    param([string]$Path, [string]$Dir, $Items)
    $obj = [ordered]@{
        dir     = $Dir
        updated = (Get-IsoNow)
        items   = @($Items)
    }
    $json = ($obj | ConvertTo-Json -Depth 8)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $script:Utf8NoBom)
}

function Invoke-Main {
    param(
        [string]$ConfigPathArg,
        [string]$PeerArg,
        [string]$RemoteArg,
        [string]$OutDirArg,
        [int]$BoundCount
    )

    if ($BoundCount -eq 0) {
        Write-Usage
        Write-Host '[FAIL] 未提供任何参数：至少需要 -Remote <root>:<relPath>'
        return 2
    }

    $cfgPath = Get-EffectiveConfigPath -Path $ConfigPathArg
    if (-not $cfgPath) {
        Write-Host ('[FAIL] 配置缺失：' + (Join-Path (Join-Path $script:Bundle 'state') 'config.json') + ' 与 config.example.json 都不存在')
        return 3
    }
    try {
        $script:Config = Import-CollabConfig -Path $cfgPath
    } catch {
        Write-Host ('[FAIL] 配置不可解析: ' + $cfgPath + ' -> ' + $_.Exception.Message)
        return 3
    }
    $script:LogFile = Join-Path (Get-LogDirectory -Config $script:Config) 'evidence_pull.log'
    Add-LogLine -Level 'INFO' -Message ('启动 config=' + $cfgPath)

    $outDir = $OutDirArg
    if (-not $outDir) {
        $baseDir = [string](Get-NodeValue -Node $script:Config -Name 'evidenceDir')
        if (-not $baseDir) { $baseDir = $script:Bundle }
        $outDir = Join-Path $baseDir 'inbox'
    } elseif (-not [System.IO.Path]::IsPathRooted($outDir)) {
        $outDir = Join-Path $script:Bundle $outDir
    }
    if (-not [System.IO.Path]::IsPathRooted($outDir)) { $outDir = Join-Path (Get-Location).Path $outDir }
    $outDir = [System.IO.Path]::GetFullPath($outDir)
    Write-Host ('[OUT] 落盘目录: ' + $outDir)

    $peerUrl = [string]$PeerArg
    if (-not $peerUrl) {
        $peerNode = Get-ConfigNode -Config $script:Config -Name 'peer'
        $v = Get-NodeValue -Node $peerNode -Name 'mcpUrl'
        if ($v) { $peerUrl = [string]$v }
    }
    $peerUrl = ([string]$peerUrl).Trim()
    if (-not $peerUrl) {
        Write-Host '[PEER] PC2 未上线（peer.mcpUrl 空）→ 无法用 MCP 拉证据，先走 issue 轮询'
        Add-LogLine -Level 'WARN' -Message 'peer.mcpUrl 为空，无法 MCP 拉取'
        Write-FallbackLine -Config $script:Config
        return 2
    }

    $endpoint = Get-PeerEndpoint -Url $peerUrl
    if (-not $endpoint) {
        Write-Host ('[FAIL] -Peer 不是合法 URL: ' + $peerUrl)
        Add-LogLine -Level 'FAIL' -Message ('-Peer 非法: ' + $peerUrl)
        Write-FallbackLine -Config $script:Config
        return 2
    }
    Write-Host ('[PEER] ' + $endpoint.Url)

    $tokenInfo = Get-PeerToken -Config $script:Config
    if (-not $tokenInfo) {
        Write-Host '[FAIL] 未取到 token（优先 peer.mcp.tokenFile，回落 mcp.tokenFile；文件不存在或内容为空）→ 不发起无认证请求'
        Add-LogLine -Level 'WARN' -Message '未取到 token，拒绝无认证请求'
        Write-FallbackLine -Config $script:Config
        return 2
    }
    Write-Host ('[TOKEN] 使用 token 文件: ' + $tokenInfo.File)

    $parsed = Parse-RemoteList -Spec $RemoteArg

    if (-not (Test-TcpPort -HostName $endpoint.Host -Port $endpoint.Port -TimeoutMs 800)) {
        Write-Host ('[TCP] 探端口失败: ' + $endpoint.Host + ':' + $endpoint.Port + '（800ms 超时）')
        Add-LogLine -Level 'WARN' -Message ('TCP 探端口失败 ' + $endpoint.Host + ':' + $endpoint.Port)
        Write-FallbackLine -Config $script:Config
        return 2
    }
    Write-Host ('[TCP] 端口可达: ' + $endpoint.Host + ':' + $endpoint.Port)

    if ($parsed.Errors.Count -gt 0) {
        foreach ($e in $parsed.Errors) {
            Write-Host ('[FAIL] ' + $e)
            Add-LogLine -Level 'FAIL' -Message $e
        }
        return 1
    }

    try {
        $initResult = Invoke-McpInitialize -Url $endpoint.Url -Token $tokenInfo.Token
    } catch {
        Write-Host ('[MCP] 握手失败: ' + $_.Exception.Message)
        Add-LogLine -Level 'WARN' -Message ('MCP 握手失败: ' + $_.Exception.Message)
        Write-FallbackLine -Config $script:Config
        return 2
    }
    $serverInfo = Get-NodeValue -Node $initResult -Name 'serverInfo'
    $serverName = [string](Get-NodeValue -Node $serverInfo -Name 'name')
    $serverVer = [string](Get-NodeValue -Node $serverInfo -Name 'version')
    Write-Host ('[MCP] initialize 成功 server=' + $serverName + ' version=' + $serverVer)
    Add-LogLine -Level 'INFO' -Message ('initialize 成功 server=' + $serverName + ' ' + $serverVer)

    $knownRoots = New-Object System.Collections.ArrayList
    try {
        $rootsResult = Invoke-McpTool -Url $endpoint.Url -Token $tokenInfo.Token -Name 'list_roots' -Arguments ([ordered]@{})
        $rootsPayload = Get-ToolPayload -Result $rootsResult
        $rootsArr = Get-NodeValue -Node $rootsPayload -Name 'roots'
        if ($rootsArr) {
            foreach ($r in @($rootsArr)) {
                $rid = Get-NodeValue -Node $r -Name 'id'
                if ($rid) { [void]$knownRoots.Add([string]$rid) }
            }
        }
        Write-Host ('[ROOTS] 对端 root: ' + ($knownRoots -join ', '))
    } catch {
        Write-Host ('[WARN] list_roots 不可用，跳过 root 存在性预检: ' + $_.Exception.Message)
        Add-LogLine -Level 'WARN' -Message ('list_roots 不可用: ' + $_.Exception.Message)
    }

    if ($knownRoots.Count -gt 0) {
        $bad = @()
        foreach ($item in $parsed.Items) {
            if (-not ($knownRoots -contains $item.Root)) { $bad += $item.Root }
        }
        if ($bad.Count -gt 0) {
            $uniq = @($bad | Select-Object -Unique)
            Write-Host ('[FAIL] 未知 root: ' + ($uniq -join ', ') + '（对端可用 root: ' + ($knownRoots -join ', ') + '）')
            Add-LogLine -Level 'FAIL' -Message ('未知 root: ' + ($uniq -join ','))
            return 1
        }
    }

    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    $manifestPath = Join-Path $outDir $script:ManifestName
    $manifest = Read-Manifest -Path $manifestPath
    $updates = New-Object System.Collections.ArrayList
    $newCount = 0
    $skipCount = 0

    foreach ($item in $parsed.Items) {
        $source = $item.Root + ':' + $item.Path
        $segments = Get-RelativeSegments -RelPath $item.Path
        if ($segments.Count -eq 0) {
            Write-Host ('[FAIL] 非法 -Remote 项 "' + $source + '"：relPath 解析后为空')
            Add-LogLine -Level 'FAIL' -Message ('relPath 为空: ' + $source)
            return 1
        }
        $targetPath = Get-EvidenceTargetPath -BaseDir $outDir -Segments $segments
        $relFile = (@($segments) -join '/')

        $shaResult = $null
        try {
            $shaResult = Invoke-McpTool -Url $endpoint.Url -Token $tokenInfo.Token -Name 'sha256_file' -Arguments ([ordered]@{ root = $item.Root; path = $item.Path })
        } catch {
            Write-Host ('[FAIL] sha256_file 失败 ' + $source + ' -> ' + $_.Exception.Message)
            Add-LogLine -Level 'FAIL' -Message ('sha256_file 失败 ' + $source + ' -> ' + $_.Exception.Message)
            return 1
        }
        $shaPayload = Get-ToolPayload -Result $shaResult
        $serverSha = Get-ShaFromPayload -Payload $shaPayload
        $serverBytes = Get-NodeValue -Node $shaPayload -Name 'bytes'
        if (-not $serverSha) {
            Write-Host ('[FAIL] 服务端未返回 sha256: ' + $source)
            Add-LogLine -Level 'FAIL' -Message ('服务端未返回 sha256: ' + $source)
            return 1
        }
        Write-Host ('[SHA] ' + $source + ' 服务端 sha256=' + $serverSha + ' bytes=' + [string]$serverBytes)

        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            $localSha = Get-LocalSha256 -FullPath $targetPath
            if ($localSha -eq $serverSha) {
                $skipCount++
                Write-Host ('[SKIP] 本地已存在且内容一致，跳过: ' + $relFile)
                Add-LogLine -Level 'INFO' -Message ('SKIP ' + $source + ' sha256=' + $localSha)
                $keepTime = Get-ManifestItemTime -Manifest $manifest -Source $source -Sha $serverSha
                if (-not $keepTime) { $keepTime = Get-IsoNow }
                $localBytes = (Get-Item -LiteralPath $targetPath).Length
                [void]$updates.Add([ordered]@{
                    source = $source
                    file   = $relFile
                    bytes  = [int64]$localBytes
                    sha256 = $serverSha
                    time   = $keepTime
                })
                continue
            }
            Write-Host ('[DIFF] 本地已存在但 SHA 不同（本地=' + $localSha + '，服务端=' + $serverSha + '），将重写: ' + $relFile)
        }

        $readPayload = $null
        try {
            $readResult = Invoke-McpTool -Url $endpoint.Url -Token $tokenInfo.Token -Name 'read_file' -Arguments ([ordered]@{ root = $item.Root; path = $item.Path })
            $readPayload = Get-ToolPayload -Result $readResult
        } catch {
            Write-Host ('[FAIL] read_file 失败 ' + $source + ' -> ' + $_.Exception.Message)
            Add-LogLine -Level 'FAIL' -Message ('read_file 失败 ' + $source + ' -> ' + $_.Exception.Message)
            return 1
        }
        if ($null -eq $readPayload) {
            Write-Host ('[FAIL] read_file 未返回内容: ' + $source)
            Add-LogLine -Level 'FAIL' -Message ('read_file 未返回内容: ' + $source)
            return 1
        }
        $readSha = Get-ShaFromPayload -Payload $readPayload
        if ($readSha -and ($readSha -ne $serverSha)) {
            Write-Host ('[FAIL] 服务端自相矛盾：sha256_file=' + $serverSha + ' read_file=' + $readSha + ' -> ' + $source)
            Add-LogLine -Level 'FAIL' -Message ('服务端 sha256 自相矛盾 ' + $source)
            return 5
        }
        $content = Get-ContentFromPayload -Payload $readPayload
        if ($null -eq $content) {
            Write-Host ('[FAIL] read_file 内容字段缺失: ' + $source)
            Add-LogLine -Level 'FAIL' -Message ('read_file 内容缺失: ' + $source)
            return 1
        }

        $writtenBytes = 0
        try {
            $writtenBytes = Write-EvidenceFile -FullPath $targetPath -Content $content
        } catch {
            Write-Host ('[FAIL] 落盘失败: ' + $targetPath + ' -> ' + $_.Exception.Message)
            Add-LogLine -Level 'FAIL' -Message ('落盘失败 ' + $targetPath + ' -> ' + $_.Exception.Message)
            return 1
        }

        $localSha = Get-LocalSha256 -FullPath $targetPath
        if ($localSha -ne $serverSha) {
            try { Remove-Item -LiteralPath $targetPath -Force } catch { }
            Write-Host ('[FAIL] SHA256 不一致：服务端=' + $serverSha + ' 本地=' + $localSha + ' -> 已删除本地文件 ' + $targetPath)
            Add-LogLine -Level 'FAIL' -Message ('SHA256 不一致 服务端=' + $serverSha + ' 本地=' + $localSha + ' 已删除 ' + $targetPath)
            return 5
        }
        $newCount++
        Write-Host ('[VERIFY] 本地与服务端 SHA 一致: ' + $relFile + ' sha256=' + $localSha + ' bytes=' + $writtenBytes)
        Add-LogLine -Level 'INFO' -Message ('PULL ' + $source + ' file=' + $relFile + ' bytes=' + $writtenBytes + ' sha256=' + $localSha)

        [void]$updates.Add([ordered]@{
            source = $source
            file   = $relFile
            bytes  = [int64]$writtenBytes
            sha256 = $localSha
            time   = (Get-IsoNow)
        })
    }

    $merged = Merge-ManifestItems -Existing $manifest -Updates @($updates)
    try {
        Write-Manifest -Path $manifestPath -Dir $outDir -Items $merged
    } catch {
        Write-Host ('[FAIL] manifest 写入失败: ' + $manifestPath + ' -> ' + $_.Exception.Message)
        Add-LogLine -Level 'FAIL' -Message ('manifest 写入失败: ' + $_.Exception.Message)
        return 1
    }
    Write-Host ('[MANIFEST] ' + $manifestPath)

    Write-Host ('PASS: 证据拉取完成 新增/更新=' + $newCount + ' 跳过=' + $skipCount + ' 失败=0')
    Add-LogLine -Level 'PASS' -Message ('新增/更新=' + $newCount + ' 跳过=' + $skipCount + ' 失败=0 dir=' + $outDir)
    return 0
}

$exitCode = 1
try {
    $mainOut = @(Invoke-Main -ConfigPathArg $ConfigPath -PeerArg $Peer -RemoteArg $Remote -OutDirArg $OutDir -BoundCount $PSBoundParameters.Count)
    $exitCode = 1
    if ($mainOut.Count -gt 0) {
        $lastItem = $mainOut[$mainOut.Count - 1]
        if ($lastItem -is [int]) { $exitCode = [int]$lastItem }
    }
} catch {
    Write-Host ('[FAIL] 未预期错误: ' + $_.Exception.Message)
    Add-LogLine -Level 'FAIL' -Message ('未预期错误: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage)
    $exitCode = 1
}
exit $exitCode
