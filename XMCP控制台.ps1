# XMCP 反代控制台 —— 单窗口，取代原来的三个 bat
# 用法：双击桌面「XMCP 反代工具」快捷方式（由 XMCP.Relay.exe 启动器隐藏拉起本脚本）；命令行排障可直接跑 XMCP控制台.bat
# 行为：读 mcp-relay.config.json -> 自动启动/检测连通性 -> 按钮随状态变化
#       通：按钮显示 "1. 最小化（缩到右下角托盘）"，点一下立即缩托盘，零等待
#       不通：按钮置灰不可点，必须先点 "重启代理"（= 停一次 + 起一次 + 防火墙同步）
# 2. 退出关闭：停止反代并退出
# 说明：配置不热加载，"配置内容"页里改完点"重启代理"才会保存并重启生效。
# 顶部 tab：状态 / 配置格式 / 配置内容 / 运行日志
# 可选：powershell -File XMCP控制台.ps1 -AutoTray   （检测为通则直接缩到托盘，不弹窗口）

param([switch]$AutoTray, [switch]$BootstrapOnly)

$ErrorActionPreference = 'Stop'

$root     = $PSScriptRoot
$cfgPath  = Join-Path $root 'mcp-relay.config.json'
$pidFile  = Join-Path $root 'mcp-relay.pid'
$startPs1 = Join-Path $root 'start-mcp-relay.ps1'
$stopPs1  = Join-Path $root 'stop-mcp-relay.ps1'
$restartPs1 = Join-Path $root 'restart-mcp-relay.ps1'
$uiLog    = Join-Path $root 'xmcp-console.log'
$traceLog = Join-Path $root 'mcp-relay-trace.log'
$uiSnap   = Join-Path $root 'xmcp-console-status.txt'
$pywExe   = 'C:\Python314\pythonw.exe'
if (-not (Test-Path -LiteralPath $pywExe)) {
    # 换机器时别写死路径：先去 PATH 找 pythonw，再退 python
    try { $pywExe = (Get-Command pythonw.exe -ErrorAction Stop).Source } catch {
        try { $pywExe = (Get-Command python.exe -ErrorAction Stop).Source } catch { $pywExe = '' }
    }
}
# 系统工具一律走绝对路径：控制台若从精简 PATH 的宿主拉起来（例如被别的自动化程序
# Start-Process），PATH 里没有 System32，裸写 curl.exe / netstat / powershell.exe 会直接
# 报“不是命令”，连通性检查会误报 0/2 不通。
$sys32     = Join-Path $env:SystemRoot 'System32'
$curlExe   = Join-Path $sys32 'curl.exe'
$netstatExe = Join-Path $sys32 'netstat.exe'
$psExe     = Join-Path $sys32 'WindowsPowerShell\v1.0\powershell.exe'
# 原生启动器 exe（内嵌 xmcp.ico）：快捷方式/任务栏固定项指向它，图标与分组才不回退到 powershell 默认图标。
$launcherExe = Join-Path $root 'XMCP.Relay.exe'

# 隐藏宿主控制台黑窗：控制台进程仍在（托盘、后台探测/启停任务都靠它），只是窗口不显示。
# 快捷方式直连 powershell.exe、不经 cmd/bat；这里再 P/Invoke 把控制台窗口藏掉作双保险。
if (-not $BootstrapOnly) {
    try {
        $consoleSig = @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
        $consoleUtil = Add-Type -MemberDefinition $consoleSig -Name XmcpConsoleUtil -Namespace Win32 -PassThru
        $consoleHwnd = $consoleUtil::GetConsoleWindow()
        if ($consoleHwnd -ne [IntPtr]::Zero) { [void]$consoleUtil::ShowWindow($consoleHwnd, 0) }  # 0 = SW_HIDE
    } catch { }
}

# 快捷方式：.lnk 里只能存绝对路径，所以它一旦跟着目录被拷到别的盘，就还指着老地方。
# 对策是「每次启动都自检 + 就地改写」：
#   1. 目录里那一份（XMCP 反代工具.lnk，X 图标）：首次运行由控制台自举生成，
#      之后启动发现 Target 不是本目录的 powershell 快捷方式就重写 —— 复制到新盘、先点一次即自动纠正；
#   2. 桌面那一份：存在则跟着最近一次运行的程序目录自动对齐。
function Write-LocalShortcut {
    param([string]$LnkPath, [string]$Label)
    try {
        $ps1 = Join-Path $root 'XMCP控制台.ps1'
        if (-not (Test-Path -LiteralPath $ps1)) { return }
        $ico = Join-Path $root 'xmcp.ico'
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($LnkPath)
        if (Test-Path -LiteralPath $launcherExe) {
            # 首选原生启动器：图标内嵌在 exe 里，任务栏固定项认 exe 身份，不回退 powershell 图标。
            $s.TargetPath = $launcherExe
            $s.Arguments = ''
            $s.IconLocation = $launcherExe + ',0'
        } else {
            # 兜底：启动器缺失时直连 powershell 隐藏启动。
            $s.TargetPath = $psExe
            $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ps1 + '"'
            if (Test-Path -LiteralPath $ico) { $s.IconLocation = $ico + ',0' }
        }
        $s.WorkingDirectory = $root
        $s.Description = 'XMCP 反代工具'
        $s.WindowStyle = 7
        $s.Save()
        Write-UiLog ($Label + ' shortcut written -> ' + $root)
    } catch { }
}

function Repair-Shortcut {
    try {
        $ps1 = Join-Path $root 'XMCP控制台.ps1'
        if (-not (Test-Path -LiteralPath $ps1)) { return }
        # 期望目标：优先启动器 exe；exe 缺失才回退 powershell 直连。
        $wantTarget = if (Test-Path -LiteralPath $launcherExe) { $launcherExe } else { $psExe }
        function Test-ShortcutOk($sc) {
            if ($sc.TargetPath -ne $wantTarget) { return $false }
            if ($wantTarget -eq $psExe) { return ($sc.Arguments -like ('*' + $ps1 + '*')) }
            return $true
        }
        # 目录里那份：没有就建，有但指错就重写
        $local = Join-Path $root 'XMCP 反代工具.lnk'
        $okLocal = $false
        if (Test-Path -LiteralPath $local) {
            $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($local)
            $okLocal = Test-ShortcutOk $sc
        }
        if (-not $okLocal) { Write-LocalShortcut -LnkPath $local -Label 'local' }
        # 桌面那份：只修正已存在的，不擅自往桌面新建
        $desktop = [Environment]::GetFolderPath('Desktop')
        if ($desktop) {
            $lnk = Join-Path $desktop 'XMCP 反代工具.lnk'
            if (Test-Path -LiteralPath $lnk) {
                $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
                $okDesktop = Test-ShortcutOk $sc
                if (-not $okDesktop) { Write-LocalShortcut -LnkPath $lnk -Label 'desktop' }
            }
        }
    } catch { }
}
$cmdExe    = Join-Path $sys32 'cmd.exe'
if (-not (Test-Path -LiteralPath $curlExe))    { $curlExe = 'curl.exe' }
if (-not (Test-Path -LiteralPath $netstatExe)) { $netstatExe = 'netstat.exe' }
if (-not (Test-Path -LiteralPath $psExe))      { $psExe = 'powershell.exe' }
if (-not (Test-Path -LiteralPath $cmdExe))     { $cmdExe = 'cmd.exe' }

. (Join-Path $root 'relay-config.ps1')

$script:ExitNow    = $false
$script:lastVerdict = '未检测'
$script:trayHint    = 'XMCP 反代'
$script:healthy     = $false
$script:sw          = [Diagnostics.Stopwatch]::StartNew()
$script:singleton   = $null
$script:bgPs        = $null
$script:bgHandle    = $null
$script:taskTimer   = $null
# MCP 探针的后台任务（与反代启停互不干扰）
$script:probePs     = $null
$script:probeHandle = $null
$script:probeTimer  = $null
$script:probeHostInfo = @{ Variant = ''; Note = ''; Skip = ''; Suggest = '' }
$script:relayTaskMode = 'Start'
$script:autoTrayPending = $false
$script:configDirty = $false
$script:suppressDirty = $false   # 程序化改写编辑框内容时，别把 dirty 置真

