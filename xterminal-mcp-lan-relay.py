#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MCP / HTTP 局域网反代（配置驱动，可挂多个代理）
------------------------------------------------------------
配置文件：mcp-relay.config.json（与本脚本同目录，或由环境变量
         XT_MCP_RELAY_CONFIG 指定）。
每条 proxy = 一组"对外监听地址:端口 → 上游地址:端口"，互相独立，
可以按需增加任意多个。

为什么需要这个反代（针对 XTerminal MCP）：
  XTerminal 的 MCP 服务只监听 127.0.0.1，且用 SDK 的
  localhostHostValidation 只接受 Host 为 127.0.0.1 / localhost / ::1，
  其它 Host 一律 403 Invalid Host。因此单纯的端口映射
  （netsh portproxy、路由器端口转发）都会失败，必须改写 Host。

所以配置里的 rewrite_host: true 表示"把 Host 头改写成上游地址"，
这是 XTerminal 这类本机服务必需的行为；普通 HTTP 服务可设为 false。

上游支持两种协议：
  "target": "127.0.0.1:12335"          -> 明文 HTTP（老写法，等价 http://）
  "target": "https://127.0.0.1:27124"  -> 反代自己去和上游谈 TLS
后一种是给"只开 HTTPS 的本机服务"用的（例如 Obsidian 的 Local REST API，
它的 HTTP 端口在某些版本上开不起来）。反代不校验上游证书，因为这类服务
用的都是自签证书；对外仍然是明文 HTTP，客户端不用改任何设置。

只依赖标准库，支持 SSE / Streamable HTTP 流式响应（chunked 透传）。

用法：
    C:\\Python314\\pythonw.exe xterminal-mcp-lan-relay.py
环境变量：
    XT_MCP_RELAY_CONFIG   指定配置文件路径（默认同目录 mcp-relay.config.json）
"""

import http.client
import http.server
import json
import os
import socket
import socketserver
import ssl
import sys
import threading
import time
import uuid

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.environ.get("XT_MCP_RELAY_CONFIG") or os.path.join(
    SCRIPT_DIR, "mcp-relay.config.json"
)

# 上游写 https:// 时用的 TLS 上下文。
# 这类本地服务（Obsidian 的 Local REST API 就是）清一色自签证书，
# 证书链和主机名都校验不过，只能关掉校验；链路只在同一台机器的
# 127.0.0.1 上，不存在中间人可插入的位置，关校验是安全的。
SSL_CONTEXT = ssl.create_default_context()
SSL_CONTEXT.check_hostname = False
SSL_CONTEXT.verify_mode = ssl.CERT_NONE


def strip_comments(text):
    """配置里允许 # 到行尾的注释；字符串内部的 # 不处理。换行保留，行号不变。"""
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
    """去掉 ] 或 } 前面多余的逗号（注释剥掉后常会留下这种尾巴）。"""
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

# 逐跳头，转发时丢弃
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}

# 没有配置文件时的兜底：保持老行为，只服务 XTerminal MCP
DEFAULT_CONFIG = {
    "proxies": [
        {
            "name": "xterminal-mcp",
            "enabled": True,
            "listen": [
                h.strip() + ":" + os.environ.get("XT_MCP_RELAY_PORT", "12335")
                for h in os.environ.get("XT_MCP_RELAY_LISTEN", "192.168.110.1,192.168.1.20").split(",")
                if h.strip()
            ],
            "target": "127.0.0.1:" + os.environ.get("XT_MCP_TARGET_PORT", "12335"),
            "rewrite_host": True,
            "upstream_timeout": 3600,
        }
    ]
}

_LOG_PATH = os.path.join(SCRIPT_DIR, "mcp-relay.log")
_LOG_MAX_BYTES = 5 * 1024 * 1024


