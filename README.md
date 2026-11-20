# XMCP · 局域网反代工具

把**只监听 `127.0.0.1` 的本地服务**（MCP 服务、本地 API、IDE 插件控制台等）安全地开放给局域网里的其它机器，窗口化配置、一键启停、自动同步防火墙。

> 绿色版：解压到任意路径即可运行，不写注册表、不改系统设置，整个目录可随意拷贝。

---

## 解决什么问题

很多本地服务为了「只给本机用」，把监听地址写死成 `127.0.0.1`，有的还校验 `Host` 头必须是 `localhost`。于是：

- 虚拟机 / 另一台电脑访问不到；
- 用端口转发（`netsh portproxy`）能连上端口，却拿到 `403 Invalid Host` —— 因为 `Host` 头没改。

XMCP 就是补上这一层：**对外监听一个局域网地址和端口 → 转发到 `127.0.0.1` 的真实服务**，并按需改写 `Host` 头，让上游认为请求来自本机。

典型场景：
- XTerminal 的 MCP 服务（地址写死 `127.0.0.1:12335`、路径 `/mcp`、校验 Host）；
- Claude / Cursor 等本地 MCP server，只绑 localhost；
- 只允许本机访问的本地 API、IDE 插件的 Web 控制台。

---

## 特性

| 能力 | 说明 |
|---|---|
| 配置驱动 | 监听地址、上游地址、防火墙端口全部来自一个 JSON，加服务只改这一个文件 |
| 多代理 | 一个配置里可放多组 `listen → target`，一个 listen 可写多个地址 |
| Host 改写 | `rewrite_host: true` 时把 Host 头改写成上游的 host:port，专治 403 |
| 防火墙自适应 | 启动时按配置自动建「放行监听端口 + 屏蔽其余端口」规则，无差异则跳过 |
| 窗口控制台 | 状态 / 配置格式 / 配置内容 / 运行日志（控制台 + 反代双日志）/ 使用说明 / 关于 |
| 首次运行自举 | 没有配置文件就按本机网卡自动生成；自动生成带图标的快捷方式 |
| 绿色免安装 | 全部路径用脚本自身目录推导，换盘、换机器都不用改配置 |

---

## 快速开始

1. 装好 **Python 3**（程序会自动在常见目录与 `PATH` 里找 `pythonw` / `python`）。
2. 双击 **`XMCP控制台.bat`**。首次运行会自动完成：
   - 生成 `mcp-relay.config.json`（监听地址取本机网卡 IPv4，网段取同段 `/24`）；
   - 生成目录内的「XMCP 反代工具.lnk」（黄底黑 X 图标）；
   - 启动反代、比对防火墙（首次会弹一次 UAC，允许即可）。
3. 在控制台「配置内容」页把 `target` 改成你的服务真实端口，点「保存并重启」，看状态页连通性。

只想静默初始化（不弹窗、不起反代）：

```powershell
powershell -ExecutionPolicy Bypass -File ".\XMCP控制台.ps1" -BootstrapOnly
```

其它命令行入口（先 `cd` 到程序目录）：

```powershell
powershell -ExecutionPolicy Bypass -File ".\start-mcp-relay.ps1"     # 只起反代
powershell -ExecutionPolicy Bypass -File ".\stop-mcp-relay.ps1"      # 只停反代
powershell -ExecutionPolicy Bypass -File ".\restart-mcp-relay.ps1"   # 重启（停+启一个进程内跑完，比分别调省一次冷启动）
powershell -ExecutionPolicy Bypass -File ".\check-mcp-relay.ps1"     # 只做连通性检测
```

---

## 配置说明

`mcp-relay.config.json`（程序首次运行会自动生成一份；也可参照 `mcp-relay.config.example.json` 手写）：

```json
{
  "log": {
    "file": "mcp-relay.log",
    "max_bytes": 5242880
  },
  "firewall": {
    "enabled": true,
    "local_address": "192.168.1.10",
    "remote_address": "192.168.1.0/24"
  },
  "proxies": [
    {
      "name": "xterminal-mcp",
      "enabled": true,
      "listen": ["192.168.1.10:12335"],
      "target": "127.0.0.1:12335",
      "rewrite_host": true,
      "upstream_timeout": 3600
    }
  ]
}
```

