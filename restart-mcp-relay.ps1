# 停止 + 启动 在同一个 powershell 进程里一次跑完
# 为什么要合并：控制台每起一个子 powershell，光是进程冷启动就约 1.9 秒。
# 原来「重启代理」要起两个子进程（stop-mcp-relay.ps1 + start-mcp-relay.ps1），
# 合并成一个能实打实省掉一次冷启动。
# 用法：powershell -ExecutionPolicy Bypass -File .\restart-mcp-relay.ps1 [-ForceFirewall]

param([switch]$ForceFirewall)

$ErrorActionPreference = 'Continue'

$root = $PSScriptRoot
$stopPath  = Join-Path $root 'stop-mcp-relay.ps1'
$startPath = Join-Path $root 'start-mcp-relay.ps1'

if (-not (Test-Path -LiteralPath $stopPath)) {
    Write-Host "找不到停止脚本: $stopPath"
    exit 1
}
if (-not (Test-Path -LiteralPath $startPath)) {
    Write-Host "找不到启动脚本: $startPath"
    exit 1
}

Write-Host '=== 停止 ==='
# 子脚本里的 exit 只会结束它自己，不会把本脚本带走（$LASTEXITCODE 照样能拿到）
& $stopPath
$stopCode = $LASTEXITCODE
if ($stopCode) { Write-Host "  停止脚本返回 $stopCode（继续尝试启动）" }

Write-Host ''
Write-Host '=== 启动 ==='
if ($ForceFirewall) {
    & $startPath -ForceFirewall
} else {
    & $startPath
}
$startCode = $LASTEXITCODE

exit $startCode
