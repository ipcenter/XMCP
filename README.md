# XMCP 局域网反代（虚拟机 → 宿主机 XTerminal MCP）

目录：本程序所在目录（绿色版，放哪个盘哪个路径都行；脚本全部用 $PSScriptRoot 定位，不写死绝对路径）
版本：配置驱动版（2026-11-17）。监听地址、上游地址、防火墙放行端口都来自 `mcp-relay.config.json`，加代理只改这一个文件。

## 一、这套东西干什么

XTerminal 的 MCP 服务有两个硬限制，导致虚拟机不能直连：

1. 只监听 `127.0.0.1:12335`（源码里 `listen(port, "127.0.0.1")`，地址常量写死）；
2. Host 白名单只收 `127.0.0.1` / `localhost` / `::1`（SDK 的 `localhostHostValidation`），
   其它 Host 一律 `403 {"message":"Invalid Host: ..."}`。

所以加一个反代：对外监听 VMnet8 网关地址，转发到 `127.0.0.1:12335`，并把 Host 头改写掉。

```
虚拟机 192.168.110.x
   │  http://192.168.110.1:12335/mcp      ← MCP 客户端填这个地址 + Bearer 令牌
   ▼
宿主机 192.168.110.1:12335                ← 本套脚本（python 反代，监听配置在 config）
   │  Host 改写为 127.0.0.1:12335
   ▼
宿主机 127.0.0.1:12335                    ← XTerminal MCP（Streamable HTTP，路径 /mcp），上游在 config
```

反代是"多条转发规则"的通用小代理：一条 `proxy` = 一组「对外监听 `listen` → 上游 `target`」，
所以除了 XTerminal，还可以顺手把别的本机服务（`http://127.0.0.1:8080` 之类）也暴露给虚拟机。

## 二、要不要部署到虚拟机里？——不要

反代必须跑在**宿主机**上，原因很直接：它要访问的 `127.0.0.1:12335` 是宿主机自己的回环地址，
装在虚拟机里，`127.0.0.1` 指的是虚拟机自己，根本到不了 XTerminal。

虚拟机里**什么都不用装**，只把 MCP 客户端的地址配成 `http://192.168.110.1:12335/mcp` 并带上令牌即可。

什么情况下虚拟机里才需要加东西：只有当虚拟机和宿主机网络不通（比如虚拟机是桥接、或换了网段），
才需要在虚拟机内做二次跳转。当前 VMnet8（NAT，网段 192.168.110.0/24）已经通了，不需要。

## 三、文件清单

