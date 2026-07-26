# 信任闸门

信任闸门控制工具执行权限，防止 AI 无意执行危险操作。

## 三种状态

| 状态 | 含义 |
|------|------|
| `Undecided` | 未决定，需要用户确认 |
| `Trusted` | 信任，允许执行 |
| `Untrusted` | 不信任，拒绝执行 |

### Parallel vs Sequential

- **Parallel 工具**（read_file、grep、glob）：始终放行
- **Sequential 工具**（bash、write_file、edit_file）：需过闸

## 目录继承

信任具有就近继承特性：信任父目录，子目录自动继承。

```cangjie
let mgr = TrustManager()
mgr.setTrust("/home/user/project", TrustState.Trusted)
// /home/user/project/src 自动继承 Trusted
```

## session vs persistent

| 级别 | 方法 | 说明 |
|------|------|------|
| 持久 | `setTrust(path, state)` | 写入全局状态，跨会话有效 |
| 会话 | `setSessionTrust(path, state)` | 仅当前 session 有效 |

`getEffectiveTrust` 优先检查 session 级再检查持久级。

## TrustDecision

```cangjie
enum TrustDecision {
    Allowed
    NeedsApproval
    Denied
}
```

`shouldAllow(tool, workDir, trustManager)` 返回三态：
- `Allowed` — 直接执行
- `NeedsApproval` — 需用户确认（ask_user）
- `Denied` — 静默拒绝

## ask_user 交互

`NeedsApproval` 时运行时自动调用 `ask_user`，用户三选：

```
Tool 'bash' needs your approval.
  y  — allow this once (session only)
  a  — always allow this directory
  n  — deny
```

- `y` → `setSessionTrust(workDir, Trusted)`，仅本次会话
- `a` → `setTrust(workDir, Trusted)`，永久信任
- `n` → 拒绝，结果标记为"not allowed"

## REPL 命令

```bash
/trust /home/user/project     # 信任目录
/untrust /home/user/project   # 取消信任
```

## HTTP API

```bash
# 查看状态
curl -X POST http://localhost:8080/trust \
  -H "Content-Type: application/json" \
  -d '{"action":"get","path":"/home/user/project"}'

# 设置信任
curl -X POST http://localhost:8080/trust \
  -H "Content-Type: application/json" \
  -d '{"action":"set","path":"/home/user/project","trust":"trusted"}'

# 重置为未决定
curl -X POST http://localhost:8080/trust \
  -H "Content-Type: application/json" \
  -d '{"action":"reset","path":"/home/user/project"}'
```

## 钩子联动

信任检查发生在 `beforeTool` 钩子之前。即使钩子通过，信任闸门仍可拦截。