支持 `#` 注释（`#` 到行尾整段忽略，字符串里的 `#` 不受影响）和**尾部多余逗号**，写坏了控制台会指出具体行列。

| 字段 | 作用 |
|---|---|
| `proxies[].name` | 代理名称，只用于显示 |
| `proxies[].enabled` | `false` 则不启动这一组 |
| `proxies[].listen` | 对外监听地址，`"IP:端口"`，可写多个（IPv6 用 `[::1]:端口`） |
| `proxies[].target` | 上游真实地址，通常 `127.0.0.1:端口`；上游只开 HTTPS 时写 `https://127.0.0.1:端口`（见下方「上游是 HTTPS」） |
| `proxies[].rewrite_host` | 是否把 Host 头改写为 `target`。上游校验 Host → `true`；普通按域名分发的 Web 服务 → `false`。拿不准就用「MCP探针」探一次，报告的 Host 校验一节会直接给出结论 |
| `proxies[].upstream_timeout` | 上游空闲超时（秒）。长连接类 MCP / SSE 建议调大（如 3600） |
| `log.file` / `log.max_bytes` | 反代日志文件名与单文件上限，超出自动轮转 |
| `firewall.enabled` | 是否由启动脚本自动同步 Windows 防火墙 |
| `firewall.local_address` | 监听所用的本机网卡地址（要和 `listen` 的 IP 一致） |
| `firewall.remote_address` | 只对这个网段放行，默认同网段 `/24` |

**加一个服务，4 步**：复制一段 `proxies` 项 → 改 `name` / `listen` / `target` → 需要就改 `rewrite_host` → 保存并重启。

### 上游是 HTTPS

有些本机服务只开加密端口（典型例子：Obsidian 的 Local REST API，默认 `port=27124` 是 HTTPS，
`insecurePort=27123` 那条 HTTP 服务在一些版本上根本起不来）。这种上游直接写协议前缀即可：

```json
{ "name": "obsidian-mcp", "listen": ["192.168.110.1:27124"],
  "target": "https://127.0.0.1:27124", "rewrite_host": true }
```

- 反代自己跟上游谈 TLS，**不校验证书**（这类服务清一色自签证书，校验必失败；链路只在同一台机器的
  `127.0.0.1` 上，没有中间人可插入的位置）。
- 对外仍是明文 HTTP，客户端不用装证书、不用改设置：`http://192.168.110.1:27124/`。
- 不写 `https://` 会怎样：明文打到 TLS 端口，上游一个字节都不回就断开，日志是
  `UPSTREAM FAIL ... Remote end closed connection without response`，客户端拿到 `502`。

---

## 界面