| 文件 | 作用 |
|---|---|
| `XMCP控制台.bat` | **唯一双击入口**（目录里只有这一个 bat），打开控制台并自动启动 + 自动检测 |
| `XMCP控制台.ps1` | 控制台本体：单窗口 + 顶部四个 tab（状态 / 配置格式 / 配置内容 / 运行日志）+ 底部三个按钮，右下角托盘常驻 |
| `validate-config.py` | 保存前用严格 JSON 校验；报错翻译成"第 X 行第 Y 列附近: …"一行中文（完整堆栈只进日志） |
| `format-config.py` | 把压成一行的 JSON 排成"一个键一行、缩进 2 格"再显示/保存（`ensure_ascii=False`，中文不转义） |
| `mcp-relay.config.json` | **配置文件**：日志、防火墙、所有代理的监听与上游 |
| `xterminal-mcp-lan-relay.py` | 反代本体，纯标准库，支持多代理、SSE / chunked 流式透传、Host 改写、日志轮转 |
| `relay-config.ps1` | 共享的配置解析（被控制台 / start / stop / check / firewall-sync 共用，不单独运行） |
| `firewall-sync.ps1` | 按配置计算并同步防火墙；不带参数只比对，`-Apply` 才真正改；同时写 `firewall-state.txt` 快照与 `firewall-fingerprint.txt` 指纹 |
| `start-mcp-relay.ps1` | 启动逻辑（读配置 → 指纹命中则跳过防火墙 → `Win32_Process.Create` 分离启动）；加 `-ForceFirewall` 可强制重查；控制台内部调它 |
| `stop-mcp-relay.ps1` | 停止逻辑（先按 PID 文件，再解析 `netstat` 按配置端口兜底，约 2.5 秒）；控制台内部调它 |
| `check-mcp-relay.ps1` | 命令行版状态检查（控制台已内置同样的检查，这个留作备用） |
| `mcp-relay.log` | 反代运行日志（超过 5MB 自动轮转为 `.1`） |
| `mcp-relay.pid` | 当前反代进程 PID |
| `xmcp-console.log` | 控制台自己的操作日志（启动计时、检测结果、重启、缩托盘、退出，排错用） |
| `xmcp-console-status.txt` | 控制台最近一次检测的完整快照（窗口不在了也能看它） |
| `firewall-state.txt` | 防火墙规则快照（`firewall-sync.ps1` 写，控制台读它显示，避免现场查 7 秒） |
| `firewall-fingerprint.txt` | 防火墙配置指纹（比对一致时才写；启动脚本见到指纹没变就跳过整段比对，省 20–24 秒。删掉即强制重查） |
| `firewall-once\` | 早期一次性防火墙脚本与执行日志（已执行完毕，仅供追溯） |

## 四、配置文件 `mcp-relay.config.json`

当前内容：

```json
{
  "log": { "file": "mcp-relay.log", "max_bytes": 5242880 },
  "firewall": {
    "enabled": true,
    "local_address": "192.168.110.1",
    "remote_address": "192.168.110.0/24"
  },
  "proxies": [
    {
      "name": "xterminal-mcp",
      "enabled": true,
      "listen": ["192.168.110.1:12335", "192.168.1.20:12335"],
      "target": "127.0.0.1:12335",
      "rewrite_host": true,
      "upstream_timeout": 3600
    }
  ]
}
```

（文件里还带一个 `示例-第二个服务`，`enabled: false`，当注释用，留着改就行。）

字段含义：

| 字段 | 说明 |
|---|---|
| `log.file` | 日志文件名，相对脚本目录 |
| `log.max_bytes` | 单个日志文件上限，超过就轮转成 `.1`（默认 5 MB） |
| `firewall.enabled` | `true` 时启动脚本会按配置自动同步防火墙；`false` 则完全不动防火墙 |
| `firewall.local_address` | 这些端口对外挂在哪个本机地址上（VMnet8 网关 `192.168.110.1`） |
| `firewall.remote_address` | 允许/拦截的来源网段（虚拟机网段 `192.168.110.0/24`） |
| `firewall.block_udp` | 可选，默认 `true`，顺带把该网段的 UDP 全封 |
| `proxies[].name` | 名字，只用于日志和界面显示 |
| `proxies[].enabled` | `false` = 跳过（日志里记一条 `SKIP`），便于随时停用某条 |
| `proxies[].listen` | **对外暴露地址**，可写多个，格式 `IP:端口` 或 `:端口`（`:端口`=监听所有地址） |
| `proxies[].target` | **上游真实地址**，格式 `IP:端口` |
| `proxies[].rewrite_host` | 是否把 Host 头改写成 `target` 的地址。**XTerminal 必须 `true`**（否则 403）；普通服务一般 `false` |
| `proxies[].upstream_timeout` | 连上游的超时秒数。MCP 走长连接 / SSE，所以给 3600；普通 HTTP 服务 60 就够 |

`listen` 和 `target` 是两个完全不同的东西，别写反：`listen` 是"别人从哪进来"，`target` 是"最终谁在提供服务"。
对外端口不必等于上游端口，例如 `listen: 192.168.110.1:18080 → target: 127.0.0.1:12335` 也成立。

### 加一个代理（4 步）

1. 在 `proxies` 数组里复制一段，改 `name`、`listen`、`target`；
2. `enabled` 设为 `true`；
3. 关掉控制台（选"2. 关闭退出"，或托盘右键"停止代理并退出"），再双击 `XMCP控制台.bat`
   （**配置不热加载，必须重开才生效**）；启动时自动比对防火墙，有差异才弹一次 UAC，点"是"即可；
4. 控制台打开后自动检测，看新地址是否在监听、HTTP 是否通。

## 五、日常使用（一个窗口 + 顶部四个 tab + 底部三个按钮）

双击 `XMCP控制台.bat` → 出现一个窗口（无黑框闪烁）。窗口布局：

```
┌ XMCP 反代控制台 ───────────────────────────────┐
│ 顶部提示：双击即可：自动启动反代 + 自动检测连通性   │
│ [状态] [配置格式] [配置内容] [运行日志]            │
│                                                  │
│   （当前 tab 的内容区 656×416）                   │
│                                                  │
│ [1. 最小化]   [重启代理]   [2. 关闭退出]           │
└──────────────────────────────────────────────────┘
```

**四个 tab**

- **状态**：配置摘要、代理进程、监听端口、各地址连通性、防火墙规则（读 `firewall-state.txt` 快照，不现场查 7 秒）。
- **配置格式**：只读样板 + 字段说明，可整段复制到「配置内容」再改。
- **配置内容**：`mcp-relay.config.json` 的**可编辑**原文，
  - 一打开就自动**排版**（一个键一行、缩进 2 格、换行统一 CRLF，和编辑器里看 JSON 一样清楚）；
  - 右上角 **「打开配置文件…」** 按钮：可以选任意 `.json` 载入到编辑框（只载入，不覆盖现有配置），
    载入后点「重启代理」才会校验并写回 `mcp-relay.config.json`；
  - 改完点底部 **「重启代理」**：先严格校验（python `json.load`，报错翻成"第 X 行第 Y 列附近: …"），
    通过才保存（旧文件自动备份 `mcp-relay.config.json.bak`）并重启代理；格式错会弹窗且**不动原文件**。
    完整报错只写 `xmcp-console.log`，弹窗里只放一行看得懂的话。
- **运行日志**：自动汇总 `mcp-relay.log` + `xmcp-console.log` 各尾 60 行，另有「刷新日志 / 打开反代日志 / 打开控制台日志」三个小按钮。

**底部三个按钮（会随检测结果变脸）**

- **1. 最小化**（宽 180px）—— 只在"检测为通"时可点；点一下窗口立刻隐藏（实测 0.17 秒），
  任务栏也不留，只留右下角一个托盘小图标，反代继续服务。悬停显示 `XMCP 反代 · 192.168.110.1:12335`；
  双击托盘图标重新打开；右键有"打开控制台 / 重启代理 / 停止代理并退出"。
- **重启代理**（宽 200px，文字不换行）—— 语义是**重启一次代理**：有未保存改动就先校验保存，
  再停掉现有反代 → 重新拉起（防火墙配置没变则跳过比对）→ 等端口真正能应答 → 再检测，并自动切回「状态」页。
  实测一次重启 **约 15 秒**，**期间窗口一直可操作**（`Responding` 全程 True，最小化 80 毫秒生效）。
- **2. 关闭退出**（宽 256px）→ 二次确认后停掉反代并退出（**虚拟机就访问不了了**）。
- 检测为**不通**时：左边按钮**置灰不可点**（文字变成"代理异常（点右侧）"），只能点「重启代理」。

1. **自动**读配置、**自动**把反代启动起来（没运行时才启动，并同步防火墙）、**自动**检测各地址连通性。
   冷启动约 **10–15 秒**（防火墙若配置没变会自动跳过比对），全程窗口可拖动、可点 `-` 最小化、可点 X 收托盘——
   **不再出现"未响应"**（启停都在后台 runspace 里跑，UI 线程只做计时轮询）。
2. 点右上角 X 不会退出，等同"最小化"——反代继续跑；要真停就用「2. 关闭退出」或托盘右键。
   点右上角 `-` 也一样：无论正在启动还是正在重启，`-` 都能立刻最小化到任务栏（不会再被冻结拦住）。
3. 单实例：已经有一个控制台在托盘里时，再双击 bat 会提示"已经在运行"，不会开出第二个窗口
   （用命名互斥量 `XMCP_Console_Singleton`，比查 WMI 进程快，启动省 2–3 秒）。
4. 防火墙那块**不现场查**（`Get-NetFirewallRule` 首次要 7 秒，是之前卡顿的元凶），改成读
   `firewall-state.txt` 快照——由 `firewall-sync.ps1` 每次同步时写；窗口上会标"快照: 时间"。
5. **防火墙配置指纹**：`firewall-sync.ps1` 比对一致时写 `firewall-fingerprint.txt`（内容形如
   `192.168.110.1|192.168.110.0/24|12335|udp=1`）。启动脚本发现指纹没变就直接跳过整段比对
   （单次比对要 20–24 秒，跳过这一步就是"重启从 80 秒降到 15 秒"的关键）。
   改了配置/手工动过规则想强制重查：删掉 `firewall-fingerprint.txt`，或加参数
   `powershell -File start-mcp-relay.ps1 -ForceFirewall`。
6. 想让配置"改坏了也不怕"：每次保存前都会严格校验，失败只弹窗、不写文件；保存时旧版自动存成 `.bak`，
   想回退把 `.bak` 改回 `mcp-relay.config.json` 再点「重启代理」即可。

命令行等价写法（不想用窗口时）：

```powershell
powershell -ExecutionPolicy Bypass -File ".\start-mcp-relay.ps1"        # 先 cd 到程序目录
powershell -ExecutionPolicy Bypass -File ".\stop-mcp-relay.ps1"
powershell -ExecutionPolicy Bypass -File ".\check-mcp-relay.ps1"
powershell -ExecutionPolicy Bypass -File ".\XMCP控制台.ps1" -AutoTray   # 检测完直接缩托盘，不弹窗口
```

正常时应看到三条监听：

```
TCP  127.0.0.1:12335       LISTENING  <XTerminal PID>
TCP  192.168.110.1:12335   LISTENING  <pythonw PID>
TCP  192.168.1.20:12335    LISTENING  <pythonw PID>
```

按当前选择，**不注册开机自启**，重启或注销后手动双击 `XMCP控制台.bat` 一次即可。

## 六、虚拟机侧怎么接

MCP 客户端配置：

```
URL:  http://192.168.110.1:12335/mcp
Header: Authorization: Bearer <XTerminal → 设置 → MCP 服务 → 客户端访问令牌 里签发>
```

虚拟机内自测（Windows，`curl` 用 `curl.exe`）：

```powershell
# 期望 401（到达了 MCP 服务，只是没带令牌）
curl.exe -sS -i --max-time 5 http://192.168.110.1:12335/mcp
```

Linux 里同一条命令去掉 `.exe`，POST 的 `initialize` 探针见旧版说明，或直接用 `check-mcp-relay.ps1` 看状态。

## 七、宿主机防火墙（启动时自动同步，不用手改）

`firewall-sync.ps1` 按配置算两件事：

- **放行端口**：所有 `listen` 里落在 `firewall.local_address`（或 `0.0.0.0` / `:端口`）上的端口；
- **端口段黑名单**：把 `1-65535` 减去放行端口集合，算成若干连续区间做 Block；
  再加一条 UDP 全段 Block（`block_udp=true`）。

靠 Windows 的"Block 优先于 Allow"实现"只放行配置里的端口"。当前规则组 `XMCP relay` 共 4 条：

| 规则名 | 动作 | 协议 | 端口 | 本地地址 | 来源 |
|---|---|---|---|---|---|
| `XMCP allow TCP 12335 (VMnet8)` | Allow | TCP | 12335 | 192.168.110.1 | 192.168.110.0/24 |
| `XMCP block TCP 1-12334 (VMnet8)` | Block | TCP | 1-12334 | 192.168.110.1 | 192.168.110.0/24 |
| `XMCP block TCP 12336-65535 (VMnet8)` | Block | TCP | 12336-65535 | 192.168.110.1 | 192.168.110.0/24 |
| `XMCP block UDP all (VMnet8)` | Block | UDP | 1-65535 | 192.168.110.1 | 192.168.110.0/24 |

加配置后的自动演化（已实测）：配置里多一个 `192.168.110.1:18080` 时，规则自动变成
`allow TCP 18080` + `block TCP 1-12334` + `block TCP 12336-18079` + `block TCP 18081-65535` + `block UDP all`（6 条）；
把那条配置撤掉再启动，规则自动收回成上面 4 条，18080 立刻从虚拟机不可达。

机制要点：

- **只比对，不改**：`powershell -File firewall-sync.ps1`，退出码 `0`=一致 / `1`=有差异 / `2`=失败 / `3`=配置错；
- **真正写**：加 `-Apply`（需要管理员，启动脚本会自动 `RunAs` 并等它结束，再复检一次）；
- 无差异时**不弹 UAC**，只有配置变了（或规则被人动过）才弹一次；
- 规则统一收在组 `XMCP relay`；早期旧命名（`XMCP block VMnet8 TCP ...`、`XTerminal MCP relay 12335 (VMnet8)`）
  会被自动删除，不需要手工清理。

另外：原有的 `Block VMnet8 192.168.110.0/24 Inbound`（整条入站全阻断）保持 **Disabled**（保留但禁用），
否则 12335 也会被它挡掉。只禁用整条阻断的话，Windows 自带的「文件和打印机共享」放行规则会重新生效
（实测虚拟机连上了宿主机 **135 / 139 / 445**），所以端口段黑名单不能省。

`192.168.1.20` 所在的以太网属 Public 默认阻断，局域网其它机器进不来。

## 八、改端口 / 改地址怎么做

**只改 `mcp-relay.config.json`，然后重启反代，防火墙会自己跟上。**

| 场景 | 改哪里 |
|---|---|
| XTerminal 设置里把 MCP 端口从 12335 改成 12340 | `target` → `127.0.0.1:12340`（对外 `listen` 保持 12335 也可以） |
| 对外端口换成别的 | `listen` 里的端口（防火墙自动换放行端口、自动重算黑名单区间） |
| 换网卡 / 换网段 | `listen` 加地址，并把 `firewall.local_address`、`firewall.remote_address` 一起改 |
| 再加一个服务给虚拟机用 | 新加一段 `proxy`，见第四节 4 步 |
| 临时停掉某条 | `enabled` → `false` |

配置文件缺失时，python 端会退回旧的环境变量默认值（`XT_MCP_RELAY_CONFIG` / `XT_MCP_RELAY_LISTEN` /
`XT_MCP_RELAY_PORT` / `XT_MCP_TARGET_PORT`），仅作兜底，不建议使用。

## 九、排错

| 现象 | 原因 / 处理 |
|---|---|
| `401 Unauthorized` | 正常。缺令牌或令牌错，去 XTerminal 签发/核对 |
| `403 Invalid Host: ...` | 没经过反代（直连了 127.0.0.1 或别的地址），或 `rewrite_host` 没开 |
| 连接超时 / 无响应 | 反代没启动、防火墙没放行、或虚拟机不在 `192.168.110.0/24` |
| 改了配置但没变化 | 配置不热加载，必须关掉控制台（选项 2 / 托盘右键）再双击 `XMCP控制台.bat`；控制台上半段"代理"列表里没出现新条目就是没读到配置 |
| 启动时弹 UAC，点了"否" | 防火墙没更新，新端口对虚拟机不通；重新双击一次控制台再点"是"，或手动 `firewall-sync.ps1 -Apply` |
| 点了窗口右上角 X 后窗口没了，但反代还在跑 | 设计如此（X = 缩到托盘）。从右下角托盘图标双击打开，或托盘右键"停止代理并退出" |
| 右下角托盘图标不见了 | 可能控制台进程被结束过（`xmcp-console.log` 末尾有 `console exited`）；反代本身不受影响，双击 bat 重开控制台即可 |
| 端口放行了仍不通 | 看 `listen` 的地址是不是绑定在 `firewall.local_address` 那块网卡上；`:端口` 形式会算作全地址放行 |
| 启动脚本报"找不到 python" | 改 `start-mcp-relay.ps1` 里的 `C:\Python314\pythonw.exe` 路径 |
| 端口被占用 | `netstat -ano | findstr :12335`，先停掉占用者：控制台选"2. 关闭退出"，或 `stop-mcp-relay.ps1` |
| PowerShell 里 POST 返回 `400 SyntaxError: Expected property name ...` | PowerShell 传参会把 JSON 里的双引号吃掉，不是反代问题。body 存文件，用 `curl.exe --data-binary "@文件"` |
| `curl: (7) ... Bad access` | Windows 上并发 curl 的偶发失败，串行重试一次即可 |
| `.ps1` 报 `missing the terminator` | 文件被存成了无 BOM 的 UTF-8，PowerShell 5.1 按 ANSI 解码。另存为 UTF-8 **带 BOM** |

## 十、已验证 / 未验证

### 控制台（2026-11-17，合并为一个 bat）

- 目录里只剩一个 bat：`XMCP控制台.bat`（旧的 启动/停止/测试 三个 bat 已删除，功能合并进控制台）
- 双击后单窗口出现，无黑框；窗口内自动完成"读配置 → 启动（未运行才启动）→ 检测"，实测输出 `小结: 2/2 个地址可达`
- 按钮随状态变脸（2026-11-17 改版）：检测为通 → 显示 **`1. 最小化`** 且可点，点一下窗口消失 **0.17 秒**（UI Automation 实测）；
  检测为不通 → 该按钮置灰、文字变"代理异常（点右侧）"，只能点"重新检测（重启代理）"
- 按钮尺寸按文字实测重排：`1. 最小化` 140px（文字 58px）、`重新检测（重启代理）` 200px（文字 128px，
  "★"态 138px，均单行不换行）、`2. 关闭退出（停止代理）` 296px（文字 142px）
- "重新检测"改为**重启一次代理**：早期同步实现要 55–80 秒、其间窗口像死机；现改为后台 runspace 执行，
  实测（22:17:25 点下 → 22:17:40 `relay task done` → 22:17:41 判 `2/2 地址可达`、`healthy=True`）**全程约 15 秒**，
  期间 `Responding` 连续 6 次全 True、`SetWindowVisualState(Minimized)` **80 毫秒**生效，完成后按钮恢复为可点的 `1. 最小化`
- 三处提速（实测）：`stop-mcp-relay.ps1` 兜底弃用 `Get-NetTCPConnection`（单次 20.5 秒）改解析 `netstat` 文本 →
  **2.5 秒**；`start-mcp-relay.ps1` 指纹命中跳过防火墙比对 → **4.6 秒**（原来 45 秒+）；后台任务改"等端口真正应答"
  （curl 轮询，最多 30×0.7 秒）替代固定 `Start-Sleep 2`，消除"重启后误报 0/2"
- 首屏计时（`xmcp-console.log` 里的 `t=`）：`t=0.5s singleton ok`（互斥量替代 WMI 查询）→ `t=2.2s ui built`
  → `t=2.5s shown` → 状态文本 1.2 秒内出齐；防火墙段改读快照文件，不再现场查 `Get-NetFirewallRule`（首次 7 秒）
- 重启后 MCP 端到端复验：`xterminal_ssh_list_servers(query="XY-CAT")` 返回 `XY-CAT`（connected），
  `xterminal_ssh_exec` 执行 `hostname` → `XY-Cat`，exitCode 0，说明反代换 PID 后 JSON-RPC 透传仍正常
- 托盘机制单独验证过（无控制台窗口也能创建 NotifyIcon，图标取自 `pythonw.exe`）
- 结束控制台进程后反代不受影响，三条监听仍在（控制台与反代是独立进程）
- 冷启动实测（先停掉反代再双击控制台）：控制台自己把反代拉起（新 PID 56388），22:17:09 开始 → 22:17:23 完成
  → 22:17:24 判 `2/2 地址可达`、`healthy=True`，**约 14 秒**；期间 `Responding` 10 次采样全 True
- 新建控制台还会留一份 `xmcp-console-status.txt` 快照，窗口关了也能查最近一次检测结果
- 单实例生效：已有控制台在托盘里时再双击只会提示"已经在运行"（命名互斥量 `XMCP_Console_Singleton`，比查 WMI 进程快 2–3 秒）

### 配置编辑 / 保存链（2026-11-17 22:38–23:26，本轮实测）

| 动作 | 结果 |
|---|---|
| 配置内容页显示 | 一个键一行、缩进 2 格，36 行全可见（原来 LF-only 被 WinForms 挤成一行 → 已加 `To-Crlf` 归一化） |
| 写入非法 JSON（末尾多个 `,`）→ 点「重启代理」 | 弹窗 `配置格式错误`，正文为一行中文 `语法错误: 第 37 行第 3 列附近: Extra data`；`config rejected` 进日志；配置文件 hash 未变、无 `.bak` |
| 写入合法 JSON（末尾多空行）→ 点「重启代理」 | 日志 `config saved (backup: mcp-relay.config.json.bak)` → `relay task start: Restart`；文件 1064→1100 字节（CRLF 规范化）、`.bak` 生成、hash 变化；完成后自动切回「状态」页并 `2/2 地址可达 healthy=True` |
| 点「打开配置文件…」 | 弹出标题为 `打开配置文件并载入到编辑框` 的文件选择框（Esc 可取消），取消后不改动编辑框 |
| 保存后再 `python validate-config.py` 校验 | 退出码 0；`/` → 404、`/mcp` → 401（`192.168.110.1` 与 `192.168.1.20` 两个监听都在答） |

折行问题的一个隐藏原因（2026-11-17 23:33 定位）：四个文本框原来都锚了
`Top|Left|Right|Bottom`，窗口是 `FixedSingle` 不可缩放，但锚点仍按父容器尺寸算出偏移，
把 `配置内容` 编辑框实际拉成 **1068×596**（客户区 1047×592），远超 `620×310` 的可见区域 ——
文字确实折行了，只是折在看不见的地方，所以看起来被"硬截断"。
去掉 Right/Bottom 锚点后客户区回到 599×306，长行正常折到下一行。
同时把 `XMCP控制台.ps1` 从纯 LF 转成 CRLF：之前 here-string 里的样例文本带 LF，
WinForms 多行框不认，`配置格式`页整段 JSON 挤成一行；转 CRLF 后逐行显示正常，
样例框也改成 `WordWrap=true + Vertical`。

### 宿主机（2026-11-17，配置驱动版）

- 启动脚本读配置打印 `[xterminal-mcp] 192.168.110.1:12335, 192.168.1.20:12335 -> 127.0.0.1:12335（Host 改写）`，
  日志 `1 个代理 / 2 个监听地址`，`netstat` 三条监听齐全（pythonw PID 与 `mcp-relay.pid` 一致）
- 三条地址 `curl .../mcp` 全部 `401`
- 防火墙规则迁移：首次同步报"缺少新命名 4 条 / 多余旧命名 4 条" → 提权 Apply → 复检"已一致"，
  旧命名（含 `XTerminal MCP relay 12335 (VMnet8)`）已被清除
- 改配置加 `18080` → 报"缺少 allow 18080 + block 12336-18079 + block 18081-65535、多余 block 12336-65535" → Apply → 一致
- 撤掉 `18080` → 报"缺少 block 12336-65535、多余 allow 18080 + 两条拆分区间" → Apply → 一致，回到 4 条

### 虚拟机内（XY-S，`192.168.110.110/24`，Windows）

| 测试 | 结果 |
|---|---|
| `Test-NetConnection 192.168.110.1 -Port 12335` | `TcpTestSucceeded : True`（宿主名解析为 Firelight） |
| `curl http://192.168.110.1:12335/mcp` | `401` + `WWW-Authenticate: Bearer realm="Xterminal MCP"` |
| `curl -X POST /mcp` + `initialize`（无令牌） | `401`，请求体完整送达上游（body-parser 正常解析） |
| 新加配置后 `192.168.110.1:18080` | `OPEN`，`curl /mcp` → `401` + 同样的 `Bearer realm="Xterminal MCP"`（证明自动放行生效、且走的是同一上游） |
| 未配置的 `192.168.110.1:8088` | `TIMEOUT`（黑名单仍然有效，没被新端口带出缺口以外的口子） |
| 撤回配置后再测 `18080` | `TIMEOUT`；`12335` 仍 `OPEN` 且 `/mcp` → `401`；`445` → `TIMEOUT` |
| `curl http://127.0.0.1:12335/mcp`（虚拟机本地回环） | `000` 连接被拒 —— 印证反代不能装在虚拟机里 |

