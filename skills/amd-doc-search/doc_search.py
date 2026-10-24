#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""AMD 官方文档检索桥（hosted `amd-doc-search` MCP 的 stdlib 客户端）。

背景：DSH 已配置原生 MCP（serverName=amd_doc_search），但配置改动要重启 dsh web
才生效；为不打断正在跑的 prj11 构建，这里用 stdlib 直接说 MCP streamable-HTTP，
任何 agent 都能用 `py doc_search.py "<query>"` 立刻查官方文档。

协议：MCP streamable HTTP（JSON-RPC 2.0，兼容 application/json 与 text/event-stream）。
服务：https://ross.amd.com/mcp/doc-search ，唯一工具 vivado_doc_search。

用法：
  py doc_search.py "incremental implementation compile UG904"
  py doc_search.py "ILA trigger setup" --limit 3
  py doc_search.py "DDR4 MIG calibration" --family "Kintex UltraScale+" --version 2023.1
  py doc_search.py "report_methodology" --json          # 打印原始 JSON
退出码：0 成功；1 协议/网络错误；2 服务端返回 isError。
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request

URL = "https://ross.amd.com/mcp/doc-search"
PROTOCOL = "2025-06-18"
TOOL = "vivado_doc_search"
TIMEOUT = 90


class McpError(RuntimeError):
    pass


class ToolError(McpError):
    """服务端返回 isError=true（工具级失败，退出码 2）。"""


class Bridge:
    def __init__(self, url: str = URL, timeout: int = TIMEOUT) -> None:
        self.url = url
        self.timeout = timeout
        self.session_id: str | None = None
        self.protocol: str = PROTOCOL
        self.server_info: dict = {}
        self._id = 0

    # ---- transport -------------------------------------------------------
    def _post(self, payload: dict) -> tuple[dict | None, dict | None]:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Accept-Encoding": "identity",
            "MCP-Protocol-Version": self.protocol,
            "User-Agent": "dsh-amd-doc-search-bridge/1.0",
        }
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        req = urllib.request.Request(self.url, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                sid = resp.headers.get("Mcp-Session-Id")
                if sid:
                    self.session_id = sid
                raw = resp.read()
                ctype = (resp.headers.get("Content-Type") or "").lower()
                status = resp.status
        except urllib.error.HTTPError as exc:
            body = exc.read()[:2000].decode("utf-8", "replace")
            raise McpError(f"HTTP {exc.code}: {body}") from exc
        except urllib.error.URLError as exc:
            raise McpError(f"network error: {exc.reason}") from exc
        if not raw:
            return None, {"status": status, "content_type": ctype}
        text = raw.decode("utf-8", "replace")
        if "text/event-stream" in ctype or text.lstrip().startswith(("event:", "data:")):
            messages = _parse_sse(text)
        else:
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError as exc:
                raise McpError(f"non-JSON response: {text[:400]!r}") from exc
            messages = parsed if isinstance(parsed, list) else [parsed]
        return messages, {"status": status, "content_type": ctype}

    # ---- protocol --------------------------------------------------------
    def initialize(self) -> dict:
        self._id += 1
        msgs, _ = self._post(
            {
                "jsonrpc": "2.0",
                "id": self._id,
                "method": "initialize",
                "params": {
                    "protocolVersion": PROTOCOL,
                    "capabilities": {},
                    "clientInfo": {"name": "dsh-amd-doc-search-bridge", "version": "1.0.0"},
                },
            }
        )
        init = _pick(msgs, self._id)
        if init is None or "result" not in init:
            raise McpError(f"initialize failed: {init}")
        self.server_info = init["result"].get("serverInfo", {})
        self.protocol = init["result"].get("protocolVersion", PROTOCOL)
        # 通知：无 id，短暂容忍失败
        try:
            self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        except McpError:
            pass
        return self.server_info

    def call_doc_search(self, arguments: dict) -> list[str]:
        self._id += 1
        msgs, _ = self._post(
            {
                "jsonrpc": "2.0",
                "id": self._id,
                "method": "tools/call",
                "params": {"name": TOOL, "arguments": arguments},
            }
        )
        resp = _pick(msgs, self._id)
        if resp is None:
            raise McpError("no response for tools/call")
        if "error" in resp:
            raise McpError(f"tool error: {resp['error']}")
        result = resp.get("result") or {}
        if result.get("isError"):
            raise ToolError("server returned isError=true")
        texts = [
            item.get("text", "")
            for item in result.get("content", [])
            if isinstance(item, dict) and item.get("type") == "text"
        ]
        return texts


def _parse_sse(text: str) -> list[dict]:
    messages: list[dict] = []
    for event in text.replace("\r\n", "\n").split("\n\n"):
        data_lines = [ln[5:].lstrip() for ln in event.splitlines() if ln.startswith("data:")]
        if not data_lines:
            continue
        payload = "\n".join(data_lines)
        try:
            obj = json.loads(payload)
        except json.JSONDecodeError:
            continue
        messages.extend(obj if isinstance(obj, list) else [obj])
    return messages


def _pick(msgs: list[dict] | None, msg_id: int) -> dict | None:
    for msg in msgs or []:
        if msg.get("id") == msg_id:
            return msg
    return None


def build_args(ns: argparse.Namespace) -> dict:
    args: dict = {"query": ns.query, "limit": ns.limit, "alpha": ns.alpha}
    if ns.family:
        args["family"] = ns.family
    if ns.version:
        args["version"] = ns.version
    if ns.tool:
        args["tool"] = ns.tool
    return args


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="AMD hosted doc-search MCP bridge")
    ap.add_argument("query")
    ap.add_argument("--limit", type=int, default=5, help="返回块数 1-50（默认 5）")
    ap.add_argument("--alpha", type=float, default=0.8, help="0=关键词 1=语义（默认 0.8）")
    ap.add_argument("--family", action="append", help="器件系列过滤，可重复")
    ap.add_argument("--version", action="append", help="工具版本过滤，可重复，如 2023.1")
    ap.add_argument("--tool", action="append", help="工具过滤，如 'Vivado Design Suite'")
    ap.add_argument("--json", action="store_true", help="输出原始 JSON（text 内容列表）")
    ns = ap.parse_args(argv)

    started = time.time()
    bridge = Bridge()
    try:
        info = bridge.initialize()
        texts = bridge.call_doc_search(build_args(ns))
    except ToolError as exc:
        print(f"[doc_search] TOOL_ERROR: {exc}", file=sys.stderr)
        return 2
    except McpError as exc:
        print(f"[doc_search] FAILED: {exc}", file=sys.stderr)
        return 1
    elapsed = time.time() - started
    if ns.json:
        print(json.dumps({"server": info, "texts": texts}, ensure_ascii=False, indent=2))
    else:
        for i, text in enumerate(texts, 1):
            print(f"--- result block {i} ---")
            print(text.strip())
            print()
        print(
            f"[doc_search] server={info.get('name', '?')} {info.get('version', '')}"
            f" | query={ns.query!r} | blocks={len(texts)} | {elapsed:.2f}s"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