def log(msg):
    line = "%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    # 1) 有控制台时同时打到控制台
    try:
        sys.stdout.write(line)
        sys.stdout.flush()
    except Exception:
        pass
    # 2) 始终写日志文件（pythonw 启动时没有控制台，只能靠这里留痕）
    try:
        if os.path.exists(_LOG_PATH) and os.path.getsize(_LOG_PATH) > _LOG_MAX_BYTES:
            os.replace(_LOG_PATH, _LOG_PATH + ".1")
        with open(_LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(line)
    except Exception:
        pass


# ---- 链路诊断日志（独立文件，只记可观测性信息，不记凭证与报文正文）----
_TRACE_PATH = os.path.join(SCRIPT_DIR, "mcp-relay-trace.log")
_TRACE_MAX_BYTES = 5 * 1024 * 1024
_TRACE_SEP = "=" * 60

# 结束原因枚举：区分客户端断开 / 上游断开 / 超时 / 下游写失败 / 正常关闭等
REASON_CLIENT_DISCONNECTED = "CLIENT_DISCONNECTED"
REASON_UPSTREAM_DISCONNECTED = "UPSTREAM_DISCONNECTED"
REASON_CONNECT_TIMEOUT = "CONNECT_TIMEOUT"
REASON_RESPONSE_TIMEOUT = "RESPONSE_TIMEOUT"
REASON_IDLE_TIMEOUT = "IDLE_TIMEOUT"
REASON_STREAM_PARSE_ERROR = "STREAM_PARSE_ERROR"
REASON_DOWNSTREAM_WRITE_ERROR = "DOWNSTREAM_WRITE_ERROR"
REASON_NORMAL_CLOSE = "NORMAL_CLOSE"
REASON_UNKNOWN_ERROR = "UNKNOWN_ERROR"


def _trace_write(line):
    """写链路日志；写失败绝不能阻塞 MCP 数据转发。"""
    try:
        if os.path.exists(_TRACE_PATH) and os.path.getsize(_TRACE_PATH) > _TRACE_MAX_BYTES:
            os.replace(_TRACE_PATH, _TRACE_PATH + ".1")
        with open(_TRACE_PATH, "a", encoding="utf-8") as fh:
            fh.write(line)
    except Exception:
        pass


def _tv(value):
    """字段值格式化：含空白/逗号就包引号，避免一行被拆乱。"""
    s = str(value)
    if any(ch in s for ch in (" ", ",", "=", ";")):
        return '"%s"' % s.replace('"', "'")
    return s


def _ms(ts, t0):
    if not ts:
        return "-"
    return "%.0f" % ((ts - t0) * 1000)


class Trace:
    """单次客户端请求的链路上下文：trace_id 贯穿接入、上游、下游交付、结束全过程。"""

    def __init__(self, proxy_name, client_addr, method, path, headers):
        self.trace_id = uuid.uuid4().hex[:12]
        self.proxy = proxy_name
        self.client = client_addr
        self.method = method
        self.path = path
        self.t0 = time.time()
        self.first_upstream_byte = None
        self.first_downstream_write = None
        self.first_sse_event = None
        self.last_activity = self.t0
        self.upstream_bytes = 0
        self.downstream_bytes = 0
        self.sse = False
        self.end_reason = REASON_UNKNOWN_ERROR
        # 请求头按大小写不敏感读取；凭证只记有无，不记真实值
        hd = {k.lower(): v for k, v in headers.items()}
        self.content_type = hd.get("content-type", "")
        self.accept = hd.get("accept", "")
        self.protocol_version = hd.get("mcp-protocol-version", "")
        self.has_session = "yes" if hd.get("mcp-session-id") else "no"
        self.auth = "present" if hd.get("authorization") else "missing"
        self._sse_tail = ""

    def _stamp(self):
        return time.strftime("%Y-%m-%d %H:%M:%S") + ".%03d" % int((time.time() % 1) * 1000)

    def event(self, kind, **fields):
        parts = ["trace=%s" % self.trace_id, "event=%s" % kind]
        for key, val in fields.items():
            if val is None or val == "":
                continue
            parts.append("%s=%s" % (key, _tv(val)))
        _trace_write("%s %s\n" % (self._stamp(), " ".join(parts)))

    def separator(self):
        """组首分隔线，带时间戳前缀（与反代日志同款），便于界面按批次分组显示。"""
        _trace_write("%s %s\n" % (self._stamp(), _TRACE_SEP))

    def touch(self):
        self.last_activity = time.time()

    def mark_upstream_bytes(self, n):
        self.upstream_bytes += n
        if self.first_upstream_byte is None and n > 0:
            self.first_upstream_byte = time.time()

    def mark_downstream_bytes(self, n):
        self.downstream_bytes += n
        if self.first_downstream_write is None and n > 0:
            self.first_downstream_write = time.time()

    def detect_sse_event(self, chunk):
        """在转发字节流里识别一个完整 SSE 事件结束（空行分隔）。

        注意：按字节流里的空行判断，不把 HTTP chunk 边界当作事件边界。
        """
        if not self.sse or self.first_sse_event is not None:
            return
        self._sse_tail = (self._sse_tail + chunk.decode("utf-8", "replace"))[-4096:]
        if "\n\n" in self._sse_tail or "\r\n\r\n" in self._sse_tail:
            self.first_sse_event = time.time()

    def finish(self, reason):
        self.end_reason = reason
        idle = "yes" if (self.sse and self.first_sse_event is None) else "no"
        self.event("END", reason=reason, up_bytes=self.upstream_bytes,
                  down_bytes=self.downstream_bytes,
                  dur_ms="%.0f" % ((time.time() - self.t0) * 1000),
                  first_up_ms=_ms(self.first_upstream_byte, self.t0),
                  first_down_ms=_ms(self.first_downstream_write, self.t0),
                  first_event_ms=_ms(self.first_sse_event, self.t0),
                  last_active_ms=_ms(self.last_activity, self.t0),
                  backpressure="n/a", idle=idle)


def parse_addr(text, field):
    """把 'host:port' 解析成 (host, port)。"""
    if not isinstance(text, str) or ":" not in text:
        raise ValueError("%s 必须是 '地址:端口' 形式，收到: %r" % (field, text))
    host, _, port_text = text.rpartition(":")
    if not host:
        raise ValueError("%s 缺少地址部分: %r" % (field, text))
    try:
        port = int(port_text)
    except ValueError:
        raise ValueError("%s 端口不是整数: %r" % (field, text))
    if not (1 <= port <= 65535):
        raise ValueError("%s 端口超出范围 1-65535: %r" % (field, text))
    return host, port


def parse_target(text, field):
    """解析上游，返回 (host, port, scheme)。scheme 是 'http' 或 'https'。

    允许三种写法：127.0.0.1:12335、http://127.0.0.1:12335、https://127.0.0.1:27124。
    不写协议就按 http（老配置一行都不用改）。上游是 TLS 时，不写 https:// 就会被
    当明文发过去，表现为"上游不回任何字节就断开"，反代只能回 502 —— 所以协议这段
    必须显式写上。
    """
    if not isinstance(text, str):
        raise ValueError("%s 必须是字符串，收到: %r" % (field, text))
    scheme = "http"
    rest = text.strip()
    for prefix, name in (("https://", "https"), ("http://", "http")):
        if rest[: len(prefix)].lower() == prefix:
            scheme = name
            rest = rest[len(prefix):]
            break
    rest = rest.split("/")[0]           # 允许顺手写个路径后缀，这里只取地址部分
    return parse_addr(rest, field) + (scheme,)


def load_config():
    """读配置并做校验，返回 (proxies, log_settings)。出错抛 ValueError。"""
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8-sig") as fh:
                raw = json.loads(sanitize(fh.read()))
        except json.JSONDecodeError as exc:
            raise ValueError("配置文件不是合法 JSON: %s (%s)" % (CONFIG_PATH, exc))
        src = CONFIG_PATH
    else:
        raw = DEFAULT_CONFIG
        src = "内置默认值（未找到 %s）" % CONFIG_PATH

    log_settings = raw.get("log") or {}
    proxies_raw = raw.get("proxies")
    if not isinstance(proxies_raw, list) or not proxies_raw:
        raise ValueError("配置里 proxies 必须是非空数组: %s" % src)

    proxies = []
    for idx, item in enumerate(proxies_raw, 1):
        if not isinstance(item, dict):
            raise ValueError("proxies[%d] 必须是对象" % idx)
        name = str(item.get("name") or "proxy-%d" % idx)
        if not item.get("enabled", True):
            log("SKIP  %s  (enabled=false)" % name)
            continue

        listen_raw = item.get("listen")
        if isinstance(listen_raw, str):
            listen_raw = [listen_raw]
        if not isinstance(listen_raw, list) or not listen_raw:
            raise ValueError("%s: listen 必须是非空数组或字符串" % name)

        listens = []
        for entry in listen_raw:
            listens.append(parse_addr(entry, "%s.listen" % name))

        target_host, target_port, target_scheme = parse_target(item.get("target"), "%s.target" % name)
        target = (target_host, target_port)

        rewrite = bool(item.get("rewrite_host", True))
        host_header = item.get("host_header")
        if host_header and not rewrite:
            raise ValueError("%s: 给了 host_header 但 rewrite_host=false，语义冲突" % name)
        if rewrite and not host_header:
            host_header = "%s:%d" % target

        timeout = item.get("upstream_timeout", 3600)
        try:
            timeout = float(timeout)
        except (TypeError, ValueError):
            raise ValueError("%s: upstream_timeout 必须是数字" % name)

        proxies.append(
            {
                "name": name,
                "listen": listens,
                "target": target,
                "target_scheme": target_scheme,
                "rewrite_host": rewrite,
                "host_header": host_header,
                "timeout": timeout,
            }
        )

    if not proxies:
        raise ValueError("所有 proxy 都是 enabled=false，没有可启动的代理")

    return proxies, log_settings, src


class RelayHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "XTMCPRelay/2.0"
    sys_version = ""
    PROXY = None  # 由 make_handler 注入

    # BaseHTTPRequestHandler 默认按 HTTP/1.0 关连接语义写日志，这里统一简化
    def log_message(self, fmt, *args):
        log("[%s:%s] %s" % (self.PROXY["name"], self.address_string(), fmt % args))

    def _read_chunked_body(self):
        """读取客户端发来的 chunked 请求体并还原为完整 bytes（MCP 请求体很小）。"""
        buf = bytearray()
        while True:
            line = self.rfile.readline(65536).strip()
            if not line:
                break
            size = int(line.split(b";")[0], 16)
            if size == 0:
                self.rfile.readline(65536)  # 吃掉结尾的空行
                break
            buf += self.rfile.read(size)
            self.rfile.read(2)  # CRLF
        return bytes(buf)

    def _relay(self):
        cfg = self.PROXY
        method = self.command
        path = self.path
        tr = Trace(cfg["name"], self.client_address[0], method, path, self.headers)

        # ---- 1. 读客户端请求体 ----
        body = None
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            body = self._read_chunked_body()
            declared_length = len(body)
        else:
            raw_len = self.headers.get("Content-Length")
            if raw_len:
                declared_length = int(raw_len)
                body = self.rfile.read(declared_length)
            else:
                declared_length = 0

        # 接入日志：只记头与有无凭证，不记 Token / Session 真值 / 报文正文
        # 每组请求开头一条分隔线，把同一次请求的 CONNECT/UPSTREAM/END 框成一组
        tr.separator()
        tr.event("CONNECT", proxy=cfg["name"], client=self.client_address[0],
                 method=method, path=path, ctype=tr.content_type, accept=tr.accept,
                 proto=tr.protocol_version, session=tr.has_session, auth=tr.auth,
                 req_bytes=declared_length)

        # ---- 2. 构造上游请求头（关键：Host 改写）----
        headers = {}
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in HOP_BY_HOP or lower == "host" or lower == "content-length":
                continue
            headers[key] = value
        if cfg["rewrite_host"]:
            headers["Host"] = cfg["host_header"]
        headers["Connection"] = "close"   # 让上游在响应结束后关连接，便于判断流结尾
        if body is not None:
            headers["Content-Length"] = str(len(body))

        # ---- 3. 请求上游 ----
        target_host, target_port = cfg["target"]
        if cfg.get("target_scheme") == "https":
            conn = http.client.HTTPSConnection(target_host, target_port, timeout=cfg["timeout"],
                                               context=SSL_CONTEXT)
        else:
            conn = http.client.HTTPConnection(target_host, target_port, timeout=cfg["timeout"])
        connect_t0 = time.time()
        try:
            conn.request(method, path, body=body, headers=headers)
            response = conn.getresponse()
        except socket.timeout as exc:
            log("UPSTREAM TIMEOUT [%s] %s %s -> %s" % (cfg["name"], method, path, exc))
            tr.finish(REASON_RESPONSE_TIMEOUT)
            payload = ('{"jsonrpc":"2.0","error":{"code":-32099,'
                       '"message":"relay upstream timeout: %s"},"id":null}' % exc).encode("utf-8")
            self.send_response_only(502, "Bad Gateway")
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                self.wfile.write(payload)
                self.wfile.flush()
            except Exception:
                pass
            conn.close()
            self.close_connection = True
            return
        except Exception as exc:  # noqa: BLE001
            log("UPSTREAM FAIL [%s] %s %s -> %s" % (cfg["name"], method, path, exc))
            tr.finish(REASON_UPSTREAM_DISCONNECTED)
            payload = ('{"jsonrpc":"2.0","error":{"code":-32099,'
                       '"message":"relay upstream unavailable: %s"},"id":null}' % exc).encode("utf-8")
            self.send_response_only(502, "Bad Gateway")
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                self.wfile.write(payload)
                self.wfile.flush()
            except Exception:
                pass
            conn.close()
            self.close_connection = True
            return

        # 上游响应日志：识别 SSE 流（200 + text/event-stream 只代表流已建立，不等于收到首帧）
        resp_ctype = response.getheader("Content-Type", "")
        resp_te = response.getheader("Transfer-Encoding", "")
        resp_cl = response.getheader("Content-Length", "")
        if "text/event-stream" in resp_ctype.lower():
            tr.sse = True
        tr.event("UPSTREAM", upstream="%s:%s" % (target_host, target_port),
                 connect_status="ok", status=response.status, ctype=resp_ctype,
                 te=resp_te or "-", cl=resp_cl or "-",
                 up_connect_ms="%.0f" % ((time.time() - connect_t0) * 1000))

        # ---- 4. 回写状态行与响应头 ----
        self.send_response_only(response.status, response.reason)
        upstream_length = response.length  # chunked 或 close-delimited 时为 None
        for key, value in response.getheaders():
            if key.lower() in HOP_BY_HOP or key.lower() == "content-length":
                continue
            self.send_header(key, value)
        if upstream_length is not None:
            self.send_header("Content-Length", str(upstream_length))
        else:
            self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        # ---- 5. 透传响应体（支持 SSE 流式）----
        chunked_to_client = upstream_length is None
        end_reason = REASON_NORMAL_CLOSE
        try:
            if method == "HEAD" or response.status in (204, 304):
                pass
            elif chunked_to_client:
                while True:
                    # 必须用 read1：read(4096) 对 chunked 流会一直凑满 4096 字节才返回，
                    # 像 subscriptions/listen 这种先回一个小 ack 帧、再挂起等事件的 SSE 长流，
                    # 首帧会卡在内部缓冲区发不出去，客户端收不到任何字节而超时。
                    # read1 只取当前可读的一块就返回，读到多少转多少。
                    data = response.read1(4096)
                    if not data:
                        break
                    tr.mark_upstream_bytes(len(data))
                    tr.detect_sse_event(data)
                    tr.touch()
                    self.wfile.write(b"%x\r\n" % len(data))
                    self.wfile.write(data)
                    self.wfile.write(b"\r\n")
                    self.wfile.flush()
                    tr.mark_downstream_bytes(len(data))
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            else:
                remaining = upstream_length
                while remaining > 0:
                    data = response.read(min(65536, remaining))
                    if not data:
                        break
                    remaining -= len(data)
                    tr.mark_upstream_bytes(len(data))
                    tr.detect_sse_event(data)
                    tr.touch()
                    self.wfile.write(data)
                    tr.mark_downstream_bytes(len(data))
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError) as exc:
            # 下游主动断开（对端关闭了连接）
            end_reason = REASON_CLIENT_DISCONNECTED
            log("CLIENT DROP [%s] %s %s -> %s" % (cfg["name"], method, path, exc))
        except socket.timeout as exc:
            # 长流静默等到超时：记 IDLE，不按业务错误处理
            end_reason = REASON_IDLE_TIMEOUT
            log("STREAM IDLE TIMEOUT [%s] %s %s -> %s" % (cfg["name"], method, path, exc))
        except OSError as exc:
            end_reason = REASON_DOWNSTREAM_WRITE_ERROR
            log("DOWNSTREAM WRITE ERROR [%s] %s %s -> %s" % (cfg["name"], method, path, exc))
        except Exception as exc:  # noqa: BLE001
            end_reason = REASON_UNKNOWN_ERROR
            log("RELAY BODY ERROR [%s] %s %s -> %s" % (cfg["name"], method, path, exc))
        finally:
            tr.finish(end_reason)
            try:
                response.close()
            except Exception:
                pass
            conn.close()

    # 所有方法统一走 _relay（MCP 用到 POST / GET / DELETE / OPTIONS）
    do_GET = _relay
    do_POST = _relay
    do_DELETE = _relay
    do_PUT = _relay
    do_PATCH = _relay
    do_HEAD = _relay
    do_OPTIONS = _relay


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        # 为什么要覆盖：http.server.HTTPServer.server_bind() 里有一步 socket.getfqdn(host)，
        # 那是反向 DNS 解析。本机 DNS 解析不通时（内网 IP 没有 PTR 记录很常见），
        # 每建一个监听地址就要卡 9 秒左右 —— 4 个地址能让"重启代理"多等近 20 秒。
        # 这里跳过反解：server_name 直接填监听地址本身，功能上没有任何影响。
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = str(host)
        self.server_port = port