### 真实 MCP 客户端端到端（2026-11-17 21:09，并在配置驱动版复测）

| 调用 | 结果 |
|---|---|
| `xterminal_ssh_list_servers(query="XY-CAT")` | 返回 `XY-CAT`（`192.168.40.20:22`，`connectionState=connected`，`sudoEnabled=true`） |
| `xterminal_ssh_exec`：`hostname; whoami; uname -sr; uptime; ip -br a` | `exitCode=0`，`XY-Cat` / `root` / `Linux 6.1.0-52-amd64` / `ens33 192.168.40.20/24`，3388 ms |
| 第二条 `xterminal_ssh_exec`（`date` / `df` / `free` / `docker ps`） | `exitCode=0`，2482 ms —— 同一会话可复用 |

结论：**虚拟机 → 反代 → XTerminal → SSH 目标机** 全链路可用；反代对 JSON-RPC 请求体、响应、
`mcp-session-id` 会话保持、SSE 流式都是正常透传的。

### 仍未验证

- 多代理并发长时间跑（只验证了单条 18080 短暂挂载）
- `listen` 用 `0.0.0.0` 或 `:端口` 的形态（代码支持，未实测；改了等于对局域网放开，属新决策）
- 「打开配置文件…」选中真实文件后的载入（只验证到对话框能弹出、Esc 取消后编辑框不变）
- 没有 python 环境时 `ConvertFrom-Json` 的回退分支（当前机器有 `C:\Python314`，走的是 python 严格校验）

