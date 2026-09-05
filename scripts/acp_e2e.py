#!/usr/bin/env python3
"""acp_e2e.py —— atelier acp（ACP v1 Agent, stdio）端到端验证 driver（离线：echo provider）。

覆盖：initialize 能力协商 / session.new(初始 configOptions) / prompt 流式 / cancel /
close / list / load 历史重放（跨进程）/ delete / set_config_option 校验。

用法：
  python3 scripts/acp_e2e.py [--atelier <bin路径>] [--delay-ms <N>]
默认查找 target/release/bin/atelier.cli；隔离 HOME 自动创建于 /tmp。
"""
import json
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ATELIER = sys.argv[sys.argv.index("--atelier") + 1] if "--atelier" in sys.argv else os.path.join(
    ROOT, "target", "release", "bin", "atelier.cli")

passed = 0
failed = 0


def check(name, cond, extra=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS {name}")
    else:
        failed += 1
        print(f"  FAIL {name} {extra}")


class AcpLineClient:
    """极简 ACP 线协议客户端：按行 JSON-RPC，自动路由通知。"""

    def __init__(self, proc):
        self.proc = proc
        self.next_id = 0
        self.notifications = []  # (method, params)
        self.pending = {}

    def send(self, method, params=None):
        self.next_id += 1
        rid = self.next_id
        msg = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        self.proc.stdin.write((json.dumps(msg) + "\n").encode("utf-8"))
        self.proc.stdin.flush()
        self.pending[rid] = method
        return rid

    def notify(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        self.proc.stdin.write((json.dumps(msg) + "\n").encode("utf-8"))
        self.proc.stdin.flush()

    def read_line(self, timeout=30):
        import select
        end = time.time() + timeout
        buf = b""
        while time.time() < end:
            r, _, _ = select.select([self.proc.stdout], [], [], 0.2)
            if r:
                ch = os.read(self.proc.stdout.fileno(), 1)
                if not ch:
                    raise EOFError("stdout closed")
                buf += ch
                if ch == b"\n":
                    return buf.decode("utf-8")
        raise TimeoutError(f"no line within {timeout}s")

    def rpc(self, method, params=None, timeout=30):
        """发送请求并等待同名响应（期间通知累积到 self.notifications）。"""
        rid = self.send(method, params)
        while True:
            line = self.read_line(timeout)
            obj = json.loads(line)
            if obj.get("method") is not None:
                self.notifications.append(obj)
                continue
            if obj.get("id") == rid:
                return obj
            # 其它请求（agent→client 反向）本 driver 不支持，忽略超时兜底

    def wait_notifications(self, session_update="agent_message_chunk", timeout=30, n=1):
        """等待收集到 n 条指定 sessionUpdate 类型的通知。"""
        seen = []
        end = time.time() + timeout
        while time.time() < end:
            for i, notif in enumerate(self.notifications):
                params = notif.get("params", {})
                if notif.get("method") == "session/update" and params.get("update", {}).get("sessionUpdate") == session_update:
                    seen.append(notif)
            if len(seen) >= n:
                return seen
            try:
                line = self.read_line(min(1, max(0.1, end - time.time())))
                obj = json.loads(line)
                if obj.get("method") is not None:
                    self.notifications.append(obj)
            except TimeoutError:
                continue
            except EOFError:
                break
        return seen

    def drain_notifications(self):
        """丢弃已累积通知（用于分段断言）。"""
        self.notifications = []


def spawn_client(env_extra=None, delay_ms=0, home=None):
    tmp = home if home else tempfile.mkdtemp(prefix="atelier-acp-e2e-")
    env = dict(os.environ)
    env["HOME"] = tmp
    env["ATELIER_PROVIDER"] = "echo"
    if delay_ms:
        env["ATELIER_ECHO_DELAY_MS"] = str(delay_ms)
    if env_extra:
        env.update(env_extra)
    proc = subprocess.Popen(
        [ATELIER, "acp"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        env=env, cwd=ROOT)
    return AcpLineClient(proc), tmp, proc


def text_block(payload):
    content = payload.get("content")
    if isinstance(content, dict):
        return content.get("text", "")
    return ""


def main():
    print("== atelier acp e2e（echo provider，离线） ==")

    # ---- 1. initialize：能力协商 ----
    c, homedir, proc = spawn_client()
    caps = {"fs": {"readTextFile": True, "writeTextFile": True},
            "session": {"configOptions": {}}}
    resp = c.rpc("initialize", {"protocolVersion": 1, "clientCapabilities": caps})
    result = resp.get("result", {})
    check("initialize ok", resp.get("error") is None and "result" in resp, str(resp.get("error")))
    check("protocol v1", result.get("protocolVersion") == 1)
    check("agentInfo", result.get("agentInfo", {}).get("name") == "atelier")
    acaps = result.get("agentCapabilities", {})
    check("loadSession cap", acaps.get("loadSession") is True)
    check("session list cap", "list" in acaps.get("sessionCapabilities", {}))
    check("session delete cap", "delete" in acaps.get("sessionCapabilities", {}))
    check("session close cap", "close" in acaps.get("sessionCapabilities", {}))
    check("session resume cap", "resume" in acaps.get("sessionCapabilities", {}))

    # ---- 2. session/new：含初始 configOptions（client 已声明） ----
    resp = c.rpc("session/new", {"cwd": "/tmp"})
    sid = resp.get("result", {}).get("sessionId", "")
    check("session/new ok", resp.get("error") is None and sid != "", str(resp.get("error")))
    opts = resp.get("result", {}).get("configOptions") or []
    check("configOptions 下发", len(opts) == 2, str(len(opts)))
    kinds = {o["id"]: o.get("type") for o in opts}
    check("model select option", kinds.get("model") == "select" and opts[0].get("category") == "model_config")
    check("compaction boolean option", kinds.get("compaction") == "boolean")

    # ---- 3. session/prompt：流式 chunk + end_turn ----
    c.drain_notifications()
    resp = c.rpc("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "第一问"}]})
    check("prompt end_turn", resp.get("result", {}).get("stopReason") == "end_turn", str(resp.get("error")))
    chunks = c.wait_notifications("agent_message_chunk", n=1)
    got = "".join(text_block(n["params"]["update"]) for n in chunks)
    check("agent_message_chunk 流式回显", got == "echo: 第一问", got)
    check("chunk 带 messageId", all(n["params"]["update"].get("messageId") for n in chunks))

    # ---- 4. session/prompt 第二回合（上下文继续） ----
    c.drain_notifications()
    resp = c.rpc("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "第二问"}]})
    check("second prompt ok", resp.get("result", {}).get("stopReason") == "end_turn")
    chunks = c.wait_notifications("agent_message_chunk", n=1)
    got = "".join(text_block(n["params"]["update"]) for n in chunks)
    check("second prompt 回显", got == "echo: 第二问", got)

    # ---- 5. set_config_option：合法切换模型 / 非法拒绝 ----
    resp = c.rpc("session/set_config_option",
                 {"sessionId": sid, "configId": "model", "type": "select", "value": "deepseek-chat"})
    res = resp.get("result")
    check("set_config_option 合法", resp.get("error") is None and res is not None and len(res.get("configOptions", [])) == 2)
    resp = c.rpc("session/set_config_option",
                 {"sessionId": sid, "configId": "model", "type": "select", "value": "not-a-real-model"})
    check("set_config_option 非法值拒绝", resp.get("error") is not None, str(resp.get("result")))
    resp = c.rpc("session/set_config_option",
                 {"sessionId": sid, "configId": "nope", "type": "select", "value": "x"})
    check("set_config_option 未知 id 拒绝", resp.get("error") is not None)

    # ---- 6. session/list ----
    resp = c.rpc("session/list", {})
    sessions = resp.get("result", {}).get("sessions", [])
    check("session/list 含本会话", any(s["sessionId"] == sid for s in sessions))

    # ---- 7. session/close：清运行态、映射保留 ----
    resp = c.rpc("session/close", {"sessionId": sid})
    check("session/close ok", resp.get("error") is None, str(resp.get("error")))
    resp = c.rpc("session/list", {})
    sessions = resp.get("result", {}).get("sessions", [])
    check("close 后 list 仍在（映射保留）", any(s["sessionId"] == sid for s in sessions))
    # 优雅退出：关闭 stdin 让 agent 正常收尾（bstorm 落盘依赖 close）
    c.proc.stdin.close()
    proc.wait(timeout=15)

    # ---- 8. 跨进程：load 历史重放 + resume + cancel + delete ----
    # 跨进程验证必须共享 HOME（映射文件与会话持久化位于同一数据目录）
    c2, homedir2, proc2 = spawn_client(home=homedir)
    c2.rpc("initialize", {"protocolVersion": 1, "clientCapabilities": caps})
    resp = c2.rpc("session/list", {})
    sessions = resp.get("result", {}).get("sessions", [])
    check("跨进程 list 恢复", any(s["sessionId"] == sid for s in sessions), str(sessions))
    # load：重放历史通知（user + assistant chunks）
    c2.drain_notifications()
    resp = c2.rpc("session/load", {"sessionId": sid, "cwd": "/tmp"})
    check("session/load ok", resp.get("error") is None, str(resp.get("error")))
    replay_user = c2.wait_notifications("user_message_chunk", n=1)
    replay_agent = c2.wait_notifications("agent_message_chunk", n=1)
    utxt = "".join(text_block(n["params"]["update"]) for n in replay_user)
    atxt = "".join(text_block(n["params"]["update"]) for n in replay_agent)
    check("load 重放历史（首轮 user）", "第一问" in utxt, utxt)
    check("load 重放历史（首轮 assistant）", "echo: 第一问" in atxt, atxt)
    # load 后 prompt 继续
    c2.drain_notifications()
    resp = c2.rpc("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "恢复后提问"}]})
    check("load 后 prompt ok", resp.get("result", {}).get("stopReason") == "end_turn")

    # resume：不重放也能继续
    c2.drain_notifications()
    resp = c2.rpc("session/resume", {"sessionId": sid, "cwd": "/tmp"})
    check("session/resume ok", resp.get("error") is None, str(resp.get("error")))
    resp = c2.rpc("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "resume 后提问"}]})
    check("resume 后 prompt ok", resp.get("result", {}).get("stopReason") == "end_turn")

    # delete：删除映射（atelier 会话一并删除）
    resp = c2.rpc("session/delete", {"sessionId": sid})
    check("session/delete ok", resp.get("error") is None, str(resp.get("error")))
    resp = c2.rpc("session/list", {})
    sessions = resp.get("result", {}).get("sessions", [])
    check("delete 后 list 为空", not any(s["sessionId"] == sid for s in sessions))
    # 已删除会话 prompt → 错误
    resp = c2.rpc("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "x"}]})
    check("已删除会话 prompt 报错", resp.get("error") is not None)
    c2.proc.stdin.close()
    proc2.wait(timeout=15)

    # ---- 9. cancel：延时回合被 session/cancel 中断（cancelled） ----
    c3, homedir3, proc3 = spawn_client(delay_ms=2500)
    c3.rpc("initialize", {"protocolVersion": 1, "clientCapabilities": caps})
    resp = c3.rpc("session/new", {"cwd": "/tmp"})
    sid3 = resp.get("result", {}).get("sessionId", "")
    check("cancel 场景 session/new ok", sid3 != "")
    c3.send("session/prompt", {"sessionId": sid3, "prompt": [{"type": "text", "text": "慢请求"}]})
    time.sleep(0.6)  # 让回合开始执行（echo delay 2.5s 未完成）
    c3.notify("session/cancel", {"sessionId": sid3})
    end = time.time() + 15
    stop = None
    while time.time() < end:
        try:
            line = c3.read_line(1)
            obj = json.loads(line)
            if obj.get("id") == c3.next_id and obj.get("method") is None:
                stop = obj.get("result", {}).get("stopReason")
                break
        except TimeoutError:
            continue
        except EOFError:
            break
    check("cancel → cancelled", stop == "cancelled", str(stop))
    c3.proc.stdin.close()
    proc3.wait(timeout=15)

    print(f"\n结果: PASS {passed} / FAIL {failed}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
