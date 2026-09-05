#!/usr/bin/env python3
"""mini_mcp_server.py —— 最小 MCP stdio server（真实连接验证用）。

实现 initialize / notifications/initialized / tools/list / tools/call（echo_tool）。
收到 initialize 后把环境变量 TOKEN 与自身收到的消息记录到 MCP_MARKER_FILE（若设置），
供端到端断言「真实握手成功 + stdio env 注入生效」。线协议：newline-framed JSON-RPC。
"""
import json
import os
import sys

MARKER = os.environ.get("MCP_MARKER_FILE", "")
TOKEN = os.environ.get("TOKEN", "")


def mark(line):
    if MARKER:
        try:
            with open(MARKER, "a") as f:
                f.write(line + "\n")
        except Exception:
            pass


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    mark("started token=%s" % TOKEN)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        if msg.get("method") == "initialize":
            pv = (msg.get("params") or {}).get("protocolVersion", "2026-07-28")
            mark("initialize pv=%s token=%s" % (pv, TOKEN))
            send({"jsonrpc": "2.0", "id": msg.get("id"), "result": {
                "protocolVersion": pv,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "mini-mcp", "version": "0.1.0"}}})
        elif msg.get("method") == "notifications/initialized":
            mark("initialized")
        elif msg.get("method") == "tools/list":
            send({"jsonrpc": "2.0", "id": msg.get("id"), "result": {"tools": [{
                "name": "echo_tool", "description": "echo a text",
                "inputSchema": {"type": "object", "properties": {}, "required": []}}]}})
        elif msg.get("method") == "tools/call":
            send({"jsonrpc": "2.0", "id": msg.get("id"), "result": {
                "content": [{"type": "text", "text": "echo ok"}], "isError": False}})
        elif "id" in msg:
            send({"jsonrpc": "2.0", "id": msg.get("id"),
                  "error": {"code": -32601, "message": "method not found"}})
    return 0


if __name__ == "__main__":
    sys.exit(main())