### 附：关窗后存活的现场证据（2026-11-17 21:11）

当时反代 PID `61220`，启动于 `20:57:42`，已连续运行 14 分钟；其父进程（`43596`）此时**已不存在**，
而反代仍正常服务。说明 `Win32_Process.Create` 拉起 `pythonw` 后，进程与 bat / powershell 窗口已无父子绑定，
关窗口不会带走反代。（依据是父进程消失而子进程存活；具体是哪一次启动无法 100% 回溯。）

## 十一、安全边界

反代本身不做鉴权，鉴权完全靠 XTerminal 令牌。建议：

- 每个客户端单独签发令牌，不用就撤销；
- 「命令执行策略」保持「每次确认」，不要设「直接执行」；
- sudo、工作区写入权限只给确实需要的令牌；
- 不要把 `listen` 改成 `0.0.0.0` / `:端口`，除非确实需要局域网其它机器接入；
- 防火墙只放行配置里的端口，别手工加全放行规则——手改会被下一次同步覆盖回去。

## 十二、控制台界面与「配置校验跑不起来」修复（2026-11-18）

### 界面
- 窗体 `Sizable`，可鼠标拉伸；右下角三角拖拽有效，布局由 `Update-Layout` 按 `ClientSize` 实时重排，`MinimumSize 700x600`。
- 标题栏自带 `最小化 / 最大化 / 关闭`，故不再放自绘的正方形最大化按钮（已删除）。
- 顶部四个 tab 自绘高亮：选中项蓝底白字加粗（`DrawMode=OwnerDrawFixed`，`DrawString` 必须传 `RectangleF`，传 `Rectangle` 会被重载解析成 `PointF` 抛异常）。
- 各页说明文字与文本框之间留一行空隙，「运行日志」页提示拆两行，不再拥挤。

