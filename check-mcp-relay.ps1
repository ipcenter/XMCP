# 查看反代状态并测试连通性（读配置，位置无关）
# 用法：双击 测试连通性.bat，或
#       powershell -ExecutionPolicy Bypass -File .\check-mcp-relay.ps1
$ErrorActionPreference = 'Continue'

$root = $PSScriptRoot
. (Join-Path $root 'relay-config.ps1')
$cfg = Get-RelayConfig -Root $root

# 绝对路径：从精简 PATH 的宿主运行时也能找到这些系统工具
$sys32 = Join-Path $env:SystemRoot 'System32'
$netstatExe = Join-Path $sys32 'netstat.exe'
$curlExe = Join-Path $sys32 'curl.exe'
if (-not (Test-Path -LiteralPath $netstatExe)) { $netstatExe = 'netstat.exe' }
if (-not (Test-Path -LiteralPath $curlExe)) { $curlExe = 'curl.exe' }

$pidFile = Join-Path $root 'mcp-relay.pid'

Write-Host "=== 1. 配置 ==="
Write-Host "  $($cfg.Path)"
if ($cfg.Error) { Write-Host "  配置错误: $($cfg.Error)" }

Write-Host "=== 2. 反代进程 ==="
if (Test-Path -LiteralPath $pidFile) {
    $relayPid = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    $proc = Get-Process -Id $relayPid -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Host "  运行中  PID $relayPid  $($proc.ProcessName)  启动于 $($proc.StartTime)"
    } else {
        Write-Host "  PID 文件存在但进程不在（PID $relayPid）"
    }
} else {
    Write-Host "  未运行（没有 PID 文件）"
}

Write-Host "=== 3. 监听 ==="
foreach ($port in (Get-RelayPortList -Config $cfg)) {
    & $netstatExe -ano | Select-String "LISTENING" | Select-String ":$port" |
        ForEach-Object { Write-Host "  $($_.Line.Trim())" }
}

Write-Host "=== 4. 每个代理的连通性 ==="
$allOk = $true
foreach ($p in $cfg.Proxies) {
    Write-Host "  [$($p.Name)] -> $($p.Target)"
    for ($i = 0; $i -lt $p.ListenHost.Count; $i++) {
        $h = $p.ListenHost[$i]
        $pt = $p.ListenPort[$i]
        if ($h -eq '0.0.0.0' -or $h -eq '*') { $h = '127.0.0.1' }
        $url = "http://$h`:$pt/"
        $code = & $curlExe -sS -o NUL -w "%{http_code}" --max-time 8 $url 2>$null
        if (-not $code) { $code = '000' }
        Write-Host "    http://$h`:$pt/  -> $code"
        if ($code -eq '000') { $allOk = $false }
    }
}

Write-Host "=== 5. 防火墙规则（VMnet8 网段）==="
$fw = Get-NetFirewallRule -Group 'XMCP relay' -ErrorAction SilentlyContinue
if ($fw) {
    foreach ($r in $fw) {
        $pf = $r | Get-NetFirewallPortFilter
        Write-Host ("  " + $r.Enabled + " " + $r.Action + " " + $pf.Protocol + " " + $pf.LocalPort + "  " + $r.DisplayName)
    }
} else {
    Write-Host "  没有 XMCP relay 规则组（可能用了旧命名，或 firewall.enabled=false）"
    Get-NetFirewallRule | Where-Object { $_.DisplayName -like '*XMCP*' -or $_.DisplayName -like '*XTerminal MCP*' } |
        ForEach-Object { Write-Host "  旧规则: $($_.DisplayName) enabled=$($_.Enabled)" }
}

Write-Host ""
Write-Host "判定："
Write-Host "  探针打的是各地址的根路径 /，只要不是 000 都说明反代已连通并到达上游。"
Write-Host "  XTerminal 只暴露 /mcp，所以 / 返回 404 是正常的；/mcp 返回 401 表示缺令牌，也正常。"
Write-Host "  000/超时    = 不通（反代没跑、端口没监听、或防火墙没放行）"
Write-Host "  403 Invalid Host = 没走反代（直连了别的地址，或 rewrite_host 没开）"
if (-not $allOk) { Write-Host "  => 有地址不通，先看第 5 节的防火墙规则是否包含对应端口。" }
