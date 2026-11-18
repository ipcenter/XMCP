# XMCP 反代控制台 —— 单窗口，取代原来的三个 bat
# 用法：双击 XMCP控制台.bat
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
$uiLog    = Join-Path $root 'xmcp-console.log'
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

# 快捷方式：.lnk 里只能存绝对路径，所以它一旦跟着目录被拷到别的盘，就还指着老地方。
# 对策是「每次启动都自检 + 就地改写」：
#   1. 目录里那一份（XMCP 反代工具.lnk，X 图标）：首次运行由 bat 拉起控制台时自动生成，
#      之后启动发现 Target 不是本目录的 bat 就重写 —— 复制到新盘、先点 bat 一次即自动纠正；
#   2. 桌面那一份：存在则跟着最近一次运行的程序目录自动对齐。
function Write-LocalShortcut {
    param([string]$LnkPath, [string]$Label)
    try {
        $bat = Join-Path $root 'XMCP控制台.bat'
        if (-not (Test-Path -LiteralPath $bat)) { return }
        $ico = Join-Path $root 'xmcp.ico'
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($LnkPath)
        $s.TargetPath = $bat
        $s.WorkingDirectory = $root
        if (Test-Path -LiteralPath $ico) { $s.IconLocation = $ico + ',0' }
        $s.Description = 'XMCP 反代工具'
        $s.WindowStyle = 7
        $s.Save()
        Write-UiLog ($Label + ' shortcut written -> ' + $root)
    } catch { }
}