### 「配置格式错误 / 无法将 cmd.exe 项识别为 cmdlet」= 真 bug，不是配置内容重复
- 现象：把配置复制一份改名，导入后点「重启代理」→ 弹「配置格式错误 / 未保存」，正文是 PowerShell 的 `CommandNotFound`。
- 根因：校验与排版两处都用 `& cmd.exe /c "<python> <脚本> <文件>"` 这种字符串拼接的写法，命令解析依赖调用者的 `PATH`。控制台若在精简 `PATH` 的宿主里拉起（缺 `System32`），`cmd.exe` 解析不到，整条校验失败，错误文本又被当成「语法错误」显示在弹窗里 —— 与配置内容毫无关系。
- 修复：三处调用全部改成**直接调解释器**，不经 `cmd.exe`：
  - `Format-JsonText`：`(& $py $fmtPy $tmpIn 2>&1 | Out-String)`
  - 校验：`(& $py $validatePy $tmp 2>&1 | Out-String)`
  - 回退分支：`(& $py -c $code $tmp 2>&1 | Out-String)`
  另加 `$cmdExe = $sys32\cmd.exe`（存在则用绝对路径，否则回退裸名）作为兜底；`netstat / curl / powershell` 同样走 `$sys32` 绝对路径。
- 错误分类也分开了：输出命中 `无法将 / not recognized / 不是内部或外部命令 / 拒绝访问 / No such file` 时提示「校验脚本没跑起来（找不到 python 或系统命令）」，不再误导成「语法错误」。
- 验证（同一份配置粘贴回编辑框 → 点「重启代理」）：`config saved (backup: mcp-relay.config.json.bak)` → `relay task start: Restart` → `relay task done` → `status updated: 2/2 地址可达 healthy=True`，三条监听齐全（`127.0.0.1` XTerminal、`192.168.110.1` 与 `192.168.1.20` 新 PID）；全程无弹窗。

### 结论：配置内容重复会不会报错
不会。校验只看两件事：JSON 语法合法、结构上至少一条 `enabled` 的 proxy 且 `listen`/`target` 齐全。文件名、内容是否与现有配置重复都不参与判断。

### 弹窗中文变乱码（「绗?19 琛?」）= 控制台管道按 GBK 解码 UTF-8
- 现象：校验失败时弹窗显示 `语法错误: 绗?19 琛? 8 鍒楅檮杩? Expecting value`。
- 根因：`& $py ... | Out-String` 抓取的是子进程标准输出，Windows PowerShell 按 `[Console]::OutputEncoding`（简中默认 GBK/936）解码，而 python 打出的是 UTF-8 字节，于是中文被双重错码。
- 修复：`validate-config.py` 增加可选第二个参数「提示输出文件」，把中文提示另写一份 UTF-8 文件；控制台改成读文件（`ReadAllText(..., UTF8Encoding)`），彻底绕开控制台编码。`-c` 回退分支没法走文件，改为临时把 `[Console]::OutputEncoding` 切到 UTF-8，`finally` 里恢复。日志里也不再追加那段乱码原文（只有读不到提示文件时才回退用管道文本）。
- 验证（故意把配置截断成非法 JSON → 点「重启代理」）：弹窗为 `语法错误: 第 32 行第 2 列附近: Expecting property name enclosed in double quotes`，日志同一条干净、无乱码尾巴；随后重启控制台恢复正常，`2/2 地址可达 healthy=True`。

## 十三、配置支持 # 注释（2026-11-18）

JSON 标准不支持任何注释，`//` 会和 URL 里的 `http://` 打架，因此统一采用 `#`：

```json
# 整行注释：反代监听配置
{
  "_说明": "字符串里的 # 不会被当成注释",   # 行尾注释也行
  "firewall": { "enabled": true },          # 是否自动同步防火墙
  "proxies": [ ... ]
}
```

规则：`#` 之后到行尾全部忽略；字符串内部的 `#` 原样保留；换行保留，所以报错行号仍然准。

四处解析点必须口径一致，本次全部改齐：

| 位置 | 作用 | 改动 |
|---|---|---|
| `validate-config.py` | 控制台点「重启代理」时校验 | 解析前 `strip_comments` |
| `format-config.py` | 自动排版 | 解析前 `strip_comments`；**带注释时不重排**（dumps 会丢注释），原样返回 |
| `xterminal-mcp-lan-relay.py` | 反代读配置 | `json.loads(strip_comments(...))` |
| `relay-config.ps1` | start / stop / check / firewall-sync 共用 | `Remove-JsonComments` 后 `ConvertFrom-Json` |
| `XMCP控制台.ps1` | 结构检查（enabled proxy、listen/target） | 同上，自带一份 `Remove-JsonComments` |

