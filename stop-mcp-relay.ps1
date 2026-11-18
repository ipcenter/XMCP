# 停止 MCP 反代（读配置里的端口，位置无关）
# 用法：双击 停止XMCP代理.bat，或
#       powershell -ExecutionPolicy Bypass -File .\stop-mcp-relay.ps1
$ErrorActionPreference = 'Continue'

$root = $PSScriptRoot
. (Join-Path $root 'relay-config.ps1')
$cfg = Get-RelayConfig -Root $root

$pidFile = Join-Path $root 'mcp-relay.pid'
$stopped = @()

if (Test-Path -LiteralPath $pidFile) {
    $oldPid = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ($oldPid) {
        $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-Process -Id $oldPid -Force
            $stopped += "PID $oldPid ($($proc.ProcessName))"
        }
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

# 兜底：按配置里的端口找 python 进程（不会误杀 XTerminal 的 127.0.0.1）
# 用 netstat 文本解析（Get-NetTCPConnection 在本机单次要 20 秒，太慢）
$ports = @(Get-RelayPortList -Config $cfg)
$netstatExe = Join-Path (Join-Path $env:SystemRoot 'System32') 'netstat.exe'
if (-not (Test-Path -LiteralPath $netstatExe)) { $netstatExe = 'netstat.exe' }
$nsText = ''
try { $nsText = (& $netstatExe -ano | Out-String) } catch { $nsText = '' }
foreach ($port in $ports) {
    $rx = [regex]('(?m)^\s*TCP\s+([0-9\.\*\[\]:]+):' + [regex]::Escape([string]$port) + '\s+[^\s]+\s+LISTENING\s+(\d+)')
    foreach ($m in $rx.Matches($nsText)) {
        $addr = $m.Groups[1].Value
        if ($addr -eq '127.0.0.1' -or $addr -eq '::1') { continue }
        $ownerPid = [int]$m.Groups[2].Value
        $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -match 'python') {
            Stop-Process -Id $ownerPid -Force
            $stopped += "PID $ownerPid ($($proc.ProcessName)) via $($addr):$port"
        }
    }
}

if ($stopped) { Write-Host ("已停止: " + ($stopped -join ', ')) }
else { Write-Host "没有发现运行中的反代进程。" }