function Repair-Shortcut {
    try {
        $bat = Join-Path $root 'XMCP控制台.bat'
        if (-not (Test-Path -LiteralPath $bat)) { return }
        # 目录里那份：没有就建，有但指错就重写
        $local = Join-Path $root 'XMCP 反代工具.lnk'
        $okLocal = $false
        if (Test-Path -LiteralPath $local) {
            $okLocal = ((New-Object -ComObject WScript.Shell).CreateShortcut($local)).TargetPath -eq $bat
        }
        if (-not $okLocal) { Write-LocalShortcut -LnkPath $local -Label 'local' }
        # 桌面那份：只修正已存在的，不擅自往桌面新建
        $desktop = [Environment]::GetFolderPath('Desktop')
        if ($desktop) {
            $lnk = Join-Path $desktop 'XMCP 反代工具.lnk'
            if (Test-Path -LiteralPath $lnk) {
                if (((New-Object -ComObject WScript.Shell).CreateShortcut($lnk)).TargetPath -ne $bat) {
                    Write-LocalShortcut -LnkPath $lnk -Label 'desktop'
                }
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

# ===== 首次运行自举：配置文件不在就按本机环境生成一份 =====
# 别人把这个目录拷到任意路径、任意机器，双击 bat 就能跑：配置、日志、快捷方式全部就地长出来。
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

function Get-StatusText {

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('=== XMCP 反代工具 ===')
    [void]$sb.AppendLine('检测时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    [void]$sb.AppendLine('')

    $cfg = Get-RelayConfig -Root $root
    [void]$sb.AppendLine('[配置] ' + $cfg.Path)
    if ($cfg.Error) { [void]$sb.AppendLine('  !! 配置错误: ' + $cfg.Error) }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('[代理]')
    $firstAddr = ''
    foreach ($p in $cfg.Proxies) {
        $listens = @()
        for ($i = 0; $i -lt $p.ListenHost.Count; $i++) { $listens += ($p.ListenHost[$i] + ':' + $p.ListenPort[$i]) }
        if (-not $firstAddr -and $p.ListenHost.Count -gt 0) { $firstAddr = $p.ListenHost[0] + ':' + $p.ListenPort[0] }
        $tag = ''
        if ($p.RewriteHost) { $tag = '  [Host改写]' }
        # 每个监听地址单独一行，避免一行太长被折成两半（第二行用等宽空格缩进对齐）
        $head = '  [' + $p.Name + '] '
        if ($listens.Count -eq 0) {
            [void]$sb.AppendLine($head + '(没写 listen 地址)  ->  ' + $p.Target + $tag)
        } else {
            for ($i = 0; $i -lt $listens.Count; $i++) {
                $lead = if ($i -eq 0) { $head } else { ' ' * $head.Length }
                $lineTag = if ($i -eq 0) { $tag } else { '' }
                [void]$sb.AppendLine($lead + $listens[$i].PadRight(22) + ' ->  ' + $p.Target + $lineTag)
            }
        }
    }
    if ($firstAddr) { $script:trayHint = 'XMCP 反代 · ' + $firstAddr }

    $proc = Get-RelayProcess

    [void]$sb.AppendLine('')
    if ($proc) {
        [void]$sb.AppendLine('[进程] 运行中   PID ' + $proc.Id + '   ' + $proc.ProcessName + '   启动于 ' + $proc.StartTime.ToString('HH:mm:ss'))
    } else {
        [void]$sb.AppendLine('[进程] 未运行   （下面若全部不通，先看这里）')
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[监听]')
    # 用正则解析完整 netstat 文本（netstat | Select-String 在本机偶发只回一行，会少显示监听）
    $nsText = ''
    try { $nsText = (& $netstatExe -ano | Out-String) } catch { $nsText = '' }
    foreach ($port in (Get-RelayPortList -Config $cfg)) {
        $rx = [regex]('(?m)^\s*TCP\s+([0-9\.\*\[\]:]+):' + [regex]::Escape([string]$port) + '\s+[^\s]+\s+LISTENING\s+(\d+)')
        $ms = $rx.Matches($nsText)
        if ($ms.Count -gt 0) {
            foreach ($m in $ms) {
                [void]$sb.AppendLine('  TCP    ' + $m.Groups[1].Value + ':' + $port + '   LISTENING   PID ' + $m.Groups[2].Value)
            }
        } else {
            [void]$sb.AppendLine('  端口 ' + $port + ' 没有监听')
        }
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[连通性] 自动检测')
    $ok = 0
    $total = 0
    foreach ($p in $cfg.Proxies) {
        for ($i = 0; $i -lt $p.ListenHost.Count; $i++) {
            $h = $p.ListenHost[$i]
            $pt = $p.ListenPort[$i]
            if ($h -eq '0.0.0.0' -or $h -eq '*') { $h = '127.0.0.1' }
            $url = 'http://' + $h + ':' + $pt + '/'
            $total++
            $code = Test-Endpoint -Url $url
            $verdict = '连通'
            if ($code -eq '000') { $verdict = '不通' } else { $ok++ }
            [void]$sb.AppendLine(('  ' + $url).PadRight(38) + ' -> ' + $code + '   ' + $verdict)
        }
    }
    [void]$sb.AppendLine('  小结: ' + $ok + '/' + $total + ' 个地址可达')
    [void]$sb.AppendLine('  （000=不通；401/404/200 都算连通——已到达上游，401 只是缺令牌）')
    $script:lastVerdict = $ok.ToString() + '/' + $total.ToString() + ' 地址可达'
    # 健康判定：进程在 且 所有配置地址都可达
    $script:healthy = [bool]($proc -ne $null -and $total -gt 0 -and $ok -eq $total)

    [void]$sb.AppendLine('')
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
            $rx = [regex]"(连通|不通)(?=\r\n|\r|\n|$)"
            foreach ($m in $rx.Matches($box.Text)) {
                $box.Select($m.Index, 2)
                if ($m.Groups[1].Value -eq '连通') { $box.SelectionColor = [Drawing.Color]::FromArgb(0, 100, 0) }
                else { $box.SelectionColor = [Drawing.Color]::FromArgb(200, 0, 0) }
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
param($Mode, $StopPs1, $StartPs1, $Addresses)
$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $exe)) { $exe = 'powershell.exe' }
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path -LiteralPath $curl)) { $curl = 'curl.exe' }
$log = @()
if ($Mode -eq 'Restart') {
    $o = & $exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $StopPs1 2>&1 | Out-String
    $log += ('stop | ' + ($o -replace "`r?`n", ' ; '))
}
$o2 = & $exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $StartPs1 2>&1 | Out-String
$log += ('start | ' + ($o2 -replace "`r?`n", ' ; '))
# 等端口真正能应答（反代从启动到绑定约 10 秒，等太久会误判"不通"）
$list = @()
if ($Addresses) { $list = $Addresses.Split(',') }
$waited = 0
for ($i = 0; $i -lt 30; $i++) {
    $allUp = $true
    foreach ($a in $list) {
        if (-not $a) { continue }
        $code = (& $curl -sS -o NUL -w '%{http_code}' --max-time 2 ("http://" + $a + "/") 2>$null)
        $code = ([string]$code).Trim()
        if (-not $code -or $code -eq '000') { $allUp = $false }
    }
    if ($allUp) { break }
    Start-Sleep -Milliseconds 700
    $waited = $i + 1
}
$log += ('wait | 等端口应答 ' + [Math]::Round($waited * 0.7, 1) + ' 秒')
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
    Set-StatusText ($label + "`r`n" + '约 10–20 秒完成。窗口此时可以正常拖动、可以点右上角"-"最小化、也可以点 X 收进托盘，完成后会自动刷新结果。')
    Write-UiLog ('relay task start: ' + $Mode)
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:relayTaskCode)
    [void]$ps.AddArgument($Mode)
    [void]$ps.AddArgument($stopPs1)
    [void]$ps.AddArgument($startPs1)
    [void]$ps.AddArgument((Get-CheckAddresses))
    $script:bgPs = $ps
    $script:bgHandle = $ps.BeginInvoke()
    $script:taskTimer.Start()
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
    if ($script:lblCfgState) { $script:lblCfgState.Text = '已载入: ' + [IO.Path]::GetFileName($path) + '   （点「重启代理」= 先校验，再存到 mcp-relay.config.json）' }
    $script:tabs.SelectedTab = $script:tabEdit
    Write-UiLog ('config imported from ' + $path)
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
    $new = $script:txtCfg.Text
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
        $showText = "配置没保存，文件保持原样。`r`n`r`n" + (($errText -replace "`r?`n", ' ').Trim())
        if ($showText.Length -gt 400) { $showText = $showText.Substring(0, 400) + '…' }
        $showText += "`r`n`r`n改好后可以再点一次「重启代理」；完整报错在「运行日志」页。"
        [Windows.Forms.MessageBox]::Show($showText, '配置格式错误', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
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
    $script:txtCfg.Text = $new          # 编辑框里也换成排版后的样子
    $script:txtCfg.SelectionStart = 0
    $script:txtCfg.ScrollToCaret()
    $script:suppressDirty = $false
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
$btnLoadCfg.Location = New-Object Drawing.Point(462, 52)
$btnLoadCfg.Size = New-Object Drawing.Size(164, 28)
$btnLoadCfg.add_Click({ Import-ConfigFile })
$tabEdit.Controls.Add($btnLoadCfg)

$txtCfg = New-Object Windows.Forms.TextBox
$txtCfg.Multiline = $true
$txtCfg.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
$txtCfg.WordWrap = $true
$txtCfg.AcceptsReturn = $true
$txtCfg.AcceptsTab = $true
$txtCfg.Font = New-Object Drawing.Font('Consolas', 9)
$txtCfg.BackColor = [Drawing.Color]::White
$txtCfg.Location = New-Object Drawing.Point(6, 78)
$txtCfg.Size = New-Object Drawing.Size(620, 286)
$txtCfg.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left
$tabEdit.Controls.Add($txtCfg)
$script:txtCfg = $txtCfg

# --- tab 4：运行日志 ---
$tabLog = New-Object Windows.Forms.TabPage
$tabLog.Text = '运行日志'
$tabLog.Padding = New-Object Windows.Forms.Padding(3)
[void]$tabs.Controls.Add($tabLog)
$script:tabLog = $tabLog

$lblLog = New-Object Windows.Forms.Label
$lblLog.Text = "最新在最上：下面两个二级 tab 分别看「控制台日志」和「反代日志」，各取最近 60 条。`r`n切到本页或点「刷新」会重新读取；要全文就用底部的记事本按钮。"
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

# 二级 tab：控制台日志 / 反代日志，各占一个只读文本框
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

$tabLog.Controls.Add($logTabs)
$script:logTabs = $logTabs

# --- tab 5：使用说明（说明书）---
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
· 地址写死在程序里、或改了会破坏签名 / 升级即失效的服务；
· 需要「多台虚拟机共享宿主机上一个本机服务」的场景；
· 需要「改配置不改代码」：加一个服务只改 JSON。
不适合：
· UDP 服务（本反代只做 TCP）；
· 需要 TLS 终结、证书替换、路径重写（这里只做端口 + Host 头转发）；
· 服务端除 Host 外还校验来源 IP / 令牌白名单的，转发后仍可能被拒，需要服务端放行；
· 需要开机自启常驻的关键业务（本工具手动启停，不注册系统服务）。

四、典型应用场景
· 虚拟机里的 Linux 用宿主机的 XTerminal SSH / MCP 工具链；
· Cursor / Claude 等客户端要连一个只绑 127.0.0.1 的本地 MCP server，客户端却在另一台机器；
· 一台 Windows 当跳板，多台虚拟机共享同一套本机服务，不必每台各装一份；
· 内网联调：既要给虚拟机开端口，又不想把整台机器的端口敞开；
· 临时把某个本机 Web 工具暴露给同事看一眼，用完点「2. 退出关闭」即收回。

五、怎么用（三步）
1. 双击「XMCP 反代工具」快捷方式或「XMCP控制台.bat」。
   程序会自动拉起反代并自检，状态页出现 2/2 地址可达、healthy=True 即正常。
2. 客户端（虚拟机 / 另一台电脑）里访问 http://192.168.110.1:12335/mcp（带令牌），
   或按对应软件的地址格式填 192.168.110.1:12335。
3. 要再转发一个服务：在「配置内容」页的 proxies 数组里加一段，例如
     "name": "我的本地服务", "enabled": true,
     "listen": ["192.168.110.1:8088"], "target": "127.0.0.1:8080",
     "rewrite_host": false, "upstream_timeout": 60
   点「重启代理」——先校验格式，通过才写盘（旧文件备份 .bak）并重启；
   随后在状态页 [监听] 确认新端口已 LISTENING，[连通性] 显示「连通」。

六、几个容易踩的点
· rewrite_host 只在服务端校验 Host 时才设 true（XTerminal 必须 true，否则 403）；
  如果上游是普通 Web 服务、按 Host 分发站点，乱改反而会 404 / 400，那就设 false。
· 401 / 404 / 200 都算「连通」：401 缺令牌、404 路径不对，都说明已到达上游；000 才是不通。
· 配置支持 # 注释：# 到行尾整段忽略，字符串里的 # 不算注释；数组最后一项留逗号也不报错。
· 反代不会开机自启：需要时双击控制台。点「1.最小化」收托盘后反代仍在跑，双击托盘图标可再打开。
· 换端口要同步改客户端：防火墙按 listen 自动推导，客户端里填的端口要自己改。
· 只想临时开一个端口：把其它 proxy 的 enabled 设成 false，或点「2. 退出关闭」停掉反代。

七、文件都在这个目录
XMCP控制台.bat                            双击入口（换目录后先双击它）
XMCP 反代工具.lnk                         首次运行自动生成（X 图标），指错会自动改写
重建快捷方式.bat                          在桌面也建一份快捷方式
XMCP控制台.ps1                            控制台本体
xterminal-mcp-lan-relay.py                反代（名字沿用历史，逻辑通用）
start-mcp-relay.ps1 / stop-mcp-relay.ps1  启动 / 停止
relay-config.ps1 / firewall-sync.ps1      配置解析 / 防火墙同步
validate-config.py / format-config.py     配置校验 / 自动排版
mcp-relay.config.json（含 .bak 备份）      配置（可加多条 proxy）
mcp-relay.log / xmcp-console.log          反代日志 / 控制台日志
xmcp.ico                                  图标
README.md                                 完整文档（含排障记录）

八、分享给别人 / 换一台机器
1. 直接把整个目录打包（zip 或拷 U 盘）发出去，对方解压到任意路径即可，不需要安装。
2. 第一次双击 XMCP控制台.bat，程序会自己完成三件事：
   · 没有 mcp-relay.config.json 就按本机网卡自动生成一份（监听地址、网段都取当前机器）；
   · 在目录里生成「XMCP 反代工具.lnk」（黄底黑 X 图标），以后双击它就够；
   · 起反代 + 比对防火墙（首次会弹一次 UAC，允许即可）。
3. 对方机器需要自己装 Python 3（程序会自动找 pythonw/python，找不到会在状态页提示）。
4. 上游服务（例如 XTerminal 的 MCP）没装或没开时，连通性会显示 000 不通——这是正常的，
   装好上游、把 target 改成它实际监听的 127.0.0.1 端口即可。
5. 打包前建议删掉本机的运行时文件，避免把别人的环境信息带出去：
   mcp-relay.config.json（及 .bak）、mcp-relay.log、mcp-relay.pid、
   xmcp-console.log、xmcp-console-status.txt、firewall-state.txt、firewall-fingerprint.txt、
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

# --- tab 6：关于软件 ---
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

版本号      1.0.0（2026-11-18）
作者        极客盟工具开发组
问题反馈    联系微信 xywaykie

适用系统    Windows 10 / 11（64 位）
运行依赖    Windows PowerShell 5.1 + Python 3（自动探测：常见安装目录或系统 PATH 均可）
安装方式    绿色版、免安装：解压即用，整个目录可随意拷贝，不写注册表、不改系统设置

界面技术    PowerShell + WinForms，单窗口六页：状态 / 配置格式 / 配置内容 / 运行日志 / 使用说明 / 关于软件
反代实现    Python 标准库（socket + threading），不依赖任何第三方包
防火墙      按配置自动生成「精确放行 + 补集拦截」规则组 XMCP relay，需管理员权限时弹一次 UAC

程序特点
· 不改第三方程序文件：XTerminal 的 asar 一行没动；
· 配置外置：监听地址、上游、超时、日志大小全部写在 JSON 里，改配置不改代码；
· 启动即自检：自动拉起反代、自动比对防火墙、自动测连通性，状态页给结论；
· 双日志分栏：控制台日志与反代日志分开看，最新一条永远在最上面；
· 出错有话说：格式错误定位到行列，配置不会被写坏，旧文件留 .bak。

许可与声明
本程序为内部自用工具，请勿把配置文件里的内网地址、端口与令牌对外传播。
本程序只做端口转发与 Host 改写，不采集、不上传任何数据。

文档        README.md（在程序目录下，含完整部署说明与排障记录）
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
            '使用说明' { $box = $script:txtHelp }
            '关于软件' { $box = $script:txtAbout }
            '运行日志' {
                if ($script:logTabs -and $script:logTabs.SelectedTab) {
                    $box = $script:logTabs.SelectedTab.Controls[0]
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
    if ($script:suppressDirty) { return }
    if ($script:configDirty -ne $true) { $script:configDirty = $true }
})

# 日志页的两个小按钮
$btnLogRefresh.add_Click({ Update-LogView })
$btnLogOpen.add_Click({ Open-LogFile -Path (Join-Path $root 'mcp-relay.log') })
$btnLogOpenUi.add_Click({ Open-LogFile -Path $uiLog })

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
        # 配置内容页
        $script:panelEdit.Location = New-Object Drawing.Point(6, 4)
        $script:panelEdit.Size = New-Object Drawing.Size(($pw - 12), 46)
        $script:lblCfgState.Location = New-Object Drawing.Point(8, 58)
        $btnLoadCfg.Location = New-Object Drawing.Point(($pw - 170), 54)
        $script:txtCfg.Location = New-Object Drawing.Point(6, 90)
        $script:txtCfg.Size = New-Object Drawing.Size(($pw - 12), ($ph - 98))
        # 运行日志页（二级 tab）
        $script:panelLog.Location = New-Object Drawing.Point(6, 4)
        $script:panelLog.Size = New-Object Drawing.Size(($pw - 12), 54)
        $script:logTabs.Location = New-Object Drawing.Point(6, 64)
        $script:logTabs.Size = New-Object Drawing.Size(($pw - 12), ($ph - 64 - 34))
        $btnLogRefresh.Location = New-Object Drawing.Point(6, ($ph - 32))
        $btnLogOpen.Location = New-Object Drawing.Point(108, ($ph - 32))
        $btnLogOpenUi.Location = New-Object Drawing.Point(274, ($ph - 32))
        # 使用说明页 / 关于软件页：整页一个带边框的阅读框
        $script:panelHelp.Location = New-Object Drawing.Point(6, 6)
        $script:panelHelp.Size = New-Object Drawing.Size(($pw - 12), ($ph - 12))
        $script:panelAbout.Location = New-Object Drawing.Point(6, 6)
        $script:panelAbout.Size = New-Object Drawing.Size(($pw - 12), ($ph - 12))
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
    try { if ($script:bgPs) { $script:bgPs.Dispose() } } catch { }
    try { if ($script:singleton) { $script:singleton.ReleaseMutex(); $script:singleton.Dispose() } } catch { }
    try { $script:ni.Visible = $false; $script:ni.Dispose() } catch { }
    Write-UiLog 'console exited'
}