实测：
- 带整行注释 + 行尾注释 + 字符串内含 `#` 的配置：校验退出码 0；排版后注释完整保留；
- `Get-RelayConfig` 解析出 1 条 proxy，防火墙指纹仍为 `192.168.110.1|192.168.110.0/24|12335|udp=1`；
- 反代用临时配置（`127.0.0.1:12399 → 127.0.0.1:12335`，带注释）实跑：`LISTEN [comment-test]` + `relay ready: 1 个代理 / 1 个监听地址`，端口确实在监听；
- 正式配置重载后 `2/2 地址可达 healthy=True`，`192.168.110.1:12335` 与 `192.168.1.20:12335` 都在（PID 39712）。

注意：**带 `#` 注释的配置不会被自动重排**，否则注释会被 json.dumps 吃掉。要恢复自动排版，先把注释删掉。

### 尾部逗号也放行（2026-11-18 追加）
用户常见写法是「最后一项后面留逗号，再跟注释」：

```json
"listen": [
  "192.168.110.1:12335",
  "192.168.1.20:12335", # 二号地址
]
```

剥掉注释后剩下 `"192.168.1.20:12335", ]` —— 逗号悬在 `]` 前面，严格 JSON 报 `Illegal trailing comma before end of array`。这不是 `#` 的错，而是逗号留在了数组/对象末尾。

现在在剥注释之后再加一道 `drop_trailing_commas`：`]` 或 `}` 前面只有空白时，那个逗号直接丢掉（字符串内部的逗号不受影响）。于是上面这种写法可以直接用。

同步改了 5 处（口径必须一致）：`validate-config.py`、`format-config.py`、`xterminal-mcp-lan-relay.py`、`relay-config.ps1`（`Convert-RelayConfigText`）、`XMCP控制台.ps1`（同名函数）。

实测：
- 含「尾逗号 + 行尾注释」的配置：`validate-config.py` 退出码 0；
- `Get-RelayConfig` 解出 1 条 proxy，`listen` 两个地址完整；
- 反代实跑（`127.0.0.1:12399 → 127.0.0.1:12335`，数组与对象都带尾逗号）：`relay ready: 1 个代理 / 1 个监听地址`；
- 正式配置重载后 `2/2 地址可达 healthy=True`，监听 `192.168.110.1:12335` / `192.168.1.20:12335`（PID 31204）。

============================================================
十四、运行日志页拆成两个二级 tab（控制台日志 / 反代日志）
============================================================

改前：运行日志页只有一个只读框，两路日志按时间合并成一份（最新在最上），
      想只看控制台那几行（按钮点了没反应、保存报错）还得自己在里面翻找。

改后：运行日志页里嵌了一个二级 TabControl，两个页各占一个只读文本框：

  控制台日志  ->  xmcp-console.log       最近 60 条，最新在最上
  反代日志    ->  mcp-relay.log          最近 60 条，最新在最上

- 二级 tab 同样是自绘高亮（选中蓝底白字加粗），跟顶部四个 tab 一致，一眼看出停在哪一页；
- 两个框都是 Dock=Fill，窗体拉伸/最大化时自动跟着变大，不用手动重排；
- 文本框横向不换行（WordWrap=false），宽行可以左右滚动，不会被折成两行看不清；
- 切到「运行日志」页、点「刷新日志」、或切换二级 tab 都会重新读一遍两个文件；
- 底部保留三个按钮：刷新日志 / 用记事本打开反代日志 / 用记事本打开控制台日志（要全文就看记事本）。

排查口径不变：
  连不上、401/403/超时、RELAY BODY ERROR  ->  看「反代日志」
  按钮没反应、保存报错、重启耗时、启动顺序  ->  看「控制台日志」

代码位置（XMCP控制台.ps1）：
  - Get-LogTailItems：读一个日志文件，按 [yyyy-MM-dd HH:mm:ss] 抠时间戳，续行沿用上一条时间；
  - Format-LogItems：按时间降序取前 60 条，行格式 [MM-dd HH:mm:ss] msg；
  - Update-LogView：分别灌 $script:txtLogUi / $script:txtLogRelay；
  - $script:logTabs：二级 TabControl（两页），在 Update-Layout 里按客户区重排。

实测（2026-11-18 16:35）：
  - 控制台日志页：第一条是 [11-18 16:35:39] status updated: 1/1 地址可达 healthy=True took=0.7s；
  - 反代日志页：第一条是 [11-18 16:30:15] relay ready: 1 个代理 / 1 个监听地址，
    往下能看到 LISTEN [xterminal-mcp] 192.168.110.1:12335 -> 127.0.0.1:12335，
    以及早前 RELAY BODY ERROR（WinError 10053）记录；
  - 两页切换、刷新、拉伸窗体均正常，无异常弹窗。

============================================================
十五、「全选复制」按钮（底部按钮行最右）
============================================================

位置：底部按钮行的最右边，紧贴在「2. 退出关闭」右边（四按钮一行：1. 最小化 / 重启代理 / 2. 退出关闭 / 全选复制）。

作用：一次点击 = 选中当前页的全部内容 + 直接放进剪贴板，不用再 Ctrl+A / Ctrl+C。

按当前选中的页给内容：
  状态      -> 状态框里的检测结果（配置路径、代理、进程、监听、连通性、防火墙规则）
  配置格式  -> 只读样板 JSON
  配置内容  -> 编辑框里的 mcp-relay.config.json 文本（改了没保存也会被复制，便于备份）
  运行日志  -> 二级 tab 当前那一页（控制台日志 或 反代日志）

点击后：
  - 文本框里文字会高亮全选；
  - 底部提示行显示「已全选并复制 N 个字符（Ctrl+V 粘贴）。」，3 秒后自动恢复原提示；
  - 当前页没有内容时提示「当前页没有内容可复制。」，不会把剪贴板清空。

布局变化：tab 控件恢复整行宽度（窗体宽 - 24）；底部三个主按钮按等宽等距自动算宽度
（btnW = (窗体宽 - 24 - 90 - 10 - 16) / 3，间距 8px，最小 96px），三个按钮尺寸完全一致、上下左右对齐；
「全选复制」单独缩成 90x30（宽缩 30%、高度压矮，垂直居中对齐按钮行），固定在右下角，
窗口再宽也不会把退出按钮拉长。