- **状态**：配置文件路径、生效的代理、进程 PID、监听端口、连通性（深绿「连通」/ 橙「上游异常」/ 红「不通」，每条下面再给一行具体原因）、防火墙规则快照。各段之间用一条横线隔开，同一段里多条代理之间也用横线分组。
- **配置格式**：带注释说明的样板，可直接抄。
- **配置内容**：内置编辑器 + 校验 + 格式化（每个键一行、2 空格缩进），保存前先验证。
- **运行日志**：二级 tab 分「控制台日志」（启停、配置读写、状态变化）与「反代日志」（每个请求的转发结果）。
- **MCP探针**：地址**必须填上游本体地址**（服务自己监听的那个，如 `http://127.0.0.1:端口/mcp`），不要填反代对你的监听地址——那层 Host 已被改写，探测结果会被门面掩盖。填好点「开始探测」：按旧规范 `initialize`（2025-11-25，有状态握手）与新规范 `server/discover`（2026-07-28，无状态）各发一发；握出会话号后再探 GET 通知流与 DELETE 会话；最后**再打一发只换 `Host` 头的变体**，用它与基线的差异判断这条链路是否必须开 `rewrite_host`。报告按真实响应给出兼容性矩阵：两条协议腿是否支持、会话能力（会话号 / GET 流 / DELETE 会话）、服务端能力（Tools / Resources / Prompts，取自初始化响应的 capabilities 声明，未逐条实际调用 `tools/list` 等验证）、Host 校验（必须开 / 未发现白名单 / 无法判定），结论分双协议 / 仅旧 / 仅新 / 需要鉴权 / 连不上 / 不确定。报告开头紧跟鉴权行写一条「探测服务端：名称 版本」，一眼看清在对谁做探测。只做探测，不改报文。

  Host 校验怎么读：

  | 基线（Host=本机名） | 变体（Host=外部地址） | 判定 |
  |---|---|---|
  | 2xx | 403 / 400 / 421 | 必须开启 `rewrite_host`，否则从局域网访问必被拒 |
  | 2xx | 2xx | 未发现 Host 白名单限制；`rewrite_host=true` 可保留，但本次测试尚未证明它必要。仅证明 Host 头未被拒绝，不验证 Origin、DNS Rebinding 与实际局域网访问；改 Host 头不等于另一台机器访问 |
  | 非 2xx | 任意 | 无法判定——基线就没通，Host 差异被遮住；先修基线的鉴权/路径 |

  变体 Host 优先取配置里对应代理的 `listen` 地址（就是你真正会用的那个），配置里没有对应代理时退化为哨兵名 `xmcp-probe.example:端口`。若地址栏填成了反代监听地址，这一节会跳过并直接写出应改填的上游本体地址。

  有的上游（Obsidian MCP 就是）用 `text/event-stream` 回包，程序会把 `data:` 帧里的 JSON 抠出来再解析，不会因为回了 SSE 就误判成"不是 MCP"。新规范那一发本来就不带会话号，只支持旧规范的服务端会先用"缺少会话"把它顶回来；这时程序用它自己的会话号补打一发（带 `Mcp-Session-Id`）作**排除性诊断**：只用于排除"第一发只是缺会话才被拒"的干扰。新规范 2026-07-28 已取消协议级会话，带旧会话号不是新规范的正确姿势，这一发结果不作为新协议兼容判定依据（判定只看不带会话号的第一发）；补打一发里的 `-32000 Unsupported protocol version` 或 `-32601 Method not found` 可佐证"上游没实现新规范"。上游的英文报错会换成中文短句（需先建会话 / 上游没实现这个方法），字母类错误码（如 `INITIALIZATION_REQUIRED`）另起一行，数字码留在主行。响应头与响应体分别落临时文件再按 UTF-8 读回，请求体以无 BOM 的 UTF-8 写临时文件：后台进程控制台可能是 GBK(936)，直接让原生程序回包流过控制台会把含中文的 JSON 按 ANSI 解码破坏，导致版本、服务端名与 capabilities 全部解析为空。

  报告里的术语都带中文：行内写成「有状态握手（Sessionful）」「会话号（Mcp-Session-Id）」「通知流（GET 长连接）」「工具（Tools）」这种，报告最底部的「名词解释」再逐条讲一遍——两套规范的区别、initialize 与 server/discover 各干什么、会话号与通知流有什么用（会话号在旧规范下也是可选的，不能单凭有无会话号判断协议版本）、capabilities 是什么、基线与变体怎么来的、`rewrite_host` 开与关分别意味着什么。

  协议兼容性那两条腿，某条不支持时错误消息常带一长串「(supported versions: 2025-11-25, 2025-06-18, ...)」。报告把这段拆成两行：主行只留「不支持的版本: 2026-07-28」，上游支持的版本列表单独缩进一行、逗号换成 ` / `，不会被挤成一条几百像素的窄行。
- **使用说明 / 关于软件**：使用说明页写应用场景、反代原理、分享与换机步骤；关于软件页给出版本、运行依赖、界面与反代实现、功能一览、同目录脚本清单、许可与声明。
- 底部：`1. 最小化`（缩到托盘）、`重启代理`、`2. 退出关闭`、`全选复制`（一键复制当前页内容）。

---

## 防火墙行为

启动时按 `firewall` 段自动比对并同步：

- 给每个 `listen` 端口在本网卡上建**放行**规则；
- 其余端口用 `TCP 1–(端口-1)`、`TCP (端口+1)–65535`、`UDP 全段`的**黑名单**封掉；
- 规则组名 `XMCP relay`，配置没变化时跳过比对（想强制重来：加 `-ForceFirewall` 或删掉 `firewall-fingerprint.txt`）。

只影响「本网卡 + 本网段」，不动你其它网卡上的规则。

---

## 适用范围与限制

能转：TCP 上的 HTTP / SSE / 长连接 MCP、只绑 localhost 的本地 API。

