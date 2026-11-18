# 读取 mcp-relay.config.json，供 start/stop/check/firewall-sync 共用（被 dot-source 引用）
# 不写死任何地址：改配置就能加代理，脚本不用动。
# 配置里允许 # 到行尾的注释（字符串内部的 # 不动），与 python 侧行为保持一致
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

function Convert-RelayConfigText {
    param([string]$Text)
    if (-not $Text) { return $Text }
    # 先剥注释
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
    $clean = $sb.ToString()

    # 再去掉 ] } 前面多余的逗号（注释剥掉后留下的尾巴）
    $sb2 = New-Object System.Text.StringBuilder
    $inStr = $false
    $esc = $false
    for ($i = 0; $i -lt $clean.Length; $i++) {
        $c = $clean[$i]
        if ($inStr) {
            [void]$sb2.Append($c)
            if ($esc) { $esc = $false }
            elseif ($c -eq [char]'\') { $esc = $true }
            elseif ($c -eq [char]'"') { $inStr = $false }
            continue
        }
        if ($c -eq [char]'"') { $inStr = $true; [void]$sb2.Append($c); continue }
        if ($c -eq [char]',') {
            $j = $i + 1
            while ($j -lt $clean.Length -and " `t`r`n".IndexOf($clean[$j]) -ge 0) { $j++ }
            if ($j -lt $clean.Length -and ($clean[$j] -eq ']' -or $clean[$j] -eq '}')) { continue }
            [void]$sb2.Append($c)
            continue
        }
        [void]$sb2.Append($c)
    }
    return $sb2.ToString()
}

function Get-RelayConfig {
    param([string]$Root = $PSScriptRoot)

    $path = Join-Path $Root 'mcp-relay.config.json'
    $cfg  = [pscustomobject]@{
        Path     = $path
        Exists   = $false
        Proxies  = @()
        LogFile  = 'mcp-relay.log'
        Firewall = [pscustomobject]@{
            Enabled       = $true
            LocalAddress  = '192.168.110.1'
            RemoteAddress = '192.168.110.0/24'
            BlockUdp      = $true
        }
        Error    = $null
    }

    if (-not (Test-Path -LiteralPath $path)) {
        # 与 python 侧内置默认值保持一致（老行为：两个地址 -> 127.0.0.1:12335）
        $cfg.Proxies = @([pscustomobject]@{
            Name        = 'xterminal-mcp'
            Raw         = @('192.168.110.1:12335', '192.168.1.20:12335')
            ListenHost  = @('192.168.110.1', '192.168.1.20')
            ListenPort  = @(12335)
            Target      = '127.0.0.1:12335'
            RewriteHost = $true
            Timeout     = 3600
        })
        return $cfg
    }

    $cfg.Exists = $true
    try {
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        $raw = Convert-RelayConfigText $text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $cfg.Error = "配置文件不是合法 JSON: $path -> $($_.Exception.Message)"
        return $cfg
    }

    if ($raw.log -and $raw.log.file) { $cfg.LogFile = [string]$raw.log.file }

    if ($raw.firewall) {
        $fw = $raw.firewall
        if ($fw.enabled -ne $null)        { $cfg.Firewall.Enabled = [bool]$fw.enabled }
        if ($fw.local_address)            { $cfg.Firewall.LocalAddress = [string]$fw.local_address }
        if ($fw.remote_address)           { $cfg.Firewall.RemoteAddress = [string]$fw.remote_address }
        if ($fw.block_udp -ne $null)      { $cfg.Firewall.BlockUdp = [bool]$fw.block_udp }
    }

    $proxies = @()
    foreach ($p in @($raw.proxies)) {
        if ($null -eq $p) { continue }
        if ($p.enabled -eq $false) { continue }

        $listenRaw = @($p.listen)
        $hosts = @(); $ports = @()
        foreach ($entry in $listenRaw) {
            $s = [string]$entry
            $i = $s.LastIndexOf(':')
            if ($i -lt 1) { $cfg.Error = "listen 格式错误（要 地址:端口）: $s"; return $cfg }
            $hosts += $s.Substring(0, $i)
            $ports += [int]$s.Substring($i + 1)
        }
        if ($hosts.Count -eq 0) { continue }

        $proxies += [pscustomobject]@{
            Name        = if ($p.name) { [string]$p.name } else { 'proxy' }
            Raw         = $listenRaw
            ListenHost  = $hosts
            ListenPort  = $ports
            Target      = [string]$p.target
            RewriteHost = if ($null -eq $p.rewrite_host) { $true } else { [bool]$p.rewrite_host }
            Timeout     = if ($p.upstream_timeout) { [int]$p.upstream_timeout } else { 3600 }
        }
    }

    if ($proxies.Count -eq 0 -and -not $cfg.Error) {
        $cfg.Error = "配置里没有 enabled=true 的 proxy"
    }
    $cfg.Proxies = $proxies
    return $cfg
}

function Get-RelayPortList {
    param($Config)
    $ports = @()
    foreach ($p in $Config.Proxies) { $ports += $p.ListenPort }
    return ($ports | Sort-Object -Unique)
}

# 需要防火墙放行的端口：凡监听在 firewall.local_address（或 0.0.0.0）上的端口
function Get-RelayFirewallPorts {
    param($Config)
    $ports = @()
    foreach ($p in $Config.Proxies) {
        for ($i = 0; $i -lt $p.ListenHost.Count; $i++) {
            $h  = $p.ListenHost[$i]
            $pt = $p.ListenPort[$i]
            if ($h -eq $Config.Firewall.LocalAddress -or $h -eq '0.0.0.0' -or $h -eq '*') { $ports += $pt }
        }
    }
    return ($ports | Sort-Object -Unique)
}

# 把 1-65535 里除放行端口之外的部分，算成若干连续区间
function Get-BlockRanges {
    param([int[]]$Ports)
    $ranges = @()
    $start = 1
    foreach ($p in ($Ports | Sort-Object)) {
        if ($p -gt $start) { $ranges += ,@($start, ($p - 1)) }
        $start = $p + 1
    }
    if ($start -le 65535) { $ranges += ,@($start, 65535) }
    return $ranges
}

# 防火墙规则的"配置指纹"：配置没变且上次比对一致时，启动脚本可以跳过重复比对（省 20–40 秒）
function Get-RelayFirewallFingerprint {
    param($Config)
    if (-not $Config -or $Config.Error) { return '' }
    if (-not $Config.Firewall.Enabled) { return 'disabled' }
    $ports = @(Get-RelayFirewallPorts -Config $Config)
    $udp = 'udp=0'
    if ($Config.Firewall.BlockUdp -ne $false) { $udp = 'udp=1' }
    return ($Config.Firewall.LocalAddress + '|' + $Config.Firewall.RemoteAddress + '|' + ($ports -join ',') + '|' + $udp)
}