实测（2026-11-18 16:40）：
  - 状态页点一下：剪贴板 795 字符，开头 === XMCP 反代控制台 === / 检测时间: 2026-11-18 16:40；
  - 配置格式页：剪贴板 733 字符，开头 { / "log": {；
  - 运行日志页（控制台日志二级 tab）：剪贴板 3947 字符，开头 （最新在最上 · 控制台 xmcp-console.log · 最多 60 条）；
  - 三页文字均全选高亮，无异常弹窗。
============================================================
十六、界面细节再调整（2026-11-18 下午）
============================================================

1. 默认窗体高度 +20%
   客户端区由 680x540 改为 680x648（540 * 1.2 = 648）。最小尺寸仍是 700x600，
   打开后状态页能一次看到防火墙规则，不用再拖大窗口。

2. 状态页「连通 / 不通」上色
   状态框由 TextBox 换成 RichTextBox（ReadOnly、DetectUrls=false、WordWrap=false、ScrollBars=Both）。
   每次刷新先把整段刷成黑色，再用正则 (连通|不通)(?=\r\n|\r|\n|$) 只认行尾那两个字：
     连通 -> 深绿 RGB(0,100,0)
     不通 -> 红   RGB(200,0,0)
   行中的「000=不通；401/404/200 都算连通」「下面若全部不通」这类说明文字不会被误染。
   字体：RichTextBox 的 .Font 只管新输入，已有内容按 RTF 自带字体渲染，会退回父窗体字体（看着和别的 tab 不一样），
   所以每帧都显式设一遍 SelectionFont = Consolas 9，和其它 tab 保持同一款字体。

3. 「配置格式」页把 # 注释写清楚
   顶部说明行追加：「支持 # 注释：从 # 到行尾整段忽略（字符串里的 # 不算注释）」；
   只读样板 JSON 的 { 之前新增三行注释规则（整行注释 / 行尾注释 / 字符串里的 # 原样保留），
   并在 max_bytes、enabled、两个 listen 地址、target、rewrite_host 处带行尾注释示例。

提示：RichTextBox 用 PrintWindow / CopyFromScreen 抓图会出现文字重影和偏色，这是抓图失真的，
   判断颜色和字体请看导出的 RTF（colorcheck2.rtf 里 \colortbl 与 \cfN）或离线 DrawToBitmap 对照图。
============================================================
十七、换图标（2026-11-18）
============================================================

做的三件事：
  1. 生成图标文件 xmcp.ico（圆角，多尺寸帧 256/64/48/32/16）；
  2. 控制台窗口标题栏 + 右下角托盘，都改用这个图标（原来托盘借用的是 pythonw.exe 的 Python 图标）；
  3. 在项目目录建了一个带图标的快捷方式「XMCP 反代控制台.lnk」，指向 XMCP控制台.bat。

为什么要有快捷方式：.bat 是文本批处理，Windows 资源管理器里它的图标由系统按文件类型给（齿轮/命令提示符那种），
没法通过改文件内容换掉。想换成自己的图标，标准做法就是配一个 .lnk 快捷方式，把 IconLocation 指到 xmcp.ico。
需要在桌面/开始菜单用新图标时，把「XMCP 反代控制台.lnk」拖到桌面即可（不要拖 .bat）。

代码位置：
  XMCP控制台.ps1 里 $form 创建之后
    $icoFile = Join-Path $root 'xmcp.ico'
    $script:appIcon = New-Object Drawing.Icon($icoFile)
    $form.Icon = $script:appIcon
  托盘那里优先用它：$icon = $script:appIcon（找不到才退回 pythonw 图标 -> 系统默认）。
  xmcp.ico 不存在时不会报错，窗体会用系统默认图标。

图标配色：底 #FFD100 -> #F0A800 渐变，X 为 #16181C 近黑，线条圆头、居中占 44% 边长。
要改颜色/粗细，改 make-icon.ps1 里的两个 Color::FromArgb 和 0.165 这个线宽系数，重跑一次即可重生成 ico。

实测：重启控制台，标题栏左上角已是新图标；窗口最大化后布局正常。
============================================================
十八、说明文字加灰底细边框 + 状态页内边距（2026-11-18）
============================================================

1. 三个 tab 的说明文字统一套进「灰底 + 1px 细边框」的容器
   （配置格式 / 配置内容 / 运行日志），做法是 Label 放进 Panel：
     $panel.BorderStyle = FixedSingle
     $panel.BackColor   = RGB(246,246,246)
     $panel.Padding     = 10,5,10,5
     $lbl.Dock = Fill，AutoSize = false，BackColor 与 Panel 同色
   为什么用 Panel 而不是直接给 Label 设边框：Label 不支持 Padding，文字会顶到框线上；
   Panel 能真正把文字往里推 10px，读起来不憋。

   各页高度与坐标（Update-Layout 里统一算）：
     配置格式：说明框 (6,4) 高 72（这段文字有 4 行，52 会被裁掉），样板框 y=84
     配置内容：说明框 (6,4) 高 46，当前文件行 y=58，按钮 y=54，编辑框 y=90
     运行日志：说明框 (6,4) 高 54，二级 tab y=64

2. 状态页文字不再贴边
   RichTextBox 没有 Padding 属性，用 EM_SETRECT(0x00B3) 把排版区往里收：
     左 10 / 上 8 / 右 10 / 下 8；
   窗体拉伸时在 Update-Layout 里重算一遍，每次写文字也重设一次。
   同时把 WordWrap 改成 true、滚动条改成 Vertical：长句子在框内折行，不会顶到右边框。

3. 状态页 [代理] 段改成每个监听地址一行
   原来是 `[xterminal-mcp] 192.168.110.1:12335, 192.168.1.20:12335 -> 127.0.0.1:12335 [Host改写]`，
   一行太长会被折成两半（折在 [Host改 / 写] 中间）。现在：
     [xterminal-mcp] 192.168.110.1:12335  ->  127.0.0.1:12335  [Host改写]
                     192.168.1.20:12335   ->  127.0.0.1:12335
   第二行用等宽空格缩进对齐，[Host改写] 只在第一行标一次。
============================================================
十九、新增「使用说明」「关于软件」两个 tab（2026-11-18）
============================================================

顶部由四个 tab 变六个：状态 / 配置格式 / 配置内容 / 运行日志 / 使用说明 / 关于软件。
按钮 ItemSize 仍是 96x26，六页共 576px，700 宽窗口下也放得下，不需要滚动箭头。

「使用说明」页：一整块带边框的只读阅读框（灰色 FixedSingle 边框 + 10/8 内边距），
正文六节：这套工具解决什么问题 / 本工具怎么解决 / 典型应用场景 / 怎么用（三步）/
几个容易踩的点 / 文件都在这个目录。写法是「先说痛点再说方案」，新接手的人从这一页就能上手。

「关于软件」页：版本号 1.0.0（2026-11-18）、作者 极客盟工具开发组、联系微信 xywaykie、
项目发起 叶问、适用系统、运行依赖、程序目录、界面技术、反代实现、防火墙策略、
程序特点、许可与声明、文档位置。同样用只读框，方便整段复制发出去。

配套改动：
  · 顶部提示行「顶部四个 tab 可切换」改成「六个」；
  · 「全选复制」按钮补上这两页（switch 里加 使用说明 -> $txtHelp、关于软件 -> $txtAbout），
    点一下就能把这些说明整段贴给别人；
  · Update-Layout 里两页的框都是 (6,6) 撑满整页（宽 pw-12、高 ph-12），拉伸窗口时跟着变。
============================================================
二十、标题改名 + 任务栏图标修复（2026-11-18）
============================================================

标题：'XMCP 反代控制台' -> 'XMCP 反代工具 - 极客盟技术组'（$form.Text）。
状态页首行 '=== XMCP 反代控制台 ===' 同步改成 '=== XMCP 反代工具 ==='；
单实例提示框标题也改成 'XMCP 反代工具'。

任务栏图标问题（最小化后显示 PowerShell 图标）根因与修法：
  1. 窗口是由 powershell.exe 承载的，最小化 / 成组时任务栏按钮沿用的是宿主进程的图标，
     标题栏显示的是我们设的 xmcp.ico，于是出现「还原时是 X、最小化后不是」的错觉。
  2. 修法一：进程启动时调用 shell32!SetCurrentProcessExplicitAppUserModelID
     ('GeekMeng.XMcp.RelayTool.1')，让任务栏把本程序当成独立应用，而不是 PowerShell 的一个窗口。
  3. 修法二：大小图标分开取，$icoBig = Icon(xmcp.ico, 32, 32)、$icoSmall = Icon(xmcp.ico, 16, 16)，
     再用 WM_SETICON(0x0080) 分别把 ICON_BIG(1) / ICON_SMALL(0) 塞进窗口句柄
     （Form.Icon 只设一次，两者会共用同一个尺寸，最小化时容易缩得糊）。
  4. 托盘图标改用 $icoSmall（16px），之前借用 pythonw.exe 的 Python 图标已彻底去掉。

实测：最小化后抓任务栏，按钮上就是黄底黑 X；还原后标题栏文字与图标都对。
补充（同批改动，2026-11-18）：
  · 「使用说明」扩写：不再只写 XTerminal，改为「凡是监听写死 127.0.0.1、地址改不动的
    本地 TCP 服务（MCP server / 本地 API / Web 控制台 / 调试端口）都能用本工具转发」，
    新增「三、适用范围（能转什么、不能转什么）」，明示 UDP、TLS 终结、来源 IP 校验、
    开机自启这四类不支持；xterminal-mcp-lan-relay.py 注明「名字沿用历史，逻辑通用」。
  · 「关于软件」删掉「程序发起 叶问（叶国维）」「程序目录 E:\...」两行绝对路径信息，
    改为「安装方式 绿色版、免安装：解压即用，整个目录可随意拷贝，不写注册表、不改系统设置」；
    「联系微信 xywaykie」改为「问题反馈 联系微信 xywaykie」。
  · 程序本身只用 $PSScriptRoot 定位自身文件，确实可整体搬走运行（绿色版）。
  · 「关于软件」顶部两行标题（XMCP 局域网反代控制台 / XTerminal MCP LAN Relay Console）
    合并成一行「XMCP 反代工具」，去掉英文副标题。  · 顶部提示行「双击即可：自动启动反代 + 自动检测连通性（顶部六个 tab 可切换）」整行删除，
    tab 条从 y=28 上移到 y=8，高度改为 h-104（底部按钮位置不变，多出的 20px 全给内容区）。
  · 新增 重建快捷方式.bat：换盘/换目录后双击它，会在当前目录重建「XMCP 反代工具.lnk」
    （Target / WorkingDirectory / Icon 全部用当前目录的绝对路径，%cd% 推导，不依赖旧位置）。
    旧「XMCP 反代控制台.lnk」已改名为 .lnk.old。

绿色版验证（2026-11-18）：整目录 robocopy 到 D:\_xmcp_portable_test 后运行
check-mcp-relay.ps1，输出配置路径为 D:\_xmcp_portable_test\mcp-relay.config.json，
说明所有路径都是 $PSScriptRoot / %~dp0 / os.path.dirname(__file__) 推导，换盘自动跟随；
唯一不会自动跟随的是 .lnk（快捷方式里存的是绝对路径），用 重建快捷方式.bat 重生成即可。
【重要】换目录后「配置路径没变」的真正原因（2026-11-18 实测）
  现象：目录已拷到 D:\Program Files (x86)\XMCP，双击里面的「XMCP 反代工具.lnk」，
        状态页 [配置] 仍显示老目录的 mcp-relay.config.json。
  原因：副本里的 .lnk 是从老目录原样带过来的，而快捷方式内部存的是绝对路径
        （Target / WorkingDirectory / Icon 全是老目录的绝对路径），双击它等于启动老目录那份控制台；
        程序自身的路径推导没问题（都是 $PSScriptRoot），是入口指错了。
  已加的自救：控制台启动时调用 Repair-Shortcut —— 检查同目录「XMCP 反代工具.lnk」，
        Target 不等于当前目录的 XMCP控制台.bat 就按当前目录重写（日志记
        "shortcut repaired -> ..."）。所以换目录后先双击一次 XMCP控制台.bat（或
        重建快捷方式.bat），之后 lnk 就永远对得上。
  判定方法：状态页 [配置] 那一行就是真相 —— 它显示哪个目录，就是哪份控制台在跑；
        【进程】里的 PID 与【日志】路径同样能对上。另注意单实例互斥：老副本还在跑时，
        双击新副本会弹「控制台已经在运行」，此时看到的是老窗口，不是路径没变。
【结构性修复 · 2026-11-18 18:15】换盘后「[配置] 还是老路径」的根因彻底消除
  根因：.lnk 只能存绝对路径。把整个程序目录拷贝到 D:\...、F:\... 时，目录里的
        「XMCP 反代工具.lnk」一起被带走，而它 Target 仍写着老目录的 ...\XMCP控制台.bat，
        双击它就等于启动 E 盘那份控制台 —— 程序自身路径推导没错，错的是入口。
  改法（三处，一次性解决，不再依赖记得手动重建）：
    1. 程序目录里不再放任何 .lnk（已从 E / D / F 三处删除），杜绝它跟着复制走样；
    2. 快捷方式只放桌面：桌面「XMCP 反代工具.lnk」→ 某个目录的 XMCP控制台.bat，
       由 重建快捷方式.bat 生成（内部按 %~dp0 推导当前目录）；
    3. 控制台启动时 Repair-Shortcut 检查桌面那个 lnk，Target 不是当前目录就自动改写。
       所以「用哪份程序，桌面图标就自动指向哪份」，无需人工干预。
  正确的换目录流程：新目录里双击 XMCP控制台.bat（或 重建快捷方式.bat）→ 桌面图标自动对齐
       → 以后点桌面图标即可。程序目录里的 bat 永远用 %~dp0，不会指错。
  判读方法不变：状态页 [配置] 那一行显示哪个目录，就是哪份控制台在跑。
【可分发包 · 2026-11-18 18:25】
  首次运行自举已在控制台里：Initialize-FirstRun —— mcp-relay.config.json 不存在时，
  按本机网卡地址自动生成（listen = 检测到的 IPv4:12335，firewall.local_address 同上，
  remote_address 取同网段 .0/24，虚拟网卡 / 169.254 排除，实在没有就 0.0.0.0）；
  Repair-Shortcut 同时生成目录内「XMCP 反代工具.lnk」（xmcp.ico 的 X 图标）并纠正指错的快捷方式。
  新增 -BootstrapOnly 开关：只生成配置 + 快捷方式，不弹窗、不起反代、不碰防火墙（静默初始化）。
  实测（C:\Users\Administrator\XMCP_首次运行测试，只有程序文件）：
      配置自动生成 1096 bytes，listen=192.168.1.20:12335，subnet=192.168.1.0/24；
      lnk 自动生成，Target=测试目录\XMCP控制台.bat，Icon=测试目录\xmcp.ico。
  打包分发时建议剔除：mcp-relay.config.json(+.bak)、mcp-relay.log、mcp-relay.pid、
  xmcp-console.log、xmcp-console-status.txt、firewall-state.txt、firewall-fingerprint.txt、
  relay-test*.log、「XMCP 反代工具.lnk」——这些都会在对方首次运行时重新生成。