# 启动 MCP 反代（读 mcp-relay.config.json，配置驱动、可挂多个代理）
# 位置无关：所有路径都基于本脚本所在目录
# 用法：双击 启动XMCP代理.bat，或
#       powershell -ExecutionPolicy Bypass -File .\start-mcp-relay.ps1
#       加 -ForceFirewall 可强制重新比对防火墙（配置没变时默认跳过，省 20–40 秒）
param([switch]$ForceFirewall)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
. (Join-Path $root 'relay-config.ps1')

$pyScript = Join-Path $root 'xterminal-mcp-lan-relay.py'
$pidFile  = Join-Path $root 'mcp-relay.pid'

# 绝对路径：从精简 PATH 的宿主运行时也能找到系统工具
$sys32 = Join-Path $env:SystemRoot 'System32'
$netstatExe = Join-Path $sys32 'netstat.exe'
if (-not (Test-Path -LiteralPath $netstatExe)) { $netstatExe = 'netstat.exe' }

if (-not (Test-Path -LiteralPath $pyScript)) {
    Write-Host "找不到反代脚本: $pyScript"
    exit 1
}

$cfg = Get-RelayConfig -Root $root
if ($cfg.Error) {
    Write-Host "配置有错，未启动："
    Write-Host "  $($cfg.Error)"
    Write-Host "  配置文件: $($cfg.Path)"
    exit 1
}

Write-Host "=== 配置 ==="
Write-Host "  文件: $($cfg.Path)"
foreach ($p in $cfg.Proxies) {
    $pairs = @()
    for ($i = 0; $i -lt $p.ListenHost.Count; $i++) {
        $pairs += "$($p.ListenHost[$i]):$($p.ListenPort[$i])"
    }
    $hostTag = if ($p.RewriteHost) { '（Host 改写）' } else { '' }
    Write-Host "  [$($p.Name)] $($pairs -join ', ')  ->  $($p.Target) $hostTag"
}

# 优先 pythonw（GUI 子系统，无控制台窗口）
$exe = $null
foreach ($cand in @('C:\Python314\pythonw.exe', 'C:\Python314\python.exe')) {
    if (Test-Path -LiteralPath $cand) { $exe = $cand; break }
}
if (-not $exe) {
    $cmd = Get-Command pythonw -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command python -ErrorAction SilentlyContinue }
    if ($cmd) { $exe = $cmd.Source }
}
if (-not $exe) {
    Write-Host "找不到 python，请先安装 Python 3 或修改本脚本里的路径"
    exit 1
}

# 已在运行则不重复启动
if (Test-Path -LiteralPath $pidFile) {
    $oldPid = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Write-Host "反代已在运行 (PID $oldPid)。"
        Write-Host "  提示: 刚改过 mcp-relay.config.json 的话，要先双击 停止XMCP代理.bat 再启动才生效。"
        exit 0
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

# ---- 防火墙：按配置自动同步（有差异才提权）----
if ($cfg.Firewall.Enabled) {
    $syncPath = Join-Path $root 'firewall-sync.ps1'
    $fpFile   = Join-Path $root 'firewall-fingerprint.txt'
    $fpNow    = Get-RelayFirewallFingerprint -Config $cfg
    $fpLast   = ''
    if (Test-Path -LiteralPath $fpFile) { $fpLast = (Get-Content -LiteralPath $fpFile -Raw).Trim() }
    Write-Host ""
    if ($fpNow -and $fpLast -and $fpNow -eq $fpLast -and -not $ForceFirewall) {
        # 配置指纹没变、上次比对已一致：跳过（单次查看规则要 7 秒以上，跳过能省 20–40 秒）
        Write-Host "=== 防火墙同步：配置没变、上次已一致，跳过重复比对 ==="
        Write-Host "  （要强制重新比对，启动时加 -ForceFirewall，或删掉 firewall-fingerprint.txt）"
    } else {
        Write-Host "=== 防火墙同步 ==="
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncPath 2>&1 |
            ForEach-Object { Write-Host "  $_" }
        $code = $LASTEXITCODE
        if ($code -eq 1) {
            Write-Host "  检测到差异，正在提权更新（会弹 UAC，请点“是”）..."
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $syncPath + '"'), '-Apply'
            ) | Out-Null
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncPath 2>&1 |
                ForEach-Object { Write-Host "  $_" }
            if ($LASTEXITCODE -ne 0) { Write-Host "  警告: 防火墙仍未同步，新增端口可能对虚拟机不可达。" }
        } elseif ($code -ne 0) {
            Write-Host "  警告: 防火墙检查未通过（exit $code），继续启动但可能不通。"
        }
    }
} else {
    Write-Host ""
    Write-Host "=== 防火墙同步：已关闭（firewall.enabled=false）==="
}

# ---- 启动：用 Win32_Process.Create，完全分离，关窗口不影响 ----
$cmdLine = '"{0}" "{1}"' -f $exe, $pyScript
$created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine      = $cmdLine
    CurrentDirectory = $root
}
if ($created.ReturnValue -ne 0 -or -not $created.ProcessId) {
    Write-Host "启动失败，Win32_Process.Create 返回 $($created.ReturnValue)"
    exit 1
}
$relayPid = $created.ProcessId
$relayPid | Set-Content -LiteralPath $pidFile -Encoding ascii

Start-Sleep -Seconds 2
if (-not (Get-Process -Id $relayPid -ErrorAction SilentlyContinue)) {
    Write-Host "启动失败，进程已退出。日志: $(Join-Path $root $cfg.LogFile)"
    $logPath = Join-Path $root $cfg.LogFile
    if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Tail 20 -Encoding utf8 | ForEach-Object { Write-Host "  $_" } }
    exit 1
}

Write-Host ""
Write-Host "反代已启动 (PID $relayPid)，解释器 $exe"
Write-Host "  运行日志: $(Join-Path $root $cfg.LogFile)"
Write-Host "--- 当前监听 ---"
foreach ($port in (Get-RelayPortList -Config $cfg)) {
    & $netstatExe -ano | Select-String "LISTENING" | Select-String ":$port" |
        ForEach-Object { Write-Host "  $($_.Line.Trim())" }
}
$logPath = Join-Path $root $cfg.LogFile
if (Test-Path -LiteralPath $logPath) {
    $bad = Select-String -LiteralPath $logPath -Pattern 'FATAL' -Encoding utf8 | Select-Object -Last 1
    if ($bad) { Write-Host "  注意: 日志里有 FATAL -> $($bad.Line)"; exit 1 }
}
