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

## 交互命令（TUI）

```bash
/trust /home/user/project     # 信任目录
/untrust /home/user/project   # 取消信任
```

## 非交互授权（headless）

TUI 之外没有回答询问的地方：`run` / `serve` 子命令（一次性端点、批处理）没有提问通道，
提问按取消处理，`NeedsApproval` 一律按拒绝处理 —— `bash` / `write_file` / `edit_file` 全部不可用。
CI、评测框架、批处理等调用方用启动期声明的环境变量显式授权：

```bash
# 冒号分隔；只认真实存在的目录；启动时置为持久信任（子目录沿父目录继承）
ATELIER_TRUST_DIR=/tmp/hb_sandbox_task1:/work/repo cli.app run "修掉这个 bug"
```

- 语义等同 TUI 里回答 `a`（`setTrust(path, Trusted)`），作用范围是所有子命令；
- 未设置该变量时行为不变（仍走交互询问）；
- 这是**启动者的授权声明**：只有拉起进程的一方能给出，Agent 自身无法自我授权；
- 传给子进程（远程子 Agent 由父进程拉起）时会随环境继承 —— 同一工作目录，语义一致。

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
