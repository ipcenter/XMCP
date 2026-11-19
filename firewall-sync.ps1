# 按 mcp-relay.config.json 同步宿主机防火墙（VMnet8 网段只放行配置里的端口）
# 原理：Windows 防火墙 Block 规则优先于 Allow 规则。
#       给配置里每个监听端口建 Allow，再把 1-65535 的其余部分用端口段 Block 掉。
#
# 用法：
#   powershell -File firewall-sync.ps1            只比对，不修改（退出码 0=已一致，1=有差异）
#   powershell -File firewall-sync.ps1 -Apply     实际写入（需要管理员/UAC）
#
# 由 start-mcp-relay.ps1 自动调用：发现差异才提权执行一次 -Apply。
param(
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
. (Join-Path $root 'relay-config.ps1')

$GROUP = 'XMCP relay'
$LEGACY = @(
    'XMCP block VMnet8 TCP 1-12334',
    'XMCP block VMnet8 TCP 12336-65535',
    'XMCP block VMnet8 UDP all',
    'XMCP block VMnet8 UDP 1-65535',
    'XTerminal MCP relay 12335 (VMnet8)'
)

function Say($msg) { Write-Host $msg }

function Write-FirewallFingerprint {
    try {
        $fp = Get-RelayFirewallFingerprint -Config $cfg
        if ($fp) {
            [IO.File]::WriteAllText((Join-Path $root 'firewall-fingerprint.txt'), $fp, (New-Object Text.UTF8Encoding($false)))
        }
    } catch { }
}
function Clear-FirewallPending {
    # 清掉「后台提权更新中」标记：控制台状态页看到这个文件就提示用户去点 UAC
    try { Remove-Item -LiteralPath (Join-Path $root 'firewall-pending.txt') -Force -ErrorAction SilentlyContinue } catch { }
}
function Write-FirewallState($Rules) {
    try {
        $lines = @()
        $lines += ('# 生成于 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        $rules = @($Rules)
        if ($rules.Count -eq 0 -or -not $rules[0]) {
            $lines += '（没有 XMCP relay 规则）'
        } else {
            foreach ($r in $rules) {
                $pf = $r | Get-NetFirewallPortFilter
                $lines += ($r.DisplayName + ' | Enabled=' + $r.Enabled + ' | ' + $r.Action + ' | ' + $pf.Protocol + ' ' + $pf.LocalPort)
            }
        }
        [IO.File]::WriteAllText((Join-Path $root 'firewall-state.txt'), ($lines -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

$cfg = Get-RelayConfig -Root $root
if ($cfg.Error) { Say "配置错误: $($cfg.Error)"; exit 3 }

if (-not $cfg.Firewall.Enabled) {
    Say "防火墙同步已关闭（firewall.enabled=false），跳过。"
    exit 0
}

$localIp  = $cfg.Firewall.LocalAddress
$remoteIp = $cfg.Firewall.RemoteAddress
$ports    = @(Get-RelayFirewallPorts -Config $cfg)
$ranges   = @(Get-BlockRanges -Ports $ports)

# ---- 目标规则清单 ----
$desired = @()
foreach ($p in $ports) {
    $desired += [pscustomobject]@{ Name = "XMCP allow TCP $p (VMnet8)"; Action = 'Allow'; Protocol = 'TCP'; Port = "$p" }
}
foreach ($r in $ranges) {
    $a = $r[0]; $b = $r[1]
    $spec = if ($a -eq $b) { "$a" } else { "$a-$b" }
    $desired += [pscustomobject]@{ Name = "XMCP block TCP $spec (VMnet8)"; Action = 'Block'; Protocol = 'TCP'; Port = $spec }
}
if ($cfg.Firewall.BlockUdp -ne $false) {
    $desired += [pscustomobject]@{ Name = 'XMCP block UDP all (VMnet8)'; Action = 'Block'; Protocol = 'UDP'; Port = '1-65535' }
}

# ---- 现状 ----
$currentObjs = @()
foreach ($name in $LEGACY) {
    $r = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
    if ($r) { $currentObjs += $r }
}
$currentObjs += @(Get-NetFirewallRule -Group $GROUP -ErrorAction SilentlyContinue)
Write-FirewallState $currentObjs

$current = @($currentObjs | ForEach-Object { [pscustomobject]@{ Name = $_.DisplayName } })

$desiredNames = @($desired | ForEach-Object { $_.Name })
$currentNames = @($current | ForEach-Object { $_.Name })

$missing = @($desiredNames | Where-Object { $currentNames -notcontains $_ })
$extra   = @($currentNames | Where-Object { $desiredNames -notcontains $_ })

Say "=== 防火墙同步（$localIp，来源 $remoteIp）==="
Say ("  放行端口: " + $(if ($ports.Count) { ($ports -join ', ') } else { '（无）' }))
Say ("  目标规则: " + $desired.Count + " 条（Allow " + $ports.Count + "，Block " + ($desired.Count - $ports.Count) + "）")

if ($missing.Count -eq 0 -and $extra.Count -eq 0) {
    Say "  状态: 已一致，无需修改。"
    Write-FirewallFingerprint
    Clear-FirewallPending
    exit 0
}

Say "  状态: 有差异"
foreach ($m in $missing) { Say "    缺少: $m" }
foreach ($e in $extra)   { Say "    多余: $e" }
# 有差异时不保留指纹，避免下次启动误判"一致"而跳过
Remove-Item -LiteralPath (Join-Path $root 'firewall-fingerprint.txt') -Force -ErrorAction SilentlyContinue

if (-not $Apply) { exit 1 }

# ---- 实际写入（需管理员）----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Say "  错误: -Apply 需要管理员权限，请通过 UAC 提权运行。"; exit 2 }

Say "  正在重建规则..."
foreach ($name in $LEGACY) {
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}
Get-NetFirewallRule -Group $GROUP -ErrorAction SilentlyContinue | Remove-NetFirewallRule

foreach ($d in $desired) {
    $params = @{
        DisplayName = $d.Name
        Group       = $GROUP
        Direction   = 'Inbound'
        Action      = $d.Action
        Protocol    = $d.Protocol
        LocalPort   = $d.Port
        LocalAddress  = $localIp
        RemoteAddress = $remoteIp
        Profile     = 'Any'
        Enabled     = 'True'
    }
    if ($d.Action -eq 'Allow') {
        $params.Description = 'XMCP relay: configured listen port, reachable from the VM subnet'
    } else {
        $params.Description = 'XMCP relay: block everything else from the VM subnet (allow rule wins on its own port)'
    }
    New-NetFirewallRule @params | Out-Null
    Say "    + $($d.Name)"
}

# ---- 校验 ----
$after = @(Get-NetFirewallRule -Group $GROUP -ErrorAction SilentlyContinue)
Write-FirewallState $after
$afterNames = @($after | ForEach-Object { $_.DisplayName })
$stillMissing = @($desiredNames | Where-Object { $afterNames -notcontains $_ })
if ($stillMissing.Count -gt 0) {
    Say ("  错误: 以下规则没有建成 -> " + ($stillMissing -join ', '))
    exit 2
}
Say ("  完成: 现有 " + $after.Count + " 条规则，与配置一致。")
Write-FirewallFingerprint
Clear-FirewallPending
exit 0