function Write-UiLog {
    param([string]$Text)
    try {
        $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $Text
        [IO.File]::AppendAllText($uiLog, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

# 批次分隔线（与反代日志同款 60 个等号，带时间戳前缀，便于界面按批次分组显示）
function Write-UiLogSep {
    try {
        $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + ('=' * 60)
        [IO.File]::AppendAllText($uiLog, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

# ===== 首次运行自举：配置文件不在就按本机环境生成一份 =====
# 别人把这个目录拷到任意路径、任意机器，双击快捷方式就能跑：配置、日志、快捷方式全部就地长出来。
function Get-DefaultListenAddress {
    # 优先挑一块能出去的真实网卡地址；VMware/Hyper-V 虚拟网卡（192.168.110.x 之类）排后面。
    # 都没有就退回 0.0.0.0（监听全部网卡），至少保证能用。
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' -and $_.PrefixOrigin -ne 'WellKnown' }
        $real = $ips | Where-Object { $_.InterfaceAlias -notmatch 'VMware|Hyper-V|VirtualBox|Loopback|vEthernet|TAP|VPN' } | Select-Object -First 1
        if ($real) { return $real.IPAddress }
        if ($ips) { return ($ips | Select-Object -First 1).IPAddress }
    } catch { }
    return '0.0.0.0'
}

function Initialize-FirstRun {
    try {
        if (Test-Path -LiteralPath $cfgPath) { return }
        $addr = Get-DefaultListenAddress
        # 网段：把最后一段换成 .0/24，给防火墙「只对本网段放行」用
        $subnet = '192.168.0.0/24'
        if ($addr -match '^(\d+)\.(\d+)\.(\d+)\.(\d+)$') {
            $subnet = "$($Matches[1]).$($Matches[2]).$($Matches[3]).0/24"
        }
        $text = @"
{
  "_说明": "本文件由控制台首次运行时自动生成。每条 proxy = 一组「对外监听 listen → 上游 target」。listen 可写多个地址；改完重启代理即生效，防火墙规则由启动脚本按本文件自动同步。支持 # 注释。",
  "log": {
    "file": "mcp-relay.log",
    "max_bytes": 5242880
  },
  "firewall": {
    "enabled": true,
    "local_address": "$addr",
    "remote_address": "$subnet",
    "_说明": "启动时自动比对：为每个监听在该网卡地址上的端口建放行规则，其余端口用端口段黑名单封掉（有差异才弹一次 UAC）。"
  },
  "proxies": [
    {
      "name": "xterminal-mcp",
      "enabled": true,
      "listen": [
        "$addr:12335"
      ],
      "target": "127.0.0.1:12335",
      "rewrite_host": true,
      "upstream_timeout": 3600
    },
    {
      "name": "示例-第二个服务",
      "enabled": false,
      "listen": [
        "$addr:8088"
      ],
      "target": "127.0.0.1:8080",
      "rewrite_host": false,
      "upstream_timeout": 60
    }
  ]
}
"@
        [IO.File]::WriteAllText($cfgPath, ($text -replace "`r`n", "`n" -replace "`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
        Write-UiLog ('config bootstrapped (listen=' + $addr + ', subnet=' + $subnet + ')')
    } catch { Write-UiLog ('config bootstrap failed: ' + $_.Exception.Message) }
}

Initialize-FirstRun

# -BootstrapOnly：只做首次运行的准备工作（生成配置 + 生成目录内快捷方式）就退出，
# 不弹窗口、不启动反代、不碰防火墙。分享给别人的包里可用它做静默初始化。
if ($BootstrapOnly) {
    try {
        Repair-Shortcut
        Write-UiLog 'bootstrap only -> done'
        Write-Output ('  配置: ' + $cfgPath)
        Write-Output ('  快捷方式: ' + (Join-Path $root 'XMCP 反代工具.lnk'))
    } catch { }
    exit 0
}

function Get-RelayProcess {
    try {
        if (-not (Test-Path -LiteralPath $pidFile)) { return $null }
        $txt = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction Stop)
        if ($null -eq $txt) { return $null }
        $txt = $txt.Trim()
        if (-not $txt) { return $null }
        return (Get-Process -Id ([int]$txt) -ErrorAction SilentlyContinue)
    } catch { return $null }
}

function Invoke-RelayScript {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "找不到脚本: $Path" }
    $out = & $psExe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $Path 2>&1 | Out-String
    if ($null -eq $out) { return '' }
    return ([string]$out).Trim()
}

function Test-Endpoint {
    param([string]$Url)
    # 单次探测（3 秒上限）。原来失败会再等 800ms 重试一次，冷启动时两个地址都失败，
    # 直接把 UI 线程拖住 5 秒多，窗口看起来像"卡死"，这里去掉重试。
    try { $code = (& $curlExe -sS -o NUL -w '%{http_code}' --max-time 3 $Url 2>$null) } catch { $code = '' }
    $code = ([string]$code).Trim()
    if (-not $code) { return '000' }
    return $code
}

function Get-HostPort {
    # 从 "http://192.168.1.20:27123/" 或 target "127.0.0.1:27123/mcp" 里抠出 host 与 port
    param([string]$Text)
    $r = @{ Host = ''; Port = '' }
    if (-not $Text) { return $r }
    $t = ($Text.Trim() -replace '^\w+://', '')
    $t = ($t -split '/')[0]
    if ($t -match '^([^:]+)(?::(\d+))?') {
        $r.Host = $Matches[1]
        $r.Port = if ($Matches[2]) { $Matches[2] } else { '80' }
    }
    return $r
}

function Test-PortListening {
    # 端口/地址是否在 TCP LISTENING；给了 HostName 就按地址精确匹配（通配绑定 0.0.0.0/:: 也算应答）
    # 只按端口匹配会把"反代自己监听在 192.168.x.x:12335"误当成"上游 127.0.0.1:12335 在监听"
    param([string]$Port, [string]$NsText, [string]$HostName = '')
    if (-not $Port -or -not $NsText) { return $false }
    $rx = [regex]('(?m)^\s*TCP\s+([0-9\.\*\[\]:]+):' + [regex]::Escape([string]$Port) + '\s+[^\s]+\s+LISTENING\s+(\d+)')
    foreach ($m in $rx.Matches($NsText)) {
        if (-not $HostName) { return $true }
        $addr = $m.Groups[1].Value
        if ($addr -eq $HostName) { return $true }
        if ($addr -eq '0.0.0.0' -or $addr -eq '::' -or $addr -eq '[::]') { return $true }
        if ($HostName -eq 'localhost' -and $addr -eq '127.0.0.1') { return $true }
        if ($HostName -eq '127.0.0.1' -and $addr -eq '::1') { return $true }
    }
    return $false
}

function Get-ConnDiag {
    # 把一条探测结果翻译成「结论 + 具体原因」，别只给连通/不通两个词
    # RewriteHost: 该代理配置里 rewrite_host 的实际值；403 提示要按它说话，已经开了就别再劝人开
    param([string]$Code, [string]$Url, [string]$Target, [string]$NsText, $RewriteHost = $null)
    $r = @{ Verdict = '连通'; Detail = '' }
    $u = Get-HostPort $Url
    $tg = Get-HostPort $Target
    $isHttpsTarget = ($Target -match '^\s*https://')

    if ($Code -eq '000') {
        $r.Verdict = '不通'
        if (-not (Test-PortListening $u.Port $NsText $u.Host)) {
            $r.Detail = '反代没在 ' + $u.Host + ':' + $u.Port + ' 监听（进程没起、启动失败或已退出）'
        } else {
            $r.Detail = $u.Host + ':' + $u.Port + ' 在监听但连不上（连接被拒或被防火墙拦下，跨网段时查防火墙）'
        }
        return $r
    }

    if ($Code -match '^5\d\d$') {
        $r.Verdict = '上游异常'
        $localTarget = $tg.Host -in @('127.0.0.1', 'localhost', '::1', '0.0.0.0')
        if ($localTarget -and -not (Test-PortListening $tg.Port $NsText $tg.Host)) {
            $r.Detail = '上游 ' + $tg.Host + ':' + $tg.Port + ' 没有监听（上游服务没开或已退出）'
        } elseif ($localTarget -and $isHttpsTarget) {
            # target 已经是 https://，就不要再劝人改成 https
            $r.Detail = '上游 ' + $tg.Host + ':' + $tg.Port + ' 在监听但 HTTPS 握不上（端口/证书不对，或该端口其实是明文 HTTP）'
        } elseif ($localTarget) {
            $r.Detail = '上游 ' + $tg.Host + ':' + $tg.Port + ' 在监听但不应答（target 里没写路径或路径不对，或上游只开了 HTTPS 而这个端口是明文的）'
        } else {
            $r.Detail = '上游 ' + $tg.Host + ':' + $tg.Port + ' 无法应答（远端服务未开或不互通）'
        }
        return $r
    }

    switch -Regex ($Code) {
        '^2'  { $r.Detail = '正常应答' }
        '^3'  { $r.Detail = '已到达上游，返回重定向' }
        '401' { $r.Detail = '已到达上游，需要令牌（401）：客户端请求要自带 Authorization: Bearer' }
        '403' {
            # 按配置实际情况给建议：rewrite_host 已开就只说令牌/其它限制
            if ($RewriteHost -eq $true) {
                $r.Detail = '已到达上游，被拒绝（403）：令牌不对或缺失；配置里 rewrite_host 已是 true，Host 这一项不用再改'
            } elseif ($RewriteHost -eq $false) {
                $r.Detail = '已到达上游，被拒绝（403）：令牌不对或缺失；若上游校验 Host，把 rewrite_host 改成 true 再重启代理'
            } else {
                $r.Detail = '已到达上游，被拒绝（403）：令牌不对或缺失；上游若校验 Host，需要 rewrite_host 为 true'
            }
        }
        '404' { $r.Detail = '已到达上游，路径不存在（404：查 URL 路径与 target 的端口/路径）' }
        default { if ($Code -match '^4') { $r.Detail = '已到达上游，请求被拒（' + $Code + '）' } else { $r.Detail = '已到达上游（' + $Code + '）' } }
    }
    return $r
}

function Get-StatusText {

    $sb = New-Object System.Text.StringBuilder
    # 段与段之间统一用一条横线隔开（比空行更容易看出"这是另一类信息"）
    $sep = ('-' * 66)
    [void]$sb.AppendLine('=== XMCP 反代工具 ===')
    [void]$sb.AppendLine('检测时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    [void]$sb.AppendLine('')

    $cfg = Get-RelayConfig -Root $root
    [void]$sb.AppendLine('[配置] ' + $cfg.Path)
    if ($cfg.Error) { [void]$sb.AppendLine('  !! 配置错误: ' + $cfg.Error) }
    [void]$sb.AppendLine($sep)

    [void]$sb.AppendLine('[代理]')
    $firstAddr = ''
    # 先把每个代理的"名字 + 地址清单"收集起来，再统一按像素算列宽：
    # 名字单独占一行（行尾挂 [Host改写] 这类标记），地址行从同一缩进起，
    # 不同代理、不同地址的箭头和上游就自然落在同一列。
    # （按字符数补空格补不齐：空格宽度和字母宽度不是一个量，中文还会回退字形）
    $pBlocks = @()
    foreach ($p in $cfg.Proxies) {
        $listens = @()
        for ($i = 0; $i -lt $p.ListenHost.Count; $i++) { $listens += ($p.ListenHost[$i] + ':' + $p.ListenPort[$i]) }
        if (-not $firstAddr -and $p.ListenHost.Count -gt 0) { $firstAddr = $p.ListenHost[0] + ':' + $p.ListenPort[0] }
        if ($listens.Count -eq 0) { $listens = @('(没写 listen 地址)') }
        $pBlocks += [pscustomobject]@{
            Name    = ('  [' + $p.Name + ']')
            Listens = $listens
            Target  = $p.Target
            Tag     = if ($p.RewriteHost) { '[Host改写]' } else { '' }
        }
    }
    if ($pBlocks.Count -gt 0) {
        $stFont = if ($script:txtStatus) { $script:txtStatus.Font } else { New-Object Drawing.Font('Consolas', 9) }
        $stSize = New-Object Drawing.Size(1000, 40)
        $stFlags = [Windows.Forms.TextFormatFlags]::NoPadding
        $meas = {
            param([string]$s)
            [int][Windows.Forms.TextRenderer]::MeasureText($s, $stFont, $stSize, $stFlags).Width
        }
        $spaceW = & $meas ' '
        if ($spaceW -lt 1) { $spaceW = 4 }
        # 补空格到某个像素列：先按平均字宽估个数，再按实际宽度前后微调一格
        $padToCol = {
            param([string]$s, [int]$x)
            $n = [int][Math]::Max(1, [Math]::Round(($x - (& $meas $s)) / $spaceW))
            while ($n -gt 1 -and (& $meas ($s + (' ' * ($n - 1)))) -ge $x) { $n-- }
            while ((& $meas ($s + (' ' * $n))) -lt $x) { $n++ }
            return $s + (' ' * $n)
        }
        $indent = '        '                     # 地址行缩进（名字行是 2 空格，地址行再进 6 格）
        $indentW = & $meas $indent
        $addrW = 0
        foreach ($b in $pBlocks) {
            foreach ($l in $b.Listens) {
                $w = & $meas $l
                if ($w -gt $addrW) { $addrW = $w }
            }
        }
        $arrowX = $indentW + $addrW + 16         # 箭头列
        $firstBlock = $true
        foreach ($b in $pBlocks) {
            if (-not $firstBlock) { [void]$sb.AppendLine($sep) }   # 代理之间用横线分组
            $firstBlock = $false
            $line = $b.Name
            if ($b.Tag) { $line = $line + '  ' + $b.Tag }
            [void]$sb.AppendLine($line)
            foreach ($l in $b.Listens) {
                [void]$sb.AppendLine((& $padToCol ($indent + $l) $arrowX) + '->  ' + $b.Target)
            }
        }
    }
    if ($firstAddr) { $script:trayHint = 'XMCP 反代 · ' + $firstAddr }

    $proc = Get-RelayProcess

    [void]$sb.AppendLine($sep)
    if ($proc) {
        [void]$sb.AppendLine('[进程] 运行中   PID ' + $proc.Id + '   ' + $proc.ProcessName + '   启动于 ' + $proc.StartTime.ToString('HH:mm:ss'))
    } else {
        [void]$sb.AppendLine('[进程] 未运行   （下面若全部不通，先看这里）')
    }

    [void]$sb.AppendLine($sep)
    [void]$sb.AppendLine('[监听]')
    # 用正则解析完整 netstat 文本（netstat | Select-String 在本机偶发只回一行，会少显示监听）
    $nsText = ''
    try { $nsText = (& $netstatExe -ano | Out-String) } catch { $nsText = '' }
    foreach ($port in (Get-RelayPortList -Config $cfg)) {
        $rx = [regex]('(?m)^\s*TCP\s+([0-9\.\*\[\]:]+):' + [regex]::Escape([string]$port) + '\s+[^\s]+\s+LISTENING\s+(\d+)')
        $ms = $rx.Matches($nsText)
        if ($ms.Count -gt 0) {
            foreach ($m in $ms) {
                $ownerPid = $m.Groups[2].Value
                # 同一个端口上可能既有反代，也有上游本体（比如 Obsidian 自己监听 127.0.0.1:27123），
                # 标一下归属，免得把上游监听当成反代在绑地址
                $note = ''
                if ($proc -and $ownerPid -ne [string]$proc.Id) { $note = '   （不是反代进程，是同端口的上游/其他程序）' }
                [void]$sb.AppendLine('  TCP    ' + $m.Groups[1].Value + ':' + $port + '   LISTENING   PID ' + $ownerPid + $note)
            }
        } else {
            [void]$sb.AppendLine('  端口 ' + $port + ' 没有监听')
        }
    }

    [void]$sb.AppendLine($sep)
    [void]$sb.AppendLine('[连通性] 自动检测')
    $ok = 0
    $bad = 0
    $warn = 0
    $total = 0
    foreach ($p in $cfg.Proxies) {
        for ($i = 0; $i -lt $p.ListenHost.Count; $i++) {
            $h = $p.ListenHost[$i]
            $pt = $p.ListenPort[$i]
            if ($h -eq '0.0.0.0' -or $h -eq '*') { $h = '127.0.0.1' }
            $url = 'http://' + $h + ':' + $pt + '/'
            $total++
            $code = Test-Endpoint -Url $url
            $diag = Get-ConnDiag -Code $code -Url $url -Target $p.Target -NsText $nsText -RewriteHost $p.RewriteHost
            switch ($diag.Verdict) {
                '不通'     { $bad++ }
                '上游异常' { $warn++ }
                default    { $ok++ }
            }
            [void]$sb.AppendLine((('  ' + $url).PadRight(40) + ' -> ' + $code.PadRight(4) + ' ' + $diag.Verdict))
            if ($diag.Detail) { [void]$sb.AppendLine('        · ' + $diag.Detail) }
        }
    }
    # 小结先报真正通达的条数；异常和不通各自单列，别混成一个"可达"糊过去
    $sum = '  小结: ' + $ok + '/' + $total + ' 个地址通达'
    if ($warn -gt 0) { $sum += '，' + $warn + ' 个上游异常' }
    if ($bad -gt 0) { $sum += '，' + $bad + ' 个不通' }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine($sum)
    [void]$sb.AppendLine('  （000=不通；5xx=反代在跑但上游没应答；401/404/200 等=已到达上游；每条的原因见下面缩进行）')
    $script:lastVerdict = $ok.ToString() + '/' + $total.ToString() + ' 地址通达'
    # 健康判定：进程在 且 所有配置地址都真正通达（5xx 不算通达，上游其实已经挂了）
    $script:healthy = [bool]($proc -ne $null -and $total -gt 0 -and $ok -eq $total)

    [void]$sb.AppendLine($sep)
    $stateFile = Join-Path $root 'firewall-state.txt'
    if (Test-Path -LiteralPath $stateFile) {
        $sl = @(Get-Content -LiteralPath $stateFile -Encoding utf8)
        $stamp = '未知'
        if ($sl.Count -gt 0 -and $sl[0] -like '# 生成于*') { $stamp = ($sl[0] -replace '^#\s*生成于\s*', '').Trim() }
        [void]$sb.AppendLine('[防火墙] 组 XMCP relay   快照: ' + $stamp)
        foreach ($line in $sl) {
            if (-not $line) { continue }
            if ($line.StartsWith('#')) { continue }
            [void]$sb.AppendLine('  ' + $line.Trim())
        }
    } else {
        [void]$sb.AppendLine('[防火墙] 还没有快照 —— 启动/重启一次代理即生成（firewall-sync.ps1 会写）')
    }
    # 提权更新是后台异步跑的（不再卡启动），这里提醒用户还有一步要手动点
    $pendingFile = Join-Path $root 'firewall-pending.txt'
    if (Test-Path -LiteralPath $pendingFile) {
        $since = ''
        try { $since = (Get-Content -LiteralPath $pendingFile -Raw).Trim() } catch { }
        [void]$sb.AppendLine('  [待办] 防火墙后台提权更新中（发起于 ' + $since + '）：UAC 还没点就点一下“是”，')
        [void]$sb.AppendLine('        完成后这行会自动消失；反代不受影响，已经在跑。')
    }

    return $sb.ToString()
}

function Set-TextInnerPad {
    # RichTextBox 没有 Padding 属性，用 EM_SETRECT 把文字排版区往里收，避免字贴着边框
    param($Box, [int]$Left = 10, [int]$Top = 8, [int]$Right = 10, [int]$Bottom = 8)
    if (-not $Box) { return }
    try {
        if (-not $Box.IsHandleCreated) { return }
        $w = $Box.ClientSize.Width
        $h = $Box.ClientSize.Height
        $rect = New-Object 'XMcp.RichPad+RECT'
        $rect.Left = $Left
        $rect.Top = $Top
        $rect.Right = [Math]::Max($Left + 20, $w - $Right)
        $rect.Bottom = [Math]::Max($Top + 20, $h - $Bottom)
        [void][XMcp.RichPad]::SendMessage($Box.Handle, 0x00B3, [IntPtr]::Zero, [ref]$rect)
    } catch { }
}

function Set-StatusText {
    param([string]$Text)
    $box = $script:txtStatus
    $box.Text = $Text
    Set-TextInnerPad $box
    # 结果标记上色：行尾「连通」= 深绿，「不通」= 红
    # 只认「整行最后两个字」这个位置（用换行做右边界），[连通性] 这类标题、括号里的说明都不会被误染
    if ($box -is [Windows.Forms.RichTextBox]) {
        try {
            $box.SelectAll()
            # RichTextBox 的 .Font 只管"新输入"，已有内容按 RTF 自带字体渲染
            # 每帧都显式设一遍，保证和其它 tab 一样是 Consolas 9
            $box.SelectionFont = New-Object Drawing.Font('Consolas', 9)
            $box.SelectionColor = [Drawing.Color]::Black
            $box.Select(0, 0)
            $rx = [regex]"(上游异常|连通|不通)(?=\r\n|\r|\n|$)"
            foreach ($m in $rx.Matches($box.Text)) {
                $box.Select($m.Index, $m.Length)
                switch ($m.Groups[1].Value) {
                    '连通'     { $box.SelectionColor = [Drawing.Color]::FromArgb(0, 100, 0) }
                    '上游异常' { $box.SelectionColor = [Drawing.Color]::FromArgb(192, 110, 0) }
                    default    { $box.SelectionColor = [Drawing.Color]::FromArgb(200, 0, 0) }
                }
            }
            # 代理名字行尾的 [Host改写]：蓝色、小一号，当提示看，不抢地址那几行的视线
            $rxTag = [regex]'\[Host改写\]'
            foreach ($m in $rxTag.Matches($box.Text)) {
                $box.Select($m.Index, $m.Length)
                $box.SelectionFont = New-Object Drawing.Font('Consolas', 8)
                $box.SelectionColor = [Drawing.Color]::FromArgb(30, 90, 200)
            }
            $box.Select(0, 0)
        } catch { }
    }
    $box.SelectionStart = 0
    $box.ScrollToCaret()
    try { $box.Invalidate(); $box.Update() } catch { }
    try {
        [IO.File]::WriteAllText($uiSnap, $Text, (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

# 按钮随健康状态变：通了 => "最小化" 可用；不通 => 置灰，必须先"重启代理"
# 配置里所有监听地址，拼成 host:port,host:port（供后台任务等端口应答）
function Get-CheckAddresses {
    try {
        $cfg = Get-RelayConfig -Root $root
        if ($cfg.Error) { return '' }
        $list = @()
        foreach ($p in $cfg.Proxies) {
            for ($i = 0; $i -lt $p.ListenHost.Count; $i++) {
                $h = $p.ListenHost[$i]
                if ($h -eq '0.0.0.0' -or $h -eq '*') { $h = '127.0.0.1' }
                $list += ($h + ':' + $p.ListenPort[$i])
            }
        }
        return ($list -join ',')
    } catch { return '' }
}

function Apply-ButtonState {    if (-not $script:btnRun) { return }
    if ($script:healthy) {
        $script:btnRun.Text = '1. 最小化'
        $script:btnRun.Enabled = $true
        $script:btnRecheck.Text = '重启代理'
    } else {
        $script:btnRun.Text = '代理异常（点右侧）'
        $script:btnRun.Enabled = $false
        $script:btnRecheck.Text = '重启代理 ★'
    }
}

function Update-Status {
    $swStatus = [Diagnostics.Stopwatch]::StartNew()
    $script:txtStatus.Cursor = [Windows.Forms.Cursors]::WaitCursor
    $script:txtStatus.Text = '检测中…'
    $script:txtStatus.Refresh()
    $text = ''
    try {
        $text = Get-StatusText
    } catch {
        $text = '检测出错: ' + $_.Exception.Message
        $script:healthy = $false
        Write-UiLog ('status error: ' + $_.Exception.Message)
    } finally {
        $script:txtStatus.Cursor = [Windows.Forms.Cursors]::Default
    }
    Set-StatusText $text
    Apply-ButtonState
    Write-UiLog ('status updated: ' + $script:lastVerdict + '  healthy=' + $script:healthy + '  took=' + [Math]::Round($swStatus.Elapsed.TotalSeconds, 1) + 's')
}

# ---- 代理启停放到后台 runspace，UI 线程不被占用（窗口可拖动 / 可最小化 / 不"未响应"）----
$script:relayTaskCode = @'
param($Mode, $RestartPs1, $StartPs1, $Addresses)
$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $exe)) { $exe = 'powershell.exe' }
$netstat = Join-Path $env:SystemRoot 'System32\netstat.exe'
if (-not (Test-Path -LiteralPath $netstat)) { $netstat = 'netstat.exe' }
$log = @()
if ($Mode -eq 'Restart') {
    # 停+启塞进同一个子 powershell：每起一个子进程光冷启动就约 1.9 秒，合并能省一次
    $o = & $exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $RestartPs1 2>&1 | Out-String
    $log += ('restart | ' + ($o -replace "`r?`n", ' ; '))
} else {
    $o = & $exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $StartPs1 2>&1 | Out-String
    $log += ('start | ' + ($o -replace "`r?`n", ' ; '))
}
# 等端口真正进入 LISTENING：netstat 一次约 0.1 秒
# 旧版是顺序 curl 每个地址 --max-time 2，反代还没绑上时每个都吃满 2 秒，一轮就要 8 秒多，
# 而日志只记了 sleep 时间（写着"1.4 秒"实际等了十几秒），把人误导得很惨
$list = @()
if ($Addresses) { $list = $Addresses.Split(',') }
$targets = @()
foreach ($a in $list) { if ($a) { $targets += $a.Trim() } }
$allUp = $false
$swWait = [Diagnostics.Stopwatch]::StartNew()
while ($swWait.Elapsed.TotalSeconds -lt 30) {
    $ns = (& $netstat -ano | Out-String)
    $allUp = $true
    foreach ($a in $targets) {
        # 只认"地址:端口"这一条自己 LISTENING，别被 127.0.0.1 上别的程序同端口骗过去
        $rx = [regex]([regex]::Escape($a) + '\s+[^\s]+\s+LISTENING')
        if (-not $rx.IsMatch($ns)) { $allUp = $false; break }
    }
    if ($allUp) { break }
    Start-Sleep -Milliseconds 300
}
$waitSec = [Math]::Round($swWait.Elapsed.TotalSeconds, 1)
$waitNote = if ($allUp) { '（全部就绪）' } else { '（超时：有地址没起来，看下面 [监听]）' }
$log += ('wait | 等端口监听 ' + $waitSec + ' 秒 ' + $waitNote)
$log -join ' || '
'@

function Start-RelayTask {
    param([ValidateSet('Start', 'Restart')][string]$Mode = 'Restart')
    if ($script:bgHandle -and -not $script:bgHandle.IsCompleted) {
        Write-UiLog 'relay task already running, ignore new request'
        return
    }
    $script:relayTaskMode = $Mode
    $script:btnRun.Enabled = $false
    $script:btnRecheck.Enabled = $false
    $script:btnQuit.Enabled = $false
    $label = '正在启动代理…'
    if ($Mode -eq 'Restart') { $label = '正在重启代理…' }
    Set-StatusText ($label + "`r`n" + '一般 5–10 秒完成。窗口此时可以正常拖动、可以点右上角"-"最小化、也可以点 X 收进托盘，完成后会自动刷新结果。')
    Write-UiLogSep
    Write-UiLog ('relay task start: ' + $Mode)
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:relayTaskCode)
    [void]$ps.AddArgument($Mode)
    [void]$ps.AddArgument($restartPs1)
    [void]$ps.AddArgument($startPs1)
    [void]$ps.AddArgument((Get-CheckAddresses))
    $script:bgPs = $ps
    $script:bgHandle = $ps.BeginInvoke()
    $script:taskTimer.Start()
}

# ===== MCP 探针 =====
# 后台任务：按 2025-11-25 规范发 initialize、按 2026-07-28 规范发 server/discover 各打一发，
# 有会话号再探 GET 通知流与 DELETE 会话；只做探测、不改报文，解析和结论判定放回 UI 线程。
$script:probeTaskCode = @'
param($Url, $Token, $HostVariant)
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path -LiteralPath $curl)) { $curl = 'curl.exe' }

# 后台进程控制台可能是 GBK(936)：原生程序（curl）的回包会被按 ANSI 解码，
# 含中文的 JSON 会被破坏。先把输入输出编码固定成 UTF-8（无 BOM；回包另走文件字节流兜底）。
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

# 兼容三种粘贴：裸 Key / "Bearer xxx" / "Authorization: Bearer xxx"，只保留裸令牌
$tok = ($Token -ireplace '^\s*(Authorization\s*:\s*)?(Bearer\s+)?', '').Trim()

function Invoke-McpPost {
    param($Url, $Tok, $Method, $Version, $Params, $EnvelopeMeta, $McpMethod, $HostOverride, $Session)
    $headers = @('-H', 'Content-Type: application/json', '-H', 'Accept: application/json, text/event-stream')
    if ($Tok)   { $headers += @('-H', ('Authorization: Bearer ' + $Tok)) }
    if ($Version) { $headers += @('-H', ('MCP-Protocol-Version: ' + $Version)) }
    if ($McpMethod) { $headers += @('-H', ('Mcp-Method: ' + $McpMethod)) }
    if ($Session) { $headers += @('-H', ('Mcp-Session-Id: ' + $Session)) }
    # 只覆盖 Host 头：curl 明确支持 -H 'Host: x' 覆盖自动生成的 Host（--http1.1 保证不会落到 :authority）
    if ($HostOverride) { $headers += @('-H', ('Host: ' + $HostOverride)) }
    $bodyParams = $Params
    if ($EnvelopeMeta) { $bodyParams = ($Params + @{ _meta = $EnvelopeMeta }) }
    $bodyObj = [ordered]@{ jsonrpc = '2.0'; id = 1; method = $Method; params = $bodyParams }
    $body = ($bodyObj | ConvertTo-Json -Compress -Depth 6)
    # 请求体/响应头/体分别落盘再按 UTF-8 读回：绕开控制台 ANSI 解码，也避免 stdin 编码带入 BOM。
    $tmpReq = [IO.Path]::GetTempFileName()
    $tmpHead = [IO.Path]::GetTempFileName()
    $tmpBody = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmpReq, $body, $utf8NoBom)
        $curlArgs = @('-sS','-k','--noproxy','*','--max-time','5','-X','POST',$Url,'-D',$tmpHead,'-o',$tmpBody) + $headers + @('--data-binary', ('@' + $tmpReq))
        [void](& $curl @curlArgs 2>&1 | Out-Null)
        $head = [IO.File]::ReadAllText($tmpHead, [Text.Encoding]::UTF8)
        $respBody = [IO.File]::ReadAllText($tmpBody, [Text.Encoding]::UTF8)
        return ($head.TrimEnd() + "`r`n`r`n" + $respBody)
    } finally {
        Remove-Item $tmpReq, $tmpHead, $tmpBody -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-McpRequest {
    param($Url, $Tok, $HttpMethod, $Session, $MaxTime)
    $headers = @('-H', 'Accept: text/event-stream, application/json')
    if ($Tok) { $headers += @('-H', ('Authorization: Bearer ' + $Tok)) }
    if ($Session) { $headers += @('-H', ('Mcp-Session-Id: ' + $Session)) }
    $tmpHead = [IO.Path]::GetTempFileName()
    $tmpBody = [IO.Path]::GetTempFileName()
    try {
        [void](& $curl -sS -k --noproxy '*' --max-time $MaxTime -X $HttpMethod $Url -D $tmpHead -o $tmpBody @headers 2>&1 | Out-Null)
        $head = [IO.File]::ReadAllText($tmpHead, [Text.Encoding]::UTF8)
        $respBody = [IO.File]::ReadAllText($tmpBody, [Text.Encoding]::UTF8)
        return ($head.TrimEnd() + "`r`n`r`n" + $respBody)
    } finally {
        Remove-Item $tmpHead, $tmpBody -Force -ErrorAction SilentlyContinue
    }
}

function Split-Response {
    param($Raw)
    $code = '000'; $session = ''; $body = ''
    if (-not $Raw) { return @{ Code = $code; Session = ''; Body = '' } }
    $parts = $Raw -split "`r?`n`r?`n", 2
    $head = $parts[0]
    if ($parts.Count -gt 1) { $body = $parts[1] }
    $m = [regex]::Match($head, 'HTTP/\S+\s+(\d+)')
    if ($m.Success) { $code = $m.Groups[1].Value }
    $sm = [regex]::Match($head, '(?im)^\s*mcp-session-id:\s*(\S+)')
    if ($sm.Success) { $session = $sm.Groups[1].Value }
    # 响应可能是 SSE 帧（event: message / data: {...}），把 data: 行拼回 JSON
    if ($body -match 'event:') {
        $jsonLines = @()
        foreach ($ln in ($body -split "`r?`n")) {
            if ($ln -match '^\s*data:\s?(.*)$') { $jsonLines += $Matches[1] }
        }
        $body = ($jsonLines -join '')
    }
    return @{ Code = $code; Session = $session; Body = $body.Trim() }
}

# 规范化 URL：没写协议补 http://；只有主机端口时补 /mcp
$u = ($Url.Trim())
if ($u -notmatch '^\w+://') { $u = 'http://' + $u }
if ($u -match '^(\w+://[^/]+)/?$') { $u = $Matches[1] + '/mcp' }

$initParams = @{
    protocolVersion = '2025-11-25'
    capabilities    = @{}
    clientInfo      = @{ name = 'xmcp-probe'; version = '1.0' }
}
# 2026-07-28 规范：信封 _meta 放在 params 内，键是扁平的 io.modelcontextprotocol/* 路径
$meta = [ordered]@{
    'io.modelcontextprotocol/protocolVersion'  = '2026-07-28'
    'io.modelcontextprotocol/clientInfo'       = @{ name = 'xmcp-probe'; version = '1.0' }
    'io.modelcontextprotocol/clientCapabilities' = @{}
}

$initRaw = Invoke-McpPost -Url $u -Tok $tok -Method 'initialize'     -Version '2025-11-25' -Params $initParams
$discRaw = Invoke-McpPost -Url $u -Tok $tok -Method 'server/discover' -Version '2026-07-28' -Params @{} -EnvelopeMeta $meta -McpMethod 'server/discover'

$init = Split-Response $initRaw
$disc = Split-Response $discRaw

# 新规范这一发按 2026-07-28 打的，不带会话号。
# 只支持旧规范的服务端会直接挑"缺少会话"拒掉；这时用它自己的会话号再打一发，
# 只用于排除"只是缺会话才被拒"的干扰；带旧会话号不是新规范的正确姿势，
# 这一发结果不作为新协议兼容判定依据。拿到的 -32601 Method not found 可佐证"未实现 server/discover"。
$disc2Code = ''; $disc2Body = ''
if ($init.Session -and $disc.Code -notmatch '^2') {
    $disc2Raw = Split-Response (Invoke-McpPost -Url $u -Tok $tok -Method 'server/discover' -Version '2026-07-28' -Params @{} -EnvelopeMeta $meta -McpMethod 'server/discover' -Session $init.Session)
    $disc2Code = $disc2Raw.Code
    $disc2Body = $disc2Raw.Body
}

# 只有旧规范握出了会话号，才去探通知流与会话删除；新规范无会话，不探
$getCode = '–'; $delCode = '–'
if ($init.Session) {
    $get = Split-Response (Invoke-McpRequest -Url $u -Tok $tok -HttpMethod 'GET'    -Session $init.Session -MaxTime 3)
    $getCode = $get.Code
    $del = Split-Response (Invoke-McpRequest -Url $u -Tok $tok -HttpMethod 'DELETE' -Session $init.Session -MaxTime 5)
    $delCode = $del.Code
}

# ---- Host 校验：只把 Host 头换成外部地址，路径/报文/令牌一字不改 ----
# 基线（Host=URL 里的主机名）与变体（Host=反代对外地址或哨兵名）对比，
# 差出 2xx vs 403 只说明上游做了 Host 白名单；是否必须开 rewrite_host，还要看反代最终转发的 Host。
$varCode = ''; $varBody = ''
if ($HostVariant) {
    $varRaw = Invoke-McpPost -Url $u -Tok $tok -Method 'initialize' -Version '2025-11-25' -Params $initParams -HostOverride $HostVariant
    $var = Split-Response $varRaw
    $varCode = $var.Code
    $varBody = $var.Body
}

$out = @()
$out += ('URL=' + $u)
$out += ('TOKEN_PRESENT=' + $(if ($tok) { 'yes' } else { 'no' }))
$out += ('INIT_HTTP=' + $init.Code)
$out += ('INIT_SESSION=' + $init.Session)
$out += ('INIT_BODY=' + $init.Body)
$out += ('DISC_HTTP=' + $disc.Code)
$out += ('DISC_BODY=' + $disc.Body)
$out += ('DISC2_HTTP=' + $disc2Code)
$out += ('DISC2_BODY=' + $disc2Body)
$out += ('GET_HTTP=' + $getCode)
$out += ('DEL_HTTP=' + $delCode)
$out += ('HOST_VARIANT=' + $(if ($HostVariant) { $HostVariant } else { '' }))
$out += ('VAR_HTTP=' + $(if ($HostVariant) { $varCode } else { '–' }))
$out += ('VAR_BODY=' + $varBody)
$out -join "`n"
'@

function Parse-ProbeBody {
    # 从单条 JSON-RPC 响应里抠出版本 / 能力 / 服务端信息 / 错误码；抠不出来就留空
    param([string]$Body)
    $r = @{
        Version = ''; ServerName = ''; ServerVer = ''
        ErrCode = ''; ErrMsg = ''
        SupportedVersions = ''; ResultType = ''
        Tools = $false; Resources = $false; Prompts = $false
    }
    if (-not $Body) { return $r }
    try { $j = $Body | ConvertFrom-Json } catch { return $r }
    if ($j.error) {
        # 两种错误体都收：JSON-RPC 的 error 对象，以及部分服务端的 {"error":"文本","code":"XXX"} 扁平体
        if ($j.error -is [string]) {
            $r.ErrMsg = [string]$j.error
            if ($j.code) { $r.ErrCode = [string]$j.code }
        } else {
            $r.ErrCode = [string]$j.error.code
            $r.ErrMsg = [string]$j.error.message
        }
    }
    if ($j.result) {
        $res = $j.result
        if ($res.protocolVersion)   { $r.Version = [string]$res.protocolVersion }
        if ($res.supportedVersions) { $r.SupportedVersions = ($res.supportedVersions -join ', ') }
        if ($res.resultType)        { $r.ResultType = [string]$res.resultType }
        if ($res.capabilities) {
            if ($res.capabilities.tools)     { $r.Tools = $true }
            if ($res.capabilities.resources) { $r.Resources = $true }
            if ($res.capabilities.prompts)    { $r.Prompts = $true }
        }
        # 服务端信息：旧规范在 result.serverInfo；新规范在 result._meta.io.modelcontextprotocol/serverInfo
        $si = $res.serverInfo
        if (-not $si -and $res._meta) { $si = $res._meta.'io.modelcontextprotocol/serverInfo' }
        if ($si) {
            $r.ServerName = [string]$si.name
            $r.ServerVer  = [string]$si.version
        }
    }
    return $r
}

function Format-ProbeErr {
    # 上游的英文报错换成人话；认不出来的原样保留并截断，保证一行放得下。
    # 只出句子，错误码由调用方另起一行显示。
    param([string]$Code, [string]$Msg)
    if (-not $Msg -and -not $Code) { return '' }
    if ($Msg -match '(?i)missing\s+session') { return '需先建会话' }
    if ($Code -eq '-32601' -or $Msg -match '(?i)method\s+not\s+found') { return '上游没实现这个方法' }
    $core = ([string]$Msg).Trim()
    if ($core.Length -gt 70) { $core = $core.Substring(0, 68) + '…' }
    return $core
}

function Get-ProbeVerdict {
    param($InitCode, $Init, $DiscCode, $Disc)
    if ($InitCode -in @('401', '403') -or $DiscCode -in @('401', '403')) { return 'auth' }
    if ($InitCode -eq '000' -and $DiscCode -eq '000') { return 'unreachable' }
    # 5xx：探针打的是反代入口时，说明反代在跑但上游没应答，和"不确定"分开报
    if ($InitCode -match '^5\d\d$' -or $DiscCode -match '^5\d\d$') { return 'upstreambad' }
    $initOk = [bool]$Init.Version
    $discOk = [bool]($Disc.SupportedVersions -or $Disc.ResultType)
    if ($initOk -and $discOk) { return 'dual' }
    if ($discOk) { return 'new' }
    if ($initOk) { return 'old' }
    return 'unknown'
}

function Get-HostVerdict {
    # 只换 Host 头的对比结论：基线通 + 变体被拒 => 上游做了 Host 白名单
    param([string]$BaseCode, [string]$VarCode)
    if (-not $VarCode -or $VarCode -eq '–') { return 'na' }
    if ($BaseCode -notmatch '^2\d\d$') { return 'unknown' }   # 基线就没通，Host 差异被遮住
    if ($VarCode -match '^2\d\d$') { return 'free' }
    if ($VarCode -match '^(400|403|421)$') { return 'must' }
    return 'unknown'
}

function Get-DefaultProbeUrl {
    # 默认填配置里第一条代理的上游，省得每次手敲；取不到就给本地占位
    try {
        $cfg = Get-RelayConfig -Root $root
        $p = @($cfg.Proxies | Where-Object { $_.enabled -ne $false } | Select-Object -First 1)
        if ($p.Count -eq 1) {
            $t = [string]$p[0].Target
            if ($t -match '^(https?://)?([^:]+):(\d+)') {
                $host2 = $Matches[2]; $port2 = $Matches[3]
                # 注意：再做一次 -match 会覆盖 $Matches，所以主机/端口先存出来
                $sch = if ($t -match '^https://') { 'https' } else { 'http' }
                return ("${sch}://{0}:{1}/mcp" -f $host2, $port2)
            }
        }
    } catch { }
    return 'http://127.0.0.1:27124/mcp'
}

function Get-LanAddress {
    # 取一个对外网卡 IPv4（优先 192.168.x），用来把 listen 里的通配 0.0.0.0 换成真实地址
    param([string]$Exclude = '')
    $ips = @()
    try {
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                 Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -ne '0.0.0.0' } |
                 ForEach-Object { [string]$_.IPAddress })
    } catch { $ips = @() }
    if ($ips.Count -eq 0) {
        try {
            $ips = @([Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) |
                     Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                     ForEach-Object { [string]$_.IPAddress } |
                     Where-Object { $_ -notlike '127.*' })
        } catch { $ips = @() }
    }
    foreach ($pat in @('192.168.', '10.', '172.')) {
        foreach ($x in $ips) { if ($x.StartsWith($pat) -and $x -ne $Exclude) { return $x } }
    }
    foreach ($x in $ips) { if ($x -ne $Exclude) { return $x } }
    return ''
}

function Get-ProbeHostVariant {
    # 算出「Host 校验」那一发要用的外部 Host，并把来源写清楚。
    # 返回 @{ Variant=''; Note=''; Skip=''; Suggest='' }：Skip 非空表示这次不测，并给出该填什么。
    param([string]$Url)
    $r = @{ Variant = ''; Note = ''; Skip = ''; Suggest = ''; ProxyName = ''; Current = $null }
    $hp = Get-HostPort $Url
    if (-not $hp.Host) { $r.Skip = '地址里没解析出主机名'; return $r }

    $cfg = $null
    try { $cfg = Get-RelayConfig -Root $root } catch { $cfg = $null }
    $proxies = @()
    if ($cfg -and $cfg.Proxies) { $proxies = @($cfg.Proxies) }

    # 按端口找对应代理（target 端口与探针端口一致）
    $match = $null
    foreach ($p in $proxies) {
        $th = Get-HostPort ([string]$p.Target)
        if ($th.Port -eq $hp.Port) { $match = $p; break }
    }

    $loopHosts = @('127.0.0.1', 'localhost', '::1', '[::1]')
    if ($loopHosts -notcontains $hp.Host.ToLower()) {
        # 填的不是上游本体：判断它是不是某个代理的对外监听地址
        $owner = $null
        foreach ($p in $proxies) {
            for ($i = 0; $i -lt @($p.ListenHost).Count; $i++) {
                if (([string]$p.ListenHost[$i]) -eq $hp.Host -and ([string]$p.ListenPort[$i]) -eq $hp.Port) { $owner = $p }
            }
            if ($owner) { break }
        }
        if ($owner) {
            $r.Skip = '填的是反代监听地址（不是上游本体），Host 已被反代改写，这里测不出真实校验'
            $r.ProxyName = [string]$owner.Name
            $r.Current = $owner.RewriteHost
            $th = Get-HostPort ([string]$owner.Target)
            $sch = if ([string]$owner.Target -match '^https://') { 'https' } else { 'http' }
            $r.Suggest = "${sch}://$($th.Host):$($th.Port)/mcp"
        } else {
            $r.Skip = '填的不是上游本体地址（应是 127.0.0.1 / localhost 这类本机地址）'
        }
        return $r
    }

    if ($match) {
        $lh = [string]$match.ListenHost[0]
        $lp = [string]$match.ListenPort[0]
        if ($lh -in @('0.0.0.0', '::', '[::]')) {
            $lan = Get-LanAddress
            if ($lan) { $lh = $lan }
        }
        $r.Variant = "${lh}:${lp}"
        $r.Note = "变体 Host 取自配置 [$($match.Name)] 的 listen 地址 $($match.ListenHost[0]):$lp"
        $r.ProxyName = [string]$match.Name
        $r.Current = $match.RewriteHost
        return $r
    }

    $r.Variant = "xmcp-probe.example:$($hp.Port)"
    $r.Note = "配置里没有与该上游对应的代理，变体 Host 用哨兵名 xmcp-probe.example:$($hp.Port)"
    return $r
}

function Set-ProbeResult {
    param([string]$Text)
    $script:txtProbeResult.Text = $Text
    Set-TextInnerPad $script:txtProbeResult
}

# 三态：yes=✓ 绿 / no=✗ 红 / unknown=? 灰 / na=– 灰
function Get-CheckState {
    param($Code, [string]$OkCodes)
    if ($null -eq $Code -or $Code -eq '–' -or $Code -eq '') { return 'na' }
    if ($Code -eq '000') { return 'unknown' }
    $ok = $OkCodes -split ','
    if ($ok -contains $Code) { return 'yes' }
    return 'no'
}

function Render-ProbeResult {
    param([string]$Raw)
    $line = @{}
    foreach ($ln in ($Raw -split "`r?`n")) {
        $i = $ln.IndexOf('=')
        if ($i -gt 0) { $line[$ln.Substring(0, $i)] = $ln.Substring($i + 1) }
    }
    $url  = $line['URL']; if (-not $url) { $url = '(未知)' }
    $initCode = $line['INIT_HTTP']; $initSession = $line['INIT_SESSION']
    $discCode = $line['DISC_HTTP']; $getCode = $line['GET_HTTP']; $delCode = $line['DEL_HTTP']
    $disc2Code = $line['DISC2_HTTP']
    $init = Parse-ProbeBody $line['INIT_BODY']
    $disc = Parse-ProbeBody $line['DISC_BODY']
    $disc2 = Parse-ProbeBody $line['DISC2_BODY']
    $verdict = Get-ProbeVerdict $initCode $init $discCode $disc

    $black  = [Drawing.Color]::Black
    $green  = [Drawing.Color]::FromArgb(0, 120, 0)
    $red    = [Drawing.Color]::FromArgb(192, 0, 0)
    $orange = [Drawing.Color]::FromArgb(192, 110, 0)
    $gray   = [Drawing.Color]::Gray
    $rt = $script:txtProbeResult
    $rt.Clear()

    # 术语高亮：名词名（连同括注英文）加粗 + 蓝色，冒号后的解释保持原行颜色。
    # 名单按长度降序，先匹配长串（'会话号（Mcp-Session-Id）' 命中后不再单独标 'Mcp-Session-Id'）。
    $termColor = [Drawing.Color]::FromArgb(0, 90, 200)
    $termFont = New-Object Drawing.Font($rt.Font.FontFamily, $rt.Font.Size, [Drawing.FontStyle]::Bold)
    $terms = @(
        '会话号（Mcp-Session-Id）', '旧规范 initialize 握手', '新规范 server/discover',
        '通知流（GET 长连接）', '关闭会话（DELETE）',
        '工具（Tools）', '资源（Resources）', '提示（Prompts）',
        '有状态（Sessionful）', '无状态（Stateless）', '基线 / 变体', '上游支持的版本', '上游不支持的版本',
        'server/discover', 'Mcp-Session-Id', 'initialize', 'capabilities', 'rewrite_host', '协议版本'
    )
    function Add-Line {
        param([string]$Text, $Color = $black, [bool]$Strong = $false)
        $lineStart = $rt.TextLength
        $rt.SelectionColor = $Color
        $rt.AppendText($Text + "`r`n")
        if ($Strong) {
            # 节标题：黑色加粗，整行不参与术语高亮
            if ($Text) {
                $rt.Select($lineStart, $Text.Length)
                $rt.SelectionFont = $termFont
                $rt.SelectionColor = $black
            }
            $rt.Select($rt.TextLength, 0)
            $rt.SelectionColor = $Color
            $rt.SelectionFont = $rt.Font
            return
        }
        if ($Text) {
            $spans = @()
            foreach ($t in ($terms | Sort-Object -Property @{ Expression = { $_.Length } } -Descending)) {
                $pos = 0
                while (($pos = $Text.IndexOf($t, $pos, [StringComparison]::OrdinalIgnoreCase)) -ge 0) {
                    $s = $pos; $e = $pos + $t.Length
                    $free = $true
                    foreach ($sp in $spans) { if ($s -lt $sp.End -and $e -gt $sp.Start) { $free = $false; break } }
                    if ($free) { $spans += New-Object psobject -Property @{ Start = $s; End = $e } }
                    $pos = $e
                }
            }
            foreach ($sp in ($spans | Sort-Object Start)) {
                $rt.Select($lineStart + $sp.Start, $sp.End - $sp.Start)
                $rt.SelectionFont = $termFont
                $rt.SelectionColor = $termColor
            }
            $rt.Select($rt.TextLength, 0)
            $rt.SelectionColor = $Color
            $rt.SelectionFont = $rt.Font
        }
    }
    function State-Symbol { param($State)
        switch ($State) { 'yes' { '✓' } 'no' { '✗' } 'na' { '–' } default { '?' } }
    }
    function State-Color { param($State)
        switch ($State) { 'yes' { $green } 'no' { $red } default { $gray } }
    }

    Add-Line 'MCP Server 检测报告' $black
    Add-Line ('目标: ' + $url)
    Add-Line ('探测时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Add-Line ('鉴权: ' + $(if ($line['TOKEN_PRESENT'] -eq 'yes') { '已带令牌' } else { '未填令牌（上游若要 Bearer，结果会是 401）' }))
    # 服务端自报的家门放最顶上，先看清在对谁做探测
    $server = $init.ServerName; $serverVer = $init.ServerVer
    if (-not $server) { $server = $disc.ServerName; $serverVer = $disc.ServerVer }
    if ($server) { Add-Line (('探测服务端：' + $server + ' ' + $serverVer).TrimEnd()) }
    Add-Line ''

    # --- 协议兼容性：两条腿分别按真实响应判定 ---
    Add-Line '协议兼容性' $black $true
    $initOk = [bool]$init.Version
    $discOk = [bool]($disc.SupportedVersions -or $disc.ResultType)
    $initState = if ($initCode -in @('401', '403')) { 'unknown' } elseif ($initOk) { 'yes' } elseif ($initCode -eq '000') { 'unknown' } else { 'no' }
    # 方法未找到不等于版本不支持：这类错误归"无法判断"，不标红色不兼容
    $discIsMethodErr = ($disc.ErrCode -eq '-32601') -or ([string]$disc.ErrMsg -match '(?i)method\s+not\s+found|unknown\s+method|method\s+not\s+implemented')
    $discState = if ($discCode -in @('401', '403')) { 'unknown' } elseif ($discOk) { 'yes' } elseif ($discCode -eq '000') { 'unknown' } elseif ($discIsMethodErr) { 'unknown' } else { 'no' }
    # discover 的错误消息里常带「supported versions: ...」长括号串，挤在一行看不出重点：
    # 把列表单独拆出来另起一行，主行只留"哪个版本不被支持"。
    $discErrText = [string]$disc.ErrMsg
    $discSupported = ''
    $discBadVer = ''
    if ($discErrText) {
        $svm = [regex]::Match($discErrText, '(?i)supported\s+versions?\s*:\s*([^)]+)')
        if ($svm.Success) {
            $discSupported = ($svm.Groups[1].Value.Trim() -replace '\s*,\s*', ' / ')
            $cut = $discErrText.IndexOf('(')
            if ($cut -ge 0 -and $cut -lt $svm.Index) { $discErrText = $discErrText.Substring(0, $cut) }
            else { $discErrText = $discErrText.Substring(0, $svm.Index) }
            $discErrText = $discErrText.Trim()
        }
        $bvm = [regex]::Match($discErrText, '(?i)Unsupported protocol version\s*:\s*(\S+)')
        if ($bvm.Success) {
            $discBadVer = $bvm.Groups[1].Value
            $discErrText = $discErrText -replace '(?i)^\s*Bad Request\s*:\s*', ''
            $discErrText = ($discErrText -replace '(?i)Unsupported protocol version\s*:\s*\S+', '').Trim()
        }
    }
    # 版本列表：成功响应取 result.supportedVersions；失败时取错误消息里的 supported versions
    $verList = @()
    if ($disc.SupportedVersions) { $verList = $disc.SupportedVersions -split ',\s*' }
    elseif ($discSupported) { $verList = $discSupported -split '\s*/\s*' }
    $hasNewVer = $false
    foreach ($v in $verList) { if ($v.Trim() -eq '2026-07-28') { $hasNewVer = $true } }
    # 错误归类（呈现层区分，不改解析）：版本不被接受 / discover 方法未找到 / 其他
    $isVerErr = ($discBadVer -ne '') -or ($discErrText -match '(?i)unsupported\s+protocol\s+version')
    $isMethodErr = $discIsMethodErr
    $initNote = if ($initOk) { 'HTTP ' + $initCode + ' · 协商版本 ' + $init.Version } else { 'HTTP ' + $initCode + $(if ($init.ErrCode) { ' · [' + $init.ErrCode + '] ' + $init.ErrMsg }) }
    # 数字错误码短，直接挂主行；字母错误码（如 INITIALIZATION_REQUIRED）太长，挪到下面单独一行
    $discCodeIsNum = [bool]($disc.ErrCode -match '^-?\d+$')
    $discErrCore = if ($discOk) { '' } else { Format-ProbeErr $disc.ErrCode $discErrText }
    $discNote = if ($discOk) { 'HTTP ' + $discCode + ' · 支持的版本 ' + $disc.SupportedVersions } else { 'HTTP ' + $discCode + $(if ($discCodeIsNum) { ' · [' + $disc.ErrCode + ']' } else { '' }) + $(if ($discErrCore) { ' · ' + $discErrCore } else { '' }) }
    Add-Line ('  [' + (State-Symbol $initState) + '] 2025-11-25 旧规范 initialize 握手   ' + $initNote) (State-Color $initState)
    Add-Line ('  [' + (State-Symbol $discState) + '] 2026-07-28 新规范请求  ' + $discNote.TrimEnd()) (State-Color $discState)
    if ($verList.Count -gt 0) {
        Add-Line ('  上游版本列表: ' + ($verList -join ' / ')) $gray
        $verMark = if ($hasNewVer) { '列表包含 2026-07-28' } else { '列表未包含 2026-07-28' }
        Add-Line ('     ' + $verMark) $gray
    }
    if ($discBadVer) { Add-Line ('  上游不支持的版本: ' + $discBadVer) $gray }
    # discover 是能力发现方法，不等于整个新协议：方法可用性与版本支持分开陈述
    if ($discOk) { $methodText = 'server/discover 调用成功' }
    elseif ($isMethodErr) { $methodText = '上游未实现 server/discover，方法不可用' }
    elseif ($isVerErr) { $methodText = '版本未被接受，discover 方法是否可用本次无法判断' }
    else { $methodText = '无法判断（HTTP ' + $discCode + '）' }
    Add-Line ('  discover 方法: ' + $methodText) $gray
    if ($disc.ErrCode -and -not $discCodeIsNum) { Add-Line (' 上游错误码: ' + $disc.ErrCode) $gray }
    # 带旧会话号补打的一发：只用于排除"第一发只是缺会话才被拒"的干扰。
    # 新规范 2026-07-28 已取消协议级会话，带旧会话号不是新规范的正确姿势，
    # 这一发的结果不作为新协议兼容性判定依据（判定只看上面不带会话号的第一发）。
    if ($disc2Code -and $disc2Code -ne '000') {
        $d2Text = [string]$disc2.ErrMsg
        $d2Show = ''
        $m2 = [regex]::Match($d2Text, '(?i)Unsupported protocol version\s*:\s*(\S+)')
        if ($m2.Success) {
            $d2Show = '仍不支持 ' + $m2.Groups[1].Value + $(if ($disc2.ErrCode) { '（' + $disc2.ErrCode + '）' })
        } else {
            $d2Show = Format-ProbeErr $disc2.ErrCode $d2Text
        }
        Add-Line (' 排除性诊断（带旧会话号，非新规范姿势）: HTTP ' + $disc2Code + $(if ($d2Show) { ' · ' + $d2Show } else { '' })) $gray
    }
    Add-Line ''

    # --- 会话能力：会话号 / 通知流 / 会话删除 ---
    Add-Line '会话能力' $black $true
    # 会话号是可选的：旧规范也允许服务端不分配。没带回不算"不支持"，标中性未分配。
    $sidState = if ($initSession) { 'yes' } elseif ($initCode -in @('401', '403', '000')) { 'unknown' } else { 'na' }
    if ($initSession) {
        Add-Line ('  [' + (State-Symbol $sidState) + '] 会话号（Mcp-Session-Id）  ' + $initSession) (State-Color $sidState)
    } else {
        Add-Line ('  [' + (State-Symbol $sidState) + '] 会话号（Mcp-Session-Id）  服务端未分配会话号') (State-Color $sidState)
        Add-Line '     采用无协议级会话模式；会话号可选，不违反规范。' $gray
    }
    $getState = Get-CheckState $getCode '200'
    # 没有会话号时 DELETE 不适用；通知流是可选传输能力，未打通只标未验证
    if (-not $initSession) { $delState = 'na'; $delText = '无会话号，不适用' } else { $delState = Get-CheckState $delCode '200,202,204'; $delText = 'HTTP ' + $delCode }
    Add-Line ('  [' + (State-Symbol $getState) + '] 通知流（GET 长连接）      HTTP ' + $getCode) (State-Color $getState)
    Add-Line ('  [' + (State-Symbol $delState) + '] 关闭会话（DELETE）        ' + $delText) (State-Color $delState)
    Add-Line ''

    # --- 服务端能力：两条腿上报的 capabilities 取并集 ---
    Add-Line '服务端能力（capabilities 声明）' $black $true
    $tools = $init.Tools -or $disc.Tools
    $res   = $init.Resources -or $disc.Resources
    $prom  = $init.Prompts -or $disc.Prompts
    $capState = { param($b) if ($b) { 'yes' } else { 'no' } }
    Add-Line ('  [' + (State-Symbol (& $capState $tools)) + '] 工具（Tools）   [' + (State-Symbol (& $capState $res)) + '] 资源（Resources）   [' + (State-Symbol (& $capState $prom)) + '] 提示（Prompts）') $black
    Add-Line '  注: ✓ 仅表示初始化响应里声明了该能力，未逐条实际调用 tools/list 等验证。' $gray
    Add-Line ''

    # --- Host 校验：同一上游、同一报文，只把 Host 头换成外部地址再打一发 ---
    Add-Line 'Host 校验（上游是否只认本机 Host）' $black $true
    $hv = $script:probeHostInfo
    if (-not $hv) { $hv = @{ Variant = ''; Note = ''; Skip = ''; Suggest = ''; ProxyName = ''; Current = $null } }
    $baseHost = Get-HostPort $url
    $baseText = $baseHost.Host + ':' + $baseHost.Port
    $varHostText = $line['HOST_VARIANT']
    if ($hv.Skip) {
        Add-Line ('  [–] 跳过：' + $hv.Skip) $gray
        if ($hv.Suggest) { Add-Line ('     应改填上游本体地址: ' + $hv.Suggest) $gray }
        Add-Line ('     现在填的是: ' + $url) $gray
    } elseif (-not $varHostText -or $line['VAR_HTTP'] -eq '–') {
        Add-Line '  [–] 跳过：这次没有构造出外部 Host' $gray
    } else {
        $hostState = Get-HostVerdict $initCode $line['VAR_HTTP']
        $baseOk = ($initCode -match '^2\d\d$')
        $baseSym = if ($baseOk) { '✓' } elseif ($initCode -eq '000') { '?' } else { '✗' }
        $baseColor = if ($baseOk) { $green } elseif ($initCode -eq '000') { $gray } else { $red }
        Add-Line ('  [' + $baseSym + '] 基线  Host=' + $baseText + '    HTTP ' + $initCode) $baseColor
        $varSym = switch ($hostState) { 'must' { '✗' } 'free' { '✓' } default { '?' } }
        $varColor = switch ($hostState) { 'must' { $red } 'free' { $green } default { $gray } }
        $varErr = Parse-ProbeBody $line['VAR_BODY']
        $varTail = if ($varErr.ErrMsg) { ' · ' + $varErr.ErrMsg } elseif ($line['VAR_HTTP'] -notmatch '^2\d\d$' -and $line['VAR_BODY']) {
            # 上游不一定按 JSON-RPC 返错，取响应体开头一段，别把原因吞掉
            $s = ($line['VAR_BODY'] -replace '\s+', ' ')
            if ($s.Length -gt 60) { $s = $s.Substring(0, 60) + '…' }
            ' · ' + $s
        } else { '' }
        Add-Line ('  [' + $varSym + '] 变体  Host=' + $varHostText + '    HTTP ' + $line['VAR_HTTP'] + $varTail) $varColor
        if ($hv.Note) { Add-Line ('     ' + $hv.Note) $gray }

        switch ($hostState) {
            'must' {
                Add-Line ('  判定: 上游存在 Host 限制 —— 外部 Host 被拒（HTTP ' + $line['VAR_HTTP'] + '），仅基线 Host 可访问') $orange
                Add-Line ('     基线通过的 Host：' + $baseText) $gray
                if ($hv.ProxyName -ne '') {
                    if ($hv.Current -eq $true) {
                        Add-Line ('     配置 [' + $hv.ProxyName + '] rewrite_host=true：反代改写为基线 Host，方向正确。') $gray
                    } elseif ($hv.Current -eq $false) {
                        Add-Line ('     配置 [' + $hv.ProxyName + '] rewrite_host=false：反代会透传客户端 Host，') $gray
                        Add-Line '     按本次结果会被拒；需开启 rewrite_host、改写为基线 Host 后重启反代。' $gray
                    }
                } else {
                    Add-Line '     是否需要改写，取决于反代最终发给上游的 Host：' $gray
                    Add-Line '     透传基线 Host 则不必改；透传外部 Host 则需开启 rewrite_host。' $gray
                }
                Add-Line '     本次探针直连上游、只比对了两种 Host；反代实际转发的 Host 是否为基线地址，' $gray
                Add-Line '     需经反代链路实际发一次请求验证。' $gray
            }
            'free' {
                Add-Line '  判定: 未发现上游存在 Host 白名单限制' $green
                Add-Line ('        两种 Host 值都照常应答（HTTP ' + $line['VAR_HTTP'] + '）；rewrite_host=true 可保留，') $gray
                Add-Line '        本次 Host 测试尚未证明它是必要配置。' $gray
                Add-Line '        本测试不验证 Origin 校验、DNS Rebinding 防护与实际局域网访问；' $gray
                Add-Line '        改 Host 头不等于另一台机器访问。' $gray
            }
            default {
                if ($initCode -eq '000') {
                    Add-Line ('  判定: 无法判定 —— 基线根本没连上（HTTP 000），先把上游服务启动再说') $orange
                } elseif (-not $baseOk) {
                    Add-Line ('  判定: 无法判定 —— 基线（Host=' + $baseText + '）就是 HTTP ' + $initCode + '，Host 差异被遮住；先把基线的鉴权/路径问题修通再测') $orange
                } elseif ($line['VAR_HTTP'] -match '^401$') {
                    Add-Line '  判定: 无法判定 —— 变体回 401，像是被鉴权拦住而不是 Host 被拒，两件事叠在一起就分不清' $orange
                } else {
                    Add-Line ('  判定: 无法判定 —— 变体回了 HTTP ' + $line['VAR_HTTP'] + '，不是明确的 Host 拒绝，看不出上游是否校验 Host') $orange
                }
            }
        }
    }
    Add-Line ''

    # --- 结论 ---
    $concl = ''; $conclColor = $gray
    switch ($verdict) {
        'dual' {
            $concl = '结论: 新旧两套协议版本都支持，同规范客户端一般可直连。'
            $conclColor = $green
        }
        'old' {
            $sessionWord = if ($initSession) { '初始化带回了会话号' } else { '未分配会话号' }
            if ($isMethodErr) {
                $concl = '结论: 旧规范 ' + $init.Version + ' 初始化成功（' + $sessionWord + '）。' + "`r`n" +
                         '  新规范 server/discover 方法未实现，不能据此判定 2026-07-28 版本是否支持，需另测。'
            } else {
                $verWord = if ($hasNewVer) { '版本列表虽列有 2026-07-28，但本次新规范请求未成功' } else { '上游版本列表不含 2026-07-28' }
                $concl = '结论: 旧规范 ' + $init.Version + ' 初始化成功（' + $sessionWord + '）。' + "`r`n" +
                         '  ' + $verWord + '。' + "`r`n" +
                         '  按 2026-07-28 版本来的客户端，需要桥接层做协议版本适配；' + "`r`n" +
                         '  是否需要会话号转换不能预设，后续请求能否直接调用要实际调用验证。'
            }
            $conclColor = $orange
        }
        'new' {
            $concl = '结论: 仅支持 2026-07-28 协议版本。旧规范客户端需要桥接。'
            $conclColor = $green
        }
        'auth' {
            $concl = '结论: 被鉴权拦截（401/403），协议版本未能判定。在「令牌」框填入 Bearer 令牌后再探测。'
            $conclColor = $orange
        }
        'unreachable' {
            # 连不上时把"具体卡在哪"写清楚：端口有没有监听、是不是被拦
            $hp = Get-HostPort $url
            $nsNow = ''
            try { $nsNow = (& $netstatExe -ano | Out-String) } catch { $nsNow = '' }
            $where = $hp.Host + ':' + $hp.Port
            if (-not (Test-PortListening $hp.Port $nsNow $hp.Host)) {
                $concl = '结论: 连不上（HTTP 000）。' + $where + ' 本机没有监听——上游服务没开或已退出，先把它启动。'
            } else {
                $concl = '结论: 连不上（HTTP 000）。' + $where + ' 有监听但连接没建立——检查是否被防火墙拦下、地址/端口是否写错，或把 http 打到了只开 https 的端口。'
            }
            $conclColor = $red
        }
        'upstreambad' {
            $concl = '结论: 反代在跑但上游没应答（5xx）。检查上游服务是否已启动，以及 target 的端口与协议（http/https）是否写对。'
            $conclColor = $orange
        }
        default {
            $concl = '结论: 不确定。两条腿都没返回标准 JSON-RPC 结果，可能不是 MCP 端点，或报文结构与预期不同，看上面各行原始错误。'
            $conclColor = $orange
        }
    }
    Add-Line $concl $conclColor
    Add-Line ''

    # --- 名词解释：上面这些英文术语到底指什么 ---
    Add-Line '名词解释' $black $true
    Add-Line '  · 有状态（Sessionful）：传输模式选择。服务端回会话号，后续请求带着它续上下文。' $black
    Add-Line '  · 无状态（Stateless）：传输模式选择。不使用协议级 Session，请求不带会话号。' $black
    Add-Line '    会话模式与协议版本是两个维度：旧规范 2025-11-25 也可以不分配会话号，' $black
    Add-Line '    新规范 2026-07-28 取消协议级会话；不能单凭有无会话号判断版本。' $black
    Add-Line '  · initialize：旧规范的握手请求，协商版本；是否回会话号由服务端决定（可选）。' $black
    Add-Line '  · server/discover：新规范的能力发现请求，回支持的版本与 capabilities。' $black
    Add-Line '  · 会话号（Mcp-Session-Id）：旧版 Streamable HTTP 中，服务端可通过响应头' $black
    Add-Line '    分配会话标识；若分配了，客户端后续请求需携带它。旧版协议允许不使用会话号。' $black
    Add-Line '  · 通知流（GET 长连接）：服务端主动往下推事件的通道；' $black
    Add-Line '    不提供也不影响调用，工具照样能一条条 POST 调。HTTP 200 只说明端点应答，' $black
    Add-Line '    未校验连接保持与事件推送。' $black
    Add-Line '  · 关闭会话（DELETE）：客户端显式告诉服务端"这个会话结束了"。' $black
    Add-Line '  · capabilities：服务端声明的能力清单，下面三项就来自这里。' $black
    Add-Line '  · 工具（Tools）：可被调用的动作，最常用；资源（Resources）：可读取的数据；' $black
    Add-Line '    提示（Prompts）：预置的提示词模板。' $black
    Add-Line '  · 基线 / 变体：基线是 Host 保持本机名打的那一发，' $black
    Add-Line '    变体是只把 Host 头换成外部地址、其余不变打的那一发。' $black
    Add-Line '  · rewrite_host：配置项。开启后，反代把转发请求的 Host 头改写为上游目标地址；' $black
    Add-Line '    关闭后原样透传客户端带来的 Host。适用于上游做 Host 校验、虚拟主机路由' $black
    Add-Line '    或其他 Host 依赖的场景。Host 与 Origin 是两个不同的请求头，不能互相替代。' $black

    # 渲染完再套一次内边距：Update-Layout 阶段句柄可能还没创建，EM_SETRECT 会被跳过；
    # 此时窗口已显示、句柄存在，确保文字四周和状态页一样留白。
    Set-TextInnerPad $rt
}

function Start-Probe {
    if ($script:probeHandle -and -not $script:probeHandle.IsCompleted) { return }
    $url = $script:txtProbeUrl.Text.Trim()
    if (-not $url) { Set-ProbeResult '请先填上游 MCP 地址。'; return }
    # 兼容裸 Key / "Bearer xxx" / "Authorization: Bearer xxx"，只保留裸令牌
    $token = ($script:txtProbeToken.Text.Trim() -ireplace '^\s*(Authorization\s*:\s*)?(Bearer\s+)?', '').Trim()
    # Host 校验用的外部 Host 在 UI 线程算好（要读配置），后台脚本只负责发请求
    $script:probeHostInfo = Get-ProbeHostVariant -Url $url
    $script:btnProbe.Enabled = $false
    Set-ProbeResult '探测中…（initialize / discover / 会话通道 / Host 变体，各最多等 5 秒）'
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:probeTaskCode)
    [void]$ps.AddArgument($url)
    [void]$ps.AddArgument($token)
    [void]$ps.AddArgument($script:probeHostInfo.Variant)
    $script:probePs = $ps
    $script:probeHandle = $ps.BeginInvoke()
    $script:probeTimer.Start()
}

function Hide-ToTray {
    $script:ni.Text = $script:trayHint
    $script:ni.Visible = $true
    $script:form.Hide()
    try {
        $script:ni.ShowBalloonTip(3000, 'XMCP 反代', "已在后台运行`r`n$($script:trayHint)`r`n双击右下角图标可重新打开", [Windows.Forms.ToolTipIcon]::Info)
    } catch { }
    Write-UiLog 'window minimized to tray'
}

function Show-Console {
    $script:ni.Visible = $false
    $script:form.Show()
    $script:form.WindowState = [Windows.Forms.FormWindowState]::Normal
    $script:form.Activate()
    $script:form.BringToFront()
    if (-not (Get-RelayProcess)) { Start-RelayTask -Mode Start }   # 托盘期间反代掉了才拉起
    Write-UiLog 'window restored'
}

# ---- 顶部 tab：状态 / 配置格式 / 配置内容 / 运行日志 ----
# 把压缩成一行的 JSON 排成"每个键一行、缩进 2 格"的样子，方便肉眼检查。
# 用 python 的 json.dumps（ensure_ascii=False，保留中文）；没有 python 就原样返回。
# 统一成 CRLF：WinForms 多行文本框只认 CRLF，LF-only 会把几十行挤成一行显示
function To-Crlf {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $t = $Text -replace "`r`n", "`n"
    $t = $t -replace "`n", "`r`n"
    return $t
}

# 配置里允许 # 到行尾的注释（字符串内部的 # 不动）。python 侧、relay-config.ps1 里是同一套规则
function Remove-JsonComments {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    $inStr = $false
    $esc = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($inStr) {
            [void]$sb.Append($c)
            if ($esc) { $esc = $false }
            elseif ($c -eq [char]'\') { $esc = $true }
            elseif ($c -eq [char]'"') { $inStr = $false }
            continue
        }
        if ($c -eq [char]'"') { $inStr = $true; [void]$sb.Append($c); continue }
        if ($c -eq [char]'#') {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
            if ($i -lt $Text.Length) { [void]$sb.Append("`n") }
            continue
        }
        [void]$sb.Append($c)
    }
    return $sb.ToString()
}

# 剥掉注释后常会剩「, ]」这种尾巴（用户在最后一项后面写了逗号再跟注释），这里去掉
function Remove-JsonTrailingCommas {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    $inStr = $false
    $esc = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($inStr) {
            [void]$sb.Append($c)
            if ($esc) { $esc = $false }
            elseif ($c -eq [char]'\') { $esc = $true }
            elseif ($c -eq [char]'"') { $inStr = $false }
            continue
        }
        if ($c -eq [char]'"') { $inStr = $true; [void]$sb.Append($c); continue }
        if ($c -eq [char]',') {
            $j = $i + 1
            while ($j -lt $Text.Length -and " `t`r`n".IndexOf($Text[$j]) -ge 0) { $j++ }
            if ($j -lt $Text.Length -and ($Text[$j] -eq ']' -or $Text[$j] -eq '}')) { continue }
            [void]$sb.Append($c)
            continue
        }
        [void]$sb.Append($c)
    }
    return $sb.ToString()
}

function Convert-RelayConfigText {
    param([string]$Text)
    return (Remove-JsonTrailingCommas (Remove-JsonComments $Text))
}

function Format-JsonText {
    param([string]$Text)
    if (-not $Text -or -not $Text.Trim()) { return $Text }
    $py = Find-PythonExe
    $fmtPy = Join-Path $root 'format-config.py'
    if (-not $py -or -not (Test-Path -LiteralPath $fmtPy)) { return (To-Crlf $Text) }
    $tmpIn = Join-Path $root 'mcp-relay.config.json.fmtin'
    $tmpOut = $tmpIn + '.fmt'
    try { [IO.File]::WriteAllText($tmpIn, $Text, (New-Object Text.UTF8Encoding($false))) } catch { return (To-Crlf $Text) }
    # 直接调解释器，不经 cmd.exe：少一层引号拼接，也不受 PATH 影响
    try { $null = (& $py $fmtPy $tmpIn 2>&1 | Out-String) } catch { }
    $ok = ($LASTEXITCODE -eq 0)
    $res = $Text
    if ($ok) {
        try { $res = [IO.File]::ReadAllText($tmpOut, (New-Object Text.UTF8Encoding($false))) } catch { $res = $Text }
    }
    Remove-Item -LiteralPath $tmpIn -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
    if (-not $ok -or -not $res) { return (To-Crlf $Text) }
    return (To-Crlf $res).TrimEnd() + "`r`n"
}

function Reload-ConfigEditor {
    $txt = ''
    try { $txt = [IO.File]::ReadAllText($cfgPath, (New-Object Text.UTF8Encoding($false))) } catch { $txt = '' }
    if (-not $txt -and (Test-Path -LiteralPath $cfgPath)) {
        try { $txt = [IO.File]::ReadAllText($cfgPath) } catch { $txt = '' }
    }
    $txt = Format-JsonText $txt
    $script:suppressDirty = $true
    $script:txtCfg.Text = $txt
    $script:suppressDirty = $false
    $script:configDirty = $false          # TextChanged 会在赋值时触发，这里再压回去
    Update-CfgLineIndex                    # 换过内容要重算行号，否则行号栏还停在上一份配置的行数上
    Clear-ConfigErrorMark                  # 重新载入就撤掉上一轮的红字标记
    if ($script:lblCfgState) { $script:lblCfgState.Text = '当前文件: mcp-relay.config.json   （改完点「重启代理」保存并重启）' }
    Write-UiLog 'config editor reloaded'
}

# 打开任意配置文件，把内容载入编辑框（只是载入，不会立刻覆盖现有配置）
function Import-ConfigFile {
    if (-not $script:txtCfg) { return }
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Title = '导入配置文件并载入到编辑框'
    $dlg.InitialDirectory = $root
    $dlg.Filter = 'JSON 配置 (*.json)|*.json|所有文件 (*.*)|*.*'
    $dlg.FileName = 'mcp-relay.config.json'
    if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
    $path = $dlg.FileName
    $txt = ''
    try {
        $bytes = [IO.File]::ReadAllBytes($path)
        $txt = (New-Object Text.UTF8Encoding($false)).GetString($bytes)
        if ($txt.Length -gt 0 -and [int][char]$txt[0] -eq 65279) { $txt = $txt.Substring(1) }   # 去掉 BOM
    } catch {
        [Windows.Forms.MessageBox]::Show('读取失败: ' + $_.Exception.Message, '导入配置文件', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    $txt = Format-JsonText $txt
    $script:suppressDirty = $true
    $script:txtCfg.Text = $txt
    $script:suppressDirty = $false
    $script:configDirty = $true
    $script:txtCfg.SelectionStart = 0
    $script:txtCfg.ScrollToCaret()
    Update-CfgLineIndex
    Clear-ConfigErrorMark
    if ($script:lblCfgState) { $script:lblCfgState.Text = '已载入: ' + [IO.Path]::GetFileName($path) + '   （点「重启代理」= 先校验，再存到 mcp-relay.config.json）' }
    $script:tabs.SelectedTab = $script:tabEdit
    Write-UiLog ('config imported from ' + $path)
}

# 把编辑框里的当前内容导出到用户选定的文件：保存对话框选路径，点「保存」即直接写盘。
# 与「导入」对称：导出的是编辑框里的现状（含尚未点「重启代理」保存的改动），不是磁盘上的旧文件。
function Export-ConfigFile {
    if (-not $script:txtCfg) { return }
    $txt = [string]$script:txtCfg.Text
    if (-not $txt -or -not $txt.Trim()) {
        [Windows.Forms.MessageBox]::Show('配置内容是空的，没有可导出的内容。', '导出配置文件', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Title = '导出当前配置到文件'
    $dlg.InitialDirectory = $root
    $dlg.Filter = 'JSON 配置 (*.json)|*.json|所有文件 (*.*)|*.*'
    $dlg.FileName = 'mcp-relay.config.json'
    $dlg.OverwritePrompt = $true
    if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
    $path = $dlg.FileName
    try {
        # 与项目其它写配置处保持一致：CRLF + UTF-8 无 BOM
        [IO.File]::WriteAllText($path, (To-Crlf $txt), (New-Object Text.UTF8Encoding($false)))
    } catch {
        [Windows.Forms.MessageBox]::Show('导出失败: ' + $_.Exception.Message, '导出配置文件', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    if ($script:lblCfgState) { $script:lblCfgState.Text = '已导出到: ' + $path }
    Write-UiLog ('config exported to ' + $path)
}

# 把一个日志文件读成条目：每条带时间戳；没有时间戳的续行沿用上一条的时间
function Get-LogTailItems {
    param([string]$Path, [string]$Rx)
    $items = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $lastT = [datetime]::MinValue
    foreach ($l in @(Get-Content -LiteralPath $Path -Encoding utf8 -Tail 120 -ErrorAction SilentlyContinue)) {
        if ($l -match $Rx) {
            $dt = $null
            try { $dt = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) } catch { }
            if ($dt) { $lastT = $dt }
            [void]$items.Add([pscustomobject]@{ T = $dt; N = $items.Count; Msg = $Matches[2].Trim() })
        } elseif ($l.Trim() -and $l.Trim() -notmatch '^=+$') {
            [void]$items.Add([pscustomobject]@{ T = $lastT; N = $items.Count; Msg = $l.Trim() })
        }
    }
    return @($items)
}

function Format-LogItems {
    param($Items, [string]$Head)
    if (-not $Items -or @($Items).Count -eq 0) { return '（这个日志文件还不存在，或还没有内容）' }
    $sorted = @($Items | Sort-Object -Property @{Expression={$_.T};Descending=$true}, @{Expression={$_.N};Descending=$true} | Select-Object -First 60)
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add($Head)
    [void]$out.Add('')
    foreach ($it in $sorted) {
        $ts = '------------ --:--:--'
        if ($it.T -and $it.T -gt [datetime]::MinValue) { $ts = $it.T.ToString('MM-dd HH:mm:ss') }
        [void]$out.Add('[' + $ts + '] ' + $it.Msg)
    }
    return (To-Crlf ($out -join "`n"))
}

function Update-LogView {
    $relayLog = Join-Path $root 'mcp-relay.log'
    $rxRelay  = '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\s(.*)$'
    $rxUi     = '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\]\s?(.*)$'
    $rxTrace  = '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)(?:\.\d{3})?\s(.*)$'

    if ($script:txtLogRelay) {
        $arr = @(Get-LogTailItems -Path $relayLog -Rx $rxRelay)
        $script:txtLogRelay.Text = (Format-LogItems -Items $arr -Head '（最新在最上 · 反代 mcp-relay.log · 最多 60 条）')
        $script:txtLogRelay.SelectionStart = 0
        $script:txtLogRelay.ScrollToCaret()
    }
    if ($script:txtLogUi) {
        $arr = @(Get-LogTailItems -Path $uiLog -Rx $rxUi)
        $script:txtLogUi.Text = (Format-LogItems -Items $arr -Head '（最新在最上 · 控制台 xmcp-console.log · 最多 60 条）')
        $script:txtLogUi.SelectionStart = 0
        $script:txtLogUi.ScrollToCaret()
    }
    if ($script:txtLogTrace) {
        $arr = @(Get-LogTailItems -Path $traceLog -Rx $rxTrace)
        $script:txtLogTrace.Text = (Format-LogItems -Items $arr -Head '（最新在最上 · 链路 mcp-relay-trace.log · 按 trace_id 贯穿接入/上游/交付/结束 · 最多 60 条）')
        $script:txtLogTrace.SelectionStart = 0
        $script:txtLogTrace.ScrollToCaret()
    }
}

function Open-LogFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [Windows.Forms.MessageBox]::Show('日志文件还不存在: ' + $Path, '打开日志', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $Path + '"') | Out-Null } catch { }
}

function Select-StatusTab {
    if ($script:tabStatus) { $script:tabs.SelectedTab = $script:tabStatus }
}

function Find-PythonExe {
    foreach ($cand in @('C:\Python314\python.exe', 'C:\Python313\python.exe', 'C:\Python312\python.exe')) {
        if (Test-Path -LiteralPath $cand) { return $cand }
    }
    try {
        $cmd = Get-Command python.exe -ErrorAction Stop
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    } catch { }
    return ''
}

# 校验 + 保存配置。返回 $true 表示可以继续重启
function Save-ConfigFromUi {
    # 编辑框是 RichTextBox，.Text 取回来只有 \n（不是 \r\n）；写回文件前统一成 CRLF，
    # 否则每次保存都会把整份配置的换行符改掉，git diff 一片红。
    $new = To-Crlf $script:txtCfg.Text
    if (-not $new -or -not $new.Trim()) {
        [Windows.Forms.MessageBox]::Show('配置内容是空的，没有保存。', '配置检查', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return $false
    }
    # 先排版（每个键一行、缩进 2 格），存回去的也是排版后的样子；排不了（语法坏）就按原文走后面的校验
    $formatted = Format-JsonText $new
    if ($formatted -and $formatted -ne $new) { $new = $formatted }
    $tmp = Join-Path $root 'mcp-relay.config.json.tmp'
    try { [IO.File]::WriteAllText($tmp, $new, (New-Object Text.UTF8Encoding($false))) } catch {
        [Windows.Forms.MessageBox]::Show('写临时文件失败: ' + $_.Exception.Message, '配置检查', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return $false
    }

    # 1) 语法：优先用 python 的 json（严格）。ConvertFrom-Json 太宽松，会把非法 JSON 当合法。
    #    validate-config.py 会把 JSONDecodeError 翻译成"第 X 行第 Y 列附近: ..."这样一行中文提示，
    #    完整堆栈只写日志，不糊到弹窗上。
    $syntaxOk = $false
    $errText = ''
    $rawText = ''
    $errFromFile = $false
    $validatePy = Join-Path $root 'validate-config.py'
    if (-not (Test-Path -LiteralPath $validatePy)) {
        $src = @'
import json, sys

def strip_comments(text):
    out = []
    i = 0
    n = len(text)
    in_str = False
    esc = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "#":
            while i < n and text[i] != "\n":
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)

def drop_trailing_commas(text):
    out = []
    i = 0
    n = len(text)
    in_str = False
    esc = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == ",":
            j = i + 1
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j < n and text[j] in "]}":
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)

def sanitize(text):
    return drop_trailing_commas(strip_comments(text))

def emit(msg, msgfile):
    if msgfile:
        try:
            with open(msgfile, "w", encoding="utf-8", newline="\n") as f:
                f.write(msg)
        except Exception:
            pass
    try:
        print(msg)
    except Exception:
        pass

def main():
    path = sys.argv[1]
    msgfile = sys.argv[2] if len(sys.argv) > 2 else None
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            text = f.read()
        json.loads(sanitize(text))
        return 0
    except json.JSONDecodeError as e:
        emit("第 %d 行第 %d 列附近: %s" % (e.lineno, e.colno, e.msg), msgfile)
        return 1
    except Exception as e:
        emit(str(e), msgfile)
        return 1

if __name__ == "__main__":
    sys.exit(main())
'@
        try { [IO.File]::WriteAllText($validatePy, $src, (New-Object Text.UTF8Encoding($false))) } catch { }
    }
    $py = Find-PythonExe
    if ($py -and (Test-Path -LiteralPath $validatePy)) {
        # 直接调解释器（不经 cmd.exe），任何 PATH 环境下都跑得起来。
        # 中文提示让 python 另写一份 UTF-8 文件再读回来：控制台管道会按 GBK 解码 UTF-8，
        # 直接在弹窗里显示就会变成"绗?19 琛?"这种乱码，走文件就不受编码影响。
        $msgFile = $tmp + '.err'
        Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
        try {
            $rawText = [string](& $py $validatePy $tmp $msgFile 2>&1 | Out-String)
            $syntaxOk = ($LASTEXITCODE -eq 0)
        } catch {
            $syntaxOk = $false
            $rawText = $_.Exception.Message
        }
        if (-not $syntaxOk) {
            $msg = ''
            $errFromFile = $false
            if (Test-Path -LiteralPath $msgFile) {
                try {
                    $msg = ([IO.File]::ReadAllText($msgFile, (New-Object Text.UTF8Encoding($false)))).Trim()
                    if ($msg) { $errFromFile = $true }
                } catch { }
            }
            if (-not $msg) {
                $msg = [string]((($rawText -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)).Trim()
            }
            if ($rawText -match '无法将|not recognized|不是内部或外部命令|拒绝访问|No such file') {
                # 这类不是 JSON 写错了，而是校验脚本/解释器根本没跑起来，别误导用户去改配置
                $errText = '校验脚本没跑起来（找不到 python 或系统命令）: ' + $msg
            } elseif ($msg) {
                $errText = '语法错误: ' + $msg
            } else {
                $errText = '语法错误: 配置文件不是合法 JSON'
            }
        }
        Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
    } elseif ($py) {
        $code = 'import json,sys; json.load(open(sys.argv[1], encoding=' + "'utf-8-sig'" + '))'
        $outText = ''
        $oldEnc = [Console]::OutputEncoding
        try {
            # 这一步只能靠控制台管道收结果，先把解码改成 UTF-8，否则中文提示会变乱码
            try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }
            $outText = (& $py -c $code $tmp 2>&1 | Out-String)
            $rawText = [string]$outText
            $syntaxOk = ($LASTEXITCODE -eq 0)
        } catch {
            $syntaxOk = $false
            $outText = $_.Exception.Message
        } finally {
            try { [Console]::OutputEncoding = $oldEnc } catch { }
        }
        if (-not $syntaxOk) {
            $brief = (($rawText -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 1)
            if ($rawText -match '无法将|not recognized|不是内部或外部命令|拒绝访问|No such file') {
                $errText = '校验脚本没跑起来（找不到 python 或系统命令）: ' + ([string]$brief).Trim()
            } else {
                $errText = '语法错误: ' + $brief
            }
        }
    } else {
        try { [void]((Convert-RelayConfigText $new) | ConvertFrom-Json); $syntaxOk = $true } catch { $syntaxOk = $false; $errText = $_.Exception.Message }
    }

    # 2) 结构：至少一条 enabled 的 proxy，且 listen / target 都在
    #    配置允许 # 注释，ConvertFrom-Json 不认，先剥掉再解析（与 python 侧口径一致）
    if ($syntaxOk) {
        try {
            $obj = Convert-RelayConfigText $new | ConvertFrom-Json
            $onCount = 0
            foreach ($pr in @($obj.proxies)) {
                if (-not $pr) { continue }
                if ($pr.enabled -eq $false) { continue }
                if (-not $pr.listen -or -not $pr.target) { throw ('proxy "' + [string]$pr.name + '" 缺少 listen 或 target') }
                $onCount++
            }
            if ($onCount -eq 0) { throw '至少要有一条 enabled=true（或省略 enabled）的 proxy' }
        } catch {
            $syntaxOk = $false
            $errText = '结构检查: ' + $_.Exception.Message
        }
    }

    if (-not $syntaxOk) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        # 日志留完整报错（排查用），弹窗只给一行看得懂的话
        $fullForLog = $errText
        if ($rawText -and -not $errFromFile) { $fullForLog = $errText + ' || ' + $rawText }
        Write-UiLog ('config rejected: ' + ($fullForLog -replace "`r?`n", ' | '))
        # 先把正文里那一行标红（行号栏同步变红、光标停到该列），再弹红字提示窗，
        # 两个动作顺序固定：先标位置，用户关掉弹窗时视线已经落在出错行上。
        Show-ConfigErrorMark $errText
        Show-ConfigErrorDialog $errText
        return $false
    }

    try {
        if (Test-Path -LiteralPath $cfgPath) { Copy-Item -LiteralPath $cfgPath -Destination ($cfgPath + '.bak') -Force }
        [IO.File]::WriteAllText($cfgPath, $new, (New-Object Text.UTF8Encoding($false)))
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        [Windows.Forms.MessageBox]::Show('保存配置失败: ' + $_.Exception.Message, '配置检查', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return $false
    }
    $script:suppressDirty = $true
    $script:txtCfg.Text = $new          # 编辑框里也换成排版后的样子（重设文本会一并清掉上一轮的红字）
    $script:txtCfg.SelectionStart = 0
    $script:txtCfg.ScrollToCaret()
    $script:suppressDirty = $false
    Update-CfgLineIndex
    Clear-ConfigErrorMark               # 保存成功：撤掉红字红底，状态行回到"共 N 行 · 光标第几行"
    $script:configDirty = $false
    if ($script:lblCfgState) { $script:lblCfgState.Text = '当前文件: mcp-relay.config.json   （已保存并排版，旧版见 .bak）' }
    Write-UiLog 'config saved (backup: mcp-relay.config.json.bak)'
    return $true
}

# "重启代理"入口：有未保存改动就先校验保存，再重启；保存失败就留在配置页让用户改
function Invoke-Recheck {
    if ($script:configDirty) {
        if (-not (Save-ConfigFromUi)) { return }
        Select-StatusTab
    }
    Start-RelayTask -Mode Restart
}

function Stop-And-Exit {
    param([switch]$SkipConfirm)
    $proc = Get-RelayProcess
    if ($proc -and -not $SkipConfirm) {
        $r = [Windows.Forms.MessageBox]::Show("停止反代并退出？`r`n停止后虚拟机将无法访问 MCP。", '确认停止', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
        if ($r -ne [Windows.Forms.DialogResult]::Yes) { return }
    }
    Write-UiLogSep
    if ($proc) {
        $out = ''
        try { $out = Invoke-RelayScript -Path $stopPs1 } catch { $out = '停止脚本异常: ' + $_.Exception.Message }
        Write-UiLog ('stop: ' + ($out -replace "`r?`n", ' | '))
    } else {
        Write-UiLog 'stop: 反代本来就没在运行'
    }
    $script:ExitNow = $true
    $script:ni.Visible = $false
    $script:ni.Dispose()
    $script:form.Close()
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
Write-UiLog ('t=' + [Math]::Round($script:sw.Elapsed.TotalSeconds, 1) + 's winforms loaded')

# ---- 单实例：互斥量（比查 WMI 进程快很多）----
try {
    $script:singleton = New-Object Threading.Mutex -ArgumentList @($false, 'XMCP_Console_Singleton')
    if (-not $script:singleton.WaitOne(0)) {
        $script:singleton.Dispose()
        $script:singleton = $null
        [Windows.Forms.MessageBox]::Show('控制台已经在运行（右下角托盘里）。双击托盘图标即可打开。', 'XMCP 反代工具', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        exit 0
    }
} catch { $script:singleton = $null }
Write-UiLog ('t=' + [Math]::Round($script:sw.Elapsed.TotalSeconds, 1) + 's singleton ok')

# ---- 窗口 ----
$form = New-Object Windows.Forms.Form
$form.Text = 'XMCP 反代工具 - 极客盟技术组'
$form.ClientSize = New-Object Drawing.Size(680, 648)   # 默认高度比原来 540 高 20%（540 -> 648）
$form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::Sizable
$form.MaximizeBox = $true
$form.MinimumSize = New-Object Drawing.Size(700, 600)
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$script:form = $form

# 窗口图标：项目目录下的 xmcp.ico，找不到就退回系统默认
$script:appIcon = $null
$icoFile = Join-Path $root 'xmcp.ico'
if (Test-Path -LiteralPath $icoFile) {
    try {
        # 大小图标分开取：任务栏（尤其最小化/成组时）用的是 16px 小图标，标题栏用 32px
        $script:icoBig   = New-Object Drawing.Icon($icoFile, 32, 32)
        $script:icoSmall = New-Object Drawing.Icon($icoFile, 16, 16)
        $script:appIcon  = $script:icoBig
        $form.Icon = $script:icoBig
    } catch { $script:appIcon = $null }
}

# 让任务栏把本程序当成独立应用（而不是 powershell.exe 的一个窗口），
# 否则最小化/成组时任务栏显示的是 PowerShell 的图标，而不是 xmcp.ico
if (-not ('XMcp.ShellId' -as [type])) {
    Add-Type -Namespace XMcp -Name ShellId -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
'@
}
try { [void][XMcp.ShellId]::SetCurrentProcessExplicitAppUserModelID('GeekMeng.XMcp.RelayTool.1') } catch { }

function Set-FormIcon {
    # 直接给窗口发 WM_SETICON：ICON_BIG=1、ICON_SMALL=0，两个都塞进去，
    # 最小化后任务栏按钮、Alt+Tab 缩略图才会都用我们的图标
    try {
        if (-not $script:form -or -not $script:form.IsHandleCreated) { return }
        if ($script:icoBig)   { [void][XMcp.ShellId]::SendMessage($script:form.Handle, 0x0080, [IntPtr]1, $script:icoBig.Handle) }
        if ($script:icoSmall) { [void][XMcp.ShellId]::SendMessage($script:form.Handle, 0x0080, [IntPtr]0, $script:icoSmall.Handle) }
    } catch { }
}

# ================= 顶部 tab 导航 =================
$tabs = New-Object Windows.Forms.TabControl
$tabs.Location = New-Object Drawing.Point(12, 8)
$tabs.Size = New-Object Drawing.Size(656, 416)
$tabs.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$tabs.ItemSize = New-Object Drawing.Size(96, 26)
$tabs.SizeMode = [Windows.Forms.TabSizeMode]::Fixed
# 选中页自绘高亮：蓝底白字加粗，未选中是普通底色黑字，一眼能看出停在哪一页
$tabs.DrawMode = [Windows.Forms.TabDrawMode]::OwnerDrawFixed
$tabs.add_DrawItem({
    param($sender, $e)
    $g = $e.Graphics
    $sel = ($e.Index -eq $sender.SelectedIndex)
    $rect = $e.Bounds
    # DrawString 必须传 RectangleF，传 Rectangle 会被重载解析误判成 PointF
    $rf = New-Object Drawing.RectangleF([single]$rect.X, [single]$rect.Y, [single]$rect.Width, [single]$rect.Height)
    $fmt = New-Object Drawing.StringFormat
    $fmt.Alignment = [Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [Drawing.StringAlignment]::Center
    $text = $sender.TabPages[$e.Index].Text
    if ($sel) {
        $b = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(31, 111, 191))
        $g.FillRectangle($b, $rect)
        $b.Dispose()
        $fb = New-Object Drawing.Font($sender.Font, [Drawing.FontStyle]::Bold)
        $g.DrawString($text, $fb, [Drawing.Brushes]::White, $rf, $fmt)
        $fb.Dispose()
    } else {
        $g.FillRectangle([Drawing.SystemBrushes]::Control, $rect)
        $g.DrawString($text, $sender.Font, [Drawing.Brushes]::Black, $rf, $fmt)
    }
    $fmt.Dispose()
})
$form.Controls.Add($tabs)
$script:tabs = $tabs

# --- tab 1：状态 ---
$tabStatus = New-Object Windows.Forms.TabPage
$tabStatus.Text = '状态'
$tabStatus.Padding = New-Object Windows.Forms.Padding(3)
[void]$tabs.Controls.Add($tabStatus)
$script:tabStatus = $tabStatus

$txt = New-Object Windows.Forms.RichTextBox
$txt.ReadOnly = $true
$txt.DetectUrls = $false
$txt.ScrollBars = [Windows.Forms.RichTextBoxScrollBars]::Vertical
$txt.WordWrap = $true    # 长句在框内自动折行，配合 EM_SETRECT 的左右内边距，不会顶到边框
$txt.Font = New-Object Drawing.Font('Consolas', 9)
$txt.BackColor = [Drawing.Color]::White
$txt.Location = New-Object Drawing.Point(6, 6)
$txt.Size = New-Object Drawing.Size(626, 358)
$txt.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left
$tabStatus.Controls.Add($txt)
$script:txtStatus = $txt
if (-not ('XMcp.RichPad' -as [type])) {
    Add-Type -Namespace XMcp -Name RichPad -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, ref RECT lParam);
'@
}

function New-HintPanel {
    # 说明文字容器：外层只做 1px 灰边框（灰底 + Padding 1），内层浅灰底 + 文字内边距
    param($Label, [int]$Height)
    $outer = New-Object Windows.Forms.Panel
    $outer.BackColor = [Drawing.Color]::FromArgb(176, 176, 176)
    $outer.Padding = New-Object Windows.Forms.Padding(1)
    $outer.Location = New-Object Drawing.Point(6, 4)
    $outer.Size = New-Object Drawing.Size(620, $Height)

    $inner = New-Object Windows.Forms.Panel
    $inner.Dock = [Windows.Forms.DockStyle]::Fill
    $inner.BackColor = [Drawing.Color]::FromArgb(248, 248, 248)
    $inner.Padding = New-Object Windows.Forms.Padding(10, 5, 10, 5)

    $Label.BackColor = $inner.BackColor
    $Label.Dock = [Windows.Forms.DockStyle]::Fill
    $Label.AutoSize = $false
    $Label.TextAlign = [Drawing.ContentAlignment]::TopLeft
    $inner.Controls.Add($Label)
    $outer.Controls.Add($inner)
    return $outer
}

# --- tab 2：配置格式（只读样板）---
$tabSample = New-Object Windows.Forms.TabPage
$tabSample.Text = '配置格式'
$tabSample.Padding = New-Object Windows.Forms.Padding(3)
[void]$tabs.Controls.Add($tabSample)

$lblSample = New-Object Windows.Forms.Label
$lblSample.Text = "格式说明（只读）：listen = 对外监听，写 IP:端口，可写多个；target = 上游地址；rewrite_host = 改写 Host 头（XTerminal 必须 true）；enabled = false 表示这条不启用。支持 # 注释：从 # 到行尾整段忽略（字符串里的 # 不算注释）。防火墙放行端口由 listen 自动推导，不用手写。下面是完整可用样板，可整段复制到「配置内容」再改。"
$lblSample.AutoSize = $false
$lblSample.TextAlign = [Drawing.ContentAlignment]::TopLeft

# 说明文字统一套一层灰边框，跟下面的文本框区分开，看起来不那么挤
$panelSample = New-HintPanel $lblSample 72
$tabSample.Controls.Add($panelSample)
$script:panelSample = $panelSample

$txtSample = New-Object Windows.Forms.TextBox
$txtSample.Multiline = $true
$txtSample.ReadOnly = $true
$txtSample.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
$txtSample.WordWrap = $true
$txtSample.Font = New-Object Drawing.Font('Consolas', 9)
$txtSample.BackColor = [Drawing.Color]::White
$txtSample.Location = New-Object Drawing.Point(6, 84)
$txtSample.Size = New-Object Drawing.Size(620, 302)
$txtSample.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left
$txtSample.Text = @'
# ===== 注释写法（本文件支持 # 注释，这是标准 JSON 之外的一层便利）=====
# 1) 整行注释：一行以 # 开头，整行忽略
# 2) 行尾注释：值后面先写逗号，再写 # 说明，逗号之后到行尾都忽略
# 3) 字符串里的 # 不算注释，按原样保留（"name": "a#b" 读出来还是 a#b）
{
  "log": {
    "file": "mcp-relay.log",
    "max_bytes": 5242880,          # 日志到 5MB 自动换新文件
  },
  "firewall": {
    "enabled": true,
    "local_address": "192.168.110.1",
    "remote_address": "192.168.110.0/24",
    "block_udp": true
  },
  "proxies": [
    {
      "name": "xterminal-mcp",
      "enabled": true,             # false = 这条不启用（不监听、不放行端口）
      "listen": [
        "192.168.110.1:12335",     # 对外监听：改这里就行，改完点「重启代理」
        "192.168.1.20:12335"       # 不要这个地址就整行删掉，或在行首加 #
      ],
      "target": "127.0.0.1:12335", # 上游：XTerminal 本机监听
      "rewrite_host": true,        # XTerminal 必须 true，否则 403
      "upstream_timeout": 3600
    },
    {
      "name": "第二个服务（示例，不启用）",
      "enabled": false,
      "listen": [
        "192.168.110.1:8088"
      ],
      "target": "127.0.0.1:8080",
      "rewrite_host": false,
      "upstream_timeout": 60
    }
  ]
}
'@
$tabSample.Controls.Add($txtSample)

# --- tab 3：配置内容（可编辑）---
$tabEdit = New-Object Windows.Forms.TabPage
$tabEdit.Text = '配置内容'
$tabEdit.Padding = New-Object Windows.Forms.Padding(3)
[void]$tabs.Controls.Add($tabEdit)
$script:tabEdit = $tabEdit

$lblEdit = New-Object Windows.Forms.Label
$lblEdit.Text = "下面是 mcp-relay.config.json 的真实内容，可直接改。改完点下方「重启代理」：先校验格式，通过才保存（旧文件备份 .bak）并重启；格式错会弹窗且不动原文件。"
$lblEdit.AutoSize = $false
$lblEdit.TextAlign = [Drawing.ContentAlignment]::TopLeft

$panelEdit = New-HintPanel $lblEdit 46
$tabEdit.Controls.Add($panelEdit)
$script:panelEdit = $panelEdit

$lblCfgState = New-Object Windows.Forms.Label
$lblCfgState.Text = '当前文件: mcp-relay.config.json'
$lblCfgState.Location = New-Object Drawing.Point(8, 56)
$lblCfgState.Size = New-Object Drawing.Size(420, 18)
$lblCfgState.ForeColor = [Drawing.Color]::DimGray
$tabEdit.Controls.Add($lblCfgState)
$script:lblCfgState = $lblCfgState

# 打开/载入别的配置文件到编辑框（改完照样点「重启代理」校验+保存）
$btnLoadCfg = New-Object Windows.Forms.Button
$btnLoadCfg.Text = '导入配置文件'
$btnLoadCfg.AutoSize = $true
$btnLoadCfg.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
$btnLoadCfg.Padding = New-Object Windows.Forms.Padding(4, 2, 4, 2)
$btnLoadCfg.Location = New-Object Drawing.Point(430, 52)
$btnLoadCfg.add_Click({ Import-ConfigFile })
$tabEdit.Controls.Add($btnLoadCfg)

# 导出编辑框当前内容到文件（保存对话框选路径，点「保存」即写盘）
$btnSaveCfg = New-Object Windows.Forms.Button
$btnSaveCfg.Text = '导出配置文件'
$btnSaveCfg.AutoSize = $true
$btnSaveCfg.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
$btnSaveCfg.Padding = New-Object Windows.Forms.Padding(4, 2, 4, 2)
$btnSaveCfg.Location = New-Object Drawing.Point(530, 52)
$btnSaveCfg.add_Click({ Export-ConfigFile })
$tabEdit.Controls.Add($btnSaveCfg)
$script:btnSaveCfg = $btnSaveCfg

# 配置编辑区 = 左边行号栏（自绘 Panel）+ 右边富文本框；外面套 1px 灰边框
# 行号是独立控件：不能编辑、不会跟着鼠标选中，正文里想复制也不会把数字带出去。
$panelCfgBox = New-Object Windows.Forms.Panel
$panelCfgBox.BackColor = [Drawing.Color]::FromArgb(176, 176, 176)
$panelCfgBox.Padding = New-Object Windows.Forms.Padding(1)
$panelCfgBox.Location = New-Object Drawing.Point(6, 90)
$panelCfgBox.Size = New-Object Drawing.Size(620, 262)
$tabEdit.Controls.Add($panelCfgBox)
$script:panelCfgBox = $panelCfgBox

$innerCfg = New-Object Windows.Forms.Panel
$innerCfg.Dock = [Windows.Forms.DockStyle]::Fill
$innerCfg.BackColor = [Drawing.Color]::White
$panelCfgBox.Controls.Add($innerCfg)
$script:innerCfg = $innerCfg

$gutterCfg = New-Object Windows.Forms.Panel
$gutterCfg.BackColor = [Drawing.Color]::FromArgb(247, 247, 247)
$gutterCfg.Location = New-Object Drawing.Point(0, 0)
$gutterCfg.Size = New-Object Drawing.Size(46, 260)
$innerCfg.Controls.Add($gutterCfg)
$script:gutterCfg = $gutterCfg

# 正文改用 RichTextBox（原来是 TextBox）：只有它能把某一行单独染色，
# 出错行要标红就得靠这个。其余行为（折行、Tab、等宽字体）和原来保持一致。
$txtCfg = New-Object Windows.Forms.RichTextBox
$txtCfg.DetectUrls = $false                 # 关掉自动识别网址，免得配置里的地址被染成蓝色链接
$txtCfg.BorderStyle = [Windows.Forms.BorderStyle]::None
$txtCfg.ScrollBars = [Windows.Forms.RichTextBoxScrollBars]::Vertical
$txtCfg.WordWrap = $true
$txtCfg.AcceptsTab = $true
$txtCfg.Font = New-Object Drawing.Font('Consolas', 9)
$txtCfg.BackColor = [Drawing.Color]::White
$txtCfg.Location = New-Object Drawing.Point(46, 0)
$txtCfg.Size = New-Object Drawing.Size(572, 260)
$innerCfg.Controls.Add($txtCfg)
$script:txtCfg = $txtCfg

# 编辑框底下的一行状态：平时显示"共 N 行 / 光标第几行第几列"，校验没过时整行变红写清错误
$lblCfgError = New-Object Windows.Forms.Label
$lblCfgError.AutoSize = $false
$lblCfgError.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
$lblCfgError.ForeColor = [Drawing.Color]::FromArgb(110, 110, 110)
$lblCfgError.Location = New-Object Drawing.Point(8, 356)
$lblCfgError.Size = New-Object Drawing.Size(612, 18)
$tabEdit.Controls.Add($lblCfgError)
$script:lblCfgError = $lblCfgError

# ---------------- 行号栏 / 出错标红 ----------------
# 为什么不用 GetFirstCharIndexFromLine 直接编号：WordWrap=true 时那个 API 走的是"显示行"，
# 一条长注释折成三行就会被算成三行，编号会串位。这里改按 \n 自己切逻辑行，
# 再用 GetPositionFromCharIndex 取每行行首的真实纵坐标 —— 折行只占位置，不占编号。
$script:cfgErrorLine = 0                                     # 1 起算；0 = 当前没有标红的行
$script:cfgLineStarts = New-Object System.Collections.Generic.List[int]
[void]$script:cfgLineStarts.Add(0)
$script:cfgLineCount = 1
$script:cfgLineIdxLen = -1                                   # 建表时的 TextLength，用来发现"表过期了"
$script:cfgLineIdxSrcLen = -1                                # 建表时实际扫描的字符串长度（句柄前会带 CR，和 TextLength 不等）
$script:cfgLineGen = 0                                       # 表的世代号：重建一次 +1，行号栏据此重画
$script:cfgLineIdxRealized = $false                          # 是否已在句柄就绪后建过表（句柄前的 .Text 不可信）
$script:gutterSig = ''
$script:gutterFont = New-Object Drawing.Font('Consolas', 9)
$script:gutterFontBold = New-Object Drawing.Font('Consolas', 9, [Drawing.FontStyle]::Bold)
$script:gutterColor = [Drawing.Color]::FromArgb(120, 120, 120)
$script:gutterColorBad = [Drawing.Color]::FromArgb(198, 30, 30)
$script:gutterBrush = New-Object Drawing.SolidBrush($script:gutterColor)
$script:gutterBrushBad = New-Object Drawing.SolidBrush($script:gutterColorBad)
$script:cfgFontPlain = New-Object Drawing.Font('Consolas', 9)
$script:cfgFontBold = New-Object Drawing.Font('Consolas', 9, [Drawing.FontStyle]::Bold)

function Update-CfgLineIndex {
    # 重建逻辑行首字符偏移表（编辑框内容一变就要重建，行号栏和报错定位都靠它）
    $box = $script:txtCfg
    if (-not $box) { return }
    try {
        $text = [string]$box.Text
        $list = New-Object System.Collections.Generic.List[int]
        [void]$list.Add(0)
        $i = 0
        while (($i = $text.IndexOf("`n", $i)) -ge 0) {
            $i += 1
            [void]$list.Add($i)
        }
        $script:cfgLineStarts = $list
        $script:cfgLineCount = $list.Count
        $script:cfgLineIdxLen = $box.TextLength
        $script:cfgLineIdxSrcLen = $text.Length      # 实际扫的那串长度：句柄就绪前 .Text 还是 CRLF 版（比 TextLength 长）
        $script:cfgLineGen = $script:cfgLineGen + 1
        if ($box.IsHandleCreated) { $script:cfgLineIdxRealized = $true }
    } catch { }
}

function Ensure-CfgLineIndex {
    # 自愈两道：1) 句柄刚就绪时，之前那次建表不可信（TextChanged 可能在 .Text 定型前就触发了，
    #    预览时实测过：行号会串位、数字互相叠在一起），强制重建一次；
    #    2) 之后只要 TextLength 和建表时不一致，也重建。
    $box = $script:txtCfg
    if (-not $box) { return }
    if (-not $box.IsHandleCreated) { return }
    if (-not $script:cfgLineIdxRealized) { Update-CfgLineIndex; return }
    # TextLength 是控件内部长度（不含 CR），.Text 在句柄就绪前还会带回 CR，两者不等就说明这张表扫的
    # 不是同一份文本（实测：表里偏移到 874，而正文只有 838 字符），必须重扫
    if ($box.TextLength -ne $script:cfgLineIdxLen -or $script:cfgLineIdxSrcLen -ne $box.TextLength) { Update-CfgLineIndex }
}

function Find-CfgLineAt {
    # 二分查：给定字符偏移，返回它落在第几个逻辑行（0 起算）
    param([int]$CharIndex)
    $starts = $script:cfgLineStarts
    if (-not $starts -or $starts.Count -lt 1) { return 0 }
    $lo = 0; $hi = $starts.Count - 1; $hit = 0
    while ($lo -le $hi) {
        $mid = [int](($lo + $hi) / 2)
        if ($starts[$mid] -le $CharIndex) { $hit = $mid; $lo = $mid + 1 } else { $hi = $mid - 1 }
    }
    return $hit
}

function Update-CfgGutter {
    param([switch]$Force)
    $gut = $script:gutterCfg
    $box = $script:txtCfg
    if (-not $gut -or -not $box) { return }
    if (-not $gut.IsHandleCreated -or -not $box.IsHandleCreated) { return }
    try {
        Ensure-CfgLineIndex
        # 滚动、改行数、标红行、控件尺寸，这几样没变就不重画，避免无谓闪烁
        $top = [Math]::Max(0, $box.GetCharIndexFromPosition((New-Object Drawing.Point(1, 1))))
        $sig = ([string]$top + '|' + [string]$script:cfgLineCount + '|' + [string]$script:cfgErrorLine +
                '|' + [string]$gut.ClientSize.Height + '|' + [string]$gut.ClientSize.Width + '|' + [string]$script:cfgLineGen)
        if (-not $Force -and $sig -eq $script:gutterSig) { return }
        $script:gutterSig = $sig
        $gut.Invalidate()
    } catch { }
}

$gutterCfg.add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $w = $sender.ClientSize.Width
    $h = $sender.ClientSize.Height
    $g.Clear([Drawing.Color]::FromArgb(247, 247, 247))
    $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(214, 214, 214))
    $g.DrawLine($pen, ($w - 1), 0, ($w - 1), $h)
    $pen.Dispose()
    $box = $script:txtCfg
    if (-not $box -or -not $box.IsHandleCreated) { return }
    try {
        Ensure-CfgLineIndex
        $starts = $script:cfgLineStarts
        if (-not $starts -or $starts.Count -lt 1) { return }
        $lineH = [int][Math]::Ceiling($script:gutterFont.GetHeight($g))
        # 从第一条可见的逻辑行开始画，滚到一半的行也能对上号
        $topChar = [Math]::Max(0, $box.GetCharIndexFromPosition((New-Object Drawing.Point(1, 1))))
        $first = Find-CfgLineAt $topChar
        # 用 GDI 的 TextRenderer 而不是 GDI+ 的 DrawString：行号的 Y 常常是带小数的，
        # DrawString 会按亚像素抗锯齿，两位数看着像"叠影"；TextRenderer 吸附到整数像素，清楚得多
        $flags = ([Windows.Forms.TextFormatFlags]::Right -bor
                  [Windows.Forms.TextFormatFlags]::NoPadding -bor
                  [Windows.Forms.TextFormatFlags]::SingleLine -bor
                  [Windows.Forms.TextFormatFlags]::VerticalCenter)
        for ($i = $first; $i -lt $starts.Count; $i++) {
            $pt = $box.GetPositionFromCharIndex($starts[$i])
            if ($pt.Y -gt $h) { break }
            $num = [string]($i + 1)
            $rf = New-Object Drawing.Rectangle(0, ([int][Math]::Round($pt.Y)), ($w - 7), $lineH)
            if (($i + 1) -eq $script:cfgErrorLine) {
                [Windows.Forms.TextRenderer]::DrawText($g, $num, $script:gutterFontBold, $rf, $script:gutterColorBad, $flags)
            } else {
                [Windows.Forms.TextRenderer]::DrawText($g, $num, $script:gutterFont, $rf, $script:gutterColor, $flags)
            }
        }
    } catch { }
})

function Update-CfgCaretStatus {
    # 状态行：共几行、光标停在第几行第几列。有报错时让报错文字占着，不覆盖。
    $lbl = $script:lblCfgError
    $box = $script:txtCfg
    if (-not $lbl -or -not $box) { return }
    if ($script:cfgErrorLine -gt 0) { return }
    try {
        Ensure-CfgLineIndex
        $caret = [Math]::Min([Math]::Max(0, $box.SelectionStart), $box.TextLength)
        $li = Find-CfgLineAt $caret
        $t = '共 ' + $script:cfgLineCount + ' 行 · 光标 第 ' + ($li + 1) + ' 行 第 ' + ($caret - $script:cfgLineStarts[$li] + 1) + ' 列'
        if ($lbl.Text -ne $t) {
            $lbl.ForeColor = [Drawing.Color]::FromArgb(110, 110, 110)
            $lbl.Text = $t
        }
    } catch { }
}

function Clear-ConfigErrorMark {
    # 去掉正文里的红字红底，并把状态行还原成"共 N 行 / 光标位置"
    $box = $script:txtCfg
    $script:cfgErrorLine = 0
    if ($box) {
        try {
            $caret = [Math]::Min([Math]::Max(0, $box.SelectionStart), $box.TextLength)
            $sel = $box.SelectionLength
            $box.SelectAll()
            $box.SelectionColor = [Drawing.Color]::Black
            $box.SelectionBackColor = [Drawing.Color]::White
            $box.SelectionFont = $script:cfgFontPlain
            $box.Select($caret, $sel)
        } catch { }
    }
    if ($script:lblCfgError) { $script:lblCfgError.ForeColor = [Drawing.Color]::FromArgb(110, 110, 110) }
    $script:gutterSig = ''
    Update-CfgGutter -Force
    Update-CfgCaretStatus
}

function Get-ConfigErrorPos {
    # 从"第 30 行第 9 列附近: …"里把行列抠出来；没写行列（比如结构检查）就返回 0
    param([string]$Text)
    $line = 0; $col = 0
    if ($Text) {
        $m = [regex]::Match([string]$Text, '第\s*(\d+)\s*行(?:第\s*(\d+)\s*列)?')
        if ($m.Success) {
            $line = [int]$m.Groups[1].Value
            if ($m.Groups[2].Success) { $col = [int]$m.Groups[2].Value }
        }
    }
    return [pscustomobject]@{ Line = $line; Col = $col }
}

function Show-ConfigErrorMark {
    # 把出错那一行正文标红（字红 + 浅红底 + 加粗），光标跳到该行并滚到可见处，
    # 行号栏里同一行的数字也变成红色加粗，三处指同一个位置。
    param([string]$Text)
    $box = $script:txtCfg
    if (-not $box) { return }
    Clear-ConfigErrorMark
    Ensure-CfgLineIndex                  # 定位用的是这张偏移表，先确保它跟正文一致
    $pos = Get-ConfigErrorPos $Text
    $line = $pos.Line
    $col = $pos.Col
    $note = ''
    if ($line -ge 1 -and $line -le $script:cfgLineCount) {
        $start = $script:cfgLineStarts[$line - 1]
        $end = if ($line -lt $script:cfgLineCount) { $script:cfgLineStarts[$line] - 1 } else { $box.TextLength }
        if ($end -lt $start) { $end = $start }
        try {
            $box.Select($start, ($end - $start))
            $box.SelectionColor = [Drawing.Color]::FromArgb(198, 30, 30)
            $box.SelectionBackColor = [Drawing.Color]::FromArgb(255, 238, 236)
            $box.SelectionFont = $script:cfgFontBold
            # 光标停在报错的那一列上，ScorllToCaret 会把这一行滚进视野
            $caret = $start
            if ($col -gt 1) { $caret = [Math]::Min($end, $start + $col - 1) }
            $box.Select($caret, 0)
            $box.ScrollToCaret()
        } catch { }
        $script:cfgErrorLine = $line
        $note = '第 ' + $line + ' 行已标红 · '
    } else {
        $note = '未通过校验 · '
    }
    $msg = (($Text -replace "`r?`n", ' ').Trim())
    if ($msg.Length -gt 60) { $msg = $msg.Substring(0, 60) + '…' }
    if ($script:lblCfgError) {
        $script:lblCfgError.ForeColor = [Drawing.Color]::FromArgb(198, 30, 30)
        $script:lblCfgError.Text = $note + $msg
    }
    $script:gutterSig = ''
    Update-CfgGutter -Force
}

function Show-ConfigErrorDialog {
    # 弹窗替代 MessageBox：MessageBox 的文字颜色改不了，这里自绘一个，
    # 出错提示本身用红字 + 加粗，行列号放最前面，和左边行号栏对得上。
    param([string]$Text)
    $pos = Get-ConfigErrorPos $Text
    $msg = (($Text -replace "`r?`n", ' ').Trim())
    if ($msg.Length -gt 320) { $msg = $msg.Substring(0, 320) + '…' }

    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = '配置格式错误'
    $dlg.ClientSize = New-Object Drawing.Size(596, 232)
    $dlg.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.StartPosition = [Windows.Forms.FormStartPosition]::CenterParent
    $dlg.BackColor = [Drawing.Color]::White
    $dlg.TopMost = $true
    $dlg.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    try { if ($script:appIcon) { $dlg.Icon = $script:appIcon } } catch { }

    $pic = New-Object Windows.Forms.PictureBox
    $pic.Location = New-Object Drawing.Point(20, 22)
    $pic.Size = New-Object Drawing.Size(32, 32)
    $pic.SizeMode = [Windows.Forms.PictureBoxSizeMode]::CenterImage
    $pic.Image = [Drawing.SystemIcons]::Warning.ToBitmap()
    $dlg.Controls.Add($pic)

    $lblHead = New-Object Windows.Forms.Label
    $lblHead.Location = New-Object Drawing.Point(66, 20)
    $lblHead.Size = New-Object Drawing.Size(510, 24)
    $lblHead.Text = '配置没保存，文件保持原样。'
    $lblHead.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10, [Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($lblHead)

    $lblErr = New-Object Windows.Forms.Label
    $lblErr.Location = New-Object Drawing.Point(66, 52)
    $lblErr.Size = New-Object Drawing.Size(510, 60)
    $lblErr.ForeColor = [Drawing.Color]::FromArgb(198, 30, 30)
    $lblErr.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
    $lblErr.Text = $msg
    $dlg.Controls.Add($lblErr)

    $lblTail = New-Object Windows.Forms.Label
    $lblTail.Location = New-Object Drawing.Point(66, 120)
    $lblTail.Size = New-Object Drawing.Size(510, 56)
    $lblTail.ForeColor = [Drawing.Color]::FromArgb(90, 90, 90)
    if ($pos.Line -ge 1) {
        $lblTail.Text = '「配置内容」页里第 ' + $pos.Line + ' 行已经用红字标出来了，光标也停在那一列；改好后可以再点一次「重启代理」。完整报错在「运行日志」页。'
    } else {
        $lblTail.Text = '「配置内容」页底部会用红字给出这条提示；改好后可以再点一次「重启代理」。完整报错在「运行日志」页。'
    }
    $dlg.Controls.Add($lblTail)

    $btnOk = New-Object Windows.Forms.Button
    $btnOk.Text = '确定'
    $btnOk.Size = New-Object Drawing.Size(96, 30)
    $btnOk.Location = New-Object Drawing.Point(480, 186)
    $btnOk.DialogResult = [Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($btnOk)
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnOk

    try {
        if ($script:form) { [void]$dlg.ShowDialog($script:form) } else { [void]$dlg.ShowDialog() }
    } finally {
        $dlg.Dispose()
    }
}

function Set-CfgBoxInnerLayout {
    # 行号栏 + 编辑框按容器当前大小摊开（不靠 Anchor：本机 Anchor 会算错）
    $panel = $script:panelCfgBox
    $gut = $script:gutterCfg
    $box = $script:txtCfg
    if (-not $panel -or -not $gut -or -not $box) { return }
    try {
        $iw = [Math]::Max(160, $panel.ClientSize.Width - 2)
        $ih = [Math]::Max(80, $panel.ClientSize.Height - 2)
        $gutW = 46
        $gut.Location = New-Object Drawing.Point(0, 0)
        $gut.Size = New-Object Drawing.Size($gutW, $ih)
        $box.Location = New-Object Drawing.Point($gutW, 0)
        $box.Size = New-Object Drawing.Size([Math]::Max(60, $iw - $gutW), $ih)
        $script:gutterSig = ''
        Update-CfgGutter -Force
    } catch { }
}

# --- tab 4：运行日志 ---
$tabLog = New-Object Windows.Forms.TabPage
$tabLog.Text = '运行日志'
$tabLog.Padding = New-Object Windows.Forms.Padding(3)
[void]$tabs.Controls.Add($tabLog)
$script:tabLog = $tabLog

$lblLog = New-Object Windows.Forms.Label
$lblLog.Text = "下面四个二级 tab：「控制台日志」「反代日志」「链路日志」各取最近 60 条（最新在最上），「日志详解」是字段与原因口径说明。`r`n切到本页或点「刷新」会重新读取；要全文就用底部的记事本按钮。"
$lblLog.AutoSize = $false
$lblLog.TextAlign = [Drawing.ContentAlignment]::TopLeft

$panelLog = New-HintPanel $lblLog 54
$tabLog.Controls.Add($panelLog)
$script:panelLog = $panelLog

$btnLogRefresh = New-Object Windows.Forms.Button
$btnLogRefresh.Text = '刷新日志'
$btnLogRefresh.Location = New-Object Drawing.Point(6, 330)
$btnLogRefresh.Size = New-Object Drawing.Size(96, 26)
$tabLog.Controls.Add($btnLogRefresh)
$script:btnLogRefresh = $btnLogRefresh

$btnLogOpen = New-Object Windows.Forms.Button
$btnLogOpen.Text = '用记事本打开反代日志'
$btnLogOpen.Location = New-Object Drawing.Point(108, 330)
$btnLogOpen.Size = New-Object Drawing.Size(160, 26)
$tabLog.Controls.Add($btnLogOpen)

$btnLogOpenUi = New-Object Windows.Forms.Button
$btnLogOpenUi.Text = '用记事本打开控制台日志'
$btnLogOpenUi.Location = New-Object Drawing.Point(274, 330)
$btnLogOpenUi.Size = New-Object Drawing.Size(176, 26)
$tabLog.Controls.Add($btnLogOpenUi)

$btnLogOpenTrace = New-Object Windows.Forms.Button
$btnLogOpenTrace.Text = '打开链路日志'
$btnLogOpenTrace.Location = New-Object Drawing.Point(456, 330)
$btnLogOpenTrace.Size = New-Object Drawing.Size(156, 26)
$tabLog.Controls.Add($btnLogOpenTrace)

# 二级 tab：控制台日志 / 反代日志 / 链路日志 / 日志详解，各占一个只读文本框
$logTabs = New-Object Windows.Forms.TabControl
$logTabs.Location = New-Object Drawing.Point(6, 38)
$logTabs.Size = New-Object Drawing.Size(620, 286)
$logTabs.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$logTabs.ItemSize = New-Object Drawing.Size(104, 24)
$logTabs.SizeMode = [Windows.Forms.TabSizeMode]::Fixed
$logTabs.DrawMode = [Windows.Forms.TabDrawMode]::OwnerDrawFixed
$logTabs.add_DrawItem({
    param($sender, $e)
    $g = $e.Graphics
    $rect = $e.Bounds
    $rf = New-Object Drawing.RectangleF([single]$rect.X, [single]$rect.Y, [single]$rect.Width, [single]$rect.Height)
    $fmt = New-Object Drawing.StringFormat
    $fmt.Alignment = [Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [Drawing.StringAlignment]::Center
    $text = $sender.TabPages[$e.Index].Text
    if ($e.Index -eq $sender.SelectedIndex) {
        $b = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(31, 111, 191))
        $g.FillRectangle($b, $rect)
        $b.Dispose()
        $fb = New-Object Drawing.Font($sender.Font, [Drawing.FontStyle]::Bold)
        $g.DrawString($text, $fb, [Drawing.Brushes]::White, $rf, $fmt)
        $fb.Dispose()
    } else {
        $g.FillRectangle([Drawing.SystemBrushes]::Control, $rect)
        $g.DrawString($text, $sender.Font, [Drawing.Brushes]::Black, $rf, $fmt)
    }
    $fmt.Dispose()
})

$logPageUi = New-Object Windows.Forms.TabPage
$logPageUi.Text = '控制台日志'
$logPageUi.Padding = New-Object Windows.Forms.Padding(4)
[void]$logTabs.TabPages.Add($logPageUi)

$txtLogUi = New-Object Windows.Forms.TextBox
$txtLogUi.Multiline = $true
$txtLogUi.ReadOnly = $true
$txtLogUi.ScrollBars = [Windows.Forms.ScrollBars]::Both
$txtLogUi.WordWrap = $false
$txtLogUi.Font = New-Object Drawing.Font('Consolas', 9)
$txtLogUi.BackColor = [Drawing.Color]::White
$txtLogUi.Dock = [Windows.Forms.DockStyle]::Fill
$logPageUi.Controls.Add($txtLogUi)
$script:txtLogUi = $txtLogUi

$logPageRelay = New-Object Windows.Forms.TabPage
$logPageRelay.Text = '反代日志'
$logPageRelay.Padding = New-Object Windows.Forms.Padding(4)
[void]$logTabs.TabPages.Add($logPageRelay)

$txtLogRelay = New-Object Windows.Forms.TextBox
$txtLogRelay.Multiline = $true
$txtLogRelay.ReadOnly = $true
$txtLogRelay.ScrollBars = [Windows.Forms.ScrollBars]::Both
$txtLogRelay.WordWrap = $false
$txtLogRelay.Font = New-Object Drawing.Font('Consolas', 9)
$txtLogRelay.BackColor = [Drawing.Color]::White
$txtLogRelay.Dock = [Windows.Forms.DockStyle]::Fill
$logPageRelay.Controls.Add($txtLogRelay)
$script:txtLogRelay = $txtLogRelay

$logPageTrace = New-Object Windows.Forms.TabPage
$logPageTrace.Text = '链路日志'
$logPageTrace.Padding = New-Object Windows.Forms.Padding(4)
[void]$logTabs.TabPages.Add($logPageTrace)

$txtLogTrace = New-Object Windows.Forms.TextBox
$txtLogTrace.Multiline = $true
$txtLogTrace.ReadOnly = $true
$txtLogTrace.ScrollBars = [Windows.Forms.ScrollBars]::Both
$txtLogTrace.WordWrap = $false
$txtLogTrace.Font = New-Object Drawing.Font('Consolas', 9)
$txtLogTrace.BackColor = [Drawing.Color]::White
$txtLogTrace.Dock = [Windows.Forms.DockStyle]::Fill
$logPageTrace.Controls.Add($txtLogTrace)
$script:txtLogTrace = $txtLogTrace

$logPageGuide = New-Object Windows.Forms.TabPage
$logPageGuide.Text = '日志详解'
$logPageGuide.Padding = New-Object Windows.Forms.Padding(4)
[void]$logTabs.TabPages.Add($logPageGuide)

$txtLogGuide = New-Object Windows.Forms.TextBox
$txtLogGuide.Multiline = $true
$txtLogGuide.ReadOnly = $true
$txtLogGuide.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
$txtLogGuide.WordWrap = $true
$txtLogGuide.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$txtLogGuide.BackColor = [Drawing.Color]::White
$txtLogGuide.BorderStyle = [Windows.Forms.BorderStyle]::None
$txtLogGuide.Dock = [Windows.Forms.DockStyle]::Fill
$guideText = @'
链路日志 · 口径详解（mcp-relay-trace.log）
每条记录以 trace= 后的 12 位编号贯穿单次请求的接入、上游、交付、结束全过程；同一 trace_id 的多条记录属于同一次请求。每组请求以一条等号分隔线开头，把 CONNECT / UPSTREAM / END 框成一组。

一、三类事件
CONNECT  客户端接入
  proxy        代理名（配置里的 name）
  client       客户端地址
  method       HTTP 方法（GET / POST / DELETE 等）
  path         请求路径
  ctype        请求 Content-Type
  accept       请求 Accept 头
  proto        MCP-Protocol-Version 协议版本头（没有则省略）
  session      是否携带会话号（yes / no，不记会话号真值）
  auth         是否携带鉴权（present / missing，不记 Token 真值）
  req_bytes    请求体字节数

UPSTREAM 上游链路
  upstream        上游地址（host:port）
  connect_status  建连状态（ok 表示已连上上游）
  status          上游响应状态码
  ctype           响应 Content-Type
  te              Transfer-Encoding（没有则记 -）
  cl              Content-Length（没有则记 -）
  up_connect_ms   建连耗时（毫秒）

END 下游交付与结束
  reason          结束原因（见下表）
  up_bytes        从上游收到的字节数
  down_bytes      写入下游的字节数（写入层接受量，不等于客户端已确认读取）
  dur_ms          本次链路总时长（毫秒）
  first_up_ms     距启动到首个上游字节
  first_down_ms   距启动到首个下游写入
  first_event_ms  距启动到首个完整 SSE 事件（无事件记 -）
  last_active_ms  最后一次活动距启动
  backpressure    背压状态（当前阻塞写无显式信号，记 n/a）
  idle            是否静默长流（yes = 流保持但尚无完整业务事件）

二、结束原因（reason）对照表
NORMAL_CLOSE          正常关闭，请求与响应完整走完。
CLIENT_DISCONNECTED   客户端主动断开：对端关闭连接、超时取消或中断。
UPSTREAM_DISCONNECTED 上游连不上或中途断开：端口没开、拒绝连接、无响应后断开。
RESPONSE_TIMEOUT      上游响应超时：建连或读响应等到超时。
IDLE_TIMEOUT          长流静默等到超时；属空闲，不是业务错误。
DOWNSTREAM_WRITE_ERROR 向下游写数据失败（断连/重置之外的写异常）。
CONNECT_TIMEOUT       预留：TCP 建连超时（当前与响应超时合并记 RESPONSE_TIMEOUT）。
STREAM_PARSE_ERROR    预留：流解析错误（纯透传不解析报文，当前不产生）。
UNKNOWN_ERROR         未归类异常，需结合「反代日志」页的具体报错排查。

三、SSE 长流怎么读
- 200 + text/event-stream 只代表流已建立，不等于已经收到首帧。
- first_event_ms=- 且 idle=yes：连接保持但还没有完整业务事件，是静默，不要当成错误。
- 完整事件按字节流里的空行（空行分隔）判定；HTTP chunk 边界不算事件边界。
- up_bytes 与 down_bytes 应一致；对不上说明中途有断开或写失败。
- 心跳注释帧（: ping 一类）也会计入字节数。

四、安全口径
- 不记录 Authorization、Token、Cookie、Session ID 真实值，只记有无。
- 默认不记录工具调用参数与响应正文。
- 按 trace_id 可在 mcp-relay-trace.log 里追到单次请求的全部记录。

五、常见场景速查
- 401：auth=missing 或上游判定凭证无效；先核对连接器的鉴权头与 Token。


- 502 / UPSTREAM_DISCONNECTED：上游没开、端口不对，或 HTTPS / HTTP 写反。
- 长流挂起无数据：idle=yes 是静默；first_up_ms=- 表示上游首字节都没到。
- 客户端掉了：reason=CLIENT_DISCONNECTED，多为连接器超时或主动取消。
- 字节对不上：up_bytes ≠ down_bytes，按 reason 区分是上游断还是下游写失败。

原始记录见「链路日志」页；详细报错堆栈见「反代日志」页。
'@
$txtLogGuide.Text = (To-Crlf $guideText)

# 参照「使用说明」：外层带边框 Panel 留内边距，内层 TextBox 无边框铺满，文字不贴边框
$panelGuide = New-Object Windows.Forms.Panel
$panelGuide.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$panelGuide.BackColor = [Drawing.Color]::White
$panelGuide.Padding = New-Object Windows.Forms.Padding(10, 8, 10, 8)
$panelGuide.Location = New-Object Drawing.Point(6, 6)
$panelGuide.Size = New-Object Drawing.Size(620, 340)
$panelGuide.Controls.Add($txtLogGuide)
$logPageGuide.Controls.Add($panelGuide)
$script:panelGuide = $panelGuide
$script:txtLogGuide = $txtLogGuide

$tabLog.Controls.Add($logTabs)
$script:logTabs = $logTabs

# --- tab 5：MCP 探针 ---
$tabProbe = New-Object Windows.Forms.TabPage
$tabProbe.Text = 'MCP探针'
$tabProbe.Padding = New-Object Windows.Forms.Padding(3)
[void]$tabs.Controls.Add($tabProbe)
$script:tabProbe = $tabProbe

$lblProbeHint = New-Object Windows.Forms.Label
$lblProbeHint.Text = "地址必须填「上游本体地址」——服务自己监听的那个地址，形如 http(s)://127.0.0.1:端口/mcp。不要填反代对你的监听地址（192.168.x.x:端口）：那是门面，Host 已被反代改写，探针在这儿测不出真实情况，Host 校验只能跳过。`r`n点「开始探测」：按旧规范发 initialize、按新规范发能力发现请求（server/discover），再发一发只换 Host 头的变体，判断上游是否存在 Host 限制、是否需要改写 rewrite_host。上游要登录就在令牌框填 API Key，只发 Authorization: Bearer，内容打码、不写日志。"
$lblProbeHint.AutoSize = $false
$lblProbeHint.TextAlign = [Drawing.ContentAlignment]::TopLeft
$panelProbeHint = New-HintPanel $lblProbeHint 64
$tabProbe.Controls.Add($panelProbeHint)
$script:panelProbeHint = $panelProbeHint

$lblProbeUrl = New-Object Windows.Forms.Label
$lblProbeUrl.Text = '上游本体地址:'
$tabProbe.Controls.Add($lblProbeUrl)
$script:lblProbeUrl = $lblProbeUrl

$txtProbeUrl = New-Object Windows.Forms.TextBox
$txtProbeUrl.Text = (Get-DefaultProbeUrl)
$tabProbe.Controls.Add($txtProbeUrl)
$script:txtProbeUrl = $txtProbeUrl

$lblProbeToken = New-Object Windows.Forms.Label
$lblProbeToken.Text = '令牌(Bearer):'
$tabProbe.Controls.Add($lblProbeToken)
$script:lblProbeToken = $lblProbeToken

$txtProbeToken = New-Object Windows.Forms.TextBox
$txtProbeToken.PasswordChar = [char]0x2022
$tabProbe.Controls.Add($txtProbeToken)
$script:txtProbeToken = $txtProbeToken

$btnProbe = New-Object Windows.Forms.Button
$btnProbe.Text = '开始探测'
$tabProbe.Controls.Add($btnProbe)
$script:btnProbe = $btnProbe

$txtProbeResult = New-Object Windows.Forms.RichTextBox
$txtProbeResult.ReadOnly = $true
$txtProbeResult.DetectUrls = $false
$txtProbeResult.ShortcutsEnabled = $true
$txtProbeResult.ScrollBars = [Windows.Forms.RichTextBoxScrollBars]::Vertical
$txtProbeResult.WordWrap = $true
$txtProbeResult.Font = New-Object Drawing.Font('Consolas', 9)
$txtProbeResult.BackColor = [Drawing.Color]::White
$tabProbe.Controls.Add($txtProbeResult)
$script:txtProbeResult = $txtProbeResult

$btnProbe.add_Click({ Start-Probe })

# --- tab 6：使用说明（说明书）---
$tabHelp = New-Object Windows.Forms.TabPage
$tabHelp.Text = '使用说明'
$tabHelp.Padding = New-Object Windows.Forms.Padding(3)
[void]$tabs.Controls.Add($tabHelp)
$script:tabHelp = $tabHelp

$txtHelp = New-Object Windows.Forms.TextBox
$txtHelp.Multiline = $true
$txtHelp.ReadOnly = $true
$txtHelp.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
$txtHelp.WordWrap = $true
$txtHelp.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$txtHelp.BackColor = [Drawing.Color]::White
$txtHelp.BorderStyle = [Windows.Forms.BorderStyle]::None
$txtHelp.Dock = [Windows.Forms.DockStyle]::Fill
$txtHelp.Text = @'
XMCP 局域网反代工具 · 使用说明
================================

一、这套工具解决什么问题
1. 很多本地服务默认只监听 127.0.0.1（本机回环），而且监听地址写死在程序里，改不了：
   虚拟机、另一台电脑、手机都访问不到。
   · 典型例子：XTerminal 自带的 MCP 服务把 127.0.0.1、路径 /mcp 硬编码在 asar 里；
   · 同类情况还有很多：Claude / Cursor 用的本地 MCP server、只绑 localhost 的本地 API、
     IDE 插件自启的 Web 控制台、某些调试代理、内网工具的管理页面……
   只要「只能在本机访问 + 地址改不动」，本工具都能把它们安全地转发到局域网。
2. 硬改程序本体（解包 asar、改配置文件、改注册表）代价大：升级会被覆盖，出问题没法回滚，
   还可能有授权与合规风险，所以本方案一律不去动第三方程序。
3. 只用 netsh portproxy 这类纯端口转发也不行：端口能通，但请求带的 Host 头还是
   192.168.110.1:12335，而服务端只认 127.0.0.1，直接回 403。
   所以中间必须有一层能改写 Host 的反代——这就是本工具的定位。

二、本工具怎么解决
1. 反代本体（xterminal-mcp-lan-relay.py，纯 Python 标准库，不依赖第三方包）：
   把「局域网地址:端口」的请求转到「本机地址:端口」，并按配置决定是否把 Host / Origin 改写成本机地址。
   文件名里的 xterminal 只是因为它诞生于 XTerminal 这个场景，转发逻辑本身与具体软件无关。
2. 配置外置（mcp-relay.config.json）：一个文件里可以写多条 proxy，每条都是
   「listen（可写多个地址）→ target（上游）」，外加 rewrite_host、超时等开关。
   换一个要转发的服务，只要加一段配置，不用改一行代码。
3. 防火墙精确放行：只放开 listen 里列出的端口，其余 TCP 与 UDP 全段 Block，
   避免为了一个服务把整台机器的端口都暴露到虚拟网络。
4. 控制台（本程序）：启动 / 重启 / 停止、连通性自检、配置编辑与校验、日志查看、使用说明，
   全部收在一个窗口里，双击即用。

三、适用范围（能转什么、不能转什么）
适合：
· 只监听 127.0.0.1 的 TCP 服务：MCP server、本地 HTTP / REST API、Web 控制台、调试端口；
· 只开加密端口的本机服务：target 写 https://127.0.0.1:端口，反代自己去谈 TLS（不校验证书），
  对外仍是明文 HTTP，客户端不用装证书（Obsidian 的 Local REST API 就是这种）；
· 地址写死在程序里、或改了会破坏签名 / 升级即失效的服务；
· 需要「多台虚拟机共享宿主机上一个本机服务」的场景；
· 需要「改配置不改代码」：加一个服务只改 JSON。
不适合：
· UDP 服务（本反代只做 TCP）；
· 需要路径重写、改响应体的场景（这里只做端口 + Host 头转发）；
· 服务端除 Host 外还校验来源 IP / 令牌白名单的，转发后仍可能被拒，需要服务端放行；
· 需要开机自启常驻的关键业务（本工具手动启停，不注册系统服务）。

四、典型应用场景
· 虚拟机里的 Linux 用宿主机的 XTerminal SSH / MCP 工具链；
· Cursor / Claude 等客户端要连一个只绑 127.0.0.1 的本地 MCP server，客户端却在另一台机器；
· 一台 Windows 当跳板，多台虚拟机共享同一套本机服务，不必每台各装一份；
· 内网联调：既要给虚拟机开端口，又不想把整台机器的端口敞开；
· 临时把某个本机 Web 工具暴露给同事看一眼，用完点「2. 退出关闭」即收回。

五、怎么用（三步）
1. 双击桌面「XMCP 反代工具」快捷方式（直连 powershell 隐藏启动，不弹黑窗）；命令行排障可直接跑 XMCP控制台.bat。
   程序会自动拉起反代并自检，状态页 [连通性] 全为「连通」、healthy=True 即正常；
   出现「上游异常」说明反代在跑但上游没应答，缩进行会写出具体卡在哪。
2. 客户端（虚拟机 / 另一台电脑）里访问 http://192.168.110.1:12335/mcp（带令牌），
   或按对应软件的地址格式填 192.168.110.1:12335。
3. 要再转发一个服务：在「配置内容」页的 proxies 数组里加一段，例如
     "name": "我的本地服务", "enabled": true,
     "listen": ["192.168.110.1:8088"], "target": "127.0.0.1:8080",
     "rewrite_host": false, "upstream_timeout": 60
   点「重启代理」——先校验格式，通过才写盘（旧文件备份 .bak）并重启；
   随后在状态页 [监听] 确认新端口已 LISTENING，[连通性] 显示「连通」。
4. 「MCP探针」页：地址必须填「上游本体地址」（服务自己监听的那个，如 127.0.0.1:端口/mcp；
   别填反代对你的监听地址，Host 已被改写，测不出真实情况）。点「开始探测」后，
   探针按旧规范 initialize、新规范能力发现请求（server/discover）各打一发，有会话号再探通知流与会话删除，
   最后再打一发只换 Host 头的变体，输出报告：两条协议腿是否支持、会话能力（会话号 /
   GET 流 / DELETE 会话）、服务端能力（Tools / Resources / Prompts）、上游是否存在 Host 限制、
   是否需要改写 rewrite_host，结论分双协议 / 仅旧 / 仅新 / 需要令牌 / 连不上 / Host 受限。

六、几个容易踩的点
· rewrite_host 只在服务端校验 Host 时才设 true（XTerminal 必须 true，否则 403）；
  如果上游是普通 Web 服务、按 Host 分发站点，乱改反而会 404 / 400，那就设 false。
· 401 / 404 / 200 都算「连通」：401 缺令牌、404 路径不对，都说明已到达上游；000 才是「不通」。
· 5xx（常见 502）单列「上游异常」：说明反代在跑、但上游没应答（没开、端口写错、只开 HTTPS 却写了 http）。
  它不算通达，也别当成服务正常；这时探针直连上游同样会报 000「连不上」，两边说的是同一件事。
· 上游只开 HTTPS 时，target 要写 https://127.0.0.1:端口。漏写协议前缀的表现是：日志里
  UPSTREAM FAIL ... Remote end closed connection without response，客户端拿到 502。
· 配置支持 # 注释：# 到行尾整段忽略，字符串里的 # 不算注释；数组最后一项留逗号也不报错。
· 反代不会开机自启：需要时双击控制台。点「1.最小化」收托盘后反代仍在跑，双击托盘图标可再打开。
· 换端口要同步改客户端：防火墙按 listen 自动推导，客户端里填的端口要自己改。
· 只想临时开一个端口：把其它 proxy 的 enabled 设成 false，或点「2. 退出关闭」停掉反代。

七、文件都在这个目录
XMCP控制台.bat                            命令行排障入口（经一层 cmd，会带控制台窗口）
XMCP 反代工具.lnk                         首次运行自动生成（X 图标），指错会自动改写
重建快捷方式.bat                          在桌面也建一份快捷方式
XMCP控制台.ps1                            控制台本体
xterminal-mcp-lan-relay.py                反代（名字沿用历史，逻辑通用）
start-mcp-relay.ps1 / stop-mcp-relay.ps1  启动 / 停止
restart-mcp-relay.ps1                     重启（停+启合并到一个进程，省一次冷启动）
relay-config.ps1 / firewall-sync.ps1      配置解析 / 防火墙同步
validate-config.py / format-config.py     配置校验 / 自动排版
mcp-relay.config.json（含 .bak 备份）      配置（可加多条 proxy）
mcp-relay.log / xmcp-console.log          反代日志 / 控制台日志
mcp-relay-trace.log                       链路诊断日志（按 trace_id 贯穿接入/上游/交付/结束）
xmcp.ico                                  图标
README.md                                 完整文档（含排障记录）

八、分享给别人 / 换一台机器
1. 直接把整个目录打包（zip 或拷 U 盘）发出去，对方解压到任意路径即可，不需要安装。
2. 第一次双击桌面快捷方式，程序会自己完成三件事：
   · 没有 mcp-relay.config.json 就按本机网卡自动生成一份（监听地址、网段都取当前机器）；
   · 在目录里生成「XMCP 反代工具.lnk」（黄底黑 X 图标），以后双击它就够；
   · 起反代 + 比对防火墙（首次会弹一次 UAC，允许即可）。
3. 对方机器需要自己装 Python 3（程序会自动找 pythonw/python，找不到会在状态页提示）。
4. 上游服务（例如 XTerminal 的 MCP）没装或没开时，连通性会显示 000 不通——这是正常的，
   装好上游、把 target 改成它实际监听的 127.0.0.1 端口即可。
5. 打包前建议删掉本机的运行时文件，避免把别人的环境信息带出去：
   mcp-relay.config.json（及 .bak）、mcp-relay.log、mcp-relay-trace.log、mcp-relay.pid、
   xmcp-console.log、xmcp-console-status.txt、firewall-state.txt、firewall-fingerprint.txt、
   firewall-pending.txt、
   「XMCP 反代工具.lnk」。程序会在首次运行时自动重新生成。
6. 想先静默初始化（不弹窗口、不起反代）：
   powershell -ExecutionPolicy Bypass -File XMCP控制台.ps1 -BootstrapOnly
'@

$panelHelp = New-Object Windows.Forms.Panel
$panelHelp.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$panelHelp.BackColor = [Drawing.Color]::White
$panelHelp.Padding = New-Object Windows.Forms.Padding(10, 8, 10, 8)
$panelHelp.Location = New-Object Drawing.Point(6, 6)
$panelHelp.Size = New-Object Drawing.Size(620, 340)
$panelHelp.Controls.Add($txtHelp)
$tabHelp.Controls.Add($panelHelp)
$script:panelHelp = $panelHelp
$script:txtHelp = $txtHelp

# --- tab 7：关于软件 ---
$tabAbout = New-Object Windows.Forms.TabPage
$tabAbout.Text = '关于软件'
$tabAbout.Padding = New-Object Windows.Forms.Padding(3)
[void]$tabs.Controls.Add($tabAbout)
$script:tabAbout = $tabAbout

$txtAbout = New-Object Windows.Forms.TextBox
$txtAbout.Multiline = $true
$txtAbout.ReadOnly = $true
$txtAbout.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
$txtAbout.WordWrap = $true
$txtAbout.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$txtAbout.BackColor = [Drawing.Color]::White
$txtAbout.BorderStyle = [Windows.Forms.BorderStyle]::None
$txtAbout.Dock = [Windows.Forms.DockStyle]::Fill
$txtAbout.Text = @'
XMCP 反代工具

版本号      1.1.0（2026-11-20）
作者        极客盟工具开发组
问题反馈    联系微信 xywaykie

适用系统    Windows 10 / 11（64 位）
运行依赖    Windows PowerShell 5.1 + Python 3（自动探测：常见安装目录或系统 PATH 均可）
安装方式    绿色版、免安装：解压即用，整个目录可随意拷贝，不写注册表、不改系统设置

界面技术    PowerShell + WinForms，单窗口七页：
            状态 / 配置格式 / 配置内容 / 运行日志 / MCP探针 / 使用说明 / 关于软件
反代实现    Python 标准库（socket + threading），不依赖任何第三方包
上游支持    target 可写 http:// 或 https://；https 给只开加密端口的服务，不校验自签证书，对外仍明文
防火墙      按配置自动生成「精确放行 + 补集拦截」规则组 XMCP relay，需管理员权限时弹一次 UAC

功能一览
· 多代理并存：一份 JSON 挂任意多组「监听地址 -> 上游」，各自独立启停，互不影响；
· Host 改写：rewrite_host 把 Host 头改成上游的 host:port，适用于上游校验 Host、只认本机名而回 403 的场景；
· 状态自检：进程 / 监听 / 连通性 / 防火墙四段，段与段之间用横线隔开，一眼看出是哪一类信息；
· 三档连通性：000 不通（红）、5xx 上游异常（橙，不计通达）、其余已到达上游（绿），
  小结行单独报「几个通达、几个上游异常、几个不通」，不再拿 502 冒充可达；
· 原因写清楚：每条结果下面再给一行具体原因——上游没监听、在监听但不应答、防火墙拦下、
  HTTPS 目标握不上、令牌缺失，以及 rewrite_host 的实况（已是 true 就不再劝你改）；
· MCP 探针：填上游本体地址 + 可选令牌，按旧规范 initialize、新规范 server/discover 各打一发，
  握出会话号再探 GET 通知流与 DELETE 会话，输出兼容性矩阵（双协议 / 仅旧 / 仅新 / 需要鉴权 / 连不上）；
· Host 校验：探针额外打一发只换 Host 头的变体，与基线对比，判断上游是否存在 Host 限制、是否需要改写 rewrite_host；
· 配置编辑：内置编辑器 + 行列定位校验 + 一键格式化（每键一行、2 空格缩进），保存前先验证并留 .bak；
· 双日志分栏：控制台日志与反代日志分开看，最新一条永远在最上面；
· 托盘常驻：最小化到右下角，双击图标还原；关窗口不杀反代，反代掉线再还原会自动拉起；
· 一键复制：底部「全选复制」按当前页取内容，状态、报告、配置都能直接贴出去排查。

程序特点
· 不改第三方程序文件：XTerminal 的 asar 一行没动；
· 配置外置：监听地址、上游、超时、日志大小全部写在 JSON 里，改配置不改代码；
· 启动即自检：自动拉起反代、自动比对防火墙、自动测连通性，状态页直接给结论；
· 出错有话说：格式错误定位到行列，配置不会被写坏，旧文件留 .bak。

同目录脚本（命令行也能用）
· start / stop / restart-mcp-relay.ps1     反代启停
· check-mcp-relay.ps1                      不开界面也能跑一遍自检
· validate-config.py / format-config.py    配置校验与格式化
· firewall-sync.ps1                        同步防火墙规则（需管理员）

许可与声明
本程序为内部自用工具，请勿把配置文件里的内网地址、端口与令牌对外传播。
本程序只做端口转发与 Host 改写，不采集、不上传任何数据。

文档        README.md（在程序目录下，含完整部署说明、探针用法与排障记录）
'@

$panelAbout = New-Object Windows.Forms.Panel
$panelAbout.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$panelAbout.BackColor = [Drawing.Color]::White
$panelAbout.Padding = New-Object Windows.Forms.Padding(10, 8, 10, 8)
$panelAbout.Location = New-Object Drawing.Point(6, 6)
$panelAbout.Size = New-Object Drawing.Size(620, 340)
$panelAbout.Controls.Add($txtAbout)
$tabAbout.Controls.Add($panelAbout)
$script:panelAbout = $panelAbout
$script:txtAbout = $txtAbout
# 多行文本框只认 CRLF：LF-only 会把整段挤成一行，这里强制归一（源文件是 CRLF 时等于不变）
$txtAbout.Text = (($txtAbout.Text -replace "`r`n", "`n") -replace "`n", "`r`n")


# ================= 底部操作按钮（只留三个）=================
$btnRun = New-Object Windows.Forms.Button
$btnRun.Text = '检测中…'
$btnRun.Enabled = $false
$btnRun.Location = New-Object Drawing.Point(12, 452)
$btnRun.Size = New-Object Drawing.Size(180, 40)
$form.Controls.Add($btnRun)

$btnRecheck = New-Object Windows.Forms.Button
$btnRecheck.Text = '重启代理'
$btnRecheck.Location = New-Object Drawing.Point(200, 452)
$btnRecheck.Size = New-Object Drawing.Size(200, 40)
$form.Controls.Add($btnRecheck)

$btnQuit = New-Object Windows.Forms.Button
$btnQuit.Text = '2. 退出关闭'
$btnQuit.Location = New-Object Drawing.Point(408, 452)
$btnQuit.Size = New-Object Drawing.Size(256, 40)
$form.Controls.Add($btnQuit)

$script:btnRun = $btnRun
$script:btnRecheck = $btnRecheck
$script:btnQuit = $btnQuit
Write-UiLog ('t=' + [Math]::Round($script:sw.Elapsed.TotalSeconds, 1) + 's ui built')

$lblHint = New-Object Windows.Forms.Label
$lblHint.Text = '连通 → 点"1. 最小化"收进托盘；配置与日志在顶部 tab 里改、查。'
$lblHint.Location = New-Object Drawing.Point(12, 502)
$lblHint.Size = New-Object Drawing.Size(656, 20)
$form.Controls.Add($lblHint)
$script:lblHint = $lblHint
$script:hintBase = $lblHint.Text

# 底部按钮行最右侧的「全选复制」：一键选中当前页内容并放进剪贴板
$btnSelCopy = New-Object Windows.Forms.Button
$btnSelCopy.Text = '全选复制'
$btnSelCopy.Location = New-Object Drawing.Point(586, 457)
$btnSelCopy.Size = New-Object Drawing.Size(90, 30)
$btnSelCopy.FlatStyle = [Windows.Forms.FlatStyle]::Flat
$btnSelCopy.add_Click({
    $box = $null
    try {
        switch ($script:tabs.SelectedTab.Text) {
            '状态'     { $box = $script:txtStatus }
            '配置格式' { $box = $txtSample }
            '配置内容' { $box = $script:txtCfg }
            'MCP探针' { $box = $script:txtProbeResult }
            '使用说明' { $box = $script:txtHelp }
            '关于软件' { $box = $script:txtAbout }
            '运行日志' {
                if ($script:logTabs -and $script:logTabs.SelectedTab) {
                    if ($script:logTabs.SelectedTab.Text -eq '日志详解') {
                        $box = $script:txtLogGuide
                    } else {
                        $box = $script:logTabs.SelectedTab.Controls[0]
                    }
                }
            }
        }
    } catch { $box = $null }
    if (-not $box) { return }
    $content = $box.Text
    if (-not $content) {
        $script:lblHint.Text = '当前页没有内容可复制。'
    } else {
        $box.Focus()
        $box.SelectAll()
        Set-Clipboard -Value $content
        $script:lblHint.Text = '已全选并复制 ' + $content.Length + ' 个字符（Ctrl+V 粘贴）。'
    }
    $tm = New-Object Windows.Forms.Timer
    $tm.Interval = 3000
    $tm.add_Tick({
        param($s, $e)
        $script:lblHint.Text = $script:hintBase
        $s.Stop()
        $s.Dispose()
    })
    $tm.Start()
})
$form.Controls.Add($btnSelCopy)
$script:btnSelCopy = $btnSelCopy

# ---- 托盘图标 ----
$icon = if ($script:icoSmall) { $script:icoSmall } else { $script:appIcon }
if (-not $icon -and (Test-Path -LiteralPath $pywExe)) {
    try { $icon = [Drawing.Icon]::ExtractAssociatedIcon($pywExe) } catch { $icon = $null }
}
if (-not $icon) { $icon = [Drawing.SystemIcons]::Application }

$ni = New-Object Windows.Forms.NotifyIcon
$ni.Icon = $icon
$ni.Text = 'XMCP 反代'
$ni.Visible = $false
$script:ni = $ni

$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('打开控制台')
[void]$menu.Items.Add('重启代理')
[void]$menu.Items.Add('停止代理并退出')
$ni.ContextMenuStrip = $menu
$script:menu = $menu

$script:miOpen   = $menu.Items[0]
$script:miCheck  = $menu.Items[1]
$script:miStop   = $menu.Items[2]

$ni.add_DoubleClick({ Show-Console })
$script:miOpen.add_Click({ Show-Console })
$script:miCheck.add_Click({
    Invoke-Recheck
})
$script:miStop.add_Click({ Stop-And-Exit })

# ---- 按钮与 tab 事件 ----
# 1. 最小化：状态已判定为"通"，直接缩托盘（不再重检，零等待）
$btnRun.add_Click({ Hide-ToTray })

# 3. 重启代理 = 有改动先校验保存，再重启一次代理（全部在后台跑，UI 不卡）
$btnRecheck.add_Click({ Invoke-Recheck })

$btnQuit.add_Click({ Stop-And-Exit })

# 配置内容页：记录是否改过（切 tab 时用来决定要不要重新读文件）
$txtCfg.add_TextChanged({
    Update-CfgLineIndex                                          # 行号栏靠这张偏移表，内容一变立刻重建
    if ($script:cfgErrorLine -gt 0) { Clear-ConfigErrorMark }    # 已经改动了，上一轮的红字位置就不作数了
    Update-CfgGutter -Force
    if ($script:suppressDirty) { return }
    if ($script:configDirty -ne $true) { $script:configDirty = $true }
})

# 行号栏和状态行的轻量刷新：不挂滚动/选中事件（自绘和选中会互相触发），
# 改成 150ms 轮询，只在「配置内容」页可见时跑；签名没变化就什么都不做。
$script:cfgUiTimer = New-Object Windows.Forms.Timer
$script:cfgUiTimer.Interval = 150
$script:cfgUiTimer.add_Tick({
    try {
        if (-not $script:form -or -not $script:form.Visible) { return }
        if (-not $script:tabs -or $script:tabs.SelectedTab -ne $script:tabEdit) { return }
        Update-CfgGutter
        Update-CfgCaretStatus
    } catch { }
})
$script:cfgUiTimer.Start()

# 日志页的两个小按钮
$btnLogRefresh.add_Click({ Update-LogView })
$btnLogOpen.add_Click({ Open-LogFile -Path (Join-Path $root 'mcp-relay.log') })
$btnLogOpenUi.add_Click({ Open-LogFile -Path $uiLog })
$btnLogOpenTrace.add_Click({ Open-LogFile -Path $traceLog })

# 切换 tab：进"配置内容"且没改动 → 重新读文件；进"运行日志" → 刷新日志
$tabs.add_SelectedIndexChanged({
    if (-not $script:configDirty) {
        if ($script:tabs.SelectedTab -eq $script:tabEdit) { Reload-ConfigEditor }
    }
    if ($script:tabs.SelectedTab -eq $script:tabLog) { Update-LogView }
})

# 后台启停任务的轮询（UI 线程只负责看是否完成）
$script:taskTimer = New-Object Windows.Forms.Timer
$script:taskTimer.Interval = 400
$script:taskTimer.add_Tick({
    if (-not $script:bgHandle) { $script:taskTimer.Stop(); return }
    $done = $true
    try { $done = $script:bgHandle.IsCompleted } catch { $done = $true }
    if (-not $done) { return }
    $script:taskTimer.Stop()
    $out = ''
    try { $out = (@($script:bgPs.EndInvoke($script:bgHandle)) -join ' ') } catch { $out = '任务异常: ' + $_.Exception.Message }
    try { $script:bgPs.Dispose() } catch { }
    $script:bgPs = $null
    $script:bgHandle = $null
    Write-UiLog ('relay task done: ' + (($out -replace "`r?`n", ' | ')))
    $script:btnQuit.Enabled = $true
    $script:btnRecheck.Enabled = $true
    Update-Status
    if ($script:tabs.SelectedTab -eq $script:tabLog) { Update-LogView }
    if ($script:autoTrayPending) {
        $script:autoTrayPending = $false
        if ($script:healthy) { Hide-ToTray }
    }
})

# 探针后台任务的轮询（与反代启停的 taskTimer 互不干扰）
$script:probeTimer = New-Object Windows.Forms.Timer
$script:probeTimer.Interval = 400
$script:probeTimer.add_Tick({
    if (-not $script:probeHandle) { $script:probeTimer.Stop(); return }
    $done = $true
    try { $done = $script:probeHandle.IsCompleted } catch { $done = $true }
    if (-not $done) { return }
    $script:probeTimer.Stop()
    $raw = ''
    try { $raw = (@($script:probePs.EndInvoke($script:probeHandle)) -join "`n") } catch { $raw = 'ERR=' + $_.Exception.Message }
    try { $script:probePs.Dispose() } catch { }
    $script:probePs = $null
    $script:probeHandle = $null
    try { Render-ProbeResult $raw } catch { Set-ProbeResult ('探针异常: ' + $_.Exception.Message) }
    $script:btnProbe.Enabled = $true
})

# 窗体可拉伸：所有控件按当前客户区重新排布（不依赖 Anchor，本机 Anchor 会算错尺寸）
function Update-Layout {
    try {
        if ($script:form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) { return }
        $w = $script:form.ClientSize.Width
        $h = $script:form.ClientSize.Height
        $tabs.Location = New-Object Drawing.Point(12, 8)
        $tabs.Size = New-Object Drawing.Size(($w - 24), ($h - 104))
        $pw = $tabs.ClientSize.Width - 10
        $ph = $tabs.ClientSize.Height - 30
        # 状态页
        $script:txtStatus.Location = New-Object Drawing.Point(6, 6)
        $script:txtStatus.Size = New-Object Drawing.Size(($pw - 12), ($ph - 12))
        Set-TextInnerPad $script:txtStatus
        # 配置格式页（说明框 + 样板）
        $script:panelSample.Location = New-Object Drawing.Point(6, 4)
        $script:panelSample.Size = New-Object Drawing.Size(($pw - 12), 72)
        $txtSample.Location = New-Object Drawing.Point(6, 84)
        $txtSample.Size = New-Object Drawing.Size(($pw - 12), ($ph - 92))
        # 配置内容页（编辑区 = 行号栏 + 富文本框，底下再留一行状态/报错）
        $script:panelEdit.Location = New-Object Drawing.Point(6, 4)
        $script:panelEdit.Size = New-Object Drawing.Size(($pw - 12), 46)
        $script:lblCfgState.Location = New-Object Drawing.Point(8, 58)
        # 「导入 / 导出」两个按钮：AutoSize 按实测文字宽度自适应（换 DPI / 缩放都不裁字），整体右对齐（右边距 6、间距 4）
        $wSave = $script:btnSaveCfg.PreferredSize.Width
        $wLoad = $btnLoadCfg.PreferredSize.Width
        $script:btnSaveCfg.Location = New-Object Drawing.Point(($pw - 6 - $wSave), 54)
        $btnLoadCfg.Location        = New-Object Drawing.Point(($pw - 6 - $wSave - 4 - $wLoad), 54)
        $script:panelCfgBox.Location = New-Object Drawing.Point(6, 90)
        $script:panelCfgBox.Size = New-Object Drawing.Size(($pw - 12), ($ph - 120))
        $script:lblCfgError.Location = New-Object Drawing.Point(8, ($ph - 26))
        $script:lblCfgError.Size = New-Object Drawing.Size(($pw - 16), 18)
        Set-CfgBoxInnerLayout
        # 运行日志页（二级 tab）
        $script:panelLog.Location = New-Object Drawing.Point(6, 4)
        $script:panelLog.Size = New-Object Drawing.Size(($pw - 12), 54)
        $script:logTabs.Location = New-Object Drawing.Point(6, 64)
        $script:logTabs.Size = New-Object Drawing.Size(($pw - 12), ($ph - 64 - 34))
        $btnLogRefresh.Location = New-Object Drawing.Point(6, ($ph - 32))
        $btnLogOpen.Location = New-Object Drawing.Point(108, ($ph - 32))
        $btnLogOpenUi.Location = New-Object Drawing.Point(274, ($ph - 32))
        $btnLogOpenTrace.Location = New-Object Drawing.Point(456, ($ph - 32))
        # MCP 探针页（说明框 + 地址一行 + 令牌/按钮一行 + 结果框）
        # 说明框高度按文字实际排版算，不写死：窗口拉宽后文字行数变少，框也跟着变矮，
        # 底下不留一片空白；下面的地址行/令牌行/结果框都相对框底往下排。
        $script:panelProbeHint.Location = New-Object Drawing.Point(6, 4)
        $hintBoxW = ($pw - 12)
        $hintTextW = $hintBoxW - 22          # 减掉边框 1×2 和内边距 10×2
        $hintH = 64
        try {
            $hintFont = if ($script:lblProbeHint.Font) { $script:lblProbeHint.Font } else { New-Object Drawing.Font('Microsoft YaHei UI', 9) }
            $hintMeas = [Windows.Forms.TextRenderer]::MeasureText(
                $script:lblProbeHint.Text, $hintFont,
                (New-Object Drawing.Size([Math]::Max(120, $hintTextW), 2000)),
                [Windows.Forms.TextFormatFlags]::WordBreak)
            $hintH = $hintMeas.Height + 14   # 上下内边距 5+5、边框 1+1，再留 2px 余量
            if ($hintH -lt 44) { $hintH = 44 }
        } catch { $hintH = 64 }
        $yBase = 4 + $hintH                  # 说明框底边
        $script:panelProbeHint.Size = New-Object Drawing.Size($hintBoxW, $hintH)
        $script:lblProbeUrl.Location = New-Object Drawing.Point(6, ($yBase + 10))
        $script:lblProbeUrl.Size = New-Object Drawing.Size(96, 22)
        $script:txtProbeUrl.Location = New-Object Drawing.Point(106, ($yBase + 8))
        $script:txtProbeUrl.Size = New-Object Drawing.Size(($pw - 112), 22)
        $script:lblProbeToken.Location = New-Object Drawing.Point(6, ($yBase + 38))
        $script:lblProbeToken.Size = New-Object Drawing.Size(100, 22)
        $btnProbe.Location = New-Object Drawing.Point(($pw - 6 - 96), ($yBase + 34))
        $btnProbe.Size = New-Object Drawing.Size(96, 26)
        $script:txtProbeToken.Location = New-Object Drawing.Point(106, ($yBase + 36))
        $script:txtProbeToken.Size = New-Object Drawing.Size(($pw - 216), 22)
        $script:txtProbeResult.Location = New-Object Drawing.Point(6, ($yBase + 66))
        $script:txtProbeResult.Size = New-Object Drawing.Size(($pw - 12), ($ph - $yBase - 66))
        Set-TextInnerPad $script:txtProbeResult
        # 使用说明页 / 关于软件页：整页一个带边框的阅读框
        $script:panelHelp.Location = New-Object Drawing.Point(6, 6)
        $script:panelHelp.Size = New-Object Drawing.Size(($pw - 12), ($ph - 12))
        $script:panelAbout.Location = New-Object Drawing.Point(6, 6)
        $script:panelAbout.Size = New-Object Drawing.Size(($pw - 12), ($ph - 12))
        if ($script:panelGuide) {
            $script:panelGuide.Location = New-Object Drawing.Point(6, 6)
            $script:panelGuide.Size = New-Object Drawing.Size(($pw - 12), ($ph - 12))
        }
        # 底部按钮：三个主按钮等宽等距对齐，右侧固定「全选复制」90x30
        $gap = 8
        $btnW = [int][Math]::Floor((($w - 24 - 90 - 10 - (2 * $gap)) / 3))
        if ($btnW -lt 96) { $btnW = 96 }
        $script:btnRun.Location = New-Object Drawing.Point(12, ($h - 88))
        $script:btnRun.Size = New-Object Drawing.Size($btnW, 40)
        $script:btnRecheck.Location = New-Object Drawing.Point((12 + $btnW + $gap), ($h - 88))
        $script:btnRecheck.Size = New-Object Drawing.Size($btnW, 40)
        $script:btnQuit.Location = New-Object Drawing.Point((12 + (2 * $btnW) + (2 * $gap)), ($h - 88))
        $script:btnQuit.Size = New-Object Drawing.Size($btnW, 40)
        $script:btnSelCopy.Location = New-Object Drawing.Point(($w - 12 - 90), ($h - 83))
        $script:btnSelCopy.Size = New-Object Drawing.Size(90, 30)
        $lblHint.Location = New-Object Drawing.Point(12, ($h - 38))
        $lblHint.Size = New-Object Drawing.Size(($w - 24), 20)
    } catch {
        Write-UiLog ('layout error: ' + $_.Exception.Message)
    }
}

$form.add_Resize({ Update-Layout })

# 右上角 X：缩到托盘，不带走反代
$form.add_FormClosing({
    param($sender, $e)
    if (-not $script:ExitNow) {
        $e.Cancel = $true
        Hide-ToTray
    }
})

$form.add_Shown({
    Write-UiLogSep
    Write-UiLog ('t=' + [Math]::Round($script:sw.Elapsed.TotalSeconds, 1) + 's shown -> check')
    Write-UiLog 'console started'
    Repair-Shortcut
    Set-FormIcon
    Update-Layout
    if (-not (Get-RelayProcess)) {
        if ($AutoTray) { $script:autoTrayPending = $true }
        Start-RelayTask -Mode Start
    } else {
        Update-Status
        if ($AutoTray -and $script:healthy) { Hide-ToTray }
    }
})

try {
    [Windows.Forms.Application]::Run($form)
} finally {
    try { $script:taskTimer.Stop(); $script:taskTimer.Dispose() } catch { }
    try { $script:probeTimer.Stop(); $script:probeTimer.Dispose() } catch { }
    try { $script:cfgUiTimer.Stop(); $script:cfgUiTimer.Dispose() } catch { }
    try { if ($script:bgPs) { $script:bgPs.Dispose() } } catch { }
    try { if ($script:probePs) { $script:probePs.Dispose() } } catch { }
    try { if ($script:singleton) { $script:singleton.ReleaseMutex(); $script:singleton.Dispose() } } catch { }
    try { $script:ni.Visible = $false; $script:ni.Dispose() } catch { }
    Write-UiLog 'console exited'
}