def make_handler(proxy_cfg):
    return type("RelayHandler_%s" % str(proxy_cfg["name"]).replace("-", "_"),
                (RelayHandler,), {"PROXY": proxy_cfg})


def main():
    global _LOG_PATH, _LOG_MAX_BYTES

    try:
        proxies, log_settings, src = load_config()
    except ValueError as exc:
        log("FATAL: 配置错误 -> %s" % exc)
        return 3

    log_file = log_settings.get("file")
    if log_file:
        _LOG_PATH = log_file if os.path.isabs(log_file) else os.path.join(SCRIPT_DIR, log_file)
    try:
        _LOG_MAX_BYTES = int(log_settings.get("max_bytes") or _LOG_MAX_BYTES)
    except (TypeError, ValueError):
        pass

    log("=" * 60)
    log("配置文件: %s" % src)

    servers = []
    for proxy in proxies:
        for host, port in proxy["listen"]:
            try:
                srv = ThreadingHTTPServer((host, port), make_handler(proxy))
            except OSError as exc:
                log("FATAL: 无法监听 %s:%d (%s) -> %s" % (host, port, proxy["name"], exc))
                log("       端口被占用？先把占用它的程序停掉，或改配置里的 listen")
                for s in servers:
                    s.server_close()
                return 2
            servers.append((proxy, srv, host, port))
            log("LISTEN %-16s http://%s:%d  ->  %s://%s:%d%s" % (
                "[" + proxy["name"] + "]",
                host, port,
                proxy.get("target_scheme") or "http",
                proxy["target"][0], proxy["target"][1],
                ("  (Host 改写为 " + proxy["host_header"] + ")") if proxy["rewrite_host"] else "",
            ))

    if not servers:
        log("FATAL: 没有任何监听起来")
        return 4

    for _, srv, _, _ in servers:
        t = threading.Thread(target=srv.serve_forever, daemon=True)
        t.start()

    log("relay ready: %d 个代理 / %d 个监听地址" % (len(proxies), len(servers)))
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        log("收到中断，退出")
    finally:
        for _, srv, _, _ in servers:
            try:
                srv.shutdown()
                srv.server_close()
            except Exception:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