不能转（或转了也没意义）：
- UDP 服务；
- 需要路径重写、改响应体的场景（这里只做端口转发 + Host 改写；HTTPS 上游只是把 TLS 谈到反代这一层）；
- 服务端自己校验来源 IP / 令牌白名单（转发后源 IP 变成运行本程序的机器）；
- 需要开机自启常驻（本工具是桌面程序，不注册服务）。

---

## 常见问题

| 现象 | 含义 / 处理 |
|---|---|
| 连通性显示 `000` 不通 | 端口没应答。缩进行会写出具体原因：反代没在该地址监听（进程没起），或端口在监听但连接没建立（防火墙/地址写错） |
| 显示 `401` / `403` / `404` 但标「连通」 | **这是好事**：状态码来自上游，说明链路已打通（`401` 缺令牌、`403` 令牌不对或 Host 校验、`404` 路径不对） |
| 显示 `502` 标「上游异常」 | 反代在跑，但没拿到上游响应。缩进行会写明"上游 `127.0.0.1:x` 没有监听"（服务没开/已退出）或"在监听但不应答"（路径不对、或 HTTPS 端口写了 `http`）。常见原因见日志 `UPSTREAM FAIL ... Remote end closed connection without response` |
| `403 Invalid Host` / 上游回 `403` | 状态页那行原因会按配置实况说话：`rewrite_host` 已是 `true` 时不必再改，问题在令牌（客户端要自带 `Authorization: Bearer`）；配置里是 `false` 才需要改成 `true` 后重启代理 |
| 虚拟机连不上，宿主机自己能连 | 检查 `listen` 是否是虚拟网卡网关地址（如 VMware 的 `192.168.x.1`）、防火墙是否放行、虚拟机与宿主机是否同网段 |
| 端口被占用 / 监听没起来 | 反代进程已在跑（`mcp-relay.pid`），或另一个副本也在跑；先「2. 退出关闭」再启动 |
| 找不到 python | 装 Python 3 并勾选加入 PATH，或把 `pythonw.exe` 加到 PATH |
| 换了目录，状态页还显示老路径 | 双击的是被拷过来的旧快捷方式；先双击一次本目录的 `XMCP控制台.bat`，快捷方式会自动纠正 |
| 「重启代理」要等二十多秒 | 曾经的主因是反代给每个监听地址做反向 DNS 解析（`HTTPServer.server_bind` 里的 `socket.getfqdn`），内网 IP 没 PTR 时每个地址卡约 9 秒；现已改成跳过反解，正常 5–10 秒（详见代码注释） |

---

## 目录结构

```
XMCP控制台.bat            入口（双击即用）
XMCP控制台.ps1            窗口控制台（界面 + 配置校验 + 启停调度）
xterminal-mcp-lan-relay.py 反代主体（纯标准库，名字沿用首版场景，逻辑通用）
relay-config.ps1          配置解析（支持 # 注释、尾逗号）
start/stop/check-mcp-relay.ps1  命令行入口
restart-mcp-relay.ps1     重启（停+启合并在一个进程，省一次 powershell 冷启动）
firewall-sync.ps1         防火墙同步
validate-config.py        配置严格校验
format-config.py          配置格式化
xmcp.ico                  图标
mcp-relay.config.example.json  配置样例
重建快捷方式.bat          手动重建桌面快捷方式
```

运行时产物（首次运行自动生成，不要提交）：`mcp-relay.config.json`、`mcp-relay.log`、`mcp-relay.pid`、`xmcp-console.log`、`xmcp-console-status.txt`、`firewall-state.txt`、`firewall-fingerprint.txt`、`firewall-pending.txt`、`*.lnk`。

---

## 分享给别人

把整个目录打包（或拷 U 盘）发出去，对方解压到任意路径、双击 `XMCP控制台.bat` 即可 —— 配置、日志、快捷方式都会在他本机自动长出来。打包前建议删掉上面那些运行时产物，免得把你这台机器的网段信息带出去。

---

## 环境要求

- Windows 10 / 11（Windows PowerShell 5.1 即可，无需 PowerShell 7）
- Python 3（自动探测常见安装目录与 PATH）
- 修改防火墙规则需要管理员权限（首次会弹 UAC）

---

## 反馈

- 作者：极客盟工具开发组
- 问题反馈：微信 `xywaykie`
